//! A database connection (sqlite3*): the entry point of the Zig API.
//!
//!     var db = try xqlite.Db.open(gpa, io, "app.db", .{});
//!     defer db.close();
//!     try db.exec("CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v)");
//!     try db.execArgs("INSERT INTO kv VALUES(?, ?)", .{ "answer", 42 });
//!     const v = try db.one(i64, "SELECT v FROM kv WHERE k = ?", .{"answer"});
//!
//! Memory, in short: `gpa` (given to open()) holds what the API layer
//! allocates, the engine's own memory comes from the library allocator
//! (`xqlite.malloc.configMalloc()`), and memory returned to the caller
//! comes from an allocator the caller passes. A `Db` is a small value
//! that may be moved, but closed once. See docs/zig-api.md ("연결과
//! 메모리") for the details.

const std = @import("std");
const engine = @import("engine.zig");
const errors = @import("errors.zig");
const value = @import("value.zig");
const func = @import("func.zig");
const module = @import("module.zig");
const Conn = @import("conn.zig").Conn;
const Stmt = @import("Stmt.zig");
const MemVfs = engine.MemVfs;
const OsVfs = engine.OsVfs;

const Allocator = std.mem.Allocator;
const Error = errors.Error;
const Db = @This();

conn: Conn,
gpa: Allocator,
/// The VFS object of `.unix` and `.memory` connections.
owned_vfs: ?*OwnedVfs,

const OwnedVfs = union(enum) {
    unix: OsVfs,
    memory: MemVfs,
};

/// Where the database files live.
pub const VfsOption = union(enum) {
    /// The operating system's file system: the POSIX VFS, or on
    /// WebAssembly the WASI VFS (wasm32-wasi) or the host's files
    /// (wasm32-freestanding, docs/wasm.md).
    unix,
    /// A private in-memory file system that belongs to this connection:
    /// a named database (and its journal or WAL) lives in RAM and
    /// disappears on close.
    memory,
    /// A VFS of the caller (e.g. `MemVfs.interface()` shared by several
    /// connections, or a crash-testing wrapper). It must outlive the
    /// connection.
    custom: engine.Vfs,
};

/// PRAGMA journal_mode values (the engine's).
pub const JournalMode = engine.JournalMode;

/// The SQL dialects (src/dialect/dialect.zig).
pub const Dialect = engine.Dialect;

pub const OpenOptions = struct {
    /// Open for reading only (SQLITE_OPEN_READONLY).
    read_only: bool = false,
    /// Create the file if it does not exist (SQLITE_OPEN_CREATE). Ignored
    /// with `read_only`.
    create: bool = true,
    vfs: VfsOption = .unix,
    /// Set the journal mode after opening (PRAGMA journal_mode). If the
    /// engine settles on another mode (a :memory: database cannot use
    /// WAL), open() fails with error.UnsupportedJournalMode.
    journal_mode: ?JournalMode = null,
    /// Retry for up to this many milliseconds when the database is locked
    /// by another connection (sqlite3_busy_timeout()); 0 fails at once
    /// with error.Busy.
    busy_timeout_ms: u31 = 0,
    /// Enforce foreign key constraints (PRAGMA foreign_keys).
    foreign_keys: bool = false,
    /// Record where each result column comes from while compiling, so
    /// that Stmt.columnOrigin() and columnTypeAlloc() cost nothing more
    /// (else the first call compiles the statement again): for a caller
    /// that describes every result, as a wire protocol server does.
    column_metadata: bool = false,
    /// The SQL dialect of the connection (setDialect()).
    dialect: Dialect = .sqlite,
    /// Receives the details of every failed call on this connection,
    /// including open() itself. Must outlive the connection.
    diagnostics: ?*errors.Diagnostics = null,
};

/// Open a connection to the database file `path`; ":memory:" or "" opens
/// a private, temporary in-memory database. Close it with close().
pub fn open(gpa: Allocator, io: std.Io, path: []const u8, options: OpenOptions) Error!Db {
    var owned: ?*OwnedVfs = null;
    errdefer if (owned) |o| destroyVfs(gpa, o);
    const v: engine.Vfs = switch (options.vfs) {
        .custom => |c| c,
        .unix => blk: {
            const o = try gpa.create(OwnedVfs);
            o.* = .{ .unix = OsVfs.init(gpa, io) };
            owned = o;
            break :blk o.unix.interface();
        },
        .memory => blk: {
            const o = try gpa.create(OwnedVfs);
            o.* = .{ .memory = MemVfs.init(gpa, io) };
            owned = o;
            break :blk o.memory.interface();
        },
    };

    var h: ?*engine.Handle = null;
    engine.open(v, path, .{ .read_only = options.read_only, .create = options.create }, &h) catch |err| {
        // Without a connection object (out of memory), there is no
        // connection to record the error in.
        const handle = h orelse {
            const code = engine.errorCode(err);
            if (options.diagnostics) |d| d.set(errors.fromEngine(err), .of(code), engine.errStr(code), null);
            return errors.fromEngine(err);
        };
        const e = (Conn{ .h = handle, .diag = options.diagnostics }).fail(err);
        engine.close(handle) catch {};
        return e;
    };
    var db: Db = .{ .conn = .{ .h = h.?, .diag = options.diagnostics }, .gpa = gpa, .owned_vfs = owned };
    errdefer engine.close(db.conn.h) catch {};
    if (options.busy_timeout_ms > 0) engine.busyTimeout(db.conn.h, options.busy_timeout_ms);
    if (options.foreign_keys) engine.setForeignKeys(db.conn.h, true);
    if (options.column_metadata) engine.setColumnMetadata(db.conn.h, true);
    if (options.dialect != .sqlite) engine.setDialect(db.conn.h, options.dialect);
    if (options.journal_mode) |mode| try db.setJournalMode(mode);
    return db;
}

fn destroyVfs(gpa: Allocator, o: *OwnedVfs) void {
    switch (o.*) {
        .memory => |*m| m.deinit(),
        .unix => {},
    }
    gpa.destroy(o);
}

/// Close the connection. Every statement must have been finalized: in
/// safe builds, an unfinalized statement is a panic (as a leak would be);
/// use tryClose() to handle it instead.
pub fn close(db: *Db) void {
    db.tryClose() catch |err| {
        if (std.debug.runtime_safety) std.debug.panic("xqlite: Db.close(): {s}: {s}", .{ @errorName(err), engine.errmsg(db.conn.h) });
    };
}

/// Close the connection, or fail with error.Busy (leaving it open) if
/// statements are still unfinalized.
pub fn tryClose(db: *Db) Error!void {
    try db.conn.check(engine.close(db.conn.h));
    if (db.owned_vfs) |o| destroyVfs(db.gpa, o);
    db.* = undefined;
}

/// Run every statement of `sql`, discarding any result rows
/// (sqlite3_exec()). For SQL with parameters use execArgs().
pub fn exec(db: *Db, sql: []const u8) Error!void {
    return db.conn.check(engine.exec(db.conn.h, sql));
}

/// Run the single statement `sql` with `args` bound (see Stmt.bind()),
/// discarding any result rows. The statement is prepared for each call:
/// to run it many times, prepare() it once and use Stmt.exec().
pub fn execArgs(db: *Db, sql: []const u8, args: anytype) Error!void {
    var s = try db.prepare(sql);
    defer s.finalize();
    try s.exec(args);
}

/// Compile the single statement `sql` (sqlite3_prepare_v2()). Trailing
/// white space, comments and semicolons are allowed; a second statement
/// is error.MultipleStatements, and SQL without any statement is
/// error.EmptyStatement. Finalize the result with Stmt.finalize().
pub fn prepare(db: *Db, sql: []const u8) Error!Stmt {
    var tail: []const u8 = "";
    const v = (try db.conn.check(engine.prepare(db.conn.h, sql, &tail))) orelse
        return db.conn.usage(error.EmptyStatement, "prepare: no SQL statement in the text", .{});
    const trivia = engine.onlyTrivia(db.gpa, tail) catch {
        engine.finalize(v);
        return db.conn.outOfMemory();
    };
    if (!trivia) {
        engine.finalize(v);
        return db.conn.usage(error.MultipleStatements, "prepare: more than one statement; use exec() for scripts", .{});
    }
    return .{ .vm = v, .conn = db.conn };
}

/// The statements of the script `sql`, compiled one at a time, for a
/// caller that wants the results of each (exec() runs a script without
/// results):
///
///     var it = try db.script(sql);
///     defer it.deinit();
///     while (try it.next()) |stmt_| {
///         var stmt = stmt_;
///         defer stmt.finalize();
///         while (try stmt.step()) { ... }
///     }
///
/// Each statement is compiled when next() reaches it, so it sees the
/// schema the ones before it left. The text is copied once (the parser
/// reads NUL-terminated text) and parsed in place.
pub fn script(db: *Db, sql: []const u8) Error!Script {
    const copy = db.gpa.dupeSentinel(u8, sql, 0) catch return db.conn.outOfMemory();
    return .{ .conn = db.conn, .gpa = db.gpa, .copy = copy, .rest = copy };
}

pub const Script = struct {
    conn: Conn,
    gpa: Allocator,
    copy: [:0]u8,
    /// The text after the statement next() returned last (as long as
    /// what is left of the caller's text).
    rest: [:0]const u8,

    pub fn deinit(s: *Script) void {
        s.gpa.free(s.copy);
        s.* = undefined;
    }

    /// The next statement (sqlite3_prepare_v2() of the rest of the
    /// text), or null at the end. Finalize it with Stmt.finalize().
    pub fn next(s: *Script) Error!?Stmt {
        while (s.rest.len > 0) {
            var tail: [:0]const u8 = "";
            const v = try s.conn.check(engine.prepareZ(s.conn.h, s.rest, &tail));
            // No statement but text left: an empty statement (";") or
            // comments, as sqlite3_exec() skips them.
            const progressed = tail.len < s.rest.len;
            s.rest = tail;
            if (v) |vm| return .{ .vm = vm, .conn = s.conn };
            if (!progressed) break;
        }
        s.rest = "";
        return null;
    }
};

/// Run `sql` with `args` and return the first row as `T` (see
/// Stmt.row()), or null if there is none. `T` may not borrow text or
/// blobs, which would not outlive the statement: use oneAlloc() for those.
/// Like execArgs(), it prepares `sql` on each call: in a loop, hold a
/// Stmt instead.
pub fn one(db: *Db, comptime T: type, sql: []const u8, args: anytype) Error!?T {
    if (comptime value.borrows(T)) @compileError("xqlite: one(" ++ @typeName(T) ++ ") would return text or blobs freed with the statement; use oneAlloc()");
    var s = try db.prepare(sql);
    defer s.finalize();
    try s.bind(args);
    if (!try s.step()) return null;
    return try s.row(T);
}

/// one() with text and blobs copied with `gpa`. Free the result with
/// `xqlite.free(gpa, row)`. Prepares `sql` on each call, as one().
pub fn oneAlloc(db: *Db, comptime T: type, gpa: Allocator, sql: []const u8, args: anytype) Error!?T {
    var s = try db.prepare(sql);
    defer s.finalize();
    try s.bind(args);
    if (!try s.step()) return null;
    return try s.rowAlloc(T, gpa);
}

/// Run `sql` with `args` and return every row as `T`, copied with `gpa`.
/// Free the result with `xqlite.free(gpa, row)` for each row, then
/// `gpa.free(rows)` (or use an arena). Prepares `sql` on each call, as
/// one().
pub fn all(db: *Db, comptime T: type, gpa: Allocator, sql: []const u8, args: anytype) Error![]T {
    var s = try db.prepare(sql);
    defer s.finalize();
    try s.bind(args);
    var rows: std.ArrayList(T) = .empty;
    errdefer {
        for (rows.items) |r| value.free(gpa, r);
        rows.deinit(gpa);
    }
    var it = s.iterator(T);
    while (try it.nextAlloc(gpa)) |r| {
        rows.append(gpa, r) catch |e| {
            value.free(gpa, r);
            return e;
        };
    }
    return rows.toOwnedSlice(gpa);
}

// ========================================================== transactions

/// The kind of BEGIN.
pub const TransactionMode = enum {
    /// Locks are taken when first needed (BEGIN DEFERRED).
    deferred,
    /// Take the write lock now (BEGIN IMMEDIATE).
    immediate,
    /// BEGIN EXCLUSIVE.
    exclusive,
};

/// BEGIN a transaction.
pub fn begin(db: *Db, mode: TransactionMode) Error!void {
    return db.exec(switch (mode) {
        .deferred => "BEGIN DEFERRED",
        .immediate => "BEGIN IMMEDIATE",
        .exclusive => "BEGIN EXCLUSIVE",
    });
}

/// COMMIT the transaction.
pub fn commit(db: *Db) Error!void {
    return db.exec("COMMIT");
}

/// ROLLBACK the transaction.
pub fn rollback(db: *Db) Error!void {
    return db.exec("ROLLBACK");
}

/// Roll back if a transaction is open, keeping the error that caused it
/// as the connection's last error.
fn rollbackKeepingError(db: *Db) void {
    if (engine.autocommit(db.conn.h)) return;
    const saved = db.conn.saveError();
    defer saved.restore();
    engine.exec(db.conn.h, "ROLLBACK") catch {};
}

/// The error union returned by transaction(f, ...).
fn TransactionResult(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type orelse @compileError("xqlite: transaction() needs a function with a known return type");
    return switch (@typeInfo(R)) {
        .error_union => |eu| (Error || eu.error_set)!eu.payload,
        else => Error!R,
    };
}

/// Run `f` with `args` (a tuple) in a transaction: BEGIN, then COMMIT if
/// `f` succeeds, or ROLLBACK if it returns an error, which is returned.
/// If COMMIT fails the transaction is rolled back too. The connection's
/// last error (and Diagnostics) still describe the original failure
/// after the rollback.
///
/// Inside an open transaction (a nested call) it uses a SAVEPOINT
/// instead, so that only the work of `f` is undone, and `mode` is
/// ignored. Transactions written with transaction() thus compose.
///
///     try db.transaction(.immediate, transfer, .{ &db, from, to, amount });
pub fn transaction(db: *Db, mode: TransactionMode, comptime f: anytype, args: anytype) TransactionResult(@TypeOf(f)) {
    if (db.inTransaction()) {
        var sp = try db.savepoint("xqlite_transaction");
        return runAndFinish(f, args, &sp, Savepoint.release, Savepoint.rollback);
    }
    try db.begin(mode);
    return runAndFinish(f, args, db, commit, rollbackKeepingError);
}

/// Call `f` with `args`, then `finish(target)` (COMMIT or RELEASE); if
/// either fails, `undo(target)` (ROLLBACK) and return the error.
fn runAndFinish(comptime f: anytype, args: anytype, target: anytype, comptime finish: anytype, comptime undo: anytype) TransactionResult(@TypeOf(f)) {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const result = if (@typeInfo(R) == .error_union)
        @call(.auto, f, args) catch |err| {
            undo(target);
            return err;
        }
    else
        @call(.auto, f, args);
    finish(target) catch |err| {
        undo(target);
        return err;
    };
    return result;
}

/// Longest savepoint name savepoint() accepts.
pub const max_savepoint_name = 64;

/// A SAVEPOINT: a named, nestable transaction. Finish it with release()
/// or rollback(); the usual pattern is
///
///     var sp = try db.savepoint("batch");
///     errdefer sp.rollback();
///     ...
///     try sp.release();
pub const Savepoint = struct {
    conn: Conn,
    name_buf: [max_savepoint_name]u8,
    name_len: usize,

    pub fn name(sp: *const Savepoint) []const u8 {
        return sp.name_buf[0..sp.name_len];
    }

    fn run(sp: *const Savepoint, comptime verb: []const u8, conn: Conn) Error!void {
        // The name quoted as an identifier (%w doubles any '"'). The
        // buffer holds any name; only the temporary buffer of a long one
        // is allocated.
        var buf: [verb.len + 4 + 2 * max_savepoint_name]u8 = undefined;
        const sql = engine.printSql(engine.connAllocator(conn.h), &buf, verb ++ " \"%w\"", &.{.{ .str = sp.name() }}) orelse
            return conn.outOfMemory();
        return conn.check(engine.exec(conn.h, sql));
    }

    /// RELEASE the savepoint, keeping its changes (committing them if it
    /// is the outermost transaction).
    pub fn release(sp: *Savepoint) Error!void {
        try sp.run("RELEASE", sp.conn);
    }

    /// ROLLBACK TO the savepoint and RELEASE it, undoing its changes. The
    /// connection's last error is left as it was, so that it is safe in
    /// errdefer.
    pub fn rollback(sp: *Savepoint) void {
        const saved = sp.conn.saveError();
        defer saved.restore();
        sp.run("ROLLBACK TO", sp.conn.quiet()) catch {};
        sp.run("RELEASE", sp.conn.quiet()) catch {};
    }
};

/// Start SAVEPOINT `name` (copied; at most max_savepoint_name bytes).
pub fn savepoint(db: *Db, name: []const u8) Error!Savepoint {
    if (name.len > max_savepoint_name) {
        return db.conn.usage(error.NameTooLong, "savepoint name longer than {d} bytes", .{max_savepoint_name});
    }
    var sp: Savepoint = .{ .conn = db.conn, .name_buf = undefined, .name_len = name.len };
    @memcpy(sp.name_buf[0..name.len], name);
    try sp.run("SAVEPOINT", db.conn);
    return sp;
}

// ================================================================ backup

/// An online backup (sqlite3_backup): copies a database into another
/// one page by page, see backup(). The usual pattern is
///
///     var b = try dest.backup("main", &src, "main");
///     defer b.finish() catch {};
///     while (!try b.step(100)) {}
///
/// or step(null) to copy everything at once.
pub const Backup = struct {
    /// The destination connection, which reports the errors.
    conn: Conn,
    b: *engine.BackupHandle,

    /// Copy up to `n_page` more pages, all of them if null. True once
    /// the copy is complete and committed to the destination. error.Busy
    /// and error.Locked (the source is being written, or the destination
    /// is locked by another connection) leave the backup to be tried
    /// again; other errors end it.
    pub fn step(self: *Backup, n_page: ?u31) Error!bool {
        return self.conn.check(engine.backupStep(self.b, self.conn.h, if (n_page) |n| n else -1));
    }

    /// Pages left to copy, as of the last step().
    pub fn remaining(self: *const Backup) u32 {
        return engine.backupRemaining(self.b);
    }

    /// Pages of the source, as of the last step().
    pub fn pageCount(self: *const Backup) u32 {
        return engine.backupPagecount(self.b);
    }

    /// End the backup and free it, rolling back the destination if the
    /// copy is not complete. The error, if any, is the one that ended the
    /// backup.
    pub fn finish(self: *Backup) Error!void {
        const conn = self.conn;
        const b = self.b;
        self.* = undefined;
        return conn.check(engine.backupFinish(b));
    }
};

/// Start copying database `src_name` ("main", "temp" or an attached
/// name) of `src` into database `dest_name` of `db` (sqlite3_backup_init()).
/// The two connections must differ, and no transaction may be open on the
/// destination. While the backup runs, the source can be read and written
/// (pages changed after they were copied are copied again), but neither
/// connection may close until finish().
pub fn backup(db: *Db, dest_name: []const u8, src: *Db, src_name: []const u8) Error!Backup {
    const b = try db.conn.check(engine.backupInit(db.conn.h, dest_name, src.conn.h, src_name));
    return .{ .conn = db.conn, .b = b };
}

// ================================================================= blobs

/// Incremental I/O on one value of a table (sqlite3_blob): reads and
/// writes go straight to the row, without SQL, see openBlob(). A write
/// cannot change the size of the value (set it with zeroblob(N) first),
/// fires no trigger and does not count in changes(). When the row is
/// changed or deleted by anything else, the blob expires: its calls fail
/// with error.Abort (bytes() is 0) until reopen() or close().
pub const BlobHandle = struct {
    conn: Conn,
    b: *engine.BlobHandle,

    /// The size of the value in bytes; 0 once the blob has expired.
    pub fn bytes(self: *const BlobHandle) u32 {
        return @intCast(engine.blobBytes(self.b));
    }

    /// Read `buf.len` bytes from `offset`. Reading past the end is
    /// error.Sql.
    pub fn read(self: *BlobHandle, buf: []u8, offset: u32) Error!void {
        return self.conn.check(engine.blobRead(self.b, buf, std.math.cast(i32, offset) orelse std.math.maxInt(i32)));
    }

    /// Overwrite `data.len` bytes at `offset` (error.ReadOnly if the blob
    /// was not opened writable, error.Sql past the end).
    pub fn write(self: *BlobHandle, data: []const u8, offset: u32) Error!void {
        return self.conn.check(engine.blobWrite(self.b, data, std.math.cast(i32, offset) orelse std.math.maxInt(i32)));
    }

    /// Move to the same column of row `rowid` of the same table. On
    /// error the blob expires.
    pub fn reopen(self: *BlobHandle, rowid: i64) Error!void {
        return self.conn.check(engine.blobReopen(self.b, rowid));
    }

    /// Close the blob, ending the transaction it opened if there was
    /// none.
    pub fn close(self: *BlobHandle) Error!void {
        const conn = self.conn;
        const b = self.b;
        self.* = undefined;
        return conn.check(engine.blobClose(b));
    }
};

/// Open the value of column `column` in row `rowid` of table `table` of
/// database `database` ("main" if null, "temp" or an attached name) for
/// incremental I/O (sqlite3_blob_open()), read-only or `writable`. The
/// value must be a BLOB or TEXT. A writable blob cannot be on an indexed
/// column (nor, with foreign keys on, on a foreign key column). An open
/// blob is a running statement: the connection cannot close until the
/// blob is closed.
pub fn openBlob(db: *Db, database: ?[]const u8, table: []const u8, column: []const u8, rowid: i64, writable: bool) Error!BlobHandle {
    const b = try db.conn.check(engine.blobOpen(db.conn.h, database, table, column, rowid, writable));
    return .{ .conn = db.conn, .b = b };
}

// ========================================================= serialization

/// The content of database `schema` ("main", "temp" or an attached
/// name) as one block of bytes, a database file image
/// (sqlite3_serialize()), allocated with `gpa`. error.NotFound if there
/// is no such database.
pub fn serialize(db: *Db, gpa: Allocator, schema: []const u8) Error![]u8 {
    const lib = try db.conn.check(engine.serialize(db.conn.h, schema));
    defer engine.libFree(lib);
    return gpa.dupe(u8, lib);
}

/// Replace database `schema` ("main" or an attached name, not "temp")
/// with an in-memory database (the memdb VFS) holding a copy of
/// `image`, a database file image such as serialize() returns
/// (sqlite3_deserialize()). It grows as written unless `read_only`.
/// No transaction may be open on it (error.Busy).
pub fn deserialize(db: *Db, schema: []const u8, image: []const u8, read_only: bool) Error!void {
    return db.conn.check(engine.deserialize(db.conn.h, schema, image, read_only));
}

/// Whether a transaction is open (not sqlite3_get_autocommit()).
pub fn inTransaction(db: *const Db) bool {
    return !engine.autocommit(db.conn.h);
}

// ================================================================ status

/// The rowid of the last successful INSERT (sqlite3_last_insert_rowid()).
/// Make `d` the SQL dialect of the statements prepared from now on (those
/// prepared before keep theirs), as PRAGMA xq_dialect does.
pub fn setDialect(db: *Db, d: Dialect) void {
    engine.setDialect(db.conn.h, d);
}

/// The SQL dialect of the connection.
pub fn dialect(db: *const Db) Dialect {
    return engine.getDialect(db.conn.h);
}

/// Stop the statements running on this connection at their next check
/// (sqlite3_interrupt()): their step() fails with error.Interrupt, and a
/// statement started afterwards runs normally. Safe to call from any
/// thread while the connection is open (an atomic flag): it is how a
/// cancel request of another thread or client stops a query.
pub fn interrupt(db: *const Db) void {
    engine.interrupt(db.conn.h);
}

/// The schema version of database `name` ("main", "temp" or an attached
/// one) as the connection last read it, without reading the file (PRAGMA
/// schema_version), or null if there is no such database. It changes with
/// every schema change, of this connection or another: a tag for what a
/// caller keeps of the schema.
pub fn schemaVersion(db: *const Db, name: []const u8) ?u32 {
    return engine.schemaVersion(db.conn.h, name);
}

/// What the schema in memory says of column `column` of table `table` in
/// database `database` ("main", "temp", an attached one): NOT NULL,
/// PRIMARY KEY, AUTOINCREMENT, UNIQUE, indexed
/// (sqlite3_table_column_metadata() without reading the schema); null
/// for a view or a table or column it does not have. For the column
/// flags of a wire protocol (MySQL's NOT_NULL_FLAG, PRI_KEY_FLAG ...),
/// with a Stmt.columnOrigin().
pub fn columnConstraints(db: *const Db, database: []const u8, table: []const u8, column: []const u8) ?Stmt.ColumnConstraints {
    return engine.columnConstraints(db.conn.h, database, table, column);
}

pub fn lastInsertRowid(db: *const Db) i64 {
    return engine.lastInsertRowid(db.conn.h);
}

/// Rows changed by the last INSERT, UPDATE or DELETE (sqlite3_changes64()).
pub fn changes(db: *const Db) i64 {
    return engine.changes(db.conn.h);
}

/// Rows changed since the connection opened (sqlite3_total_changes64()).
pub fn totalChanges(db: *const Db) i64 {
    return engine.totalChanges(db.conn.h);
}

/// The last error of the connection, or null if the last call succeeded.
/// The message is borrowed: it is valid until the next call that uses
/// the connection or one of its statements.
pub fn lastError(db: *const Db) ?errors.ErrorInfo {
    return db.conn.lastError();
}

/// Change the busy timeout (see OpenOptions.busy_timeout_ms).
pub fn setBusyTimeout(db: *Db, ms: u31) void {
    engine.busyTimeout(db.conn.h, ms);
}

/// PRAGMA journal_mode = `mode`; error.UnsupportedJournalMode if the
/// engine keeps another mode.
pub fn setJournalMode(db: *Db, mode: JournalMode) Error!void {
    var buf: [40]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "PRAGMA journal_mode={s}", .{@tagName(mode)}) catch unreachable;
    var s = try db.prepare(sql);
    defer s.finalize();
    if (!try s.step()) return db.conn.usage(error.UnsupportedJournalMode, "journal_mode={s} returned no row", .{@tagName(mode)});
    const got = try s.column([]const u8, 0);
    if (!std.ascii.eqlIgnoreCase(got, @tagName(mode))) {
        return db.conn.usage(error.UnsupportedJournalMode, "journal_mode={s} refused: the database uses {s}", .{ @tagName(mode), got });
    }
}

/// The engine's connection, for the low-level API (`xqlite.sql.*`).
pub fn raw(db: *Db) *engine.Handle {
    return db.conn.h;
}

// ============================================================ extensions

pub const FunctionOptions = func.FunctionOptions;

/// Register the Zig function `f` as the scalar SQL function `name`. Its
/// arity and argument and result types are taken from its signature:
///
/// * If `context` is not `{}` it must be a pointer, and `f` receives it
///   as its first parameter (the pointer must outlive the registration).
/// * A `std.mem.Allocator` parameter receives an arena whose memory is
///   freed after the call, once the result has been copied (the arena
///   keeps its buffer for the next call).
/// * A single `xqlite.Args` parameter makes the function variadic.
/// * Every other parameter is an SQL argument, read as its type (see
///   value.zig); a NULL passed to a non-optional parameter, or a value
///   that does not convert, fails the call.
/// * The return value becomes the result (text and blobs are copied);
///   `void` and `null` are NULL; an error fails the statement with the
///   error name as message.
///
///     fn add(a: i64, b: i64) i64 { return a + b; }
///     try db.createFunction("add", {}, add, .{ .deterministic = true });
pub fn createFunction(db: *Db, name: []const u8, context: anytype, comptime f: anytype, opts: FunctionOptions) Error!void {
    return func.createScalar(db.conn, db.gpa, name, context, f, opts);
}

/// Register the aggregate SQL function `name`, whose per-group state is
/// a `State` (at most 8-byte aligned), made with `State.init()` if
/// declared, else `State{}`:
///
///     const Sum = struct {
///         total: i64 = 0,
///         pub fn step(self: *Sum, x: i64) void { self.total += x; }
///         pub fn final(self: *Sum) i64 { return self.total; }
///     };
///     try db.createAggregate("my_sum", Sum, .{});
///
/// `step` takes the SQL arguments as createFunction() does; `final`
/// gives the result. Optional: `deinit(self)` or `deinit(self, gpa)`,
/// run after final() (also when a statement is abandoned); and `value`
/// and `inverse` (the arguments of step), which make it usable as a
/// window function. An Allocator parameter of these methods receives
/// the Db's allocator, which state may keep until deinit().
pub fn createAggregate(db: *Db, name: []const u8, comptime State: type, opts: FunctionOptions) Error!void {
    return func.createAggregate(db.conn, db.gpa, name, State, opts);
}

/// Register the collation `name`. `cmp` is `fn (a: []const u8, b:
/// []const u8) std.math.Order`, or with a non-void `context` (a pointer
/// that must outlive the connection) `fn (ctx, a, b) std.math.Order`, as
/// for std.sort.
pub fn createCollation(db: *Db, name: []const u8, context: anytype, comptime cmp: anytype) Error!void {
    return func.createCollation(db.conn, name, context, cmp);
}

/// Register the virtual table type `T` as module `name`, usable with
/// CREATE VIRTUAL TABLE t USING name(args) and as the eponymous table
/// (or table-valued function) `name`. See src/api/module.zig for what `T`
/// declares. A non-void `context` (a pointer that must outlive the
/// connection) is passed to `T.connect()`.
pub fn createModule(db: *Db, name: []const u8, comptime T: type, context: anytype) Error!void {
    return module.create(db.conn, db.gpa, name, T, context);
}
