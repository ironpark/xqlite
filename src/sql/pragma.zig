//! PRAGMA statements (port of pragma.c and the generated pragma.h).
//!
//! Pragmas that need missing subsystems (exclusive locking, UTF-16) fail
//! with "not supported yet".

const std = @import("std");
const flags = @import("xqlite_base").flags;
const builtin = @import("builtin");
const int = @import("sqlite_int.zig");
const fkey = @import("fkey.zig");
const pending = @import("pending.zig");
const util = @import("util.zig");
const build = @import("build.zig");
const prepare = @import("prepare.zig");
const auth = @import("auth.zig");
const expr = @import("expr.zig");
const ec = @import("expr_code.zig");
const insert = @import("insert.zig");
const delete = @import("delete.zig");
const update = @import("update.zig");
const func = @import("func.zig");
const callback = @import("callback.zig");
const coll = @import("coll.zig");
const main_mod = @import("main.zig");
const ctype = @import("xqlite_base").ctype;
const btree = @import("xqlite_storage").btree;
const pager_mod = @import("xqlite_storage").pager;
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const api = @import("../vdbe/api.zig");
const mem = @import("../vdbe/mem.zig");
const vtab = @import("vtab.zig");

const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const Token = int.Token;
const Table = int.Table;
const Index = int.Index;
const DbFlag = int.DbFlag;
const Vdbe = vi.Vdbe;
const OP = vi.OP;
const Oom = int.Oom;

// ================================================================ pragma.h

/// The pragma types (PragTyp_*), with SQLite's values.
pub const PragTyp = enum(u8) {
    activate_extensions = 0,
    analysis_limit = 1,
    header_value = 2,
    auto_vacuum = 3,
    flag = 4,
    busy_timeout = 5,
    cache_size = 6,
    cache_spill = 7,
    case_sensitive_like = 8,
    collation_list = 9,
    compile_options = 10,
    data_store_directory = 11,
    database_list = 12,
    default_cache_size = 13,
    encoding = 14,
    foreign_key_check = 15,
    foreign_key_list = 16,
    function_list = 17,
    hard_heap_limit = 18,
    incremental_vacuum = 19,
    index_info = 20,
    index_list = 21,
    integrity_check = 22,
    journal_mode = 23,
    journal_size_limit = 24,
    lock_proxy_file = 25,
    locking_mode = 26,
    page_count = 27,
    mmap_size = 28,
    module_list = 29,
    optimize = 30,
    page_size = 31,
    pragma_list = 32,
    secure_delete = 33,
    shrink_memory = 34,
    soft_heap_limit = 35,
    synchronous = 36,
    table_info = 37,
    table_list = 38,
    temp_store = 39,
    temp_store_directory = 40,
    threads = 41,
    wal_autocheckpoint = 42,
    wal_checkpoint = 43,
    lock_status = 44,
    stats = 45,
};

/// Property flags of the pragmas (PragFlg_*).
pub const PragFlg = packed struct(u8) {
    /// Force schema load before running.
    NeedSchema: bool = false,
    /// OP_ResultRow called with zero columns.
    NoColumns: bool = false,
    /// Zero columns if the RHS argument is present.
    NoColumns1: bool = false,
    /// Read-only HEADER_VALUE.
    ReadOnly: bool = false,
    /// Acts as query when no argument.
    Result0: bool = false,
    /// Acts as query when it has one argument.
    Result1: bool = false,
    /// Schema restricts name search if present.
    SchemaOpt: bool = false,
    /// Schema required - "main" is the default.
    SchemaReq: bool = false,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(PragFlg, .{
            .NeedSchema = 0x01,
            .NoColumns = 0x02,
            .NoColumns1 = 0x04,
            .ReadOnly = 0x08,
            .Result0 = 0x10,
            .Result1 = 0x20,
            .SchemaOpt = 0x40,
            .SchemaReq = 0x80,
        });
    }
};

/// Names of the result columns of pragmas that return several columns,
/// or one named differently from the pragma (pragCName).
const prag_c_name = [_][:0]const u8{
    // 0: foreign_key_list
    "id",      "seq",          "table",  "from",    "to",         "on_update", "on_delete", "match",
    // 8: table_xinfo (table_info uses the first 6)
    "cid",     "name",         "type",   "notnull", "dflt_value", "pk",        "hidden",
    // 15: function_list
       "name",
    "builtin", "type",         "enc",    "narg",    "flags",
    // 21: table_list
         "schema",    "name",      "type",
    "ncol",    "wr",           "strict",
    // 27: index_xinfo (index_info uses the first 3)
    "seqno",   "cid",        "name",      "desc",      "coll",
    "key",
    // 33: index_list (collation_list uses the first 2)
        "seq",          "name",   "unique",  "origin",     "partial",
    // 38: stats
      "tbl",       "idx",
    "wdth",    "hght",         "flgs",
    // 43: foreign_key_check
      "table",   "rowid",      "parent",    "fkid",
    // 47: wal_checkpoint
         "busy",
    "log",     "checkpointed",
    // 50: database_list
    "seq",    "name",    "file",
    // 53: lock_status
          "database",  "status",
    // 55: default_cache_size
       "cache_size",
    // 56: busy_timeout
    "timeout",
};

/// A built-in pragma (PragmaName).
pub const PragmaName = struct {
    name: [:0]const u8,
    typ: PragTyp,
    flags: PragFlg = .{},
    /// Start and number of the column names in prag_c_name; 0 names means
    /// the one column is named after the pragma.
    i_prag_c_name: u8 = 0,
    n_prag_c_name: u8 = 0,
    i_arg: u64 = 0,
};

const F = PragFlg;

/// SQLITE_ENABLE_LOCKING_STYLE, on by default on Apple platforms.
const locking_style = builtin.os.tag.isDarwin();

/// The pragmas, sorted by name for pragmaLocate() (aPragmaName), as in a
/// default build of SQLite 3.54.1 without SQLITE_DEBUG.
const pragma_names = [_]PragmaName{
    .{ .name = "analysis_limit", .typ = .analysis_limit, .flags = .{ .Result0 = true } },
    .{ .name = "application_id", .typ = .header_value, .flags = .{ .NoColumns1 = true, .Result0 = true }, .i_arg = @backingInt(btree.Meta.application_id) },
    .{ .name = "auto_vacuum", .typ = .auto_vacuum, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true, .NoColumns1 = true } },
    .{ .name = "automatic_index", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .AutoIndex = true }) },
    .{ .name = "busy_timeout", .typ = .busy_timeout, .flags = .{ .Result0 = true }, .i_prag_c_name = 56, .n_prag_c_name = 1 },
    .{ .name = "cache_size", .typ = .cache_size, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true, .NoColumns1 = true } },
    .{ .name = "cache_spill", .typ = .cache_spill, .flags = .{ .Result0 = true, .SchemaReq = true, .NoColumns1 = true } },
    .{ .name = "case_sensitive_like", .typ = .case_sensitive_like, .flags = .{ .NoColumns = true } },
    .{ .name = "cell_size_check", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .CellSizeCk = true }) },
    .{ .name = "checkpoint_fullfsync", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .CkptFullFSync = true }) },
    .{ .name = "collation_list", .typ = .collation_list, .flags = .{ .Result0 = true }, .i_prag_c_name = 33, .n_prag_c_name = 2 },
    .{ .name = "compile_options", .typ = .compile_options, .flags = .{ .Result0 = true } },
    .{ .name = "count_changes", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .CountRows = true }) },
} ++ (if (builtin.os.tag == .windows) [_]PragmaName{
    .{ .name = "data_store_directory", .typ = .data_store_directory, .flags = .{ .NoColumns1 = true } },
} else [_]PragmaName{}) ++ [_]PragmaName{
    .{ .name = "data_version", .typ = .header_value, .flags = .{ .ReadOnly = true, .Result0 = true }, .i_arg = @backingInt(btree.Meta.data_version) },
    .{ .name = "database_list", .typ = .database_list, .flags = .{ .Result0 = true }, .i_prag_c_name = 50, .n_prag_c_name = 3 },
    .{ .name = "default_cache_size", .typ = .default_cache_size, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true, .NoColumns1 = true }, .i_prag_c_name = 55, .n_prag_c_name = 1 },
    .{ .name = "defer_foreign_keys", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .DeferFKs = true }) },
    .{ .name = "empty_result_callbacks", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .NullCallback = true }) },
    .{ .name = "encoding", .typ = .encoding, .flags = .{ .Result0 = true, .NoColumns1 = true } },
    .{ .name = "foreign_key_check", .typ = .foreign_key_check, .flags = .{ .NeedSchema = true, .Result0 = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 43, .n_prag_c_name = 4 },
    .{ .name = "foreign_key_list", .typ = .foreign_key_list, .flags = .{ .NeedSchema = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 0, .n_prag_c_name = 8 },
    .{ .name = "foreign_keys", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .ForeignKeys = true }) },
    .{ .name = "freelist_count", .typ = .header_value, .flags = .{ .ReadOnly = true, .Result0 = true }, .i_arg = @backingInt(btree.Meta.free_page_count) },
    .{ .name = "full_column_names", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .FullColNames = true }) },
    .{ .name = "fullfsync", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .FullFSync = true }) },
    .{ .name = "function_list", .typ = .function_list, .flags = .{ .Result0 = true }, .i_prag_c_name = 15, .n_prag_c_name = 6 },
    .{ .name = "hard_heap_limit", .typ = .hard_heap_limit, .flags = .{ .Result0 = true } },
    .{ .name = "ignore_check_constraints", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .IgnoreChecks = true }) },
    .{ .name = "incremental_vacuum", .typ = .incremental_vacuum, .flags = .{ .NeedSchema = true, .NoColumns = true } },
    .{ .name = "index_info", .typ = .index_info, .flags = .{ .NeedSchema = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 27, .n_prag_c_name = 3 },
    .{ .name = "index_list", .typ = .index_list, .flags = .{ .NeedSchema = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 33, .n_prag_c_name = 5 },
    .{ .name = "index_xinfo", .typ = .index_info, .flags = .{ .NeedSchema = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 27, .n_prag_c_name = 6, .i_arg = 1 },
    .{ .name = "integrity_check", .typ = .integrity_check, .flags = .{ .NeedSchema = true, .Result0 = true, .Result1 = true, .SchemaOpt = true } },
    .{ .name = "journal_mode", .typ = .journal_mode, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true } },
    .{ .name = "journal_size_limit", .typ = .journal_size_limit, .flags = .{ .Result0 = true, .SchemaReq = true } },
    .{ .name = "legacy_alter_table", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .LegacyAlter = true }) },
} ++ (if (locking_style) [_]PragmaName{
    .{ .name = "lock_proxy_file", .typ = .lock_proxy_file, .flags = .{ .NoColumns1 = true } },
} else [_]PragmaName{}) ++ [_]PragmaName{
    .{ .name = "locking_mode", .typ = .locking_mode, .flags = .{ .Result0 = true, .SchemaReq = true } },
    .{ .name = "max_page_count", .typ = .page_count, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true } },
    .{ .name = "mmap_size", .typ = .mmap_size },
    .{ .name = "module_list", .typ = .module_list, .flags = .{ .Result0 = true }, .i_prag_c_name = 9, .n_prag_c_name = 1 },
    .{ .name = "optimize", .typ = .optimize, .flags = .{ .Result1 = true, .NeedSchema = true } },
    .{ .name = "page_count", .typ = .page_count, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true } },
    .{ .name = "page_size", .typ = .page_size, .flags = .{ .Result0 = true, .SchemaReq = true, .NoColumns1 = true } },
    .{ .name = "pragma_list", .typ = .pragma_list, .flags = .{ .Result0 = true }, .i_prag_c_name = 9, .n_prag_c_name = 1 },
    .{ .name = "query_only", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .QueryOnly = true }) },
    .{ .name = "quick_check", .typ = .integrity_check, .flags = .{ .NeedSchema = true, .Result0 = true, .Result1 = true, .SchemaOpt = true } },
    .{ .name = "read_uncommitted", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .ReadUncommit = true }) },
    .{ .name = "recursive_triggers", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .RecTriggers = true }) },
    .{ .name = "reverse_unordered_selects", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .ReverseOrder = true }) },
    .{ .name = "schema_version", .typ = .header_value, .flags = .{ .NoColumns1 = true, .Result0 = true }, .i_arg = @backingInt(btree.Meta.schema_version) },
    .{ .name = "secure_delete", .typ = .secure_delete, .flags = .{ .Result0 = true } },
    .{ .name = "short_column_names", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .ShortColNames = true }) },
    .{ .name = "shrink_memory", .typ = .shrink_memory, .flags = .{ .NoColumns = true } },
    .{ .name = "soft_heap_limit", .typ = .soft_heap_limit, .flags = .{ .Result0 = true } },
    .{ .name = "synchronous", .typ = .synchronous, .flags = .{ .NeedSchema = true, .Result0 = true, .SchemaReq = true, .NoColumns1 = true } },
    .{ .name = "table_info", .typ = .table_info, .flags = .{ .NeedSchema = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 8, .n_prag_c_name = 6 },
    .{ .name = "table_list", .typ = .table_list, .flags = .{ .NeedSchema = true, .Result1 = true }, .i_prag_c_name = 21, .n_prag_c_name = 6 },
    .{ .name = "table_xinfo", .typ = .table_info, .flags = .{ .NeedSchema = true, .Result1 = true, .SchemaOpt = true }, .i_prag_c_name = 8, .n_prag_c_name = 7, .i_arg = 1 },
    .{ .name = "temp_store", .typ = .temp_store, .flags = .{ .Result0 = true, .NoColumns1 = true } },
    .{ .name = "temp_store_directory", .typ = .temp_store_directory, .flags = .{ .NoColumns1 = true } },
    .{ .name = "threads", .typ = .threads, .flags = .{ .Result0 = true } },
    .{ .name = "trusted_schema", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .TrustedSchema = true }) },
    .{ .name = "user_version", .typ = .header_value, .flags = .{ .NoColumns1 = true, .Result0 = true }, .i_arg = @backingInt(btree.Meta.user_version) },
    .{ .name = "wal_autocheckpoint", .typ = .wal_autocheckpoint },
    .{ .name = "wal_checkpoint", .typ = .wal_checkpoint, .flags = .{ .NeedSchema = true }, .i_prag_c_name = 47, .n_prag_c_name = 3 },
    .{ .name = "writable_schema", .typ = .flag, .flags = .{ .Result0 = true, .NoColumns1 = true }, .i_arg = DbFlag.int(.{ .WriteSchema = true, .NoSchemaError = true }) },
};

comptime {
    for (pragma_names[1..], 0..) |pn, i| std.debug.assert(ctype.strICmp(pragma_names[i].name, pn.name) < 0);
}

// ================================================================ helpers

/// SQLITE_INTEGRITY_CHECK_ERROR_MAX.
const integrity_check_error_max = 100;

/// PAGER_SYNCHRONOUS_MASK.
const pager_synchronous_mask = 0x07;

/// Port of sqlite3Atoi(): the 32-bit integer prefix of `z`, or 0.
fn atoi(z: []const u8) i32 {
    return util.getInt32(z) orelse 0;
}

/// Port of getSafetyLevel(): `z` as a safety level: 0 for OFF, 1 for ON
/// or NORMAL, 2 for FULL and 3 for EXTRA, or `dflt` if not recognized.
/// FULL and EXTRA are refused if `omit_full`. The values are one less than
/// the safety levels proper, for compatibility with old boolean scripts.
fn getSafetyLevel(z: []const u8, omit_full: bool, dflt: u8) u8 {
    const text = "onoffalseyestruextrafull";
    const offsets = [_]u8{ 0, 1, 2, 4, 9, 12, 15, 20 };
    const lengths = [_]u8{ 2, 2, 3, 5, 3, 4, 5, 4 };
    const values = [_]u8{ 1, 0, 0, 0, 1, 1, 3, 2 };
    if (z.len > 0 and ctype.isDigit(z[0])) return @intFromBool(atoi(z) != 0);
    for (lengths, offsets, values) |n, off, val| {
        if (n == z.len and ctype.eqlNoCase(text[off..][0..n], z) and (!omit_full or val <= 1)) return val;
    }
    return dflt;
}

/// Port of sqlite3GetBoolean().
pub fn getBoolean(z: []const u8, dflt: bool) bool {
    return getSafetyLevel(z, true, @intFromBool(dflt)) != 0;
}

/// PAGER_LOCKINGMODE_*.
const LockingMode = enum { query, normal, exclusive };

/// Port of getLockingMode().
fn getLockingMode(z_opt: ?[]const u8) LockingMode {
    if (z_opt) |z| {
        if (ctype.eqlNoCase(z, "exclusive")) return .exclusive;
        if (ctype.eqlNoCase(z, "normal")) return .normal;
    }
    return .query;
}

/// Port of getAutoVacuum(): "none", "full", "incremental" or 0 to 2.
fn getAutoVacuum(z: []const u8) u8 {
    if (ctype.eqlNoCase(z, "none")) return 0;
    if (ctype.eqlNoCase(z, "full")) return 1;
    if (ctype.eqlNoCase(z, "incremental")) return 2;
    const i = atoi(z);
    return if (i >= 0 and i <= 2) @intCast(i) else 0;
}

/// Port of getTempStore(): 1 for file, 2 for memory, 0 for the default.
fn getTempStore(z: []const u8) u8 {
    if (z.len > 0 and z[0] >= '0' and z[0] <= '2') return z[0] - '0';
    if (ctype.eqlNoCase(z, "file")) return 1;
    if (ctype.eqlNoCase(z, "memory")) return 2;
    return 0;
}

/// Port of invalidateTempStorage(): close the TEMP database, so that it
/// is reopened with the new temp_store setting.
fn invalidateTempStorage(p: *Parse) bool {
    const db = p.db;
    if (db.dbs.items[1].bt) |bt| {
        if (!db.auto_commit or bt.txnState() != .none) {
            util.errorMsg(p, "temporary storage cannot be changed from within a transaction", .{});
            return false;
        }
        bt.close(.{});
        db.dbs.items[1].bt = null;
        build.resetAllSchemasOfConnection(db);
    }
    return true;
}

/// Port of changeTempStorage().
fn changeTempStorage(p: *Parse, storage_type: []const u8) void {
    const ts = getTempStore(storage_type);
    const db = p.db;
    if (db.temp_store == ts) return;
    if (!invalidateTempStorage(p)) return;
    db.temp_store = ts;
}

/// Port of setPragmaResultColumnNames().
fn setPragmaResultColumnNames(v: *Vdbe, pragma_name: *const PragmaName) void {
    const n = pragma_name.n_prag_c_name;
    aux.setNumCols(v, if (n == 0) 1 else n);
    if (n == 0) {
        aux.setColName(v, 0, vi.COLNAME_NAME, pragma_name.name);
    } else {
        for (0..n) |i| aux.setColName(v, i, vi.COLNAME_NAME, prag_c_name[pragma_name.i_prag_c_name + i]);
    }
}

/// xqlite: PRAGMA xq_dialect[=NAME]: the SQL dialect of the connection
/// (dialect.zig), one row with its name. Setting it takes effect when the
/// statement is prepared, for the statements prepared after it, as
/// PRAGMA case_sensitive_like does.
fn xqDialect(p: *Parse, v: *Vdbe, right: ?[]const u8) void {
    const dialect = @import("../dialect/dialect.zig");
    if (right) |z| {
        const d = dialect.Dialect.fromName(z) orelse {
            util.errorMsg(p, "unknown dialect: {s}", .{z});
            return;
        };
        main_mod.setDialect(p.db, d);
    }
    aux.setNumCols(v, 1);
    aux.setColName(v, 0, vi.COLNAME_NAME, "xq_dialect");
    returnSingleText(v, main_mod.getDialect(p.db).name());
}

/// Port of returnSingleInt().
fn returnSingleInt(v: *Vdbe, value: i64) void {
    _ = aux.addInt64(v, 1, value);
    _ = aux.addOp2(v, OP.ResultRow, 1, 1);
}

/// Port of returnSingleText().
fn returnSingleText(v: *Vdbe, value: ?[]const u8) void {
    if (value) |z| {
        _ = aux.loadString(v, 1, z);
        _ = aux.addOp2(v, OP.ResultRow, 1, 1);
    }
}

/// Port of setAllPagerFlags(): give every pager its safety level and the
/// PAGER_FULLFSYNC and PAGER_CACHESPILL bits of the connection flags.
fn setAllPagerFlags(db: *Sqlite3) void {
    if (!db.auto_commit) return;
    for (db.dbs.items) |*d| {
        const bt = d.bt orelse continue;
        const level: pager_mod.Synchronous = switch (d.safety_level & pager_synchronous_mask) {
            1 => .off,
            2 => .normal,
            4 => .extra,
            else => .full,
        };
        bt.setPagerFlags(level, db.flags.FullFSync, db.flags.CkptFullFSync, db.flags.CacheSpill);
    }
}

/// Port of actionName(): the name of a foreign key action.
fn actionName(action: int.OE) [:0]const u8 {
    return switch (action) {
        int.OE.SetNull => "SET NULL",
        int.OE.SetDflt => "SET DEFAULT",
        int.OE.Cascade => "CASCADE",
        int.OE.Restrict => "RESTRICT",
        else => "NO ACTION",
    };
}

/// PAGER_JOURNALMODE_QUERY.
const journalmode_query: i32 = -1;

/// Port of pragmaLocate(): the pragma named `name`, or null.
fn pragmaLocate(name: []const u8) ?*const PragmaName {
    var lwr: isize = 0;
    var upr: isize = pragma_names.len - 1;
    while (lwr <= upr) {
        const mid: usize = @intCast(@divTrunc(lwr + upr, 2));
        const rc = ctype.strICmp(name, pragma_names[mid].name);
        if (rc == 0) return &pragma_names[mid];
        if (rc < 0) upr = @as(isize, @intCast(mid)) - 1 else lwr = @as(isize, @intCast(mid)) + 1;
    }
    return null;
}

/// Port of pragmaFunclistLine(): the row of PRAGMA function_list for the
/// implementation `f`, if it is shown (C loops over the pNext chain here).
fn pragmaFunclistLine(v: *Vdbe, f: *const int.FuncDef, is_builtin: bool, show_intern_funcs: bool) void {
    const FN = callback.FNFLAG;
    // The flags column shows the bits of FuncDef.funcFlags as C has them.
    const shown: callback.FUNC = FN.DETERMINISTIC.with(FN.DIRECTONLY).with(FN.SUBTYPE).with(FN.INNOCUOUS).with(.{ .INTERNAL = true });
    const enc_names = [_]?[]const u8{ null, "utf8", "utf16le", "utf16be" };
    if (f.x_sfunc == null) return;
    if (f.func_flags.INTERNAL and !show_intern_funcs) return;
    const typ: []const u8 = if (f.x_value != null) "w" else if (f.x_finalize != null) "a" else "s";
    aux.multiLoad(v, 1, &.{
        .{ .s = f.name },
        .{ .i = @intFromBool(is_builtin) },
        .{ .s = typ },
        .{ .s = enc_names[f.func_flags.enc] },
        .{ .i = f.n_arg },
        .{ .i = @bitCast((if (show_intern_funcs) f.func_flags else f.func_flags.only(shown)).int() ^ FN.INNOCUOUS.int()) },
    }, false);
}

/// Port of integrityCheckResultRow(): output the row in register 3, count
/// it against the error limit in register 1, and halt at the limit.
/// Returns the address of the OP_IfPos.
fn integrityCheckResultRow(v: *Vdbe) i32 {
    _ = aux.addOp2(v, OP.ResultRow, 3, 1);
    const addr = aux.addOp3(v, OP.IfPos, 1, aux.currentAddr(v) + 2, 1);
    _ = aux.addOp0(v, OP.Halt);
    return addr;
}

/// Port of tableSkipIntegrityCheck(): with `obj_tab`, check only that
/// table; otherwise skip imposter tables.
fn tableSkipIntegrityCheck(t: *const Table, obj_tab: ?*const Table) bool {
    if (obj_tab) |o| return t != o;
    return t.tab_flags.Imposter;
}

// ================================================================= pragma

/// Port of sqlite3Pragma(): code the statement
///
///     PRAGMA [schema.]id [= value]
///
/// `id1` is the schema name and `id2` the pragma name if both are given;
/// otherwise `id1` is the pragma name and `id2` empty. `minus` means a
/// minus sign preceded the numeric `value`.
pub fn pragma(p: *Parse, id1: Token, id2: Token, value: ?Token, minus: bool) void {
    if (p.syntax_only) return;
    pragmaImpl(p, id1, id2, value, minus) catch build.oomFault(p);
}

fn pragmaImpl(p: *Parse, id1: Token, id2_arg: Token, value: ?Token, minus: bool) Oom!void {
    const db = p.db;
    const v = build.getVdbe(p) orelse return;
    aux.runOnlyOnce(v);
    p.n_mem = 2;

    // The database the pragma applies to.
    var id2 = id2_arg;
    var id: *const Token = undefined;
    var i_db = build.twoPartName(p, &id1, &id2, &id) orelse return;

    // A named TEMP database must be open.
    if (i_db == 1) build.openTempDatabase(p) catch return;

    const left = (try build.nameFromToken(p.arena, id.*)) orelse return;
    const right: ?[:0]u8 = if (minus)
        try std.fmt.allocPrintSentinel(p.arena, "-{s}", .{value.?.slice()}, 0)
    else
        try build.nameFromToken(p.arena, value);
    const zdb: ?[:0]const u8 = if (id2.n > 0) db.dbs.items[i_db].name else null;
    if (auth.check(p, auth.Code.PRAGMA, left, right, zdb) != auth.OK) return;

    db.busy_handler.n_busy = 0;
    // The SQLITE_FCNTL_PRAGMA file control is not supported by the VFS
    // layer, which is as if every VFS answered SQLITE_NOTFOUND.

    // Unknown pragmas are silently ignored.
    const pn = pragmaLocate(left) orelse {
        // xqlite's own, outside SQLite's table (so pragma_list and
        // PRAGMA function_list are unchanged).
        if (ctype.eqlNoCase(left, "xq_dialect")) xqDialect(p, v, right);
        return;
    };

    if (pn.flags.NeedSchema) {
        prepare.readSchema(p) catch return;
    }

    // Pragmas that return results name their columns.
    if (!pn.flags.NoColumns and (!pn.flags.NoColumns1 or right == null)) {
        setPragmaResultColumnNames(v, pn);
    }

    const pdb = &db.dbs.items[i_db];

    switch (pn.typ) {
        // PRAGMA [schema.]default_cache_size[=N]: the cache size stored in
        // the database header. Setting it also sets cache_size.
        .default_cache_size => {
            const get_cache_size = [_]aux.OpListItem{
                .{ .opcode = OP.Transaction },
                .{ .opcode = OP.ReadCookie, .p2 = 1, .p3 = @backingInt(btree.Meta.default_cache_size) },
                .{ .opcode = OP.IfPos, .p1 = 1, .p2 = 8 },
                .{ .opcode = OP.Integer, .p2 = 2 },
                .{ .opcode = OP.Subtract, .p1 = 1, .p2 = 2, .p3 = 1 },
                .{ .opcode = OP.IfPos, .p1 = 1, .p2 = 8 },
                .{ .opcode = OP.Integer, .p2 = 1 },
                .{ .opcode = OP.Noop },
                .{ .opcode = OP.ResultRow, .p1 = 1, .p2 = 1 },
            };
            aux.usesBtree(v, @intCast(i_db));
            if (right) |z| {
                const size = absInt32(atoi(z));
                build.beginWriteOperation(p, false, i_db);
                _ = aux.addOp3(v, OP.SetCookie, @intCast(i_db), @backingInt(btree.Meta.default_cache_size), size);
                pdb.schema.cache_size = size;
                pdb.bt.?.setCacheSize(size);
            } else {
                p.n_mem += 2;
                const ops = aux.addOpList(v, &get_cache_size) orelse return;
                ops[0].p1 = @intCast(i_db);
                ops[1].p1 = @intCast(i_db);
                ops[6].p1 = int.DEFAULT_CACHE_SIZE;
            }
        },

        // PRAGMA [schema.]page_size[=N]: the page size, which can only be
        // set before the database is created.
        .page_size => {
            const bt = pdb.bt.?;
            if (right) |z| {
                db.next_pagesize = @bitCast(atoi(z));
                bt.setPageSize(db.next_pagesize, 0, false) catch |err| {
                    if (err == error.OutOfMemory) build.oomFault(p);
                };
            } else {
                returnSingleInt(v, bt.getPageSize());
            }
        },

        // PRAGMA [schema.]secure_delete[=ON|OFF|FAST]. Without a schema
        // name the setting applies to every database.
        .secure_delete => {
            var mode: ?btree.SecureDelete = null;
            if (right) |z| {
                mode = if (ctype.eqlNoCase(z, "fast")) .fast else if (getBoolean(z, false)) .on else .off;
            }
            if (id2.n == 0 and mode != null) {
                for (db.dbs.items) |*d| if (d.bt) |bt| {
                    _ = bt.secureDelete(mode);
                };
            }
            const in_effect: btree.SecureDelete = if (pdb.bt) |bt| bt.secureDelete(mode) else .off;
            returnSingleInt(v, @backingInt(in_effect));
        },

        // PRAGMA [schema.]max_page_count[=N] and PRAGMA [schema.]page_count.
        .page_count => {
            build.codeVerifySchema(p, i_db);
            p.n_mem += 1;
            const reg = p.n_mem;
            if (ctype.toLower(left[0]) == 'p') {
                _ = aux.addOp2(v, OP.Pagecount, @intCast(i_db), reg);
            } else {
                var x: i64 = 0;
                if (right) |z| {
                    if (util.decOrHexToI64(z, &x) == .ok) {
                        if (x < 0) x = 0 else if (x > 0xfffffffe) x = 0xfffffffe;
                    } else {
                        x = 0;
                    }
                }
                _ = aux.addOp3(v, OP.MaxPgcnt, @intCast(i_db), reg, @bitCast(@as(u32, @intCast(x))));
            }
            _ = aux.addOp2(v, OP.ResultRow, reg, 1);
        },

        // PRAGMA [schema.]locking_mode[=NORMAL|EXCLUSIVE]. The pager only
        // has the NORMAL mode.
        .locking_mode => {
            const mode = getLockingMode(right);
            if (mode == .exclusive) return pending.notYet(p, "PRAGMA locking_mode=EXCLUSIVE");
            returnSingleText(v, "normal");
        },

        // PRAGMA [schema.]journal_mode[=DELETE|PERSIST|OFF|TRUNCATE|MEMORY|WAL].
        .journal_mode => {
            var mode: i32 = journalmode_query;
            if (right) |z| {
                // An unknown mode is a query.
                for (std.enums.values(pager_mod.JournalMode)) |m| {
                    const name = m.name();
                    if (z.len <= name.len and ctype.eqlNoCase(z, name[0..z.len])) {
                        mode = @backingInt(m);
                        break;
                    }
                }
                // OFF can corrupt the database with ordinary SQL.
                if (mode == @backingInt(pager_mod.JournalMode.off) and db.flags.Defensive) {
                    mode = journalmode_query;
                }
            }
            if (mode == @backingInt(pager_mod.JournalMode.memory)) return pending.notYet(p, "PRAGMA journal_mode=MEMORY");
            if (mode == journalmode_query and id2.n == 0) {
                // "PRAGMA journal_mode" means "PRAGMA main.journal_mode".
                i_db = 0;
                id2.n = 1;
            }
            var ii = db.dbs.items.len;
            while (ii > 0) {
                ii -= 1;
                if (db.dbs.items[ii].bt != null and (ii == i_db or id2.n == 0)) {
                    aux.usesBtree(v, @intCast(ii));
                    _ = aux.addOp3(v, OP.JournalMode, @intCast(ii), 1, mode);
                }
            }
            _ = aux.addOp2(v, OP.ResultRow, 1, 1);
        },

        // PRAGMA [schema.]journal_size_limit[=N].
        .journal_size_limit => {
            const pager = pdb.bt.?.pager;
            var limit: i64 = -2;
            if (right) |z| {
                _ = util.decOrHexToI64(z, &limit);
                if (limit < -1) limit = -1;
            }
            returnSingleInt(v, pager.journalSizeLimit(limit));
        },

        // PRAGMA [schema.]auto_vacuum[=N]: 0 NONE, 1 FULL, 2 INCREMENTAL.
        .auto_vacuum => {
            const bt = pdb.bt.?;
            if (right) |z| {
                const e_auto = getAutoVacuum(z);
                db.next_autovac = @intCast(e_auto);
                // Set the b-tree flags in case this connection creates the
                // database file, which must then be auto-vacuum capable.
                const ok = if (bt.setAutoVacuum(@fromBackingInt(@intCast(e_auto)))) |_| true else |_| false;
                if (ok and (e_auto == 1 or e_auto == 2)) {
                    // Write meta[6] (incremental vacuum), but only if meta[3]
                    // says this really is an auto-vacuum database.
                    const set_meta6 = [_]aux.OpListItem{
                        .{ .opcode = OP.Transaction, .p2 = 1 },
                        .{ .opcode = OP.ReadCookie, .p2 = 1, .p3 = @backingInt(btree.Meta.largest_root_page) },
                        .{ .opcode = OP.If, .p1 = 1 },
                        .{ .opcode = OP.Halt, .p1 = int.RC.OK, .p2 = @intCast(int.OE.Abort.int()) },
                        .{ .opcode = OP.SetCookie, .p2 = @backingInt(btree.Meta.incr_vacuum) },
                    };
                    const i_addr = aux.currentAddr(v);
                    const ops = aux.addOpList(v, &set_meta6) orelse return;
                    ops[0].p1 = @intCast(i_db);
                    ops[1].p1 = @intCast(i_db);
                    ops[2].p2 = i_addr + 4;
                    ops[4].p1 = @intCast(i_db);
                    ops[4].p3 = e_auto - 1;
                    aux.usesBtree(v, @intCast(i_db));
                }
            } else {
                returnSingleInt(v, @backingInt(bt.getAutoVacuum()));
            }
        },

        // PRAGMA [schema.]incremental_vacuum(N): free up to N pages.
        .incremental_vacuum => {
            var limit: i32 = 0;
            if (right) |z| limit = atoi(z);
            if (limit <= 0) limit = 0x7fffffff;
            build.beginWriteOperation(p, false, i_db);
            _ = aux.addOp2(v, OP.Integer, limit, 1);
            const addr = aux.addOp1(v, OP.IncrVacuum, @intCast(i_db));
            _ = aux.addOp1(v, OP.ResultRow, 1);
            _ = aux.addOp2(v, OP.AddImm, 1, -1);
            _ = aux.addOp2(v, OP.IfPos, 1, addr);
            aux.jumpHere(v, addr);
        },

        // PRAGMA [schema.]cache_size[=N]: pages, or KiB if negative.
        .cache_size => {
            if (right) |z| {
                const size = atoi(z);
                pdb.schema.cache_size = size;
                pdb.bt.?.setCacheSize(size);
            } else {
                returnSingleInt(v, pdb.schema.cache_size);
            }
        },

        // PRAGMA [schema.]cache_spill[=BOOLEAN|N]: whether dirty pages may
        // be written before commit, and from how many pages on. The boolean
        // applies to every database.
        .cache_spill => {
            if (right) |z| {
                var size: i32 = 1;
                if (util.getInt32(z)) |n| {
                    size = n;
                    _ = pdb.bt.?.setSpillSize(size);
                }
                if (getBoolean(z, size != 0)) {
                    db.flags.CacheSpill = true;
                } else {
                    db.flags.CacheSpill = false;
                }
                setAllPagerFlags(db);
            } else {
                returnSingleInt(v, if (!db.flags.CacheSpill) 0 else pdb.bt.?.setSpillSize(0));
            }
        },

        // PRAGMA [schema.]mmap_size(N): memory mapping is not supported,
        // as in a build with SQLITE_MAX_MMAP_SIZE=0.
        .mmap_size => returnSingleInt(v, 0),

        // PRAGMA temp_store[=DEFAULT|FILE|MEMORY].
        .temp_store => {
            if (right) |z| changeTempStorage(p, z) else returnSingleInt(v, db.temp_store);
        },

        // PRAGMA temp_store_directory[=DIR]: sqlite3_temp_directory, which
        // the VFS package keeps (the POSIX VFS reads it).
        .temp_store_directory => {
            const vfs_pkg = @import("xqlite_vfs");
            const z = right orelse {
                returnSingleText(v, if (vfs_pkg.temp_directory) |d| std.mem.span(d) else null);
                return;
            };
            if (z.len > 0) {
                const vfs_ = db.vfs orelse return;
                if (!(vfs_.access(z, .read_write) catch false)) {
                    util.errorMsg(p, "not a writable directory", .{});
                    return;
                }
            }
            // SQLITE_TEMP_STORE is 1.
            if (db.temp_store <= 1 and !invalidateTempStorage(p)) return;
            const malloc_mod = @import("malloc.zig");
            const new: ?[*:0]u8 = if (z.len > 0) (try malloc_mod.allocator.dupeSentinel(u8, z, 0)).ptr else null;
            malloc_mod.free(vfs_pkg.temp_directory);
            vfs_pkg.temp_directory = new;
        },

        // PRAGMA data_store_directory: Windows only in SQLite, where it
        // sets sqlite3_data_directory; elsewhere it does nothing.
        .data_store_directory => {},
        .lock_proxy_file => return pending.notYet(p, "PRAGMA lock_proxy_file"),

        // PRAGMA [schema.]synchronous[=OFF|NORMAL|FULL|EXTRA].
        .synchronous => {
            if (right) |z| {
                if (!db.auto_commit) {
                    util.errorMsg(p, "Safety level may not be changed inside a transaction", .{});
                } else if (i_db != 1) {
                    var level: i32 = if (z.len > 0 and ctype.isDigit(z[0])) atoi(z) else getSafetyLevel(z, false, 1);
                    level = (level +% 1) & pager_synchronous_mask;
                    if (level == 0) level = 1;
                    pdb.safety_level = @intCast(level);
                    pdb.sync_set = true;
                    setAllPagerFlags(db);
                }
            } else {
                returnSingleInt(v, @as(i64, pdb.safety_level) - 1);
            }
        },

        // The pragmas that read or set a bit of the connection flags.
        .flag => {
            if (right) |z| {
                var mask = DbFlag.fromInt(pn.i_arg);
                // Foreign keys cannot be turned on or off in a transaction.
                if (!db.auto_commit) mask.ForeignKeys = false;
                if (getBoolean(z, false)) {
                    if (!mask.WriteSchema or !db.flags.Defensive) db.flags.set(mask);
                } else {
                    db.flags.clear(mask);
                    if (mask == DbFlag{ .DeferFKs = true }) {
                        db.n_deferred_imm_cons = 0;
                        db.n_deferred_cons = 0;
                    }
                    // writable_schema=RESET also reloads the schema.
                    if (mask.WriteSchema and ctype.eqlNoCase(z, "reset")) {
                        build.resetAllSchemasOfConnection(db);
                    }
                }
                // Many flags change the code generated, so expire every
                // statement.
                _ = aux.addOp0(v, OP.Expire);
                setAllPagerFlags(db);
                // The C b-tree reads cell_size_check from db->flags; this
                // one keeps its own copy, set here and when a b-tree opens.
                for (db.dbs.items) |*d| if (d.bt) |bt| {
                    bt.cell_size_check = db.flags.CellSizeCk;
                };
            } else {
                setPragmaResultColumnNames(v, pn);
                returnSingleInt(v, @intFromBool(db.flags.intersects(.fromInt(pn.i_arg))));
            }
        },

        // PRAGMA table_info(T) and table_xinfo(T): a row per column of T,
        // the latter including hidden and generated columns.
        .table_info => if (right) |z| {
            build.codeVerifyNamedSchema(p, zdb);
            const t = build.locateTable(p, build.LOCATE_NOERR, z, zdb) orelse return;
            var n_hidden: i32 = 0;
            const pk = build.primaryKeyIndex(t);
            p.n_mem = 7;
            build.viewGetColumnNames(p, t) catch {};
            for (t.cols, 0..) |*col, i| {
                var is_hidden: i32 = 0;
                if (col.col_flags.intersects(int.COLFLAG.NOINSERT)) {
                    if (pn.i_arg == 0) {
                        n_hidden += 1;
                        continue;
                    }
                    if (col.col_flags.VIRTUAL) {
                        is_hidden = 2; // GENERATED ALWAYS AS ... VIRTUAL
                    } else if (col.col_flags.STORED) {
                        is_hidden = 3; // GENERATED ALWAYS AS ... STORED
                    } else {
                        is_hidden = 1; // HIDDEN
                    }
                }
                var k: i32 = 0;
                if (!col.col_flags.PRIMKEY) {
                    k = 0;
                } else if (pk) |pki| {
                    k = 1;
                    while (k <= t.nCol() and k - 1 < pki.ai_column.len and pki.ai_column[@intCast(k - 1)] != i) k += 1;
                } else {
                    k = 1;
                }
                const col_expr = build.columnExpr(t, col);
                const dflt: ?[]const u8 = if (is_hidden >= 2 or col_expr == null) null else col_expr.?.token();
                const values = [_]aux.LoadValue{
                    .{ .i = @as(i32, @intCast(i)) - n_hidden },
                    .{ .s = col.name() },
                    .{ .s = build.columnType(col, "") },
                    .{ .i = @intFromBool(col.not_null != .None) },
                    .{ .s = dflt },
                    .{ .i = k },
                    .{ .i = is_hidden },
                };
                aux.multiLoad(v, 1, if (pn.i_arg != 0) &values else values[0..6], false);
            }
        },

        // PRAGMA table_list[(T)]: a row per table and view of every
        // database.
        .table_list => {
            p.n_mem = 6;
            build.codeVerifyNamedSchema(p, zdb);
            for (0..db.dbs.items.len) |ii| {
                if (zdb) |name| if (!ctype.eqlNoCase(name, db.dbs.items[ii].name)) continue;

                // Make sure the column count of every view is known. Each
                // computation may change the hash table, so restart the scan.
                var init_n_col = db.dbs.items[ii].schema.tbl_hash.count();
                while (init_n_col > 0) : (init_n_col -= 1) {
                    var it = db.dbs.items[ii].schema.tbl_hash.valueIterator();
                    const t = while (it.next()) |tp| {
                        if (tp.*.cols.len == 0) break tp.*;
                    } else break;
                    const sql = try build.mprintf(p, "SELECT*FROM\"%w\"", &.{.{ .str = t.name }});
                    var dummy: ?*Vdbe = null;
                    _ = prepare.prepareLang(db, sql, .sqlite, aux.PREPARE_DONT_LOG, &dummy, null);
                    if (dummy) |d| _ = api.finalize(d);
                    if (db.malloc_failed) return error.OutOfMemory;
                }

                var it = db.dbs.items[ii].schema.tbl_hash.valueIterator();
                while (it.next()) |tp| {
                    const t = tp.*;
                    if (right) |z| if (!ctype.eqlNoCase(z, t.name)) continue;
                    const typ: []const u8 = if (t.isView())
                        "view"
                    else if (t.e_tab_type == .vtab)
                        "virtual"
                    else if (t.tab_flags.Shadow)
                        "shadow"
                    else
                        "table";
                    aux.multiLoad(v, 1, &.{
                        .{ .s = db.dbs.items[ii].name },
                        .{ .s = build.preferredTableName(t.name) },
                        .{ .s = typ },
                        .{ .i = t.nCol() },
                        .{ .i = @intFromBool(t.tab_flags.WithoutRowid) },
                        .{ .i = @intFromBool(t.tab_flags.Strict) },
                    }, false);
                }
            }
        },

        // PRAGMA index_info(I) and index_xinfo(I): a row per column of
        // index I (or of the PRIMARY KEY of WITHOUT ROWID table I), the
        // latter including the columns after the key.
        .index_info => if (right) |z| {
            var idx_opt = build.findIndex(db, z, zdb);
            if (idx_opt == null) {
                if (build.locateTable(p, build.LOCATE_NOERR, z, zdb)) |t| {
                    if (!t.hasRowid()) idx_opt = build.primaryKeyIndex(t);
                }
            }
            if (idx_opt) |idx| {
                const i_idx_db = prepare.schemaToIndex(db, idx.schema);
                var mx: usize = undefined;
                if (pn.i_arg != 0) {
                    mx = idx.n_column;
                    p.n_mem = 6;
                } else {
                    mx = idx.n_key_col;
                    p.n_mem = 3;
                }
                const t = idx.table;
                build.codeVerifySchema(p, @intCast(i_idx_db));
                for (0..mx) |i| {
                    const cnum = idx.ai_column[i];
                    aux.multiLoad(v, 1, &.{
                        .{ .i = @intCast(i) },
                        .{ .i = cnum },
                        .{ .s = if (cnum < 0) null else t.cols[@intCast(cnum)].name() },
                    }, true);
                    if (pn.i_arg != 0) {
                        aux.multiLoad(v, 4, &.{
                            .{ .i = if (i < idx.sort_order.len) idx.sort_order[i] else 0 },
                            .{ .s = if (i < idx.coll.len) idx.coll[i] else coll.str_binary },
                            .{ .i = @intFromBool(i < idx.n_key_col) },
                        }, true);
                    }
                    _ = aux.addOp2(v, OP.ResultRow, 1, p.n_mem);
                }
            }
        },

        // PRAGMA index_list(T): a row per index of table T.
        .index_list => if (right) |z| {
            const t = build.findTable(db, z, zdb) orelse return;
            const i_tab_db = prepare.schemaToIndex(db, t.schema);
            p.n_mem = 5;
            build.codeVerifySchema(p, @intCast(i_tab_db));
            const origin = [_][]const u8{ "c", "u", "pk" };
            var i: i32 = 0;
            var idx_opt = t.index;
            while (idx_opt) |idx| : ({
                idx_opt = idx.next;
                i += 1;
            }) {
                aux.multiLoad(v, 1, &.{
                    .{ .i = i },
                    .{ .s = idx.name },
                    .{ .i = @intFromBool(idx.isUnique()) },
                    .{ .s = origin[@backingInt(idx.idx_type)] },
                    .{ .i = @intFromBool(idx.part_idx_where != null) },
                }, false);
            }
        },

        // PRAGMA database_list.
        .database_list => {
            p.n_mem = 3;
            for (db.dbs.items, 0..) |*d, i| {
                const bt = d.bt orelse continue;
                aux.multiLoad(v, 1, &.{
                    .{ .i = @intCast(i) },
                    .{ .s = d.name },
                    .{ .s = bt.pager.filename() },
                }, false);
            }
        },

        // PRAGMA collation_list: the built-in collations, then those of the
        // connection.
        .collation_list => {
            var i: i32 = 0;
            p.n_mem = 2;
            for (coll.builtins()) |*c| {
                // A collation of the connection may shadow a built-in one.
                if (db.colls.contains(c.name)) continue;
                aux.multiLoad(v, 1, &.{ .{ .i = i }, .{ .s = c.name } }, false);
                i += 1;
            }
            var it = db.colls.valueIterator();
            while (it.next()) |c| {
                aux.multiLoad(v, 1, &.{ .{ .i = i }, .{ .s = c.*.name } }, false);
                i += 1;
            }
        },

        // PRAGMA function_list: the built-in functions, then those of the
        // connection.
        .function_list => {
            const show_intern = db.m_db_flags.InternalFunc;
            p.n_mem = 6;
            for (callback.builtins.names) |defs| {
                for (defs) |*f| pragmaFunclistLine(v, f, true, show_intern);
            }
            var it = db.funcs.valueIterator();
            while (it.next()) |head| {
                var f_opt: ?*int.FuncDef = head.*;
                while (f_opt) |f| : (f_opt = f.next) pragmaFunclistLine(v, f, false, show_intern);
            }
        },

        // PRAGMA module_list: the virtual table modules.
        .module_list => {
            p.n_mem = 1;
            var it = db.modules.valueIterator();
            while (it.next()) |m| aux.multiLoad(v, 1, &.{.{ .s = m.*.name }}, false);
        },

        // PRAGMA pragma_list.
        .pragma_list => {
            for (&pragma_names) |*n| aux.multiLoad(v, 1, &.{.{ .s = n.name }}, false);
        },

        // PRAGMA foreign_key_list(T): a row per column of each foreign key
        // of table T.
        .foreign_key_list => if (right) |z| {
            const t = build.findTable(db, z, zdb) orelse return;
            if (!t.isOrdinary()) return;
            var fk_opt = t.u.tab.fkey;
            if (fk_opt == null) return;
            const i_tab_db = prepare.schemaToIndex(db, t.schema);
            var i: i32 = 0;
            p.n_mem = 8;
            build.codeVerifySchema(p, @intCast(i_tab_db));
            while (fk_opt) |fk| : (fk_opt = fk.next_from) {
                for (fk.cols, 0..) |fc, j| {
                    aux.multiLoad(v, 1, &.{
                        .{ .i = i },
                        .{ .i = @intCast(j) },
                        .{ .s = fk.to },
                        .{ .s = t.cols[@intCast(fc.i_from)].name() },
                        .{ .s = fc.col },
                        .{ .s = actionName(fk.a_action[1]) }, // ON UPDATE
                        .{ .s = actionName(fk.a_action[0]) }, // ON DELETE
                        .{ .s = "NONE" },
                    }, false);
                }
                i += 1;
            }
        },

        .foreign_key_check => try foreignKeyCheck(p, v, i_db, zdb, right),

        // PRAGMA case_sensitive_like=BOOLEAN: reinstall LIKE.
        .case_sensitive_like => if (right) |z| {
            func.registerLikeFunctions(db, getBoolean(z, false));
        },

        .integrity_check => try integrityCheck(p, v, left, if (id2.z == null) null else i_db, value, right),

        // PRAGMA encoding[=UTF-8|UTF-16|UTF-16le|UTF-16be]: the encoding,
        // which can only be chosen before the main database is read.
        .encoding => {
            const EncName = struct { name: []const u8, enc: u8 };
            const encnames = [_]EncName{
                .{ .name = "UTF8", .enc = vi.ENC.UTF8 },
                .{ .name = "UTF-8", .enc = vi.ENC.UTF8 }, // must be element [1]
                .{ .name = "UTF-16le", .enc = vi.ENC.UTF16LE }, // must be element [2]
                .{ .name = "UTF-16be", .enc = vi.ENC.UTF16BE }, // must be element [3]
                .{ .name = "UTF16le", .enc = vi.ENC.UTF16LE },
                .{ .name = "UTF16be", .enc = vi.ENC.UTF16BE },
                .{ .name = "UTF-16", .enc = 0 }, // SQLITE_UTF16NATIVE
                .{ .name = "UTF16", .enc = 0 }, // SQLITE_UTF16NATIVE
            };
            if (right) |z| {
                if (!db.m_db_flags.EncodingFixed) {
                    for (encnames) |e| {
                        if (!ctype.eqlNoCase(z, e.name)) continue;
                        const enc = if (e.enc != 0) e.enc else if (builtin.cpu.arch.endian() == .little) vi.ENC.UTF16LE else vi.ENC.UTF16BE;
                        if (enc != vi.ENC.UTF8) return pending.notYet(p, "PRAGMA encoding=UTF-16");
                        db.dbs.items[0].schema.enc = enc;
                        db.enc = enc;
                        break;
                    } else util.errorMsg(p, "unsupported encoding: {s}", .{z});
                }
            } else {
                prepare.readSchema(p) catch return;
                returnSingleText(v, encnames[db.enc].name);
            }
        },

        // PRAGMA [schema.]schema_version, user_version, application_id
        // [=N], freelist_count and data_version: header values.
        .header_value => {
            const cookie: i32 = @intCast(pn.i_arg);
            aux.usesBtree(v, @intCast(i_db));
            if (right != null and !pn.flags.ReadOnly) {
                const set_cookie = [_]aux.OpListItem{
                    .{ .opcode = OP.Transaction, .p2 = 1 },
                    .{ .opcode = OP.SetCookie },
                };
                const ops = aux.addOpList(v, &set_cookie) orelse return;
                ops[0].p1 = @intCast(i_db);
                ops[1].p1 = @intCast(i_db);
                ops[1].p2 = cookie;
                ops[1].p3 = atoi(right.?);
                ops[1].p5 = 1;
                // No schema_version=N in defensive mode.
                if (cookie == @backingInt(btree.Meta.schema_version) and db.flags.Defensive) {
                    ops[1].opcode = OP.Noop;
                }
            } else {
                const read_cookie = [_]aux.OpListItem{
                    .{ .opcode = OP.Transaction },
                    .{ .opcode = OP.ReadCookie, .p2 = 1 },
                    .{ .opcode = OP.ResultRow, .p1 = 1, .p2 = 1 },
                };
                const ops = aux.addOpList(v, &read_cookie) orelse return;
                ops[0].p1 = @intCast(i_db);
                ops[1].p1 = @intCast(i_db);
                ops[1].p3 = cookie;
                aux.reusable(v);
            }
        },

        // PRAGMA compile_options.
        .compile_options => {
            p.n_mem = 1;
            var i: i32 = 0;
            while (func.compileoptionGet(i)) |opt| : (i += 1) {
                _ = aux.loadString(v, 1, opt);
                _ = aux.addOp2(v, OP.ResultRow, 1, 1);
            }
            aux.reusable(v);
        },

        // PRAGMA [schema.]wal_checkpoint[(PASSIVE|FULL|RESTART|TRUNCATE|NOOP)]:
        // checkpoint one database, or all of them, returning the busy
        // flag, the WAL size and the frames checkpointed.
        .wal_checkpoint => {
            const i_bt: i32 = if (id2.n > 0) @intCast(i_db) else int.MAX_DB;
            var e_mode = pager_mod.CheckpointMode.passive;
            if (right) |z| {
                if (ctype.eqlNoCase(z, "full")) {
                    e_mode = .full;
                } else if (ctype.eqlNoCase(z, "restart")) {
                    e_mode = .restart;
                } else if (ctype.eqlNoCase(z, "truncate")) {
                    e_mode = .truncate;
                } else if (ctype.eqlNoCase(z, "noop")) {
                    e_mode = .noop;
                }
            }
            p.n_mem = 3;
            _ = aux.addOp3(v, OP.Checkpoint, i_bt, @backingInt(e_mode), 1);
            _ = aux.addOp2(v, OP.ResultRow, 1, 3);
        },

        // PRAGMA wal_autocheckpoint[=N].
        .wal_autocheckpoint => {
            if (right) |z| _ = main_mod.walAutocheckpoint(db, atoi(z));
            returnSingleInt(v, main_mod.walAutocheckpointValue(db));
        },

        // PRAGMA shrink_memory: the page caches are not shrunk on demand,
        // so this does nothing.
        .shrink_memory => {},

        // PRAGMA [schema.]optimize[(MASK)]: in analyze.zig.
        .optimize => try @import("analyze.zig").optimize(p, v, i_db, zdb == null, right),

        // PRAGMA busy_timeout[=N].
        .busy_timeout => {
            if (right) |z| if (util.getInt32(z)) |n| {
                _ = main_mod.busyTimeout(db, n);
            };
            returnSingleInt(v, db.busy_timeout);
        },

        // PRAGMA soft_heap_limit[=N].
        .soft_heap_limit => {
            var n: i64 = undefined;
            if (right) |z| if (util.decOrHexToI64(z, &n) == .ok) {
                _ = main_mod.softHeapLimit64(n);
            };
            returnSingleInt(v, main_mod.softHeapLimit64(-1));
        },

        // PRAGMA hard_heap_limit[=N]: can only lower or set the limit.
        .hard_heap_limit => {
            var n: i64 = undefined;
            if (right) |z| if (util.decOrHexToI64(z, &n) == .ok) {
                const prior = main_mod.hardHeapLimit64(-1);
                if (n > 0 and (prior == 0 or prior > n)) _ = main_mod.hardHeapLimit64(n);
            };
            returnSingleInt(v, main_mod.hardHeapLimit64(-1));
        },

        // PRAGMA threads[=N].
        .threads => {
            var n: i64 = undefined;
            if (right) |z| if (util.decOrHexToI64(z, &n) == .ok and n >= 0) {
                _ = main_mod.limit(db, .worker_threads, @intCast(n & 0x7fffffff));
            };
            returnSingleInt(v, main_mod.limit(db, .worker_threads, -1));
        },

        // PRAGMA analysis_limit[=N].
        .analysis_limit => {
            var n: i64 = undefined;
            if (right) |z| if (util.decOrHexToI64(z, &n) == .ok and n >= 0) {
                db.n_analysis_limit = @intCast(n & 0x7fffffff);
            };
            returnSingleInt(v, db.n_analysis_limit);
        },

        // Not in builds without SQLITE_DEBUG or SQLITE_ENABLE_CEROD.
        .activate_extensions, .lock_status, .stats => unreachable,
    }
}

/// sqlite3AbsInt32().
fn absInt32(x: i32) i32 {
    if (x >= 0) return x;
    if (x == std.math.minInt(i32)) return std.math.maxInt(i32);
    return -x;
}

/// PRAGMA [schema.]foreign_key_check[(T)]: a row (table, rowid, parent,
/// fkid) for each row of T (or of every table) whose foreign key refers
/// to no parent row.
fn foreignKeyCheck(p: *Parse, v: *Vdbe, i_db_arg: usize, zdb_arg: ?[:0]const u8, right: ?[:0]u8) Oom!void {
    const db = p.db;
    var i_db = i_db_arg;
    var zdb = zdb_arg;
    const reg_result = p.n_mem + 1;
    p.n_mem += 4;
    p.n_mem += 1;
    const reg_row = p.n_mem;
    // As in C, nothing is checked if the schema has no tables, even if a
    // table is named.
    var it = db.dbs.items[i_db].schema.tbl_hash.valueIterator();
    var more = db.dbs.items[i_db].schema.tbl_hash.count() > 0;
    while (more) {
        var t_opt: ?*Table = null;
        if (right) |z| {
            t_opt = build.locateTable(p, 0, z, zdb);
            more = false;
        } else {
            const tp = it.next() orelse break;
            t_opt = tp.*;
        }
        const t = t_opt orelse continue;
        if (!t.isOrdinary() or t.u.tab.fkey == null) continue;
        i_db = @intCast(prepare.schemaToIndex(db, t.schema));
        zdb = db.dbs.items[i_db].name;
        build.codeVerifySchema(p, i_db);
        expr.touchRegister(p, t.nCol() + reg_row);
        insert.openTable(p, 0, i_db, t, OP.OpenRead);
        _ = aux.loadString(v, reg_result, t.name);

        // Open each parent table, or the index its key uses.
        var i: i32 = 1;
        var fk_opt = t.u.tab.fkey;
        while (fk_opt) |fk| : ({
            i += 1;
            fk_opt = fk.next_from;
        }) {
            const parent = build.findTable(db, fk.to, zdb) orelse continue;
            var idx: ?*Index = null;
            if (!fkey.fkLocateIndex(p, parent, fk, &idx, null)) {
                if (idx) |ix| {
                    _ = aux.addOp3(v, OP.OpenRead, i, @intCast(ix.tnum), @intCast(i_db));
                    aux.setP4KeyInfo(p, ix);
                } else {
                    insert.openTable(p, i, i_db, parent, OP.OpenRead);
                }
            } else {
                more = false;
                break;
            }
        }
        if (fk_opt != null) break;
        if (p.n_tab < i) p.n_tab = i;

        // Look up the parent key of each child row.
        const addr_top = aux.addOp1(v, OP.Rewind, 0);
        i = 1;
        fk_opt = t.u.tab.fkey;
        while (fk_opt) |fk| : ({
            i += 1;
            fk_opt = fk.next_from;
        }) {
            const parent = build.findTable(db, fk.to, zdb);
            var idx: ?*Index = null;
            var ai_cols: ?[]i32 = null;
            if (parent) |par| _ = fkey.fkLocateIndex(p, par, fk, &idx, &ai_cols);
            const addr_ok = aux.makeLabel(p);
            const n_col: i32 = @intCast(fk.cols.len);

            // A NULL in the child key cannot violate the constraint.
            expr.touchRegister(p, reg_row + n_col);
            for (fk.cols, 0..) |fc, j| {
                const i_col = if (ai_cols) |a| a[j] else fc.i_from;
                const reg = reg_row + @as(i32, @intCast(j));
                ec.codeGetColumnOfTable(v, t, 0, i_col, reg);
                _ = aux.addOp2(v, OP.IsNull, reg, addr_ok);
            }

            // A matching parent key is fine.
            if (idx) |ix| {
                const aff = insert.indexAffinityStr(p, ix) orelse return error.OutOfMemory;
                _ = aux.addOp4Str(v, OP.Affinity, reg_row, n_col, 0, aff[0..@intCast(n_col)]);
                _ = aux.addOp4Int(v, OP.Found, i, addr_ok, reg_row, n_col);
            } else if (parent != null) {
                const jmp = aux.currentAddr(v) + 2;
                _ = aux.addOp3(v, OP.SeekRowid, i, jmp, reg_row);
                _ = aux.goto_(v, addr_ok);
            }

            // Report the violation.
            if (t.hasRowid()) {
                _ = aux.addOp2(v, OP.Rowid, 0, reg_result + 1);
            } else {
                _ = aux.addOp2(v, OP.Null, 0, reg_result + 1);
            }
            aux.multiLoad(v, reg_result + 2, &.{ .{ .s = fk.to }, .{ .i = i - 1 } }, true);
            _ = aux.addOp2(v, OP.ResultRow, reg_result, 4);
            aux.resolveLabel(v, addr_ok);
        }
        _ = aux.addOp2(v, OP.Next, 0, addr_top + 1);
        aux.jumpHere(v, addr_top);
    }
}

/// PRAGMA [schema.]integrity_check[(N|T)] and quick_check[(N|T)]: verify
/// the b-trees of every database (or `i_db_opt`), then each table's rows
/// against its indexes, NOT NULL, datatype and CHECK constraints. At most
/// N errors are reported (100 by default); with a table name T, only T is
/// checked. quick_check skips the index contents and key order checks.
fn integrityCheck(p: *Parse, v: *Vdbe, left: []const u8, i_db_opt: ?usize, value: ?Token, right: ?[:0]u8) Oom!void {
    const db = p.db;
    const is_quick = ctype.toLower(left[0]) == 'q';
    p.n_mem = 6;

    // The error limit, or the one table to check.
    var mx_err: i32 = integrity_check_error_max;
    var obj_tab: ?*Table = null;
    if (right) |z| {
        if (util.getInt32(value.?.slice())) |n| {
            mx_err = if (n <= 0) integrity_check_error_max else n;
        } else {
            obj_tab = build.locateTable(p, 0, z, if (i_db_opt) |i| db.dbs.items[i].name else null);
        }
    }
    // Register 1 holds the number of errors still allowed.
    _ = aux.addOp2(v, OP.Integer, mx_err - 1, 1);

    for (0..db.dbs.items.len) |i| {
        if (i_db_opt) |only| if (i != only) continue;
        build.codeVerifySchema(p, i);
        p.ok_const_factor = false;

        // The root pages of every table and index.
        const tbls = &db.dbs.items[i].schema.tbl_hash;
        var cnt: usize = 0;
        var it = tbls.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (tableSkipIntegrityCheck(t, obj_tab)) continue;
            if (t.hasRowid()) cnt += 1;
            var idx_opt = t.index;
            while (idx_opt) |idx| : (idx_opt = idx.next) cnt += 1;
        }
        if (cnt == 0) continue;
        if (obj_tab != null) cnt += 1;
        const roots = try v.alloc().alloc(u32, cnt + 1);
        cnt = 0;
        // A leading 0 makes the b-tree check partial.
        if (obj_tab != null) {
            cnt += 1;
            roots[cnt] = 0;
        }
        it = tbls.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (tableSkipIntegrityCheck(t, obj_tab)) continue;
            if (t.hasRowid()) {
                cnt += 1;
                roots[cnt] = t.tnum;
            }
            var idx_opt = t.index;
            while (idx_opt) |idx| : (idx_opt = idx.next) {
                cnt += 1;
                roots[cnt] = idx.tnum;
            }
        }
        roots[0] = @intCast(cnt);
        const n_root: i32 = @intCast(cnt);

        expr.touchRegister(p, 8 + n_root);
        _ = aux.addOp3(v, OP.Null, 0, 8, 8 + n_root);
        expr.clearTempRegCache(p);

        // The b-tree checks, which leave the entry count of each b-tree
        // in registers 8 and up.
        _ = aux.addOp4(v, OP.IntegrityCk, 1, n_root, 8, .{ .intarray = roots });
        aux.changeP5(v, @intCast(i));
        var addr = aux.addOp1(v, OP.IsNull, 2);
        const in_db = try build.mprintf(p, "*** in database %s ***\n", &.{.{ .str = db.dbs.items[i].name }});
        _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, in_db);
        _ = aux.addOp3(v, OP.Concat, 2, 3, 3);
        _ = integrityCheckResultRow(v);
        aux.jumpHere(v, addr);

        // Every index must have as many entries as its table.
        var k: i32 = if (obj_tab != null) 1 else 0;
        _ = aux.loadString(v, 2, "wrong # of entries in index ");
        it = tbls.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (tableSkipIntegrityCheck(t, obj_tab)) continue;
            var i_tab: i32 = undefined;
            if (t.hasRowid()) {
                i_tab = k;
                k += 1;
            } else {
                // The PRIMARY KEY index holds the rows.
                i_tab = k;
                var idx_opt = t.index;
                while (idx_opt) |idx| : (idx_opt = idx.next) {
                    if (idx.isPrimaryKey()) break;
                    i_tab += 1;
                }
            }
            var idx_opt = t.index;
            while (idx_opt) |idx| : (idx_opt = idx.next) {
                if (idx.part_idx_where == null) {
                    addr = aux.addOp3(v, OP.Eq, 8 + k, 0, 8 + i_tab);
                    _ = aux.loadString(v, 4, idx.name);
                    _ = aux.addOp3(v, OP.Concat, 4, 2, 3);
                    _ = integrityCheckResultRow(v);
                    aux.jumpHere(v, addr);
                }
                k += 1;
            }
        }

        // Check each row of each table.
        it = tbls.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (tableSkipIntegrityCheck(t, obj_tab)) continue;
            if (!t.isOrdinary()) continue;
            try integrityCheckTable(p, v, t, is_quick);
        }
        // Second pass: the xIntegrity method of the virtual tables.
        it = tbls.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (tableSkipIntegrityCheck(t, obj_tab)) continue;
            if (t.isOrdinary()) continue;
            if (!t.isVirtual()) continue;
            if (t.cols.len == 0) {
                if (db.modules.get(t.u.vtab.args[0]) == null) continue;
            }
            build.viewGetColumnNames(p, t) catch {};
            const vt = t.u.vtab.p orelse continue;
            const pv = vt.vtab orelse continue;
            if (pv.module.i_version < 4) continue;
            if (pv.module.x_integrity == null) continue;
            _ = aux.addOp3(v, OP.VCheck, @intCast(i), 3, @intFromBool(is_quick));
            aux.appendP4(v, .{ .tableref = t });
            const a1 = aux.addOp1(v, OP.IsNull, 3);
            _ = integrityCheckResultRow(v);
            aux.jumpHere(v, a1);
        }
    }

    // Report "ok" if there were no errors.
    const end_code = [_]aux.OpListItem{
        .{ .opcode = OP.AddImm, .p1 = 1 },
        .{ .opcode = OP.IfNotZero, .p1 = 1, .p2 = 4 },
        .{ .opcode = OP.String8, .p2 = 3 },
        .{ .opcode = OP.ResultRow, .p1 = 3, .p2 = 1 },
        .{ .opcode = OP.Halt },
        .{ .opcode = OP.String8, .p2 = 3 },
        .{ .opcode = OP.Goto, .p2 = 3 },
    };
    if (aux.addOpList(v, &end_code)) |ops| {
        ops[0].p2 = 1 - mx_err;
        ops[2].setP4(.{ .z = "ok" });
        ops[5].setP4(.{ .z = util.errStr(int.RC.CORRUPT) });
    }
    // A corrupt record seen by OP_Column jumps to the "corrupt" message.
    aux.changeP3(v, 0, aux.currentAddr(v) - 2);
}

/// The per-row checks of integrityCheck() for table `t`: index entries,
/// key order of WITHOUT ROWID tables, NOT NULL, datatypes and CHECK
/// constraints.
fn integrityCheckTable(p: *Parse, v: *Vdbe, t: *Table, is_quick: bool) Oom!void {
    const db = p.db;
    var pk: ?*Index = null;
    var r2: i32 = 0;
    if (!is_quick and !t.hasRowid()) {
        pk = build.primaryKeyIndex(t).?;
        r2 = expr.getTempRange(p, pk.?.n_key_col);
        _ = aux.addOp3(v, OP.Null, 1, r2, r2 + pk.?.n_key_col - 1);
    }
    var i_data_cur: i32 = undefined;
    var i_idx_cur: i32 = undefined;
    _ = insert.openTableAndIndices(p, t, OP.OpenRead, 0, 1, null, &i_data_cur, &i_idx_cur);
    // Register 7 counts the rows, 8+j the entries of the j-th index.
    _ = aux.addOp2(v, OP.Integer, 0, 7);
    var j: i32 = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        j += 1;
    }) _ = aux.addOp2(v, OP.Integer, 0, 8 + j);
    _ = aux.addOp2(v, OP.Rewind, i_data_cur, 0);
    const loop_top = aux.addOp2(v, OP.AddImm, 7, 1);

    // Fetch the right-most column, which parses and sanity-checks the
    // whole record header, and fills the column cache OP_IsType uses.
    var mx_col: i32 = -1;
    if (t.hasRowid()) {
        for (t.cols) |c| {
            if (!c.col_flags.VIRTUAL) mx_col += 1;
        }
        if (mx_col == t.i_pkey) mx_col -= 1;
    } else {
        // VIRTUAL columns are not in the PRIMARY KEY index.
        mx_col = @as(i32, build.primaryKeyIndex(t).?.n_column) - 1;
    }
    if (mx_col >= 0) {
        _ = aux.addOp3(v, OP.Column, i_data_cur, mx_col, 3);
        aux.typeofColumn(v, 3);
    }

    if (pk) |pki| {
        // The keys of a WITHOUT ROWID table must be in order.
        const n_key: i32 = pki.n_key_col;
        const a1 = aux.addOp4Int(v, OP.IdxGT, i_data_cur, 0, r2, n_key);
        _ = aux.addOp1(v, OP.IsNull, r2);
        const msg = try build.mprintf(p, "row not in PRIMARY KEY order for %s", &.{.{ .str = t.name }});
        _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, msg);
        _ = integrityCheckResultRow(v);
        aux.jumpHere(v, a1);
        aux.jumpHere(v, a1 + 1);
        for (0..pki.n_key_col) |jj| ec.codeLoadIndexColumn(p, pki, i_data_cur, jj, r2 + @as(i32, @intCast(jj)));
    }

    // The datatype of every column:
    //   (1) NOT NULL columns may not hold NULL;
    //   (2) non-ANY columns of STRICT tables need exactly their type;
    //   (3) TEXT columns of other tables hold NULL, TEXT or BLOB;
    //   (4) numeric columns of other tables hold no TEXT that converts
    //       to a number without loss.
    const strict = t.tab_flags.Strict;
    for (t.cols, 0..) |*col, jj| {
        const jc: i32 = @intCast(jj);
        if (jc == t.i_pkey) continue;
        const do_type_check = if (strict) col.e_ctype.int() > int.COLTYPE.ANY.int() else col.affinity > int.Aff.blob;
        if (col.not_null == .None and !do_type_check) continue;

        // The operands of OP_IsType.
        var p4: i32 = vi.SQLITE_NULL;
        var p1: i32 = undefined;
        var p3: i32 = undefined;
        if (col.col_flags.VIRTUAL) {
            ec.codeGetColumnOfTable(v, t, i_data_cur, jc, 3);
            p1 = -1;
            p3 = 3;
        } else {
            if (col.i_dflt != 0) {
                const dflt = update.valueFromExpr(v, build.columnExpr(t, col), col.affinity) catch return error.OutOfMemory;
                if (dflt) |m| {
                    p4 = api.valueType(m);
                    mem.release(m);
                }
            }
            p1 = i_data_cur;
            if (!t.hasRowid()) {
                p3 = build.tableColumnToIndex(build.primaryKeyIndex(t).?, jc);
            } else {
                p3 = build.tableColumnToStorage(t, @intCast(jc));
            }
        }

        const label_error = aux.makeLabel(p);
        const label_ok = aux.makeLabel(p);
        if (col.not_null != .None) {
            // (1) NOT NULL columns may not hold NULL.
            const jmp2 = aux.addOp4Int(v, OP.IsType, p1, label_ok, p3, p4);
            var jmp3: i32 = undefined;
            if (p1 < 0) {
                aux.changeP5(v, 0x0f); // INT, REAL, TEXT or BLOB
                jmp3 = jmp2;
            } else {
                aux.changeP5(v, 0x0d); // INT, TEXT or BLOB
                // OP_IsType takes a NaN stored as REAL for a REAL, but it
                // reads as NULL: load the value to be sure.
                _ = aux.addOp3(v, OP.Column, p1, p3, 3);
                update.columnDefault(v, t, jc, 3);
                jmp3 = aux.addOp2(v, OP.NotNull, 3, label_ok);
            }
            const msg = try build.mprintf(p, "NULL value in %s.%s", &.{ .{ .str = t.name }, .{ .str = col.name() } });
            _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, msg);
            if (do_type_check) {
                _ = aux.goto_(v, label_error);
                aux.jumpHere(v, jmp2);
                aux.jumpHere(v, jmp3);
            }
        }
        if (strict and do_type_check) {
            // (2) Exact types in STRICT tables.
            const std_type_mask = [_]u16{
                0x1f, // ANY
                0x18, // BLOB
                0x11, // INT
                0x11, // INTEGER
                0x13, // REAL
                0x14, // TEXT
            };
            _ = aux.addOp4Int(v, OP.IsType, p1, label_ok, p3, p4);
            aux.changeP5(v, std_type_mask[col.e_ctype.stdTypeIndex()]);
            const msg = try build.mprintf(p, "non-%s value in %s.%s", &.{
                .{ .str = build.std_type[col.e_ctype.stdTypeIndex()] },
                .{ .str = t.name },
                .{ .str = col.name() },
            });
            _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, msg);
        } else if (!strict and col.affinity == int.Aff.text) {
            // (3) TEXT columns hold NULL, TEXT or BLOB.
            _ = aux.addOp4Int(v, OP.IsType, p1, label_ok, p3, p4);
            aux.changeP5(v, 0x1c); // NULL, TEXT or BLOB
            const msg = try build.mprintf(p, "NUMERIC value in %s.%s", &.{ .{ .str = t.name }, .{ .str = col.name() } });
            _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, msg);
        } else if (!strict and col.affinity >= int.Aff.numeric) {
            // (4) Numeric columns hold no TEXT that looks like a number.
            _ = aux.addOp4Int(v, OP.IsType, p1, label_ok, p3, p4);
            aux.changeP5(v, 0x1b); // NULL, INT, FLOAT or BLOB
            if (p1 >= 0) ec.codeGetColumnOfTable(v, t, i_data_cur, jc, 3);
            _ = aux.addOp4(v, OP.Affinity, 3, 1, 0, .{ .z = "C" });
            _ = aux.addOp4Int(v, OP.IsType, -1, label_ok, 3, p4);
            aux.changeP5(v, 0x1c); // NULL, TEXT or BLOB
            const msg = try build.mprintf(p, "TEXT value in %s.%s", &.{ .{ .str = t.name }, .{ .str = col.name() } });
            _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, msg);
        }
        aux.resolveLabel(v, label_error);
        _ = integrityCheckResultRow(v);
        aux.resolveLabel(v, label_ok);
    }

    // CHECK constraints.
    if (t.check) |checks| if (!db.flags.IgnoreChecks) {
        const check = (try expr.listDup(p.arena, checks)).?;
        const addr_ck_fault = aux.makeLabel(p);
        const addr_ck_ok = aux.makeLabel(p);
        p.i_self_tab = i_data_cur + 1;
        var kk = check.len() - 1;
        while (kk > 0) : (kk -= 1) ec.exprIfFalse(p, check.at(kk).expr, addr_ck_fault, 0);
        ec.exprIfTrue(p, check.at(0).expr, addr_ck_ok, vi.SQLITE_JUMPIFNULL);
        aux.resolveLabel(v, addr_ck_fault);
        p.i_self_tab = 0;
        const msg = try build.mprintf(p, "CHECK constraint failed in %s", &.{.{ .str = t.name }});
        _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, msg);
        _ = integrityCheckResultRow(v);
        aux.resolveLabel(v, addr_ck_ok);
    };

    if (!is_quick) {
        // The index entries of the row.
        var prior: ?*Index = null;
        var r1: i32 = -1;
        j = 0;
        idx_opt = t.index;
        while (idx_opt) |idx| : ({
            idx_opt = idx.next;
            j += 1;
        }) {
            if (pk == idx) continue;
            const ck_uniq = aux.makeLabel(p);
            var jmp3: i32 = 0;
            r1 = delete.generateIndexKey(p, idx, i_data_cur, 0, false, &jmp3, prior, r1);
            prior = idx;
            const n_column: i32 = idx.n_column;
            // Count the entry.
            _ = aux.addOp2(v, OP.AddImm, 8 + j, 1);
            // The index must hold an entry for the row.
            _ = aux.addOp4Int(v, OP.Found, i_idx_cur + j, ck_uniq, r1, n_column);
            const jmp2 = aux.addOp3(v, OP.IFindKey, i_idx_cur + j, ck_uniq, r1);
            aux.changeP4(v, -1, .{ .index = idx });
            const imprecise = try build.mprintf(p, "index %s stores an imprecise floating-point value for row ", &.{.{ .str = idx.name }});
            _ = aux.addOp4Str(v, OP.String8, 0, 3, 0, imprecise);
            _ = aux.addOp3(v, OP.Concat, 7, 3, 3);
            _ = integrityCheckResultRow(v);
            _ = aux.addOp2(v, OP.Goto, 0, ck_uniq);

            aux.jumpHere(v, jmp2);
            _ = aux.loadString(v, 3, "row ");
            _ = aux.addOp3(v, OP.Concat, 7, 3, 3);
            _ = aux.loadString(v, 4, " missing from index ");
            _ = aux.addOp3(v, OP.Concat, 4, 3, 3);
            const jmp5 = aux.loadString(v, 4, idx.name);
            _ = aux.addOp3(v, OP.Concat, 4, 3, 3);
            const jmp4 = integrityCheckResultRow(v);
            aux.resolveLabel(v, ck_uniq);

            // OP_IdxRowid takes the rowid from the end of the entry, which
            // only works if nothing follows it.
            if (t.hasRowid()) {
                _ = aux.addOp2(v, OP.IdxRowid, i_idx_cur + j, 3);
                const jmp7 = aux.addOp3(v, OP.Eq, 3, 0, r1 + n_column - 1);
                _ = aux.loadString(v, 3, "rowid not at end-of-record for row ");
                _ = aux.addOp3(v, OP.Concat, 7, 3, 3);
                _ = aux.loadString(v, 4, " of index ");
                _ = aux.goto_(v, jmp5 - 1);
                aux.jumpHere(v, jmp7);
            }

            // Columns with a non-BINARY collation must still hold exactly
            // the text of the table.
            var label6: i32 = 0;
            for (0..idx.n_key_col) |kk| {
                if (idx.coll[kk].ptr == coll.str_binary.ptr) continue;
                if (label6 == 0) label6 = aux.makeLabel(p);
                _ = aux.addOp3(v, OP.Column, i_idx_cur + j, @intCast(kk), 3);
                _ = aux.addOp3(v, OP.Ne, 3, label6, r1 + @as(i32, @intCast(kk)));
            }
            if (label6 != 0) {
                const jmp6 = aux.addOp0(v, OP.Goto);
                aux.resolveLabel(v, label6);
                _ = aux.loadString(v, 3, "row ");
                _ = aux.addOp3(v, OP.Concat, 7, 3, 3);
                _ = aux.loadString(v, 4, " values differ from index ");
                _ = aux.goto_(v, jmp5 - 1);
                aux.jumpHere(v, jmp6);
            }

            // A UNIQUE index holds one entry per key, unless the key has a
            // NULL.
            if (idx.isUnique()) {
                const uniq_ok = aux.makeLabel(p);
                for (0..idx.n_key_col) |kk| {
                    const i_col = idx.ai_column[kk];
                    if (i_col >= 0 and t.cols[@intCast(i_col)].not_null != .None) continue;
                    _ = aux.addOp2(v, OP.IsNull, r1 + @as(i32, @intCast(kk)), uniq_ok);
                }
                const jmp6 = aux.addOp1(v, OP.Next, i_idx_cur + j);
                _ = aux.goto_(v, uniq_ok);
                aux.jumpHere(v, jmp6);
                _ = aux.addOp4Int(v, OP.IdxGT, i_idx_cur + j, uniq_ok, r1, idx.n_key_col);
                _ = aux.loadString(v, 3, "non-unique entry in index ");
                _ = aux.goto_(v, jmp5);
                aux.resolveLabel(v, uniq_ok);
            }
            aux.jumpHere(v, jmp4);
            delete.resolvePartIdxLabel(p, jmp3);
        }
    }
    _ = aux.addOp2(v, OP.Next, i_data_cur, loop_top);
    aux.jumpHere(v, loop_top - 1);
    if (pk) |pki| expr.releaseTempRange(p, r2, pki.n_key_col);
}

// ===================================================== pragma virtual tables

/// The eponymous virtual table that runs a pragma (PragmaVtab).
const PragmaVtab = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
    /// The pragma.
    name: *const PragmaName,
    /// Number of hidden columns.
    n_hidden: u8,
    /// Index of the first hidden column.
    i_hidden: u8,

    fn of(p: *vtab.Vtab) *PragmaVtab {
        return @fieldParentPtr("base", p);
    }
};

/// A cursor of a PragmaVtab (PragmaVtabCursor).
const PragmaVtabCursor = struct {
    base: vtab.VtabCursor = .{},
    /// The pragma statement running.
    pragma: ?*Vdbe = null,
    /// Current rowid.
    i_rowid: i64 = 0,
    /// Values of the argument and the schema.
    args: [2]?[:0]u8 = .{ null, null },

    fn of(cur: *vtab.VtabCursor) *PragmaVtabCursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }
};

/// Port of pragmaVtabConnect(): declare the result columns of the pragma
/// and HIDDEN columns for its argument and schema.
fn pragmaVtabConnect(db: *Sqlite3, pn: *const PragmaName, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, err: *?[:0]u8) i32 {
    var buf: [200]u8 = undefined;
    var acc: std.Io.Writer = .fixed(&buf);
    var sep: u8 = '(';
    acc.writeAll("CREATE TABLE x") catch {};
    var i: u8 = 0;
    while (i < pn.n_prag_c_name) : (i += 1) {
        acc.print("{c}\"{s}\"", .{ sep, prag_c_name[pn.i_prag_c_name + i] }) catch {};
        sep = ',';
    }
    if (i == 0) {
        acc.print("(\"{s}\"", .{pn.name}) catch {};
        i += 1;
    }
    var j: u8 = 0;
    if (pn.flags.Result1) {
        acc.writeAll(",arg HIDDEN") catch {};
        j += 1;
    }
    if (pn.flags.intersects(.{ .SchemaOpt = true, .SchemaReq = true })) {
        acc.writeAll(",schema HIDDEN") catch {};
        j += 1;
    }
    acc.writeAll(")") catch {};
    std.debug.assert(acc.end < buf.len - 1);
    buf[acc.end] = 0;
    var rc = vtab.declareVtab(db, buf[0..acc.end :0]);
    var tab: ?*PragmaVtab = null;
    if (rc == int.RC.OK) {
        if (db.gpa.create(PragmaVtab)) |t| {
            t.* = .{ .db = db, .name = pn, .i_hidden = i, .n_hidden = j };
            tab = t;
        } else |_| {
            rc = int.RC.NOMEM;
        }
    } else {
        err.* = db.gpa.dupeSentinel(u8, main_mod.errmsg(db), 0) catch null;
    }
    pp_vtab.* = if (tab) |t| &t.base else null;
    return rc;
}

/// Port of pragmaVtabDisconnect().
fn pragmaVtabDisconnect(p: *vtab.Vtab) i32 {
    const t = PragmaVtab.of(p);
    t.db.gpa.destroy(t);
    return int.RC.OK;
}

/// Port of pragmaVtabBestIndex(): there is no index to choose, but ==
/// constraints on the hidden parameters, the first above all, should be
/// used: unconstrained ones cost much.
fn pragmaVtabBestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    const t = PragmaVtab.of(p);
    info.estimated_cost = 1;
    if (t.n_hidden == 0) return int.RC.OK;
    var seen = [2]usize{ 0, 0 };
    for (info.constraints, 0..) |cons, i| {
        if (cons.i_column < t.i_hidden) continue;
        if (cons.op != vtab.INDEX_CONSTRAINT.EQ) continue;
        if (!cons.usable) return int.RC.CONSTRAINT;
        const j: usize = @intCast(cons.i_column - t.i_hidden);
        std.debug.assert(j < 2);
        seen[j] = i + 1;
    }
    if (seen[0] == 0) {
        info.estimated_cost = 2147483647;
        info.estimated_rows = 2147483647;
        return int.RC.OK;
    }
    var j = seen[0] - 1;
    info.usage[j] = .{ .argv_index = 1, .omit = true };
    info.estimated_cost = 20;
    info.estimated_rows = 20;
    if (seen[1] != 0) {
        j = seen[1] - 1;
        info.usage[j] = .{ .argv_index = 2, .omit = true };
    }
    return int.RC.OK;
}

/// Port of pragmaVtabOpen().
fn pragmaVtabOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t = PragmaVtab.of(p);
    const c = t.db.gpa.create(PragmaVtabCursor) catch return int.RC.NOMEM;
    c.* = .{};
    c.base.vtab = p;
    pp_cursor.* = &c.base;
    return int.RC.OK;
}

/// Port of pragmaVtabCursorClear().
fn pragmaVtabCursorClear(c: *PragmaVtabCursor) void {
    const gpa = PragmaVtab.of(c.base.vtab).db.gpa;
    if (c.pragma) |stmt| _ = api.finalize(stmt);
    c.pragma = null;
    c.i_rowid = 0;
    for (&c.args) |*a| {
        if (a.*) |z| gpa.free(z);
        a.* = null;
    }
}

/// Port of pragmaVtabClose().
fn pragmaVtabClose(cur: *vtab.VtabCursor) i32 {
    const c = PragmaVtabCursor.of(cur);
    const gpa = PragmaVtab.of(cur.vtab).db.gpa;
    pragmaVtabCursorClear(c);
    gpa.destroy(c);
    return int.RC.OK;
}

/// Port of pragmaVtabNext().
fn pragmaVtabNext(cur: *vtab.VtabCursor) i32 {
    const c = PragmaVtabCursor.of(cur);
    var rc: i32 = int.RC.OK;
    c.i_rowid += 1;
    std.debug.assert(c.pragma != null);
    if (api.step(c.pragma.?) != int.RC.ROW) {
        rc = api.finalize(c.pragma.?);
        c.pragma = null;
        pragmaVtabCursorClear(c);
    }
    return rc;
}

/// Port of pragmaVtabFilter(): run "PRAGMA [schema.]name[=arg]".
fn pragmaVtabFilter(cur: *vtab.VtabCursor, _: i32, _: ?[:0]const u8, argv: []*vi.Mem) i32 {
    const c = PragmaVtabCursor.of(cur);
    const t = PragmaVtab.of(cur.vtab);
    const db = t.db;
    pragmaVtabCursorClear(c);
    var j: usize = if (t.name.flags.Result1) 0 else 1;
    for (argv) |a| {
        std.debug.assert(j < c.args.len);
        std.debug.assert(c.args[j] == null);
        if (api.valueText(a)) |text| {
            c.args[j] = db.gpa.dupeSentinel(u8, text, 0) catch return int.RC.NOMEM;
        }
        j += 1;
    }
    const printf = @import("printf.zig");
    var acc = printf.StrAccum.init(@import("malloc.zig").allocator, &.{}, @intCast(db.limit(.sql_length)));
    acc.appendAll("PRAGMA ");
    if (c.args[1]) |schema| acc.appendf("%Q.", &.{.{ .str = schema }});
    acc.appendAll(t.name.name);
    if (c.args[0]) |arg| acc.appendf("=%Q", &.{.{ .str = arg }});
    const sql = acc.finish() orelse return int.RC.NOMEM;
    defer db.gpa.free(sql);
    // xqlite: the PRAGMA is SQLite text, whatever the dialect.
    const rc = prepare.prepareLang(db, sql, .sqlite, 0, &c.pragma, null);
    if (rc != int.RC.OK) {
        vtab.setErrMsg(db, &t.base, "{s}", .{main_mod.errmsg(db)});
        return rc;
    }
    return pragmaVtabNext(cur);
}

/// Port of pragmaVtabEof().
fn pragmaVtabEof(cur: *vtab.VtabCursor) bool {
    return PragmaVtabCursor.of(cur).pragma == null;
}

/// Port of pragmaVtabColumn(): the column of the pragma's row, or a
/// hidden argument.
fn pragmaVtabColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = PragmaVtabCursor.of(cur);
    const t = PragmaVtab.of(cur.vtab);
    if (i < t.i_hidden) {
        api.resultValue(ctx, api.columnValue(c.pragma.?, @intCast(i)));
    } else {
        api.resultText(ctx, c.args[@intCast(i - t.i_hidden)], .transient);
    }
    return int.RC.OK;
}

/// Port of pragmaVtabRowid().
fn pragmaVtabRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = PragmaVtabCursor.of(cur).i_rowid;
    return int.RC.OK;
}

/// The pragma virtual table module (pragmaVtabModule).
const pragma_vtab_module: vtab.Module = .{
    .i_version = 0,
    .x_connect = vtab.Module.constructor(pragmaVtabConnect),
    .x_best_index = pragmaVtabBestIndex,
    .x_disconnect = pragmaVtabDisconnect,
    .x_open = pragmaVtabOpen,
    .x_close = pragmaVtabClose,
    .x_filter = pragmaVtabFilter,
    .x_next = pragmaVtabNext,
    .x_eof = pragmaVtabEof,
    .x_column = pragmaVtabColumn,
    .x_rowid = pragmaVtabRowid,
};

/// Port of sqlite3PragmaVtabRegister(): if `name` is "pragma_" and the
/// name of a pragma that returns rows, register the eponymous virtual
/// table module that runs it.
pub fn vtabRegister(db: *Sqlite3, name: []const u8) ?*int.Module {
    std.debug.assert(ctype.eqlNoCase(name[0..7], "pragma_"));
    const pn = pragmaLocate(name[7..]) orelse return null;
    if (!pn.flags.intersects(.{ .Result0 = true, .Result1 = true })) return null;
    std.debug.assert(db.modules.get(name) == null);
    return vtab.createModuleInternal(db, name, &pragma_vtab_module, vtab.Module.auxFor(pragmaVtabConnect, pn), null);
}
