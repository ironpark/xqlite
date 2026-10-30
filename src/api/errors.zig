//! Errors of the Zig API: an error set in place of SQLite's integer result
//! codes, the extended code (`ResultCode`) and message behind an error, and
//! `Diagnostics`, an optional caller-owned record of the last error.
//!
//! Every engine failure surfaces as one member of `SqlError`, chosen by the
//! primary result code (the low byte). The full extended code and the
//! message are available afterwards from `Db.lastError()` (borrowed from
//! the connection) or, if the connection was opened with
//! `OpenOptions.diagnostics`, copied into that `Diagnostics`.

const std = @import("std");
const engine = @import("engine.zig");

const RC = engine.RC;

/// Errors reported by the engine, one per primary SQLite result code.
pub const SqlError = error{
    /// SQLITE_ERROR: a generic error, usually in the SQL itself (syntax
    /// error, no such table or column, a failing function ...).
    Sql,
    /// SQLITE_INTERNAL.
    Internal,
    /// SQLITE_PERM: access permission denied.
    PermissionDenied,
    /// SQLITE_ABORT: the operation was aborted (e.g. by ROLLBACK).
    Abort,
    /// SQLITE_BUSY: the database file is locked by another connection.
    Busy,
    /// SQLITE_LOCKED: a table in the database is locked.
    Locked,
    /// SQLITE_NOMEM.
    OutOfMemory,
    /// SQLITE_READONLY: attempt to write a read-only database.
    ReadOnly,
    /// SQLITE_INTERRUPT.
    Interrupt,
    /// SQLITE_IOERR: disk I/O error.
    IoErr,
    /// SQLITE_CORRUPT: the database disk image is malformed.
    Corrupt,
    /// SQLITE_NOTFOUND.
    NotFound,
    /// SQLITE_FULL: database or disk is full.
    DiskFull,
    /// SQLITE_CANTOPEN: unable to open the database file.
    CantOpen,
    /// SQLITE_PROTOCOL: locking protocol error.
    Protocol,
    /// SQLITE_EMPTY.
    Empty,
    /// SQLITE_SCHEMA: the schema changed.
    Schema,
    /// SQLITE_TOOBIG: string or blob too big.
    TooBig,
    /// SQLITE_CONSTRAINT: a UNIQUE, NOT NULL, CHECK, FOREIGN KEY ...
    /// constraint failed. The extended code tells which.
    Constraint,
    /// SQLITE_MISMATCH: datatype mismatch.
    Mismatch,
    /// SQLITE_MISUSE: the library was used incorrectly.
    Misuse,
    /// SQLITE_NOLFS: large file support is disabled.
    NoLfs,
    /// SQLITE_AUTH: authorization denied.
    Auth,
    /// SQLITE_FORMAT.
    Format,
    /// SQLITE_RANGE: a bind or column index out of range.
    Range,
    /// SQLITE_NOTADB: the file is not a database.
    NotADatabase,
};

/// Errors of the API layer itself: values that do not fit the requested
/// Zig type, or arguments that do not fit the statement.
pub const UsageError = error{
    /// A NULL was read into a type that is not optional.
    UnexpectedNull,
    /// An integer does not fit the requested Zig type, or a Zig integer
    /// does not fit SQLite's 64-bit signed integer.
    IntegerOverflow,
    /// A value names no member of the requested enum.
    InvalidEnum,
    /// The number of values passed to bind() is not the number of
    /// parameters of the statement.
    ParameterCountMismatch,
    /// A struct field passed to bind() names no parameter (`:name`,
    /// `@name` or `$name`) of the statement.
    UnknownParameter,
    /// A struct field read by row() names no result column.
    ColumnNotFound,
    /// A column index past the last result column, or a tuple read by
    /// row() with more fields than the statement has columns.
    ColumnIndexOutOfRange,
    /// prepare() was given more than one statement.
    MultipleStatements,
    /// prepare() was given only white space or comments.
    EmptyStatement,
    /// OpenOptions.journal_mode was refused (e.g. WAL for a :memory:
    /// database).
    UnsupportedJournalMode,
    /// A savepoint name longer than `max_savepoint_name`.
    NameTooLong,
};

/// Every error of the API.
pub const Error = SqlError || UsageError;

/// An SQLite result code, primary or extended (SQLITE_CONSTRAINT_UNIQUE
/// ...). Non-exhaustive: codes without a name here are still valid.
pub const ResultCode = enum(i32) {
    ok = RC.OK,
    @"error" = RC.ERROR,
    internal = RC.INTERNAL,
    perm = RC.PERM,
    abort = RC.ABORT,
    busy = RC.BUSY,
    locked = RC.LOCKED,
    nomem = RC.NOMEM,
    readonly = RC.READONLY,
    interrupt = RC.INTERRUPT,
    ioerr = RC.IOERR,
    corrupt = RC.CORRUPT,
    notfound = RC.NOTFOUND,
    full = RC.FULL,
    cantopen = RC.CANTOPEN,
    protocol = RC.PROTOCOL,
    empty = RC.EMPTY,
    schema = RC.SCHEMA,
    toobig = RC.TOOBIG,
    constraint = RC.CONSTRAINT,
    mismatch = RC.MISMATCH,
    misuse = RC.MISUSE,
    nolfs = RC.NOLFS,
    auth = RC.AUTH,
    format = RC.FORMAT,
    range = RC.RANGE,
    notadb = RC.NOTADB,
    notice = RC.NOTICE,
    warning = RC.WARNING,
    row = RC.ROW,
    done = RC.DONE,

    error_missing_collseq = RC.ERROR_MISSING_COLLSEQ,
    error_retry = RC.ERROR_RETRY,
    error_snapshot = RC.ERROR_SNAPSHOT,
    abort_rollback = RC.ABORT_ROLLBACK,
    busy_recovery = RC.BUSY_RECOVERY,
    busy_snapshot = RC.BUSY_SNAPSHOT,
    busy_timeout = RC.BUSY_TIMEOUT,
    locked_sharedcache = RC.LOCKED_SHAREDCACHE,
    readonly_recovery = RC.READONLY_RECOVERY,
    readonly_cantlock = RC.READONLY_CANTLOCK,
    readonly_rollback = RC.READONLY_ROLLBACK,
    readonly_dbmoved = RC.READONLY_DBMOVED,
    readonly_cantinit = RC.READONLY_CANTINIT,
    readonly_directory = RC.READONLY_DIRECTORY,
    ioerr_read = RC.IOERR_READ,
    ioerr_short_read = RC.IOERR_SHORT_READ,
    ioerr_write = RC.IOERR_WRITE,
    ioerr_fsync = RC.IOERR_FSYNC,
    ioerr_lock = RC.IOERR_LOCK,
    ioerr_shmopen = RC.IOERR_SHMOPEN,
    ioerr_shmsize = RC.IOERR_SHMSIZE,
    ioerr_shmlock = RC.IOERR_SHMLOCK,
    ioerr_shmmap = RC.IOERR_SHMMAP,
    corrupt_vtab = RC.CORRUPT_VTAB,
    corrupt_sequence = RC.CORRUPT_SEQUENCE,
    corrupt_index = RC.CORRUPT_INDEX,
    cantopen_notempdir = RC.CANTOPEN_NOTEMPDIR,
    cantopen_isdir = RC.CANTOPEN_ISDIR,
    cantopen_fullpath = RC.CANTOPEN_FULLPATH,
    constraint_check = RC.CONSTRAINT_CHECK,
    constraint_commithook = RC.CONSTRAINT_COMMITHOOK,
    constraint_foreignkey = RC.CONSTRAINT_FOREIGNKEY,
    constraint_function = RC.CONSTRAINT_FUNCTION,
    constraint_notnull = RC.CONSTRAINT_NOTNULL,
    constraint_primarykey = RC.CONSTRAINT_PRIMARYKEY,
    constraint_trigger = RC.CONSTRAINT_TRIGGER,
    constraint_unique = RC.CONSTRAINT_UNIQUE,
    constraint_vtab = RC.CONSTRAINT_VTAB,
    constraint_rowid = RC.CONSTRAINT_ROWID,
    constraint_pinned = RC.CONSTRAINT_PINNED,
    constraint_datatype = RC.CONSTRAINT_DATATYPE,
    _,

    /// The code `c` of the engine.
    pub fn of(c: i32) ResultCode {
        return @fromBackingInt(c);
    }

    /// The primary code (the low byte) of an extended code.
    pub fn primary(c: ResultCode) ResultCode {
        return of(@backingInt(c) & 0xff);
    }

    /// The English description of the code (sqlite3_errstr()).
    pub fn description(c: ResultCode) [:0]const u8 {
        return engine.errStr(@backingInt(c));
    }

    /// Whether the code reports an error: anything but OK, ROW and DONE,
    /// and the NOTICE and WARNING codes, which are only logged.
    pub fn isError(c: ResultCode) bool {
        return switch (c.primary()) {
            .ok, .row, .done, .notice, .warning => false,
            else => true,
        };
    }

    /// The Zig error for the code, or null if it is not an error.
    pub fn toError(c: ResultCode) ?SqlError {
        if (!c.isError()) return null;
        return fromEngine(engine.codeError(@backingInt(c)));
    }
};

/// The API's error for an error of the engine. Engine errors that stand
/// for an extended code (BusySnapshot, ShortRead ...) become the error of
/// their primary code; the extended code stays in the connection.
pub fn fromEngine(err: engine.Error) SqlError {
    return switch (err) {
        error.Error, error.ErrorSnapshot => error.Sql,
        error.Internal => error.Internal,
        error.Perm => error.PermissionDenied,
        error.Abort => error.Abort,
        error.Busy, error.BusyRecovery, error.BusySnapshot => error.Busy,
        error.Locked => error.Locked,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadOnly, error.ReadOnlyRecovery, error.ReadOnlyRollback, error.ReadOnlyCantInit => error.ReadOnly,
        error.Interrupt => error.Interrupt,
        error.IoErr, error.ShortRead, error.LockErr, error.ShmOpen, error.ShmSize, error.ShmLock, error.ShmMap => error.IoErr,
        error.Corrupt => error.Corrupt,
        error.NotFound => error.NotFound,
        error.DiskFull => error.DiskFull,
        error.CantOpen => error.CantOpen,
        error.Protocol => error.Protocol,
        error.Empty => error.Empty,
        error.Schema => error.Schema,
        error.TooBig => error.TooBig,
        error.Constraint => error.Constraint,
        error.Mismatch => error.Mismatch,
        error.Misuse => error.Misuse,
        error.NoLfs => error.NoLfs,
        error.Auth => error.Auth,
        error.Format => error.Format,
        error.Range => error.Range,
        error.NotADatabase => error.NotADatabase,
    };
}

/// The error behind the last failed call on a connection, as returned by
/// `Db.lastError()`. `message` is borrowed from the connection: it is
/// valid until the next call that uses the connection (any `Db` or
/// `Stmt` method).
pub const ErrorInfo = struct {
    /// The extended result code (sqlite3_extended_errcode()).
    code: ResultCode,
    /// The message (sqlite3_errmsg()).
    message: [:0]const u8,
    /// Byte offset in the SQL text of the token that caused the error
    /// (sqlite3_error_offset()), if known.
    offset: ?usize,
};

/// A caller-owned copy of the last error, in the spirit of
/// std.json.Diagnostics. Pass one in `OpenOptions.diagnostics` and every
/// failing call of that connection (and its statements) fills it in,
/// including Db.open() itself, which has no connection to ask afterwards.
/// No allocation: the message is truncated to `buf.len` bytes.
pub const Diagnostics = struct {
    /// The extended result code; `.ok` until an error is recorded. For an
    /// API error (UsageError) the code is `.misuse`, `.range` or
    /// `.mismatch` as SQLite would report a similar problem, and `.nomem`
    /// when an allocation of the API layer fails.
    code: ResultCode = .ok,
    /// Byte offset in the SQL text of the token that caused the error.
    offset: ?usize = null,
    /// The Zig error last returned.
    err: ?Error = null,
    buf: [max_message]u8 = undefined,
    len: usize = 0,

    pub const max_message = 256;

    /// The message of the last error.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.buf[0..d.len];
    }

    /// Record an error.
    pub fn set(d: *Diagnostics, err: Error, code: ResultCode, msg: []const u8, offset: ?usize) void {
        d.err = err;
        d.code = code;
        d.offset = offset;
        d.len = @min(msg.len, d.buf.len);
        @memcpy(d.buf[0..d.len], msg[0..d.len]);
    }

    /// Forget the last error.
    pub fn clear(d: *Diagnostics) void {
        d.* = .{};
    }
};

/// The result code recorded in Diagnostics for an API error.
pub fn usageCode(err: UsageError) ResultCode {
    return switch (err) {
        error.ColumnIndexOutOfRange, error.ColumnNotFound, error.ParameterCountMismatch, error.UnknownParameter => .range,
        error.UnexpectedNull, error.IntegerOverflow, error.InvalidEnum => .mismatch,
        else => .misuse,
    };
}

test "zig api: ResultCode: errors of primary and extended codes" {
    try std.testing.expectEqual(@as(?SqlError, null), ResultCode.ok.toError());
    try std.testing.expectEqual(@as(?SqlError, null), ResultCode.done.toError());
    try std.testing.expectEqual(@as(?SqlError, null), ResultCode.of(RC.WARNING | (1 << 8)).toError());
    try std.testing.expectEqual(@as(?SqlError, error.Constraint), ResultCode.constraint_unique.toError());
    try std.testing.expectEqual(@as(?SqlError, error.Busy), ResultCode.busy_snapshot.toError());
    try std.testing.expectEqual(@as(?SqlError, error.IoErr), ResultCode.ioerr_write.toError());
    try std.testing.expectEqual(@as(?SqlError, error.Sql), ResultCode.of(1000).toError());
    try std.testing.expectEqual(ResultCode.constraint, ResultCode.constraint_notnull.primary());
    try std.testing.expectEqualStrings("database is locked", ResultCode.busy.description());
}
