//! The Zig API of xqlite: a thin, typed layer over the engine.
//!
//! ```zig
//! var db = try xqlite.Db.open(gpa, io, "app.db", .{ .journal_mode = .wal });
//! defer db.close();
//!
//! try db.exec("CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT, age INT)");
//! try db.execArgs("INSERT INTO users(name, age) VALUES(:name, :age)", .{ .name = "Ada", .age = 36 });
//!
//! var stmt = try db.prepare("SELECT id, name FROM users WHERE age > ?");
//! defer stmt.finalize();
//! try stmt.bind(.{30});
//! var it = stmt.iterator(struct { id: i64, name: []const u8 });
//! while (try it.next()) |u| std.debug.print("{d} {s}\n", .{ u.id, u.name });
//! ```
//!
//! Each C API call has a Zig counterpart (sqlite3_open_v2 is Db.open,
//! sqlite3_step is Stmt.step or an Iterator, the error codes are an
//! error set plus Db.lastError() ...): the full mapping, the lifetime
//! rules and the design are in docs/zig-api.md.
//!
//! This file is the list of the public names of the Zig API. The module
//! root (root.zig) re-exports every one of them, which a test there
//! checks.

const value = @import("api/value.zig");
const errors = @import("api/errors.zig");
const func = @import("api/func.zig");

pub const Db = @import("api/Db.zig");
pub const Stmt = @import("api/Stmt.zig");
pub const Savepoint = Db.Savepoint;
pub const Script = Db.Script;
pub const Origin = Stmt.Origin;
pub const TypeName = Stmt.TypeName;
pub const Backup = Db.Backup;
pub const BlobHandle = Db.BlobHandle;
pub const OpenOptions = Db.OpenOptions;
pub const JournalMode = Db.JournalMode;
pub const Dialect = Db.Dialect;
pub const TransactionMode = Db.TransactionMode;
pub const VfsOption = Db.VfsOption;

pub const Error = errors.Error;
pub const SqlError = errors.SqlError;
pub const UsageError = errors.UsageError;
pub const ResultCode = errors.ResultCode;
pub const ErrorInfo = errors.ErrorInfo;
pub const Diagnostics = errors.Diagnostics;

pub const Value = value.Value;
pub const Kind = value.Kind;
pub const Blob = value.Blob;
pub const ZeroBlob = value.ZeroBlob;
pub const EnumStorage = value.EnumStorage;
/// Free a value returned by an `*Alloc` read.
pub const free = value.free;

pub const FunctionOptions = func.FunctionOptions;
pub const Args = func.Args;
pub const FilterArgs = @import("api/module.zig").FilterArgs;

/// The type of a result column, independent of the dialect that declared
/// it (types.Type, types.parse()).
pub const types = @import("api/types.zig");
/// Values as the dialect a client speaks shows them (display.text(), and
/// display.Columns for the types of result columns).
pub const display = @import("api/display.zig");

test {
    _ = errors;
    _ = types;
    _ = display;
    _ = @import("api/test.zig");
}
