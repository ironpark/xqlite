//! Virtual tables (port of vtab.c), and the interface between the core
//! and virtual table modules (sqlite3_module and the sqlite3_vtab_*()
//! functions of sqlite.h).
//!
//! A module is a `Module`: a struct of optional methods, as
//! sqlite3_module. Its objects embed `Vtab` (sqlite3_vtab) and
//! `VtabCursor` (sqlite3_vtab_cursor) and recover themselves with
//! @fieldParentPtr. Strings a module hands to the core (`Vtab.err_msg`,
//! the error of xCreate/xConnect, `IndexInfo.idx_str` with
//! `need_to_free_idx_str`) are allocated with sqlite3_malloc()
//! (malloc.allocator) or the connection's allocator (db.gpa); the core
//! frees them through db.gpa, which, as sqlite3DbFree(), takes either.
//!
//! The methods return C result codes, which may be extended codes. The
//! functions here that call them for the VM (begin(), savepoint(),
//! sync(), callCreate(), callDestroy()) pass the code on as it is; the
//! opcodes turn it into an error (Exec.check()), keeping the code in
//! Vdbe.rc. The sqlite3_vtab_*() and sqlite3_*_module() functions are
//! the C-shaped API and return codes too.

const std = @import("std");
const int = @import("sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");
const aux = @import("../vdbe/aux.zig");
const serial = @import("../vdbe/serial.zig");
const btree = @import("xqlite_storage").btree;
const build = @import("build.zig");
const auth = @import("auth.zig");
const prepare = @import("prepare.zig");
const util = @import("util.zig");
const main_mod = @import("main.zig");
const expr_mod = @import("expr.zig");
const tokenize = @import("../parse/tokenize.zig");
const ctype = @import("xqlite_base").ctype;
const wi = @import("where_int.zig");
const malloc = @import("malloc.zig");
const thunk = @import("xqlite_base").thunk;
const record_fmt = @import("xqlite_storage").record;

const Allocator = std.mem.Allocator;
const Parse = int.Parse;
const Table = int.Table;
const Token = int.Token;
const Sqlite3 = int.Sqlite3;
const VTable = int.VTable;
const FuncDef = int.FuncDef;
const Mem = vi.Mem;
const Context = vi.Context;
const RC = int.RC;
const TK = int.TK;
const OP = vi.OP;

// ================================================================ the API

/// A virtual table module (sqlite3_module). Methods left null are not
/// implemented; which are required is as documented for SQLite. Methods
/// return an SQLite result code unless noted.
pub const Module = struct {
    /// iVersion: 1, 2 for xSavepoint/xRelease/xRollbackTo, 3 for
    /// xShadowName, 4 for xIntegrity.
    i_version: i32 = 1,
    /// Make a new virtual table (CREATE VIRTUAL TABLE). `argv` holds the
    /// module name, the database name, the table name and the module
    /// arguments. The constructor must call declareVtab() and store its
    /// object in `vtab`; on failure it may set `err` (from db.gpa).
    x_create: ?ConstructFn = null,
    /// Connect to an existing virtual table; as x_create.
    x_connect: ?ConstructFn = null,
    x_best_index: ?*const fn (vtab: *Vtab, info: *IndexInfo) i32 = null,
    x_disconnect: ?*const fn (vtab: *Vtab) i32 = null,
    x_destroy: ?*const fn (vtab: *Vtab) i32 = null,
    x_open: ?*const fn (vtab: *Vtab, cursor: *?*VtabCursor) i32 = null,
    x_close: ?*const fn (cursor: *VtabCursor) i32 = null,
    /// Start a scan: `idx_num` and `idx_str` are those xBestIndex chose,
    /// `argv` the constraint values it asked for.
    x_filter: ?*const fn (cursor: *VtabCursor, idx_num: i32, idx_str: ?[:0]const u8, argv: []*Mem) i32 = null,
    x_next: ?*const fn (cursor: *VtabCursor) i32 = null,
    /// True past the last row.
    x_eof: ?*const fn (cursor: *VtabCursor) bool = null,
    /// Set the result of `ctx` (api.result*()) to column `i`.
    x_column: ?*const fn (cursor: *VtabCursor, ctx: *Context, i: i32) i32 = null,
    x_rowid: ?*const fn (cursor: *VtabCursor, rowid: *i64) i32 = null,
    /// Insert, update or delete a row, as for sqlite3_module.xUpdate.
    x_update: ?*const fn (vtab: *Vtab, argv: []*Mem, rowid: *i64) i32 = null,
    x_begin: ?*const fn (vtab: *Vtab) i32 = null,
    x_sync: ?*const fn (vtab: *Vtab) i32 = null,
    x_commit: ?*const fn (vtab: *Vtab) i32 = null,
    x_rollback: ?*const fn (vtab: *Vtab) i32 = null,
    /// Overload function `name` taking `n_arg` arguments when its first
    /// argument is a column of this table: nonzero (or at least
    /// INDEX_CONSTRAINT.FUNCTION, to offer it to xBestIndex) with the
    /// implementation and its user data set.
    x_find_function: ?*const fn (vtab: *Vtab, n_arg: i32, name: [:0]const u8, func: *?FuncDef.StepFn, arg: *?*anyopaque) i32 = null,
    x_rename: ?*const fn (vtab: *Vtab, new_name: [:0]const u8) i32 = null,
    x_savepoint: ?*const fn (vtab: *Vtab, i: i32) i32 = null,
    x_release: ?*const fn (vtab: *Vtab, i: i32) i32 = null,
    x_rollback_to: ?*const fn (vtab: *Vtab, i: i32) i32 = null,
    /// Whether `name` is the suffix of a shadow table name. `aux` is the
    /// pAux of the module, as for xCreate (C passes nothing).
    x_shadow_name: ?ShadowNameFn = null,
    /// Check the table's content; report problems in `err` (db.gpa).
    x_integrity: ?*const fn (vtab: *Vtab, schema: [:0]const u8, tab_name: [:0]const u8, flags: i32, err: *?[:0]u8) i32 = null,

    pub const ConstructFn = *const fn (db: *Sqlite3, aux: ?*anyopaque, argv: []const [:0]const u8, vtab: *?*Vtab, err: *?[:0]u8) i32;
    pub const ShadowNameFn = *const fn (aux: ?*anyopaque, name: []const u8) bool;

    /// The type of the pAux that `f`, a typed xCreate or xConnect, takes
    /// as its second parameter.
    pub fn Aux(comptime f: anytype) type {
        return @typeInfo(@TypeOf(f)).@"fn".param_types[1].?;
    }

    /// The ConstructFn of `f`, an xCreate or xConnect taking the pAux of
    /// its module typed (thunk.thunk()). Register the module with
    /// auxFor(f, aux) as pAux.
    pub fn constructor(comptime f: anytype) ConstructFn {
        return thunk.thunk(ConstructFn, f);
    }

    /// The ShadowNameFn of `f`, an xShadowName taking the pAux typed as
    /// constructor() does.
    pub fn shadowName(comptime f: anytype) ShadowNameFn {
        return thunk.thunk(ShadowNameFn, f);
    }

    /// `p_aux`, of the type constructor(f) takes, as the pAux of a module.
    pub fn auxFor(comptime f: anytype, p_aux: Aux(f)) ?*anyopaque {
        return @ptrCast(@constCast(p_aux));
    }
};

/// The base of a virtual table object (sqlite3_vtab). The core sets its
/// fields after the constructor returns.
pub const Vtab = struct {
    module: *const Module = undefined,
    /// Open cursors (nRef).
    n_ref: i32 = 0,
    /// An error message for the core to report (from db.gpa).
    err_msg: ?[:0]u8 = null,
};

/// The base of a virtual table cursor (sqlite3_vtab_cursor).
pub const VtabCursor = struct {
    vtab: *Vtab = undefined,
};

/// xDisconnect, xOpen and xClose of a built-in module: its table type
/// `T` and cursor type `C` hold their base (Vtab, VtabCursor) in a field
/// `base`, and both live in the connection's allocator, which `T` has
/// as `db`. The declarations below are looked up with @hasDecl, so they
/// must be pub.
///   - disconnect frees the table;
///   - open makes the cursor `C.init(t)` (`fn (t: *T) C`), or `.{}` if C
///     declares no init, then calls `c.opened(t)` if C declares it, once
///     the cursor is in place (for pointers into itself);
///   - close calls `c.deinit(db)` if C declares it, then frees it.
pub fn Lifecycle(comptime T: type, comptime C: type) type {
    return struct {
        pub fn table(p: *Vtab) *T {
            return @alignCast(@fieldParentPtr("base", p));
        }

        pub fn cursor(p: *VtabCursor) *C {
            return @alignCast(@fieldParentPtr("base", p));
        }

        pub fn disconnect(p: *Vtab) i32 {
            const t = table(p);
            t.db.gpa.destroy(t);
            return int.RC.OK;
        }

        pub fn open(p: *Vtab, pp_cursor: *?*VtabCursor) i32 {
            const t = table(p);
            const c = t.db.gpa.create(C) catch return int.RC.NOMEM;
            c.* = if (@hasDecl(C, "init")) C.init(t) else .{};
            if (@hasDecl(C, "opened")) c.opened(t);
            pp_cursor.* = &c.base;
            return int.RC.OK;
        }

        pub fn close(p: *VtabCursor) i32 {
            const c = cursor(p);
            const db = table(p.vtab).db;
            if (@hasDecl(C, "deinit")) c.deinit(db);
            db.gpa.destroy(c);
            return int.RC.OK;
        }
    };
}

/// sqlite3_index_info.aConstraint[] (sqlite3_index_constraint).
pub const IndexConstraint = struct {
    /// Column constrained; -1 for the rowid.
    i_column: i32,
    /// INDEX_CONSTRAINT.*.
    op: u8,
    usable: bool = false,
    /// Used internally (iTermOffset).
    i_term_offset: i32,
};

/// sqlite3_index_info.aOrderBy[] (sqlite3_index_orderby).
pub const IndexOrderBy = struct {
    i_column: i32,
    desc: bool,
};

/// sqlite3_index_info.aConstraintUsage[].
pub const IndexConstraintUsage = struct {
    /// If positive, the constraint's value is argv[argv_index-1] of
    /// xFilter.
    argv_index: i32 = 0,
    /// Do not code a test for the constraint.
    omit: bool = false,
};

/// The input and output of xBestIndex (sqlite3_index_info).
pub const IndexInfo = struct {
    // Inputs.
    constraints: []IndexConstraint,
    order_by: []IndexOrderBy,
    // Outputs.
    usage: []IndexConstraintUsage,
    idx_num: i32 = 0,
    idx_str: ?[:0]u8 = null,
    /// `idx_str` is from db.gpa and the core frees it.
    need_to_free_idx_str: bool = false,
    order_by_consumed: bool = false,
    estimated_cost: f64 = 0,
    estimated_rows: i64 = 0,
    /// INDEX_SCAN_* flags.
    idx_flags: i32 = 0,
    /// Input: the columns used by the statement.
    col_used: u64 = 0,
};

/// sqlite3_index_info.idxFlags (SQLITE_INDEX_SCAN_*).
pub const INDEX_SCAN_UNIQUE: i32 = 0x00000001;
pub const INDEX_SCAN_HEX: i32 = 0x00000002;

/// IndexConstraint.op (SQLITE_INDEX_CONSTRAINT_*).
pub const INDEX_CONSTRAINT = struct {
    pub const EQ: u8 = 2;
    pub const GT: u8 = 4;
    pub const LE: u8 = 8;
    pub const LT: u8 = 16;
    pub const GE: u8 = 32;
    pub const MATCH: u8 = 64;
    pub const LIKE: u8 = 65;
    pub const GLOB: u8 = 66;
    pub const REGEXP: u8 = 67;
    pub const NE: u8 = 68;
    pub const ISNOT: u8 = 69;
    pub const ISNOTNULL: u8 = 70;
    pub const ISNULL: u8 = 71;
    pub const IS: u8 = 72;
    pub const LIMIT: u8 = 73;
    pub const OFFSET: u8 = 74;
    pub const FUNCTION: u8 = 150;
};

/// sqlite3_vtab_config() options (SQLITE_VTAB_*).
pub const VTAB_CONSTRAINT_SUPPORT: i32 = 1;
pub const VTAB_INNOCUOUS: i32 = 2;
pub const VTAB_DIRECTONLY: i32 = 3;
pub const VTAB_USES_ALL_SCHEMAS: i32 = 4;

/// sqlite3_vtab_on_conflict() results.
pub const SQLITE_ROLLBACK: i32 = 1;
pub const SQLITE_IGNORE: i32 = 2;
pub const SQLITE_FAIL: i32 = 3;
pub const SQLITE_ABORT: i32 = 4;
pub const SQLITE_REPLACE: i32 = 5;

/// Set the error message of `vtab` to a copy of the formatted text.
pub fn setErrMsg(db: *Sqlite3, vtab: *Vtab, comptime fmt: []const u8, args: anytype) void {
    setErrMsgOwned(db, vtab, std.fmt.allocPrintSentinel(db.gpa, fmt, args, 0) catch null);
}

/// Set the error message of `vtab` to `msg` (from db.gpa, or null for
/// OOM), which it takes over, freeing the old one.
pub fn setErrMsgOwned(db: *Sqlite3, vtab: *Vtab, msg: ?[:0]u8) void {
    freeErrMsg(db, vtab);
    vtab.err_msg = msg;
}

/// Free the error message of `vtab`, if any. The core does this before
/// xDisconnect and xDestroy, so modules need not.
fn freeErrMsg(db: *Sqlite3, vtab: *Vtab) void {
    if (vtab.err_msg) |old| db.gpa.free(old);
    vtab.err_msg = null;
}

// ============================================================== the core

/// The state of the xCreate or xConnect running (VtabCtx), for
/// declareVtab() and vtabConfig().
pub const VtabCtx = struct {
    /// The virtual table being constructed.
    vtable: *VTable,
    /// The Table of the virtual table.
    tab: *Table,
    prior: ?*VtabCtx,
    /// declareVtab() was called.
    b_declared: bool = false,
};

/// Port of sqlite3VtabCreateModule(): install module `name`, replacing any
/// module of that name; delete it if `module` is null.
/// Null if out of memory, which is recorded.
pub fn createModuleInternal(db: *Sqlite3, name: []const u8, module: ?*const Module, aux_data: ?*anyopaque, x_destroy: ?int.DestructorFn) ?*int.Module {
    return createModuleOrOom(db, name, module, aux_data, x_destroy) catch {
        db.oomFault();
        return null;
    };
}

fn createModuleOrOom(db: *Sqlite3, name: []const u8, module: ?*const Module, aux_data: ?*anyopaque, x_destroy: ?int.DestructorFn) error{OutOfMemory}!?*int.Module {
    const gpa = db.gpa;
    var new: ?*int.Module = null;
    var old: ?*int.Module = null;
    if (module) |m| {
        const pm = try gpa.create(int.Module);
        errdefer gpa.destroy(pm);
        const copy = try gpa.dupeSentinel(u8, name, 0);
        errdefer gpa.free(copy);
        pm.* = .{ .module = m, .name = copy, .aux = aux_data, .x_destroy = x_destroy };
        const gop = try db.modules.getOrPut(gpa, pm.name);
        if (gop.found_existing) old = gop.value_ptr.*;
        gop.key_ptr.* = pm.name;
        gop.value_ptr.* = pm;
        new = pm;
    } else if (db.modules.fetchRemove(name)) |kv| {
        old = kv.value;
    }
    if (old) |del| {
        epoTableClear(db, del);
        moduleUnref(db, del);
    }
    return new;
}

/// Port of createModule(): sqlite3_create_module_v2(). The destructor
/// of `aux_data` runs if the registration fails.
fn createModuleImpl(db: *Sqlite3, name: []const u8, module: ?*const Module, aux_data: ?*anyopaque, x_destroy: ?int.DestructorFn) i32 {
    _ = createModuleInternal(db, name, module, aux_data, x_destroy);
    const rc = main_mod.apiExit(db, RC.OK);
    if (rc != RC.OK) if (x_destroy) |d| d(aux_data);
    return rc;
}

/// Port of sqlite3_create_module(): register module `name`; `aux_data`
/// is passed to its constructors.
pub fn createModule(db: *Sqlite3, name: []const u8, module: ?*const Module, aux_data: ?*anyopaque) i32 {
    return createModuleImpl(db, name, module, aux_data, null);
}

/// Port of sqlite3_create_module_v2(): sqlite3_create_module() with a
/// destructor for `aux_data`, run when the module is replaced or the
/// connection closes.
pub fn createModuleV2(db: *Sqlite3, name: []const u8, module: ?*const Module, aux_data: ?*anyopaque, x_destroy: ?int.DestructorFn) i32 {
    return createModuleImpl(db, name, module, aux_data, x_destroy);
}

/// Port of sqlite3_drop_modules(): unregister every module whose name is
/// not in `keep` (all of them if `keep` is null).
pub fn dropModules(db: *Sqlite3, keep: ?[]const []const u8) i32 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(db.gpa);
    var it = db.modules.valueIterator();
    while (it.next()) |pm| {
        if (keep) |list| {
            var found = false;
            for (list) |k| {
                if (std.mem.eql(u8, k, pm.*.name)) found = true;
            }
            if (found) continue;
        }
        names.append(db.gpa, pm.*.name) catch return RC.NOMEM;
    }
    for (names.items) |n| {
        // `n` belongs to the module being dropped, but deleting a module
        // uses its name only for the lookup, before the module is freed.
        _ = createModuleImpl(db, n, null, null, null);
    }
    return RC.OK;
}

/// Port of sqlite3VtabModuleUnref(): drop a reference to a module; the
/// last one destroys it.
pub fn moduleUnref(db: *Sqlite3, m: *int.Module) void {
    std.debug.assert(m.n_ref_module > 0);
    m.n_ref_module -= 1;
    if (m.n_ref_module == 0) {
        if (m.x_destroy) |d| d(m.aux);
        std.debug.assert(m.epo_tab == null);
        db.gpa.free(m.name);
        db.gpa.destroy(m);
    }
}

/// Port of sqlite3VtabLock(): keep `vt` from being disconnected.
pub fn lock(vt: *VTable) void {
    vt.n_ref += 1;
}

/// Port of sqlite3GetVTable(): the VTable of `t` for connection `db`.
pub fn getVTable(db: *Sqlite3, t: *Table) ?*VTable {
    std.debug.assert(t.isVirtual());
    var it = t.u.vtab.p;
    while (it) |vt| : (it = vt.next) {
        if (vt.db == db) return vt;
    }
    return null;
}

/// Port of sqlite3VtabUnlock(): drop a reference; the last one calls
/// xDisconnect.
pub fn unlock(vt: *VTable) void {
    const db = vt.db;
    std.debug.assert(vt.n_ref > 0);
    vt.n_ref -= 1;
    if (vt.n_ref == 0) {
        if (vt.vtab) |p| {
            freeErrMsg(db, p);
            _ = p.module.x_disconnect.?(p);
        }
        moduleUnref(db, vt.mod);
        db.gpa.destroy(vt);
    }
}

/// Port of vtabDisconnectAll(): move the VTables of `p` to the
/// disconnect lists of their connections, except that of `db`, which
/// stays and is returned.
fn disconnectAll(db: ?*Sqlite3, p: *Table) ?*VTable {
    std.debug.assert(p.isVirtual());
    var ret: ?*VTable = null;
    var it = p.u.vtab.p;
    p.u.vtab.p = null;
    while (it) |vt| {
        const db2 = vt.db;
        const next = vt.next;
        if (db != null and db2 == db.?) {
            ret = vt;
            p.u.vtab.p = vt;
            vt.next = null;
        } else {
            vt.next = db2.disconnect;
            db2.disconnect = vt;
        }
        it = next;
    }
    std.debug.assert(db == null or ret != null);
    return ret;
}

/// Port of sqlite3VtabDisconnect(): unlink and unlock the VTable of `p`
/// for `db` (when `db` closes).
pub fn disconnect(db: *Sqlite3, p: *Table) void {
    std.debug.assert(p.isVirtual());
    var pp: *?*VTable = &p.u.vtab.p;
    while (pp.*) |vt| : (pp = &vt.next) {
        if (vt.db == db) {
            pp.* = vt.next;
            unlock(vt);
            break;
        }
    }
}

/// Port of sqlite3VtabUnlockList(): disconnect the VTables queued on
/// `db`.
pub fn unlockList(db: *Sqlite3) void {
    var p = db.disconnect;
    if (p != null) {
        db.disconnect = null;
        while (p) |vt| {
            const next = vt.next;
            unlock(vt);
            p = next;
        }
    }
}

/// Port of sqlite3VtabClear(): forget the virtual table state of `p`
/// before it is freed.
pub fn clear(db: *Sqlite3, p: *Table) void {
    std.debug.assert(p.isVirtual());
    _ = db;
    _ = disconnectAll(null, p);
    // The arguments live in the table's memory; the declared columns in
    // their own.
    p.u.vtab.args = &.{};
    if (p.u.vtab.decl_mem) |m| {
        p.cols = &.{};
        p.index = null;
        const gpa = m.child_allocator;
        m.deinit();
        gpa.destroy(m);
        p.u.vtab.decl_mem = null;
    }
}

/// Port of addModuleArgument(): append `arg` (in the table's memory) to
/// the module arguments of `t`.
fn addModuleArgument(p: *Parse, t: *Table, arg: ?[:0]const u8) void {
    const db = p.db;
    std.debug.assert(t.isVirtual());
    const n_arg = t.u.vtab.args.len;
    if (n_arg + 3 >= @as(usize, @intCast(db.limit(.column)))) {
        util.errorMsg(p, "too many columns on {s}", .{t.name});
    }
    const z = arg orelse return;
    const a = t.mem.?.allocator();
    const args = a.realloc(t.u.vtab.args, n_arg + 1) catch return build.oomFault(p);
    args[n_arg] = z;
    t.u.vtab.args = args;
}

/// Port of sqlite3VtabBeginParse(): the start of CREATE VIRTUAL TABLE,
/// after the module name.
pub fn beginParse(p: *Parse, name1: Token, name2: Token, module_name: Token, if_not_exists: bool) void {
    if (p.syntax_only) return;
    build.startTable(p, name1, name2, false, false, true, if_not_exists);
    const t = p.new_table orelse return;
    std.debug.assert(t.index == null);
    t.e_tab_type = .vtab;
    t.u = .{ .vtab = .{} };
    std.debug.assert(t.u.vtab.args.len == 0);
    const a = t.mem.?.allocator();
    addModuleArgument(p, t, build.nameFromToken(a, module_name) catch return build.oomFault(p));
    // The database name goes here when a constructor runs.
    addModuleArgument(p, t, "");
    addModuleArgument(p, t, a.dupeSentinel(u8, t.name, 0) catch return build.oomFault(p));
    std.debug.assert((p.name_token.z == name2.z and name2.z != null) or
        (p.name_token.z == name1.z and name2.z == null));
    p.name_token.n = @intCast(@intFromPtr(module_name.z.? + module_name.n) - @intFromPtr(p.name_token.z.?));

    // The second check of CREATE VIRTUAL TABLE (startTable() made the
    // first, for the sqlite_schema row).
    if (t.u.vtab.args.len > 0) {
        const i_db: usize = @intCast(prepare.schemaToIndex(p.db, t.schema));
        _ = auth.check(p, auth.Code.CREATE_VTABLE, t.name, t.u.vtab.args[0], p.db.dbs.items[i_db].name);
    }
}

/// Port of addArgumentToVtab(): add the argument in p.s_arg.
fn addArgumentToVtab(p: *Parse) void {
    if (p.s_arg.z != null) if (p.new_table) |t| {
        const a = t.mem.?.allocator();
        addModuleArgument(p, t, a.dupeSentinel(u8, p.s_arg.slice(), 0) catch return build.oomFault(p));
    };
}

/// Port of sqlite3VtabFinishParse(): the end of CREATE VIRTUAL TABLE.
/// Unless reading the schema, code its sqlite_schema row and the
/// xCreate call; otherwise add the table to the schema.
pub fn finishParse(p: *Parse, end: ?Token) void {
    const t = p.new_table orelse return;
    const db = p.db;
    if (p.syntax_only) return;
    std.debug.assert(t.isVirtual());
    addArgumentToVtab(p);
    p.s_arg.z = null;
    if (t.u.vtab.args.len < 1) return;

    if (!db.init.busy) {
        main_mod.mayAbort(p);
        // The complete text of the statement.
        if (end) |e| {
            p.name_token.n = @intCast(@intFromPtr(e.z.?) - @intFromPtr(p.name_token.z.?) + e.n);
        }
        const stmt = build.mprintf(p, "CREATE VIRTUAL TABLE %T", &.{.{ .token = &p.name_token }}) catch return build.oomFault(p);

        // Fill in the placeholder row of sqlite_schema coded by
        // startTable(), whose rowid is in register u1.cr.reg_rowid.
        const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
        std.debug.assert(p.is_create);
        build.nestedParse(p, "UPDATE %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " SET type='table', name=%Q, tbl_name=%Q, rootpage=0, sql=%Q WHERE rowid=#%d", &.{
            .{ .str = db.dbs.items[i_db].name },
            .{ .str = t.name },
            .{ .str = t.name },
            .{ .str = stmt },
            .{ .int = p.u1.cr.reg_rowid },
        });
        const v = build.getVdbe(p) orelse return;
        build.changeCookie(p, i_db);

        _ = aux.addOp0(v, OP.Expire);
        const where = build.mprintf(p, "name=%Q AND sql=%Q", &.{ .{ .str = t.name }, .{ .str = stmt } }) catch return build.oomFault(p);
        aux.addParseSchemaOp(v, @intCast(i_db), where, 0);

        p.n_mem += 1;
        const i_reg = p.n_mem;
        _ = aux.loadString(v, i_reg, t.name);
        _ = aux.addOp2(v, OP.VCreate, @intCast(i_db), i_reg);
    } else {
        // Rereading sqlite_schema: add the table to the schema.
        const s = t.schema.?;
        build.markAllShadowTablesOf(db, t);
        s.tbl_hash.put(db.gpa, t.name, t) catch {
            db.oomFault();
            return;
        };
        s.tbl_order.insert(db.gpa, t.name, t) catch {
            _ = s.tbl_hash.remove(t.name);
            db.oomFault();
            return;
        };
        p.new_table = null;
    }
}

/// Port of sqlite3VtabArgInit(): the first token of a module argument.
pub fn argInit(p: *Parse) void {
    addArgumentToVtab(p);
    p.s_arg.z = null;
    p.s_arg.n = 0;
}

/// Port of sqlite3VtabArgExtend(): another token of a module argument.
pub fn argExtend(p: *Parse, t: Token) void {
    const arg = &p.s_arg;
    if (arg.z == null) {
        arg.z = t.z;
        arg.n = t.n;
    } else {
        std.debug.assert(@intFromPtr(arg.z.?) <= @intFromPtr(t.z.?));
        arg.n = @intCast(@intFromPtr(t.z.? + t.n) - @intFromPtr(arg.z.?));
    }
}

fn allocErr(db: *Sqlite3, comptime fmt: []const u8, args: anytype) ?[:0]u8 {
    return std.fmt.allocPrintSentinel(db.gpa, fmt, args, 0) catch {
        db.oomFault();
        return null;
    };
}

/// Port of vtabCallConstructor(): run xCreate or xConnect for `t`. On
/// error `err` gets a message (from db.gpa).
fn callConstructor(db: *Sqlite3, t: *Table, m: *int.Module, x_construct: Module.ConstructFn, err: *?[:0]u8) i32 {
    std.debug.assert(t.isVirtual());
    const gpa = db.gpa;

    // The table may not be under construction already.
    var it = db.vtab_ctx;
    while (it) |c| : (it = c.prior) {
        if (c.tab == t) {
            err.* = allocErr(db, "vtable constructor called recursively: {s}", .{t.name});
            return RC.LOCKED;
        }
    }

    const module_name = gpa.dupeSentinel(u8, t.name, 0) catch return RC.NOMEM;
    defer gpa.free(module_name);

    const vt = gpa.create(VTable) catch {
        db.oomFault();
        return RC.NOMEM;
    };
    vt.* = .{ .db = db, .mod = m, .e_vtab_risk = int.VTABRISK.Normal };

    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    t.u.vtab.args[1] = db.dbs.items[i_db].name;

    // Run the constructor.
    var s_ctx: VtabCtx = .{ .tab = t, .vtable = vt, .prior = db.vtab_ctx };
    db.vtab_ctx = &s_ctx;
    t.n_tab_ref += 1;
    var z_err: ?[:0]u8 = null;
    var rc = x_construct(db, m.aux, t.u.vtab.args, &vt.vtab, &z_err);
    build.deleteTable(db, t);
    db.vtab_ctx = s_ctx.prior;
    if (rc == RC.NOMEM) db.oomFault();

    if (rc != RC.OK) {
        if (z_err == null) {
            err.* = allocErr(db, "vtable constructor failed: {s}", .{module_name});
        } else {
            err.* = z_err;
        }
        gpa.destroy(vt);
    } else if (vt.vtab) |pv| {
        pv.* = .{ .module = m.module };
        m.n_ref_module += 1;
        vt.n_ref = 1;
        if (!s_ctx.b_declared) {
            err.* = allocErr(db, "vtable constructor did not declare schema: {s}", .{module_name});
            unlock(vt);
            rc = RC.ERROR;
        } else {
            // Link the VTable in, and make the columns whose type
            // contains the word "hidden" HIDDEN, removing the word.
            vt.next = t.u.vtab.p;
            t.u.vtab.p = vt;
            var ooo_hidden: int.TF = .{};
            for (t.cols) |*col| {
                const zt = build.columnType(col, "");
                const z: [*]u8 = @constCast(zt.ptr);
                const n_type = zt.len;
                var i: usize = 0;
                while (i < n_type) : (i += 1) {
                    if (i + 6 <= n_type and ctype.eqlNoCase(z[i .. i + 6], "hidden") and
                        (i == 0 or z[i - 1] == ' ') and
                        (z[i + 6] == 0 or z[i + 6] == ' '))
                    {
                        break;
                    }
                }
                if (i < n_type) {
                    const n_del: usize = 6 + @as(usize, @intFromBool(z[i + 6] != 0));
                    var j = i;
                    while (j + n_del <= n_type) : (j += 1) z[j] = z[j + n_del];
                    if (z[i] == 0 and i > 0) {
                        std.debug.assert(z[i - 1] == ' ');
                        z[i - 1] = 0;
                    }
                    col.col_flags.HIDDEN = true;
                    t.tab_flags.HasHidden = true;
                    ooo_hidden = .{ .OOOHidden = true };
                } else {
                    t.tab_flags.set(ooo_hidden);
                }
            }
        }
    } else {
        gpa.destroy(vt);
    }
    return rc;
}

/// Port of sqlite3VtabCallConnect(): make sure `t` is connected on this
/// connection (xConnect). Errors are left in `p`, with the result code of
/// the constructor in Parse.rc.
pub fn callConnect(p: *Parse, t: *Table) int.ParseError!void {
    const db = p.db;
    std.debug.assert(t.isVirtual());
    if (getVTable(db, t) != null) return;

    // Find the module.
    const z_mod = t.u.vtab.args[0];
    const m = db.modules.get(z_mod) orelse {
        util.errorMsg(p, "no such module: {s}", .{z_mod});
        return error.ParseFailed;
    };
    var z_err: ?[:0]u8 = null;
    defer if (z_err) |e| db.gpa.free(e);
    const rc = callConstructor(db, t, m, m.module.x_connect.?, &z_err);
    if (rc != RC.OK) {
        util.errorMsg(p, "{s}", .{z_err orelse ""});
        p.rc = rc;
        return error.ParseFailed;
    }
    build.markAllShadowTablesOf(db, t);
}

/// Port of growVTrans(): room for one more entry in db.a_vtrans.
fn growVTrans(db: *Sqlite3) error{OutOfMemory}!void {
    const array_incr = 5;
    if (db.n_vtrans % array_incr == 0) {
        const old: []*VTable = db.a_vtrans orelse &.{};
        db.a_vtrans = try db.gpa.realloc(old, db.n_vtrans + array_incr);
    }
}

/// Port of addToVTrans().
fn addToVTrans(db: *Sqlite3, vt: *VTable) void {
    db.a_vtrans.?[db.n_vtrans] = vt;
    db.n_vtrans += 1;
    lock(vt);
}

/// Port of sqlite3VtabCallCreate(): run xCreate for the virtual table
/// `tab_name` of database `i_db` (OP_VCreate). On error `err` gets a
/// message (from db.gpa).
pub fn callCreate(db: *Sqlite3, i_db: usize, tab_name: []const u8, err: *?[:0]u8) i32 {
    var rc: i32 = RC.OK;
    const t = build.findTable(db, tab_name, db.dbs.items[i_db].name).?;
    std.debug.assert(t.isVirtual() and t.u.vtab.p == null);

    // The module must exist and have xCreate and xDestroy.
    const z_mod = t.u.vtab.args[0];
    const m_opt = db.modules.get(z_mod);
    if (m_opt == null or m_opt.?.module.x_create == null or m_opt.?.module.x_destroy == null) {
        err.* = allocErr(db, "no such module: {s}", .{z_mod});
        rc = RC.ERROR;
    } else {
        const m = m_opt.?;
        rc = callConstructor(db, t, m, m.module.x_create.?, err);
    }

    if (rc == RC.OK) if (getVTable(db, t)) |vt| {
        growVTrans(db) catch return RC.NOMEM;
        addToVTrans(db, vt);
    };
    return rc;
}

/// Port of sqlite3_declare_vtab(): called by xCreate or xConnect to set
/// the columns of the virtual table from a CREATE TABLE statement.
pub fn declareVtab(db: *Sqlite3, create_table: [:0]const u8) i32 {
    // The statement must start with CREATE TABLE.
    var z: [*:0]const u8 = create_table.ptr;
    for ([_]u8{ TK.CREATE, TK.TABLE }) |kw| {
        var tk: u8 = undefined;
        while (true) {
            const t = tokenize.getToken(z);
            z += t.len;
            tk = t.tk;
            if (tk != TK.SPACE and tk != TK.COMMENT) break;
        }
        if (tk != kw) {
            main_mod.errorWithMsg(db, RC.ERROR, "syntax error", .{});
            return RC.ERROR;
        }
    }

    const ctx = db.vtab_ctx orelse {
        main_mod.setError(db, RC.MISUSE);
        return RC.MISUSE;
    };
    if (ctx.b_declared) {
        main_mod.setError(db, RC.MISUSE);
        return RC.MISUSE;
    }
    const tab = ctx.tab;
    std.debug.assert(tab.isVirtual());

    var arena_state = std.heap.ArenaAllocator.init(db.gpa);
    defer arena_state.deinit();
    var p: Parse = .{ .db = db, .arena = arena_state.allocator() };
    defer build.releaseTableRefs(&p);
    defer prepare.parseObjectResetLookaside(&p);
    p.e_parse_mode = .declare_vtab;
    p.disable_triggers = true;
    // Never reached while reading the schema; defend against it anyway.
    std.debug.assert(!db.init.busy);
    const init_busy = db.init.busy;
    db.init.busy = false;
    defer db.init.busy = init_busy;
    p.n_query_loop = 1;

    var rc: i32 = RC.OK;
    const parsed = if (tokenize.runParser(&p, create_table)) |_| true else |err| switch (err) {
        error.OutOfMemory => blk: {
            db.oomFault();
            break :blk false;
        },
        error.ParseFailed => false,
    };
    if (parsed and p.new_table != null) {
        const new = p.new_table.?;
        std.debug.assert(new.isOrdinary());
        if (tab.cols.len == 0) {
            // The columns stay in the memory of the declared table, which
            // the virtual table takes over.
            tab.cols = new.cols;
            tab.n_nv_col = @intCast(new.cols.len);
            tab.tab_flags.set(new.tab_flags.only(.{ .WithoutRowid = true, .NoVisibleRowid = true }));
            new.cols = &.{};
            std.debug.assert(tab.index == null);
            std.debug.assert(new.hasRowid() or build.primaryKeyIndex(new) != null);
            if (!new.hasRowid() and ctx.vtable.mod.module.x_update != null and
                build.primaryKeyIndex(new).?.n_key_col != 1)
            {
                // A writable WITHOUT ROWID virtual table must have a
                // single-column PRIMARY KEY.
                rc = RC.ERROR;
            }
            if (new.index) |idx| {
                std.debug.assert(idx.next == null);
                tab.index = idx;
                new.index = null;
                idx.table = tab;
            }
            std.debug.assert(tab.u.vtab.decl_mem == null);
            tab.u.vtab.decl_mem = new.mem;
            new.mem = null;
        }
        ctx.b_declared = true;
    } else {
        if (p.err_msg) |msg| {
            main_mod.errorWithMsg(db, RC.ERROR, "{s}", .{msg});
        } else {
            main_mod.setError(db, RC.ERROR);
        }
        rc = RC.ERROR;
    }
    p.e_parse_mode = .normal;

    if (p.vdbe) |v| _ = aux.finalize(v);
    if (p.new_table) |nt| build.deleteTable(db, nt);
    return main_mod.apiExit(db, rc);
}

/// Port of sqlite3VtabCallDestroy(): run xDestroy for the virtual table
/// `tab_name` of database `i_db` (OP_VDestroy, for DROP TABLE).
pub fn callDestroy(db: *Sqlite3, i_db: usize, tab_name: []const u8) i32 {
    var rc: i32 = RC.OK;
    const t = build.findTable(db, tab_name, db.dbs.items[i_db].name) orelse return RC.OK;
    if (t.isVirtual() and t.u.vtab.p != null) {
        var it = t.u.vtab.p;
        while (it) |vt| : (it = vt.next) {
            std.debug.assert(vt.vtab != null);
            if (vt.vtab.?.n_ref > 0) return RC.LOCKED;
        }
        const p = disconnectAll(db, t).?;
        const x_destroy = p.mod.module.x_destroy orelse p.mod.module.x_disconnect.?;
        t.n_tab_ref += 1;
        freeErrMsg(db, p.vtab.?);
        rc = x_destroy(p.vtab.?);
        // Remove the vtab from db.a_vtrans, if there.
        if (rc == RC.OK) {
            std.debug.assert(t.u.vtab.p == p and p.next == null);
            p.vtab = null;
            t.u.vtab.p = null;
            unlock(p);
        }
        build.deleteTable(db, t);
    }
    return rc;
}

/// Which method of the virtual tables in db.a_vtrans callFinaliser() calls.
const Finaliser = enum { commit, rollback };

/// Port of callFinaliser(): call xCommit or xRollback of every virtual
/// table with a transaction, and empty db.a_vtrans.
fn callFinaliser(db: *Sqlite3, which: Finaliser) void {
    const a = db.a_vtrans orelse return;
    db.a_vtrans = null;
    for (a[0..db.n_vtrans]) |vt| {
        if (vt.vtab) |p| {
            const x = switch (which) {
                .commit => p.module.x_commit,
                .rollback => p.module.x_rollback,
            };
            if (x) |f| _ = f(p);
        }
        vt.i_savepoint = 0;
        unlock(vt);
    }
    db.gpa.free(a);
    db.n_vtrans = 0;
}

/// Port of sqlite3VtabSync(): call xSync of every virtual table with a
/// transaction; the first error stops. Error messages go to `v`.
pub fn sync(db: *Sqlite3, v: *vi.Vdbe) i32 {
    var rc: i32 = RC.OK;
    const a = db.a_vtrans;
    db.a_vtrans = null;
    var i: usize = 0;
    while (rc == RC.OK and i < db.n_vtrans) : (i += 1) {
        if (a.?[i].vtab) |p| if (p.module.x_sync) |x| {
            rc = x(p);
            importErrmsg(v, p);
        };
    }
    db.a_vtrans = a;
    return rc;
}

/// Port of sqlite3VtabRollback(). (C returns SQLITE_OK.)
pub fn rollback(db: *Sqlite3) void {
    callFinaliser(db, .rollback);
}

/// Port of sqlite3VtabCommit(). (C returns SQLITE_OK.)
pub fn commit(db: *Sqlite3) void {
    callFinaliser(db, .commit);
}

/// sqlite3VtabInSync(): xSync methods are running.
pub fn inSync(db: *const Sqlite3) bool {
    return db.n_vtrans > 0 and db.a_vtrans == null;
}

/// Port of sqlite3VtabBegin(): start a transaction on `vt` (xBegin) if
/// it supports them and has none.
pub fn begin(db: *Sqlite3, vt_opt: ?*VTable) i32 {
    var rc: i32 = RC.OK;
    // Writing to a virtual table from within xSync is not allowed.
    if (inSync(db)) return RC.LOCKED;
    const vt = vt_opt orelse return RC.OK;
    const module = vt.vtab.?.module;
    if (module.x_begin) |x_begin| {
        // Nothing to do if it is already in db.a_vtrans.
        if (db.a_vtrans) |a| for (a[0..db.n_vtrans]) |t| {
            if (t == vt) return RC.OK;
        };
        growVTrans(db) catch return RC.NOMEM;
        rc = x_begin(vt.vtab.?);
        if (rc == RC.OK) {
            const i_svpt = db.n_statement + db.n_savepoint;
            addToVTrans(db, vt);
            if (i_svpt != 0) if (module.x_savepoint) |x_savepoint| {
                vt.i_savepoint = i_svpt;
                rc = x_savepoint(vt.vtab.?, i_svpt - 1);
            };
        }
    }
    return rc;
}

/// Port of sqlite3VtabSavepoint(): call xSavepoint, xRollbackTo or
/// xRelease (`op` SAVEPOINT_BEGIN, _ROLLBACK or _RELEASE) of every virtual
/// table with a transaction.
pub fn savepoint(db: *Sqlite3, op: aux.SAVEPOINT, i_savepoint: i32) i32 {
    var rc: i32 = RC.OK;
    std.debug.assert(i_savepoint >= -1);
    if (db.a_vtrans) |a| {
        var i: usize = 0;
        while (rc == RC.OK and i < db.n_vtrans) : (i += 1) {
            const vt = a[i];
            const module = vt.mod.module;
            if (vt.vtab != null and module.i_version >= 2) {
                lock(vt);
                const x_method = switch (op) {
                    .BEGIN => blk: {
                        vt.i_savepoint = i_savepoint + 1;
                        break :blk module.x_savepoint;
                    },
                    .ROLLBACK => module.x_rollback_to,
                    else => module.x_release,
                };
                if (x_method) |x| if (vt.i_savepoint > i_savepoint) {
                    const saved_defensive = db.flags.Defensive;
                    db.flags.Defensive = false;
                    rc = x(vt.vtab.?, i_savepoint);
                    if (saved_defensive) db.flags.Defensive = true;
                };
                unlock(vt);
            }
        }
    }
    return rc;
}

/// Port of sqlite3VtabOverloadFunction(): if `e` (the first argument of
/// function `def`) is a column of a virtual table, let xFindFunction
/// overload the function; returns `def` or a new ephemeral FuncDef
/// (SQLITE_FUNC_EPHEM) allocated in `a`.
pub fn overloadFunction(db: *Sqlite3, a: Allocator, def: *const FuncDef, n_arg: i32, e_opt: ?*int.Expr) *const FuncDef {
    const e = e_opt orelse return def;
    if (e.op != TK.COLUMN) return def;
    std.debug.assert(e.useYTab());
    const t = e.y.tab orelse return def;
    if (!t.isVirtual()) return def;
    const vtab = getVTable(db, t).?.vtab.?;
    const x_find = vtab.module.x_find_function orelse return def;

    // xFindFunction has always been called with a lower-case name.
    var x_sfunc: ?FuncDef.StepFn = null;
    var arg: ?*anyopaque = null;
    const rc = x_find(vtab, n_arg, def.name, &x_sfunc, &arg);
    if (rc == 0) return def;

    // An ephemeral copy of the function with the new implementation.
    const new = a.create(FuncDef) catch return def;
    new.* = def.*;
    new.name = a.dupeSentinel(u8, def.name, 0) catch return def;
    new.x_sfunc = x_sfunc;
    new.user_data = arg;
    new.func_flags.EPHEM = true;
    return new;
}

/// Port of sqlite3VtabMakeWritable(): make sure the statement codes an
/// OP_VBegin for `t`.
pub fn makeWritable(p: *Parse, t: *Table) void {
    const top = build.toplevel(p);
    std.debug.assert(t.isVirtual());
    for (top.vtab_lock.items) |x| {
        if (x == t) return;
    }
    top.vtab_lock.append(top.arena, t) catch build.oomFault(top);
}

/// Port of sqlite3VtabEponymousTableInit(): make the eponymous virtual
/// table of module `m` if it can have one (xCreate is null or the same
/// as xConnect). True if it exists afterwards, or if making it failed
/// with an error left in `p`.
pub fn epoTableInit(p: *Parse, m: *int.Module) bool {
    const module = m.module;
    const db = p.db;
    if (m.epo_tab != null) return true;
    if (module.x_create != null and module.x_create != module.x_connect) return false;
    const t = build.newSchemaTable(db, m.name) catch return false;
    m.epo_tab = t;
    t.n_tab_ref = 1;
    t.e_tab_type = .vtab;
    t.u = .{ .vtab = .{} };
    t.schema = db.dbs.items[0].schema;
    t.i_pkey = -1;
    t.tab_flags.Eponymous = true;
    const a = t.mem.?.allocator();
    addModuleArgument(p, t, a.dupeSentinel(u8, t.name, 0) catch null);
    addModuleArgument(p, t, "");
    addModuleArgument(p, t, a.dupeSentinel(u8, t.name, 0) catch null);
    db.n_schema_lock += 1;
    var z_err: ?[:0]u8 = null;
    const rc = callConstructor(db, t, m, module.x_connect.?, &z_err);
    db.n_schema_lock -= 1;
    if (rc != RC.OK) {
        util.errorMsg(p, "{s}", .{z_err orelse ""});
        p.rc = rc;
        if (z_err) |e| db.gpa.free(e);
        epoTableClear(db, m);
    }
    return true;
}

/// Port of sqlite3VtabEponymousTableClear(): free the eponymous virtual
/// table of `m`, if any.
pub fn epoTableClear(db: *Sqlite3, m: *int.Module) void {
    if (m.epo_tab) |t| {
        // Not in a schema.
        t.tab_flags.Ephemeral = true;
        build.deleteTable(db, t);
        m.epo_tab = null;
    }
}

/// Port of sqlite3VtabEponymousTableClearAll().
pub fn epoTableClearAll(db: *Sqlite3) void {
    var it = db.modules.valueIterator();
    while (it.next()) |m| epoTableClear(db, m.*);
}

/// Port of sqlite3VtabImportErrmsg() (vdbeaux.c): move the error message
/// of `vtab` to `v`.
pub fn importErrmsg(v: *vi.Vdbe, vtab: *Vtab) void {
    if (vtab.err_msg) |msg| {
        aux.setErrMsg(v, v.db.gpa.dupeSentinel(u8, msg, 0) catch null);
        v.db.gpa.free(msg);
        vtab.err_msg = null;
    }
}

/// Port of sqlite3_vtab_on_conflict(): the ON CONFLICT mode of the xUpdate
/// call running (SQLITE_ROLLBACK, _ABORT, _FAIL, _IGNORE or _REPLACE).
pub fn onConflict(db: *const Sqlite3) i32 {
    return switch (db.vtab_on_conflict) {
        .Rollback => SQLITE_ROLLBACK,
        .Abort => SQLITE_ABORT,
        .Fail => SQLITE_FAIL,
        .Ignore => SQLITE_IGNORE,
        .Replace => SQLITE_REPLACE,
        else => unreachable,
    };
}

/// Port of sqlite3_vtab_config(): called by xCreate or xConnect to set
/// option `op` (VTAB_*); `arg` is the argument of
/// VTAB_CONSTRAINT_SUPPORT.
pub fn config(db: *Sqlite3, op: i32, arg: i32) i32 {
    var rc: i32 = RC.OK;
    if (db.vtab_ctx) |p| {
        switch (op) {
            VTAB_CONSTRAINT_SUPPORT => p.vtable.b_constraint = arg != 0,
            VTAB_INNOCUOUS => p.vtable.e_vtab_risk = int.VTABRISK.Low,
            VTAB_DIRECTONLY => p.vtable.e_vtab_risk = int.VTABRISK.High,
            VTAB_USES_ALL_SCHEMAS => p.vtable.b_all_schemas = true,
            else => rc = RC.MISUSE,
        }
    } else {
        rc = RC.MISUSE;
    }
    if (rc != RC.OK) main_mod.setError(db, rc);
    return rc;
}

/// Port of sqlite3_vtab_nochange() (vdbeapi.c): within xColumn of an
/// UPDATE, the column is not changed and its value is not needed.
pub fn nochange(ctx: *Context) bool {
    return ctx.out.isNullNochng();
}

// ================================================= xBestIndex helpers

/// The planner's state behind an IndexInfo (HiddenIndexInfo); `info` is
/// what xBestIndex sees.
pub const HiddenIndexInfo = struct {
    info: IndexInfo,
    /// The WHERE clause being analyzed.
    wc: *wi.WhereClause,
    parse: *Parse,
    /// The ORDER BY may be handled as DISTINCT (sqlite3_vtab_distinct()).
    e_distinct: i32 = 0,
    /// Constraints that are IN operators (mIn).
    m_in: u32 = 0,
    /// Those xBestIndex wants handled with sqlite3_vtab_in() (mHandleIn).
    m_handle_in: u32 = 0,
    /// The values of the right-hand sides, as made by vtabRhsValue().
    rhs: []?*Mem,

    pub fn of(info: *IndexInfo) *HiddenIndexInfo {
        return @fieldParentPtr("info", info);
    }
};

/// Port of termFromWhereClause() (where.c): term `i_term` of `wc` and its
/// outer clauses, numbered in that order.
pub fn termFromWhereClause(wc_arg: *wi.WhereClause, i_term_arg: i32) ?*wi.WhereTerm {
    var i_term = i_term_arg;
    var it: ?*wi.WhereClause = wc_arg;
    while (it) |p| : (it = p.outer) {
        if (i_term < p.n_term) return &p.a[@intCast(i_term)];
        i_term -= p.n_term;
    }
    return null;
}

/// Port of sqlite3_vtab_collation(): the collation of constraint `i_cons`
/// of xBestIndex.
pub fn collation(info: *IndexInfo, i_cons: i32) ?[:0]const u8 {
    const hidden = HiddenIndexInfo.of(info);
    if (i_cons >= 0 and i_cons < info.constraints.len) {
        const i_term = info.constraints[@intCast(i_cons)].i_term_offset;
        const x = termFromWhereClause(hidden.wc, i_term).?.expr;
        var c: ?*const int.CollSeq = null;
        if (x.left != null) c = expr_mod.compareCollSeq(hidden.parse, x);
        return if (c) |cs| cs.name else "BINARY";
    }
    return null;
}

/// Port of sqlite3_vtab_in(): whether constraint `i_cons` is an IN
/// operator; with `b_handle` 1 (or 0) xFilter gets (or does not get) all
/// the values at once, through vtabInFirst()/vtabInNext().
pub fn in(info: *IndexInfo, i_cons: i32, b_handle: i32) bool {
    const hidden = HiddenIndexInfo.of(info);
    const m = wi.smaskBit32(@as(u32, @bitCast(i_cons)));
    if (m & hidden.m_in != 0) {
        if (b_handle == 0) {
            hidden.m_handle_in &= ~m;
        } else if (b_handle > 0) {
            hidden.m_handle_in |= m;
        }
        return true;
    }
    return false;
}

/// Port of sqlite3_vtab_rhs_value(): the value of the right-hand side of
/// constraint `i_cons`, if it is known while planning. RC.NOTFOUND if
/// not.
pub fn rhsValue(info: *IndexInfo, i_cons: i32, out: *?*Mem) i32 {
    const h = HiddenIndexInfo.of(info);
    var val: ?*Mem = null;
    var rc: i32 = RC.OK;
    if (i_cons < 0 or i_cons >= info.constraints.len) {
        rc = RC.MISUSE;
    } else {
        const i: usize = @intCast(i_cons);
        if (h.rhs[i] == null) {
            const term = termFromWhereClause(h.wc, info.constraints[i].i_term_offset).?;
            h.rhs[i] = @import("update.zig").valueFromExpr(h.parse.vdbe.?, term.expr.right, int.Aff.blob) catch blk: {
                rc = RC.NOMEM;
                break :blk null;
            };
        }
        val = h.rhs[i];
    }
    out.* = val;
    if (rc == RC.OK and val == null) rc = RC.NOTFOUND;
    return rc;
}

/// Port of sqlite3_vtab_distinct(): how the ORDER BY may be relaxed (0-3).
pub fn distinct(info: *IndexInfo) i32 {
    const hidden = HiddenIndexInfo.of(info);
    std.debug.assert(hidden.e_distinct >= 0 and hidden.e_distinct <= 3);
    return hidden.e_distinct;
}

/// The values of an IN operator handed to xFilter as one argument
/// (ValueList): the ephemeral table of the values and the register the
/// current one is read into.
pub const ValueList = struct {
    csr: *btree.Cursor,
    out: *Mem,
};

/// The pointer type of a ValueList argument.
pub const value_list_type = "ValueList";

/// Port of sqlite3VdbeValueListFree() (vdbeapi.c), as a typed destructor
/// (int.destructor(valueListFree) is the C-shaped one).
pub fn valueListFree(list: *ValueList) void {
    malloc.allocator.destroy(list);
}

/// Port of valueFromValueList() (vdbeapi.c).
fn valueFromValueList(val_opt: ?*Mem, out: *?*Mem, b_next: bool) i32 {
    out.* = null;
    const val = val_opt orelse return RC.MISUSE;
    const rhs = mem.dynObject(val, valueListFree) orelse return RC.ERROR;
    var rc: i32 = RC.OK;
    if (b_next) {
        const more = rhs.csr.next() catch |err| return int.errorCode(err);
        if (!more) rc = RC.DONE;
    } else {
        const any = rhs.csr.first() catch |err| return int.errorCode(err);
        if (!any or rhs.csr.eof()) rc = RC.DONE;
    }
    if (rc == RC.OK) {
        var s_mem: Mem = .{ .flags = .{ .Null = true } };
        const sz = rhs.csr.payloadSize();
        mem.fromBtreeZeroOffset(rhs.csr, sz, &s_mem) catch |err| return int.errorCode(err);
        defer mem.release(&s_mem);
        const buf = s_mem.bytes();
        const sv = record_fmt.getVarint32(buf, 1);
        const p_out = rhs.out;
        serial.serialGet(buf, 1 + sv.len, sv.value, p_out);
        p_out.enc = p_out.db.?.enc;
        if (p_out.flags.Ephem) {
            mem.makeWriteable(p_out) catch return RC.NOMEM;
        }
        out.* = p_out;
    }
    return rc;
}

/// Port of sqlite3_vtab_in_first(): the first value of an IN operator
/// handed to xFilter (see in()); RC.DONE if there is none.
pub fn inFirst(val: ?*Mem, out: *?*Mem) i32 {
    return valueFromValueList(val, out, false);
}

/// Port of sqlite3_vtab_in_next(): the next value; RC.DONE at the end.
pub fn inNext(val: ?*Mem, out: *?*Mem) i32 {
    return valueFromValueList(val, out, true);
}
