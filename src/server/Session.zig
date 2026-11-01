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
//!     notice(Notice)            optional (a sink without a pub notice()
//!                               gets none):
//!                               a warning of a statement that ran
//!
//! Or it prepares a statement (prepare(): an extended query's Parse,
//! MySQL's COM_STMT_PREPARE), describes it before it runs (its parameter
//! and result types), binds values and executes it, a number of rows at a
//! time (Prepared.execute()), reporting to a sink the same way.
//!
//! The session also keeps what the protocols report between statements:
//! whether a transaction is open, and whether it failed (PostgreSQL's
//! "aborted transaction block", Options.abort_failed_transactions).

const std = @import("std");
const xqlite = @import("xqlite");
const types = xqlite.types;
const errors = @import("errors.zig");
const command = @import("command.zig");

const Allocator = std.mem.Allocator;
const Session = @This();

gpa: Allocator,
db: xqlite.Db,
abort_failed_transactions: bool,
implicit_transactions: bool,
/// A statement failed inside the open transaction (only with
/// abort_failed_transactions; cleared when the transaction ends).
aborted: bool = false,
/// The open transaction is one the session began itself
/// (implicit_transactions), to end at the end of the script or at sync().
implicit: bool = false,
/// The columns of the statement being described.
scratch: std.heap.ArenaAllocator,
/// The declared types of the table columns described so far.
type_cache: xqlite.display.Columns,

pub const Options = struct {
    /// How to open the database; `dialect` is the client's.
    open: xqlite.OpenOptions = .{},
    /// PostgreSQL's rule: once a statement fails inside a transaction,
    /// every statement but ROLLBACK fails (in_failed_transaction) until
    /// the transaction ends, and COMMIT rolls it back. Without it, a
    /// failed statement undoes only itself, as in SQLite, MySQL and SQL
    /// Server.
    abort_failed_transactions: bool = false,
    /// PostgreSQL's implicit transaction block: outside a transaction,
    /// the statements of a script, or the prepared statements executed
    /// up to sync(), run in one transaction, which a failure rolls back
    /// (a BEGIN among them makes it the client's); and COMMIT or ROLLBACK
    /// outside a transaction is a warning (notice), not an error.
    implicit_transactions: bool = false,
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
    /// The rows the statement returned (for a prepared statement, in this
    /// execute() call).
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

/// A warning of a statement that ran (implicit_transactions: COMMIT
/// outside a transaction).
pub const Notice = struct {
    sqlstate: [5]u8,
    /// Static.
    message: []const u8,
};

/// Opened with OpenOptions.column_metadata, as every result is described.
pub fn open(gpa: Allocator, io: std.Io, path: []const u8, options: Options) xqlite.Error!Session {
    var o = options.open;
    o.column_metadata = true;
    return .{
        .gpa = gpa,
        .db = try xqlite.Db.open(gpa, io, path, o),
        .abort_failed_transactions = options.abort_failed_transactions,
        .implicit_transactions = options.implicit_transactions,
        .scratch = .init(gpa),
        .type_cache = .init(gpa),
    };
}

/// Close the prepared statements first.
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
    return if (s.db.inTransaction() and !s.implicit) .in_transaction else .idle;
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
        if (s.admit(cmd) == .refuse) return s.refuse(sink, cmd);
        var stmt = (it.next() catch return s.fail(sink, at, cmd)) orelse return s.sync(sink);
        defer stmt.finalize();
        // A single statement needs no transaction of its own.
        switch (try s.enter(&stmt, cmd, !onlyTrivia(it.rest), sink)) {
            .run => {},
            .done => continue,
            .failed => return,
        }
        if (!try s.runOne(&stmt, cmd, sink)) return s.fail(sink, at, cmd);
        s.after(cmd);
    }
}

/// Whether a statement may run in the session's state, decided before
/// compiling it (PostgreSQL does no analysis in a failed transaction):
/// in a failed transaction, only ROLLBACK runs, and COMMIT rolls back.
/// prepare() and Prepared.execute() decide so too.
pub fn admit(s: *const Session, cmd: command.Command) enum { run, refuse, roll_back } {
    if (!s.aborted) return .run;
    return switch (cmd.verb) {
        .rollback => .run,
        .commit => .roll_back,
        else => .refuse,
    };
}

/// End the implicit transaction, if one is open (implicit_transactions):
/// commit it, reporting a failure to `sink`. run() does at the end of its
/// script; a protocol calls it where its batch of prepared statements
/// ends (PostgreSQL's Sync). Executions in progress should be reset
/// first.
pub fn sync(s: *Session, sink: anytype) !void {
    if (!s.implicit) return;
    // A failure rolls back (markFailed()).
    if (s.db.inTransaction()) s.db.commit() catch return s.fail(sink, null, .{ .verb = .commit });
    s.implicit = false;
}

/// After a protocol's own failure in a statement (a value it cannot
/// encode), what a failure of the statement would do to the transaction:
/// roll back the implicit one, or mark the open one failed.
pub fn markFailed(s: *Session) void {
    if (s.implicit) {
        s.implicit = false;
        if (s.db.inTransaction()) s.db.rollback() catch {};
    } else if (s.abort_failed_transactions and s.db.inTransaction()) s.aborted = true;
}

fn refuse(s: *Session, sink: anytype, cmd: command.Command) !void {
    _ = s;
    return sink.failed(.{
        .sqlstate = errors.in_failed_transaction.*,
        .number = null,
        .code = .@"error",
        .message = "current transaction is aborted, commands ignored until end of transaction block",
        .offset = null,
        .command = cmd,
    });
}

/// What to do with a compiled statement before it runs, for the
/// transaction rules: run it, or not (`done`: reported complete; `failed`:
/// reported failed). COMMIT of a failed transaction rolls back; with
/// implicit_transactions, an implicit transaction begins (if `more`
/// statements may follow), a BEGIN in it makes it the client's, and COMMIT
/// or ROLLBACK outside a transaction is a warning.
fn enter(s: *Session, stmt: *xqlite.Stmt, cmd: command.Command, more: bool, sink: anytype) !enum { run, done, failed } {
    if (s.admit(cmd) == .roll_back) {
        // COMMIT of a failed transaction rolls it back.
        s.db.rollback() catch {
            try s.fail(sink, null, cmd);
            return .failed;
        };
        s.aborted = false;
        s.implicit = false;
        try s.completeBare(sink, .{ .verb = .rollback });
        return .done;
    }
    if (!s.implicit_transactions) return .run;
    const in_tx = s.db.inTransaction();
    switch (cmd.verb) {
        .begin => if (s.implicit) {
            s.implicit = false;
            try s.completeBare(sink, cmd);
            return .done;
        },
        .commit, .rollback => if (!in_tx and !savepointName(stmt.sql())) {
            if (std.meta.hasMethod(@TypeOf(sink), "notice")) try sink.notice(.{
                .sqlstate = "25P01".*,
                .message = "there is no transaction in progress",
            });
            try s.completeBare(sink, cmd);
            return .done;
        },
        // What cannot run in a transaction, or needs none.
        .savepoint, .release, .vacuum, .attach, .detach, .pragma, .set, .show, .use => {},
        else => if (!in_tx and more) {
            s.db.exec("BEGIN") catch {
                try s.fail(sink, null, cmd);
                return .failed;
            };
            s.implicit = true;
        },
    }
    return .run;
}

/// After a statement ran: a transaction that ended, or a ROLLBACK TO a
/// savepoint, ends the failure.
fn after(s: *Session, cmd: command.Command) void {
    if (!s.db.inTransaction()) {
        s.aborted = false;
        s.implicit = false;
    } else if (cmd.verb == .rollback) s.aborted = false;
}

fn completeBare(s: *Session, sink: anytype, cmd: command.Command) !void {
    try sink.complete(.{ .command = cmd, .rows = 0, .changes = 0, .last_insert_id = s.db.lastInsertRowid() });
}

/// Whether a COMMIT or ROLLBACK names a savepoint (ROLLBACK TO x): the
/// word TO.
fn savepointName(sql: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, sql, " \t\r\n;");
    while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, "to")) return true;
    return false;
}

/// Whether nothing but white space and semicolons is left of a script
/// (comments count as more: they cost an implicit transaction at worst).
fn onlyTrivia(rest: []const u8) bool {
    for (rest) |c| switch (c) {
        ' ', '\t', '\r', '\n', ';' => {},
        else => return false,
    };
    return true;
}

/// Run one statement: false if it failed (its error in the connection).
fn runOne(s: *Session, stmt: *xqlite.Stmt, cmd: command.Command, sink: anytype) !bool {
    var rows: u64 = 0;
    const has_row = stmt.step() catch return false;
    if (hasResult(stmt, cmd)) {
        defer _ = s.scratch.reset(.retain_capacity);
        try sink.columns(try s.describe(s.scratch.allocator(), stmt, has_row));
    } else if (has_row) {
        // A SET the dialect makes a query of (set_config()): no result.
        while (stmt.step() catch return false) {}
    }
    if (has_row and hasResult(stmt, cmd)) {
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

/// Whether a statement's rows are its result: a SET has none, though a
/// dialect may run it as a query (PostgreSQL's set_config()).
fn hasResult(stmt: *const xqlite.Stmt, cmd: command.Command) bool {
    return stmt.columnCount() > 0 and cmd.verb != .set;
}

/// Report the connection's last error for the statement at `at` (null:
/// no offset), and mark a failed transaction, or roll back the implicit
/// one.
fn fail(s: *Session, sink: anytype, at: ?usize, cmd: command.Command) !void {
    const info = s.db.lastError() orelse xqlite.ErrorInfo{ .code = .@"error", .message = "unknown error", .offset = null };
    defer s.markFailed();
    try sink.failed(.{
        .sqlstate = errors.sqlstate(info.code, info.sqlstate),
        .number = info.dialect_number,
        .code = info.code,
        .message = info.message,
        .offset = if (at) |a| if (info.offset) |o| a + o else null else null,
        .command = cmd,
    });
}

/// The result columns of `stmt`, allocated with `a`. With `has_row`, the
/// statement is on its first row, which gives the types of the
/// expressions the statement does not know; else they are `.unknown`.
fn describe(s: *Session, a: Allocator, stmt: *xqlite.Stmt, has_row: bool) ![]Column {
    const cols = try a.alloc(Column, stmt.columnCount());
    for (cols, 0..) |*c, i| {
        const declared = try s.type_cache.ofStmt(stmt, i);
        c.* = .{
            .name = try a.dupe(u8, stmt.columnName(i)),
            .origin = stmt.columnOrigin(i),
            // Copied: the connection's catalog owns it.
            .type_name = if (declared) |d| try a.dupe(u8, d.name) else null,
            .type = if (declared) |d| d.type else if (has_row) types.ofKind(stmt.columnKind(i)) else .{ .logical = .unknown },
        };
    }
    return cols;
}

// ====================================================== prepared statements

/// A statement prepared to be described, bound and executed any number of
/// times (prepare()). Protocol-neutral: PostgreSQL's prepared statements
/// and portals, MySQL's COM_STMT_PREPARE/EXECUTE.
pub const Prepared = struct {
    session: *Session,
    /// Null for SQL without a statement (an empty query).
    stmt: ?xqlite.Stmt,
    /// What the text says (classify()).
    command: command.Command,
    arena: std.heap.ArenaAllocator,
    /// The SQL, copied.
    sql: []const u8,
    /// The result columns, described before the statement runs: a table
    /// column's declared type, an expression's type as the statement
    /// gives it (engine.resultType()), else `.unknown`. Described again
    /// when a schema change has recompiled the statement (execute()).
    columns: []Column,
    /// Stmt.recompileCount() when `columns` were described.
    described_at: u32 = 0,
    /// An execution is in progress (execute() returned `.suspended`).
    running: bool = false,

    pub const Outcome = enum {
        /// Ran to its end (sink.complete()).
        complete,
        /// Returned `max_rows` rows; execute() again for more.
        suspended,
        /// Failed (sink.failed()).
        failed,
        /// No statement (an empty query): nothing reported.
        empty,
    };

    pub fn parameterCount(p: *const Prepared) usize {
        return if (p.stmt) |*st| st.parameterCount() else 0;
    }

    /// The type the statement gives parameter `i` (1-based), if it knows
    /// one (Stmt.parameterType()).
    pub fn parameterType(p: *const Prepared, i: usize) ?types.Type {
        return if (p.stmt) |*st| st.parameterType(i) else null;
    }

    /// Bind parameter `i` (1-based); the value is copied. Ends an
    /// execution in progress. The bindings stay for the next executions.
    pub fn bind(p: *Prepared, i: usize, v: xqlite.Value) xqlite.Error!void {
        const st = if (p.stmt) |*x| x else return;
        if (p.running) p.reset();
        try st.bindAt(i, v);
    }

    /// Set every parameter to NULL.
    pub fn clearBindings(p: *Prepared) void {
        const st = if (p.stmt) |*x| x else return;
        if (p.running) p.reset();
        st.clearBindings();
    }

    /// Run the statement, or go on with the execution in progress,
    /// reporting to `sink` as Session.run() does: `columns` when an
    /// execution starts, its rows, up to `max_rows` (0: all), then
    /// `complete` or `failed`. The columns are those described before it
    /// ran (`columns`, described again first if a schema change
    /// recompiled the statement), with the types of the expressions it
    /// does not know (`.unknown`) taken from its first row, as run()
    /// does; a protocol that described the result already may ignore
    /// them. The transaction rules apply as to run()'s statements
    /// (admit()). The errors are the sink's and OutOfMemory; after one
    /// the execution is ended (reset()).
    pub fn execute(p: *Prepared, max_rows: u64, sink: anytype) !Outcome {
        const s = p.session;
        const st = if (p.stmt) |*x| x else return .empty;
        errdefer p.reset();
        var has_row: bool = undefined;
        if (!p.running) {
            if (s.admit(p.command) == .refuse) {
                try s.refuse(sink, p.command);
                return .failed;
            }
            switch (try s.enter(st, p.command, true, sink)) {
                .run => {},
                .done => return .complete,
                .failed => return .failed,
            }
            p.running = true;
            has_row = st.step() catch return p.failed(sink);
            if (hasResult(st, p.command)) {
                // The schema changed since prepare() (Stmt.step()
                // recompiled it).
                if (st.recompileCount() != p.described_at) try p.describe();
                defer _ = s.scratch.reset(.retain_capacity);
                try sink.columns(try p.ofFirstRow(has_row));
            }
        } else has_row = st.step() catch return p.failed(sink);
        var rows: u64 = 0;
        var row: Row = .{ .stmt = st };
        while (has_row) {
            if (hasResult(st, p.command)) {
                try sink.row(&row);
                rows += 1;
                if (max_rows != 0 and rows == max_rows) return .suspended;
            }
            has_row = st.step() catch return p.failed(sink);
        }
        try sink.complete(.{
            .command = p.command,
            .rows = rows,
            .changes = if (st.countsChanges()) @intCast(@max(s.db.changes(), 0)) else 0,
            .last_insert_id = s.db.lastInsertRowid(),
        });
        p.reset();
        s.after(p.command);
        return .complete;
    }

    fn failed(p: *Prepared, sink: anytype) !Outcome {
        try p.session.fail(sink, 0, p.command);
        p.reset();
        return .failed;
    }

    /// Describe the result columns (again), in the arena.
    fn describe(p: *Prepared) !void {
        const st = &p.stmt.?;
        p.columns = try p.session.describe(p.arena.allocator(), st, false);
        p.described_at = st.recompileCount();
    }

    /// The columns of an execution: `columns`, those of type `.unknown`
    /// of the type of their value in the first row (a copy in the
    /// session's scratch arena), if there is one.
    fn ofFirstRow(p: *Prepared, has_row: bool) ![]const Column {
        if (!has_row) return p.columns;
        const st = &p.stmt.?;
        const unknown = for (p.columns) |c| {
            if (c.type_name == null and c.type.logical == .unknown) break true;
        } else false;
        if (!unknown) return p.columns;
        const cols = try p.session.scratch.allocator().dupe(Column, p.columns);
        for (cols, 0..) |*c, i| if (c.type_name == null and c.type.logical == .unknown) {
            c.type = types.ofKind(st.columnKind(i));
        };
        return cols;
    }

    /// End the execution in progress, if any (the bindings stay).
    pub fn reset(p: *Prepared) void {
        p.running = false;
        if (p.stmt) |*st| st.reset();
    }

    pub fn close(p: *Prepared) void {
        if (p.stmt) |*st| st.finalize();
        p.arena.deinit();
        p.session.gpa.destroy(p);
    }
};

/// Prepare the single statement `sql` (empty is allowed: Outcome.empty),
/// described before it runs. A failure (the SQL does not compile, more
/// than one statement, a failed transaction) is reported to
/// sink.failed(), and is null; it fails the transaction as a statement
/// would. The errors are the sink's and OutOfMemory. Close the result
/// with Prepared.close() before the session.
pub fn prepare(s: *Session, sql: []const u8, sink: anytype) !?*Prepared {
    const cmd = command.classify(sql);
    if (s.admit(cmd) == .refuse) {
        try s.refuse(sink, cmd);
        return null;
    }
    const p = try s.gpa.create(Prepared);
    errdefer s.gpa.destroy(p);
    p.* = .{ .session = s, .stmt = null, .command = cmd, .arena = .init(s.gpa), .sql = "", .columns = &.{} };
    errdefer p.arena.deinit();
    p.sql = try p.arena.allocator().dupe(u8, sql);
    p.stmt = s.db.prepare(sql) catch |err| switch (err) {
        error.EmptyStatement => null,
        error.OutOfMemory => return error.OutOfMemory,
        error.MultipleStatements => {
            try sink.failed(.{
                .sqlstate = "42601".*,
                .number = null,
                .code = .@"error",
                .message = "cannot insert multiple commands into a prepared statement",
                .offset = null,
                .command = cmd,
            });
            s.markFailed();
            p.arena.deinit();
            s.gpa.destroy(p);
            return null;
        },
        else => {
            try s.fail(sink, 0, cmd);
            p.arena.deinit();
            s.gpa.destroy(p);
            return null;
        },
    };
    errdefer if (p.stmt) |*st| st.finalize();
    if (p.stmt) |*st| if (hasResult(st, cmd)) try p.describe();
    return p;
}

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

    pub fn notice(l: *Log, n: Notice) !void {
        try l.out.print(testing.allocator, "notice {s} {s}\n", .{ &n.sqlstate, n.message });
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
        \\failed 23505 duplicate key value violates unique constraint "t_pkey"
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
        \\cols count:int8 ?column?:int4
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

test "run: PostgreSQL's implicit transactions" {
    if (!xqlite.Dialect.postgres.built()) return;
    var s = try Session.open(testing.allocator, testing.io, ":memory:", .{
        .open = .{ .dialect = .postgres },
        .abort_failed_transactions = true,
        .implicit_transactions = true,
    });
    defer s.close();
    try expectRun(&s, "CREATE TABLE t(id integer PRIMARY KEY)", "done CREATE TABLE rows=0 changes=0\n");
    // A failure rolls back the statements before it.
    try expectRun(&s, "INSERT INTO t VALUES(1); INSERT INTO t VALUES(1)",
        \\done INSERT rows=0 changes=1
        \\failed 23505 duplicate key value violates unique constraint "t_pkey"
        \\
    );
    try testing.expectEqual(Status.idle, s.status());
    try expectRun(&s, "SELECT count(*) FROM t", "cols count:int8\nrow 0\ndone SELECT rows=1 changes=0\n");
    // A BEGIN makes the transaction the client's.
    try expectRun(&s, "INSERT INTO t VALUES(1); BEGIN; INSERT INTO t VALUES(2)",
        \\done INSERT rows=0 changes=1
        \\done BEGIN rows=0 changes=0
        \\done INSERT rows=0 changes=1
        \\
    );
    try testing.expectEqual(Status.in_transaction, s.status());
    try expectRun(&s, "COMMIT", "done COMMIT rows=0 changes=0\n");
    // COMMIT outside a transaction: a warning.
    try expectRun(&s, "COMMIT; SELECT count(*) FROM t",
        \\notice 25P01 there is no transaction in progress
        \\done COMMIT rows=0 changes=0
        \\cols count:int8
        \\row 2
        \\done SELECT rows=1 changes=0
        \\
    );
}

test "prepare: describe, bind, execute a few rows at a time" {
    if (!xqlite.Dialect.postgres.built()) return;
    var s = try Session.open(testing.allocator, testing.io, ":memory:", .{
        .open = .{ .dialect = .postgres },
        .abort_failed_transactions = true,
        .implicit_transactions = true,
    });
    defer s.close();
    try expectRun(&s, "CREATE TABLE t(id integer, b boolean); INSERT INTO t VALUES (1, true), (2, false), (3, true)",
        \\done CREATE TABLE rows=0 changes=0
        \\done INSERT rows=0 changes=3
        \\
    );
    var log: Log = .{};
    defer log.out.deinit(testing.allocator);
    const p = (try s.prepare("SELECT id, b, id > $1 AS big FROM t WHERE id >= $1 ORDER BY id", &log)).?;
    defer p.close();
    try testing.expectEqual(@as(usize, 1), p.parameterCount());
    try testing.expectEqual(types.Logical.int4, p.parameterType(1).?.logical);
    try testing.expectEqual(@as(usize, 3), p.columns.len);
    try testing.expectEqual(types.Logical.boolean, p.columns[2].type.logical);
    try p.bind(1, .{ .integer = 1 });
    try testing.expectEqual(Prepared.Outcome.suspended, try p.execute(2, &log));
    try testing.expectEqual(Prepared.Outcome.complete, try p.execute(2, &log));
    try s.sync(&log);
    try p.bind(1, .{ .integer = 3 });
    try testing.expectEqual(Prepared.Outcome.complete, try p.execute(0, &log));
    try testing.expectEqualStrings(
        \\cols id:int4 b:boolean big:boolean
        \\row 1 1 0
        \\row 2 0 1
        \\row 3 1 1
        \\done SELECT rows=1 changes=0
        \\cols id:int4 b:boolean big:boolean
        \\row 3 1 0
        \\done SELECT rows=1 changes=0
        \\
    , log.out.items);
    log.out.clearRetainingCapacity();

    // Failures: two statements, SQL that does not compile; an empty one.
    try testing.expect(try s.prepare("SELECT 1; SELECT 2", &log) == null);
    try testing.expect(try s.prepare("SELECT * FROM nope", &log) == null);
    const empty = (try s.prepare(" ", &log)).?;
    defer empty.close();
    try testing.expectEqual(Prepared.Outcome.empty, try empty.execute(0, &log));
    try testing.expectEqualStrings(
        \\failed 42601 cannot insert multiple commands into a prepared statement
        \\failed 42P01 relation "nope" does not exist
        \\
    , log.out.items);
    log.out.clearRetainingCapacity();

    // In a failed transaction only ROLLBACK prepares and runs.
    try expectRun(&s, "BEGIN; SELECT * FROM nope",
        \\done BEGIN rows=0 changes=0
        \\failed 42P01 relation "nope" does not exist
        \\
    );
    try testing.expect(try s.prepare("SELECT 1", &log) == null);
    try testing.expectEqual(Prepared.Outcome.failed, try p.execute(0, &log));
    const rb = (try s.prepare("ROLLBACK", &log)).?;
    defer rb.close();
    try testing.expectEqual(Prepared.Outcome.complete, try rb.execute(0, &log));
    try testing.expectEqual(Status.idle, s.status());
    try testing.expectEqualStrings(
        \\failed 25P02 current transaction is aborted, commands ignored until end of transaction block
        \\failed 25P02 current transaction is aborted, commands ignored until end of transaction block
        \\done ROLLBACK rows=0 changes=0
        \\
    , log.out.items);
}

test "prepare: described again after a schema change, unknown types from the first row" {
    var s = try Session.open(testing.allocator, testing.io, ":memory:", .{});
    defer s.close();
    try expectRun(&s, "CREATE TABLE t(a INT); INSERT INTO t VALUES (1)",
        \\done CREATE TABLE rows=0 changes=0
        \\done INSERT rows=0 changes=1
        \\
    );
    var log: Log = .{};
    defer log.out.deinit(testing.allocator);
    const p = (try s.prepare("SELECT *, a + 0.5 AS h FROM t", &log)).?;
    defer p.close();
    // SQLite's dialect types no expression: unknown until a row says.
    try testing.expectEqual(types.Logical.unknown, p.columns[1].type.logical);
    try testing.expectEqual(Prepared.Outcome.complete, try p.execute(0, &log));
    try expectRun(&s, "ALTER TABLE t ADD COLUMN b TEXT", "done ALTER TABLE rows=0 changes=0\n");
    try testing.expectEqual(Prepared.Outcome.complete, try p.execute(0, &log));
    try testing.expectEqual(@as(usize, 3), p.columns.len);
    try testing.expectEqualStrings(
        \\cols a:int8 h:float8
        \\row 1 1.5
        \\done SELECT rows=1 changes=0
        \\cols a:int8 b:text h:float8
        \\row 1 NULL 1.5
        \\done SELECT rows=1 changes=0
        \\
    , log.out.items);
}
