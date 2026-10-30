//! xqlite: an embedded SQL database ported from SQLite to Zig.
//!
//! Layers are ported bottom-up; see README.md for the roadmap.

const std = @import("std");

// ============================================================== Zig API
// The primary public surface: every public name of src/xqlite.zig (the
// one list of them; see docs/zig-api.md), re-exported here, which the
// comptime block below checks. The low-level exports further down stay
// for the shell, tools and tests.

pub const api = @import("xqlite.zig");
pub const Db = api.Db;
pub const Stmt = api.Stmt;
pub const Savepoint = api.Savepoint;
pub const Backup = api.Backup;
pub const BlobHandle = api.BlobHandle;
pub const OpenOptions = api.OpenOptions;
pub const JournalMode = api.JournalMode;
pub const Dialect = api.Dialect;
pub const TransactionMode = api.TransactionMode;
pub const VfsOption = api.VfsOption;
pub const Error = api.Error;
pub const SqlError = api.SqlError;
pub const UsageError = api.UsageError;
pub const ResultCode = api.ResultCode;
pub const ErrorInfo = api.ErrorInfo;
pub const Diagnostics = api.Diagnostics;
pub const Value = api.Value;
pub const Kind = api.Kind;
pub const Blob = api.Blob;
pub const ZeroBlob = api.ZeroBlob;
pub const EnumStorage = api.EnumStorage;
pub const free = api.free;
pub const FunctionOptions = api.FunctionOptions;
pub const Args = api.Args;
pub const FilterArgs = api.FilterArgs;

comptime {
    for (std.meta.declarations(api)) |name| {
        if (!@hasDecl(@This(), name)) @compileError("root.zig must re-export `" ++ name ++ "` of xqlite.zig");
        const mine = @field(@This(), name);
        const theirs = @field(api, name);
        if (@TypeOf(mine) != @TypeOf(theirs) or (@TypeOf(mine) == type and mine != theirs)) {
            @compileError("root." ++ name ++ " is not xqlite.zig's " ++ name);
        }
    }
}

pub const varint = @import("util/varint.zig");

pub const vfs = @import("vfs/vfs.zig");
pub const MemVfs = @import("vfs/mem.zig").MemVfs;
/// The POSIX VFS; void on WebAssembly, which has no POSIX locks.
pub const UnixVfs = switch (@import("builtin").os.tag) {
    .wasi, .freestanding => void,
    else => @import("vfs/unix.zig").UnixVfs,
};
/// The WASI VFS (docs/wasm.md); void but on wasm32-wasi.
pub const WasiVfs = if (@import("builtin").os.tag == .wasi) @import("vfs/wasi.zig").WasiVfs else void;
/// The VFS whose files the embedder supplies through imports
/// (docs/wasm.md); void but on wasm32-freestanding.
pub const HostVfs = if (@import("builtin").os.tag == .freestanding) @import("vfs/host.zig").HostVfs else void;
/// The file-system VFS of the target: UnixVfs, WasiVfs or HostVfs.
pub const OsVfs = vfs.OsVfs;
/// A VFS wrapper that crashes the process at a chosen write (testing aid).
pub const crash_vfs = @import("vfs/crash.zig");

pub const pager = @import("pager/pager.zig");
pub const pcache = @import("pager/pcache.zig");

pub const btree = @import("btree/btree.zig");

pub const record = @import("vdbe/record.zig");

pub const tokenize = @import("parse/tokenize.zig");
/// SQL dialects: frontends and semantic hooks (Phase 4).
pub const dialect = @import("dialect/dialect.zig");
/// The common IR the frontends lower into.
pub const ir = @import("ir/ir.zig");
/// Dialect metadata (xq_catalog) and sequences (xq_sequence).
pub const catalog = @import("catalog/catalog.zig");
pub const sql_util = @import("sql/util.zig");
pub const numeric = @import("sql/numeric.zig");
pub const printf = @import("sql/printf.zig");
/// The allocators: sqlite3_malloc() and the per-connection lookaside
/// (malloc.c).
pub const malloc = @import("sql/malloc.zig");

/// The SQL interface: connections (sql.main) and statement execution.
pub const sql = struct {
    pub const Sqlite3 = @import("sql/sqlite_int.zig").Sqlite3;
    pub const main = @import("sql/main.zig");
    pub const legacy = @import("sql/legacy.zig");
    pub const prepare = @import("sql/prepare.zig");
    pub const complete = @import("sql/complete.zig");
    /// The online backup API (sqlite3_backup_*).
    pub const backup = @import("sql/backup.zig");
    pub const api = @import("vdbe/api.zig");
    /// Virtual table modules (sqlite3_module, sqlite3_create_module()).
    pub const vtab = @import("sql/vtab.zig");
    /// A prepared statement (sqlite3_stmt).
    pub const Stmt = @import("vdbe/vdbe_int.zig").Vdbe;
    pub const RC = @import("sql/sqlite_int.zig").RC;
    /// Connection flags (Sqlite3.flags; SQLITE_DBCONFIG_* and PRAGMAs).
    pub const DbFlag = @import("sql/sqlite_int.zig").DbFlag;
};

/// Extensions from ext/misc that the sqlite3 shell builds in.
pub const ext = struct {
    /// generate_series() (series.c).
    pub const series = @import("ext/series.zig");
    /// vtablog (vtablog.c), a virtual table that prints its method calls.
    pub const vtablog = @import("ext/vtablog.zig");
};

pub const vdbe = struct {
    pub const mem = @import("vdbe/mem.zig");
    pub const aux = @import("vdbe/aux.zig");
    pub const serial = @import("vdbe/serial.zig");
};

// Analyze every declaration of the SQL layer, which is not yet reachable
// from a public entry point.
test {
    inline for (.{
        @import("vdbe/mem.zig"),            @import("vdbe/aux.zig"),           @import("vdbe/serial.zig"),
        @import("vdbe/vdbe_int.zig"),       @import("sql/expr.zig"),           @import("sql/build.zig"),
        @import("sql/select.zig"),          @import("sql/window.zig"),         @import("sql/main.zig"),
        @import("sql/util.zig"),            @import("sql/walker.zig"),         @import("sql/trigger.zig"),
        @import("parse/parser.zig"),        @import("vdbe/exec.zig"),          @import("vdbe/sorter.zig"),
        @import("vdbe/rowset.zig"),         @import("vdbe/api.zig"),           @import("sql/func.zig"),
        @import("sql/prepare.zig"),         @import("sql/legacy.zig"),         @import("sql/resolve.zig"),
        @import("sql/expr_code.zig"),       @import("sql/coll.zig"),           @import("sql/date.zig"),
        @import("sql/sql_test.zig"),        @import("sql/pragma.zig"),         @import("sql/pragma_test.zig"),
        @import("sql/where_int.zig"),       @import("sql/where.zig"),          @import("sql/where_loop.zig"),
        @import("sql/where_code.zig"),      @import("sql/where_expr.zig"),     @import("sql/where_test.zig"),
        @import("sql/vtab.zig"),            @import("ext/series.zig"),         @import("sql/malloc.zig"),
        @import("ext/vtablog.zig"),         @import("vdbe/vdbevtab.zig"),      @import("sql/vtab_test.zig"),
        @import("vdbe/exec/control.zig"),   @import("vdbe/exec/register.zig"), @import("vdbe/exec/arith.zig"),
        @import("vdbe/exec/record.zig"),    @import("vdbe/exec/txn.zig"),      @import("vdbe/exec/cursor.zig"),
        @import("vdbe/exec/btree_ops.zig"), @import("vdbe/exec/agg.zig"),      @import("vdbe/exec/vtab_ops.zig"),
        @import("vdbe/exec/misc.zig"),      @import("util/flags.zig"),         @import("sql/sqlite_int.zig"),
        @import("util/thunk.zig"),          @import("util/cast.zig"),          @import("dialect/dialect.zig"),
        @import("ir/ir.zig"),               @import("catalog/catalog.zig"),    @import("catalog/sequence.zig"),
        @import("sql/analyze.zig"),         @import("sql/analyze_test.zig"),   @import("sql/hash.zig"),
    }) |file| std.testing.refAllDecls(file);
}

test {
    std.testing.refAllDecls(@import("sql/attach.zig"));
    std.testing.refAllDecls(@import("sql/uri.zig"));
    std.testing.refAllDecls(@import("sql/serialize.zig"));
    std.testing.refAllDecls(@import("sql/status.zig"));
    _ = @import("sql/attach_test.zig");
}

test {
    std.testing.refAllDecls(@import("sql/complete.zig"));
}

test {
    std.testing.refAllDecls(@import("sql/vacuum.zig"));
    std.testing.refAllDecls(@import("sql/backup.zig"));
    _ = @import("sql/vacuum_test.zig");
}

test {
    // The fuzzers' smoke test (`zig build fuzz` runs them for longer).
    _ = @import("fuzz_tests.zig");
}

test {
    std.testing.refAllDecls(@import("sql/json.zig"));
}

/// The SQLite release this port tracks (SQLITE_VERSION_NUMBER). Keep in sync
/// with sqlite_version in tools/xqt/fetch.zig.
pub const sqlite_version_number = 3054001;

test {
    std.testing.refAllDecls(@This());
}

test "read header of a database written by sqlite3" {
    const bytes = @embedFile("testdata/basic.db");
    const h = try btree.header.Header.parse(bytes[0..btree.header.size]);
    try std.testing.expectEqual(@as(u32, 1024), h.page_size);
    try std.testing.expectEqual(@as(u32, 42), h.user_version);
    try std.testing.expectEqual(@as(u32, 1481724236), h.application_id);
    try std.testing.expectEqual(btree.header.TextEncoding.utf8, h.text_encoding);
    try std.testing.expectEqual(@as(u32, 4), h.schema_format);
    try std.testing.expect(h.inHeaderSizeValid());
    try std.testing.expectEqual(@as(u32, bytes.len / 1024), h.database_size);
}
