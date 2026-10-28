//! Error reporting shared by Db, Stmt and Savepoint: turn an engine error
//! or an error of the API layer into the API's Zig error, recording the
//! details in the connection (for Db.lastError()) and in the optional
//! Diagnostics.

const engine = @import("engine.zig");
const errors = @import("errors.zig");

const Error = errors.Error;
const ResultCode = errors.ResultCode;

pub const Conn = struct {
    h: *engine.Handle,
    diag: ?*errors.Diagnostics,

    /// The API's error for `err`, an error of the engine, which has
    /// already recorded its code and message in the connection.
    pub fn fail(c: Conn, err: engine.Error) Error {
        const e = errors.fromEngine(err);
        c.record(e);
        return e;
    }

    /// The result of an engine call, its error turned into the API's.
    pub fn check(c: Conn, result: anytype) Error!@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| c.fail(err);
    }

    /// Copy the connection's error into the Diagnostics, if any.
    fn record(c: Conn, err: Error) void {
        const d = c.diag orelse return;
        const off = engine.errorOffset(c.h);
        d.set(err, .of(engine.extendedErrcode(c.h)), engine.errmsg(c.h), if (off >= 0) @intCast(off) else null);
    }

    /// The one entry point for errors that the API layer itself detects:
    /// record `code` and the formatted message as the connection's error
    /// (as the engine records its own) and in the Diagnostics, and
    /// return `err`.
    pub fn raise(c: Conn, err: Error, code: ResultCode, comptime fmt: []const u8, args: anytype) Error {
        engine.setError(c.h, @backingInt(code), fmt, args);
        c.record(err);
        return err;
    }

    /// `err`, an API usage error, with a formatted message.
    pub fn usage(c: Conn, err: errors.UsageError, comptime fmt: []const u8, args: anytype) Error {
        return c.raise(err, errors.usageCode(err), fmt, args);
    }

    /// error.OutOfMemory for an allocation of the API layer (from the
    /// `gpa` of Db.open() or the caller's allocator), recorded as
    /// SQLITE_NOMEM.
    pub fn outOfMemory(c: Conn) Error {
        return c.raise(error.OutOfMemory, .nomem, "out of memory", .{});
    }

    /// The connection's last error, saved by saveError() so that calls
    /// which must not change it (cleanups: finalize, rollback) can run.
    pub const SavedError = struct {
        h: *engine.Handle,
        saved: engine.SavedError,

        /// Make the saved error the connection's last error again, with
        /// its whole message and its offset, dropping any error the calls
        /// since saveError() left.
        pub fn restore(s: SavedError) void {
            engine.restoreError(s.h, s.saved);
        }
    };

    /// Save the connection's last error until SavedError.restore():
    ///
    ///     const saved = conn.saveError();
    ///     defer saved.restore();
    ///     ... calls whose errors are not reported ...
    ///
    /// Those calls should go through quiet(), so that the Diagnostics
    /// keep the saved error too.
    pub fn saveError(c: Conn) SavedError {
        return .{ .h = c.h, .saved = engine.saveError(c.h) };
    }

    /// This connection without Diagnostics, for calls whose errors are
    /// not reported.
    pub fn quiet(c: Conn) Conn {
        return .{ .h = c.h, .diag = null };
    }
};
