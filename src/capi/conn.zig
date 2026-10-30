//! Connections: sqlite3_open*(), sqlite3_close*(), sqlite3_exec(),
//! errors, limits, configuration, hooks, backups and the interfaces
//! xqlite does not support (stubs that fail cleanly).

const std = @import("std");
const c = @import("common.zig");
const vfs_mod = @import("vfs.zig");
const stmt = @import("stmt.zig");
const func = @import("func.zig");

const Handle = c.Handle;
const RC = c.RC;
const Ext = c.Ext;
const uri = @import("../sql/uri.zig");
const build = @import("../sql/build.zig");
const backup_mod = @import("../sql/backup.zig");

// SQLITE_OPEN_* flags of sqlite3_open_v2().
const OPEN_READONLY = 0x01;
const OPEN_CREATE = 0x04;
const OPEN_URI = 0x40;
const OPEN_MEMORY = 0x80;
const OPEN_NOMUTEX = 0x8000;
const OPEN_FULLMUTEX = 0x10000;
const OPEN_EXRESCODE = 0x02000000;

// ================================================================== open

fn openDatabase(z_filename: ?[*:0]const u8, pp_db: ?*?*Handle, flags: c_int, z_vfs: ?[*:0]const u8) c_int {
    const out = pp_db orelse return RC.MISUSE;
    out.* = null;
    c.ensureInit();
    // Only READONLY, READWRITE and READWRITE|CREATE are allowed.
    if ((@as(u32, 1) << @intCast(flags & 7)) & 0x46 == 0) return RC.MISUSE;
    const name = c.span(z_filename) orelse "";
    const oflags: c.main.OpenFlags = .{
        .read_only = flags & OPEN_READONLY != 0,
        .create = flags & OPEN_CREATE != 0,
        .uri = flags & OPEN_URI != 0 or c.state.uri,
        .memory = flags & OPEN_MEMORY != 0,
        .vfs_resolved = true,
    };

    // The URI parameters the C ABI reads itself: vfs= (the registry is
    // here) and xqlite's dialect=. The engine parses the URI again.
    var parsed = uri.parse(c.gpa, name, oflags);
    defer parsed.deinit(c.gpa);
    var vfs_name = c.span(z_vfs);
    var dialect: ?c.dialect.Dialect = null;
    var bad_dialect: ?[]const u8 = null;
    if (parsed.rc == RC.OK) {
        if (parsed.parameter("vfs")) |v| vfs_name = v;
        if (parsed.parameter("dialect")) |d| {
            dialect = c.dialect.Dialect.fromName(d);
            if (dialect == null) bad_dialect = d;
        }
    }
    const entry = vfs_mod.find(vfs_name);

    const ext = c.gpa.create(Ext) catch return RC.NOMEM;
    ext.* = .{ .vfs = entry orelse vfs_mod.find(null).? };
    // Serialized or multi-thread, as in SQLite's openDatabase().
    const serialized = if (!c.state.core_mutex)
        false
    else if (flags & OPEN_NOMUTEX != 0)
        false
    else if (flags & OPEN_FULLMUTEX != 0)
        true
    else
        c.state.full_mutex;
    if (serialized) {
        ext.mutex = c.sqlite3_mutex_alloc(c.MUTEX_RECURSIVE) orelse {
            c.gpa.destroy(ext);
            return RC.NOMEM;
        };
    }
    var h: ?*Handle = null;
    // A connection that cannot get going still comes back with its
    // error, as in SQLite: here one on a private in-memory database.
    const failing = entry == null or bad_dialect != null;
    var rc = c.main.open(ext.vfs.engine, if (failing) ":memory:" else name, if (failing) .{} else oflags, &h);
    const db = h orelse {
        if (ext.mutex) |m| c.sqlite3_mutex_free(m);
        c.gpa.destroy(ext);
        return RC.NOMEM;
    };
    db.capi = ext;
    // The C ABI is built as with SQLITE_ENABLE_CARRAY (capi/carray.zig).
    db.enable_carray = true;
    out.* = db;
    if (entry == null) {
        rc = RC.ERROR;
        c.main.errorWithMsg(db, rc, "no such vfs: {s}", .{vfs_name.?});
    } else if (bad_dialect) |d| {
        rc = RC.ERROR;
        c.main.errorWithMsg(db, rc, "no such dialect: {s}", .{d});
    }
    if (rc == RC.OK) {
        if (flags & OPEN_EXRESCODE != 0) c.main.extendedResultCodes(db, true);
        if (dialect) |d| c.main.setDialect(db, d);
        rc = autoExtensions(db);
    }
    if (rc != RC.OK) return c.main.errcode(db) | (if (flags & OPEN_EXRESCODE != 0) c.main.extendedErrcode(db) else 0);
    return RC.OK;
}

/// Run the automatic extensions on a new connection.
fn autoExtensions(db: *Handle) c_int {
    var i: usize = 0;
    while (true) : (i += 1) {
        c.state.lock.lock();
        const entry: ?*const anyopaque = if (i < c.state.auto_ext.items.len) c.state.auto_ext.items[i] else null;
        c.state.lock.unlock();
        const p = entry orelse return RC.OK;
        const init_fn: *const fn (?*Handle, *?[*:0]u8, ?*const anyopaque) callconv(.c) c_int = @ptrCast(@alignCast(p));
        var err: ?[*:0]u8 = null;
        const rc = init_fn(db, &err, @import("loadext.zig").apis());
        if (rc != RC.OK) {
            c.main.errorWithMsg(db, rc, "automatic extension loading failed: {s}", .{std.mem.span(err orelse "")});
            if (err) |e| c.malloc.free(e);
            return rc;
        }
    }
}

pub export fn sqlite3_open(z_filename: ?[*:0]const u8, pp_db: ?*?*Handle) callconv(.c) c_int {
    return openDatabase(z_filename, pp_db, 0x06, null);
}

pub export fn sqlite3_open_v2(z_filename: ?[*:0]const u8, pp_db: ?*?*Handle, flags: c_int, z_vfs: ?[*:0]const u8) callconv(.c) c_int {
    return openDatabase(z_filename, pp_db, flags, z_vfs);
}

pub export fn sqlite3_open16(z_filename: ?*const anyopaque, pp_db: ?*?*Handle) callconv(.c) c_int {
    const out = pp_db orelse return RC.MISUSE;
    out.* = null;
    const z = c.utf16ToUtf8(c.utf16Slice(z_filename orelse return RC.MISUSE, -1), false) orelse return RC.NOMEM;
    defer c.gpa.free(z);
    return openDatabase(z.ptr, pp_db, 0x06, null);
}

// ================================================================= close

fn freeExt(e: *Ext) void {
    for (e.colls.items) |w| func.CollWrap.destroy(w);
    e.colls.deinit(c.gpa);
    for (e.clientdata.items) |cd| {
        if (cd.x_destroy) |d| d(cd.data);
        c.gpa.free(cd.name);
    }
    e.clientdata.deinit(c.gpa);
    if (e.errmsg16) |m| c.gpa.free(m);
    if (e.autovac_destroy) |d| d(e.autovac.arg);
    // Last: the code of what was freed above may be the extensions'.
    @import("loadext.zig").closeExtensions(e);
    if (e.mutex) |m| c.sqlite3_mutex_free(m);
    c.gpa.destroy(e);
}

/// Port of sqlite3Close(): close `db`, or with `zombie` (sqlite3_close_v2())
/// leave it to close itself once its statements and backups are gone.
fn close(db_arg: ?*Handle, zombie: bool) c_int {
    const db = db_arg orelse return RC.OK;
    const e = c.extOf(db) orelse return c.main.close(db);
    const lk = c.lock(db);
    if (db.m_trace & c.TRACE_CLOSE != 0 and !e.zombie) _ = db.trace_v2.?(c.TRACE_CLOSE, db.trace_arg, db, null);
    const rc = c.main.close(db);
    if (rc == RC.BUSY) {
        defer lk.unlock();
        if (zombie) {
            e.zombie = true;
            c.main.errorClear(db);
            return RC.OK;
        }
        return RC.BUSY;
    }
    // The mutex goes with the connection (sqlite3LeaveMutexAndCloseZombie()).
    lk.unlock();
    freeExt(e);
    return rc;
}

/// Port of sqlite3LeaveMutexAndCloseZombie(): leave the mutex taken by
/// `lk`, closing `db` first if it is a zombie that can now close (after
/// a finalize or a backup ends).
pub fn leaveAndCloseZombie(db: *Handle, lk: c.Lock) void {
    const e = c.extOf(db) orelse return lk.unlock();
    if (!e.zombie or db.vdbe != null or c.main.close(db) != RC.OK) return lk.unlock();
    lk.unlock();
    freeExt(e);
}

pub export fn sqlite3_close(db: ?*Handle) callconv(.c) c_int {
    return close(db, false);
}

pub export fn sqlite3_close_v2(db: ?*Handle) callconv(.c) c_int {
    return close(db, true);
}

// ================================================================ errors

pub export fn sqlite3_errcode(db: ?*Handle) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    return c.main.errcode(db orelse return RC.NOMEM);
}

pub export fn sqlite3_extended_errcode(db: ?*Handle) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    return c.main.extendedErrcode(db orelse return RC.NOMEM);
}

pub export fn sqlite3_errmsg(db: ?*Handle) callconv(.c) [*:0]const u8 {
    const lk = c.lock(db);
    defer lk.unlock();
    return c.main.errmsg(db orelse return c.util.errStr(RC.NOMEM).ptr).ptr;
}

pub export fn sqlite3_errmsg16(db_arg: ?*Handle) callconv(.c) ?*const anyopaque {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return null;
    const e = c.ext(db);
    if (e.errmsg16) |m| c.gpa.free(m);
    e.errmsg16 = c.utf8ToUtf16(c.main.errmsg(db));
    return if (e.errmsg16) |m| m.ptr else null;
}

pub export fn sqlite3_errstr(rc: c_int) callconv(.c) [*:0]const u8 {
    return c.util.errStr(rc).ptr;
}

pub export fn sqlite3_error_offset(db: ?*Handle) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    return c.main.errorOffset(db orelse return -1);
}

pub export fn sqlite3_extended_result_codes(db: ?*Handle, on: c_int) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    c.main.extendedResultCodes(db orelse return RC.MISUSE, on != 0);
    return RC.OK;
}

pub export fn sqlite3_set_errmsg(db_arg: ?*Handle, code: c_int, msg: ?[*:0]const u8) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    if (msg) |m| {
        c.main.errorWithMsg(db, code, "{s}", .{std.mem.span(m)});
    } else {
        c.main.setError(db, code);
    }
    return RC.OK;
}

pub export fn sqlite3_system_errno(_: ?*Handle) callconv(.c) c_int {
    return 0;
}

// ================================================================== exec

const ExecCallback = *const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int;

/// Port of sqlite3_exec() (legacy.c), on the C ABI's own prepare and
/// step, so tracing and the other hooks see its statements.
pub export fn sqlite3_exec(
    db_arg: ?*Handle,
    z_sql: ?[*:0]const u8,
    x_callback: ?ExecCallback,
    p_arg: ?*anyopaque,
    pz_errmsg: ?*?[*:0]u8,
) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    var sql: [*:0]const u8 = z_sql orelse "";
    var rc: c_int = RC.OK;
    var p_stmt: ?*c.Vdbe = null;
    var az_cols: ?[]?[*:0]u8 = null;
    c.main.setError(db, RC.OK);
    outer: while (rc == RC.OK and sql[0] != 0) {
        p_stmt = null;
        var leftover: ?[*]const u8 = null;
        rc = stmt.sqlite3_prepare_v2(db, sql, -1, &p_stmt, &leftover);
        if (rc != RC.OK) continue;
        const s = p_stmt orelse {
            // A comment or white space.
            sql = @ptrCast(leftover.?);
            continue;
        };
        var callback_is_init = false;
        while (true) {
            rc = stmt.sqlite3_step(s);
            if (x_callback) |cb| if (rc == RC.ROW or (rc == RC.DONE and !callback_is_init and db.flags.NullCallback)) {
                const n_col: usize = @intCast(stmt.sqlite3_column_count(s));
                if (!callback_is_init) {
                    az_cols = c.gpa.alloc(?[*:0]u8, 2 * n_col + 1) catch {
                        db.oomFault();
                        break :outer;
                    };
                    for (0..n_col) |i| az_cols.?[i] = @constCast(stmt.sqlite3_column_name(s, @intCast(i)));
                    callback_is_init = true;
                }
                const cols = az_cols.?;
                var vals: ?[*]?[*:0]u8 = null;
                if (rc == RC.ROW) {
                    vals = cols[n_col..].ptr;
                    for (0..n_col) |i| {
                        const t = stmt.sqlite3_column_text(s, @intCast(i));
                        if (t == null and stmt.sqlite3_column_type(s, @intCast(i)) != c.vi.SQLITE_NULL) {
                            db.oomFault();
                            break :outer;
                        }
                        cols[n_col + i] = @constCast(t);
                    }
                    cols[2 * n_col] = null;
                }
                if (cb(p_arg, @intCast(n_col), vals, cols.ptr) != 0) {
                    rc = RC.ABORT;
                    _ = stmt.sqlite3_finalize(s);
                    p_stmt = null;
                    c.main.setError(db, RC.ABORT);
                    break :outer;
                }
            };
            if (rc != RC.ROW) {
                rc = stmt.sqlite3_finalize(s);
                p_stmt = null;
                sql = @ptrCast(leftover.?);
                while (c.ctype.isSpace(sql[0])) sql += 1;
                break;
            }
        }
        if (az_cols) |a| c.gpa.free(a);
        az_cols = null;
    }
    if (p_stmt) |s| _ = stmt.sqlite3_finalize(s);
    if (az_cols) |a| c.gpa.free(a);
    rc = c.main.apiExit(db, rc);
    if (pz_errmsg) |out| {
        if (rc != RC.OK) {
            out.* = c.dupZ(c.main.errmsg(db));
            if (out.* == null) {
                rc = RC.NOMEM;
                c.main.setError(db, RC.NOMEM);
            }
        } else out.* = null;
    }
    return rc;
}

/// The state of sqlite3_get_table() (table.c's TabResult).
const TabResult = struct {
    az: std.ArrayList(?[*:0]u8) = .empty,
    n_row: u32 = 0,
    n_column: u32 = 0,
    err: ?[*:0]u8 = null,
    rc: c_int = RC.OK,

    fn callback(p: ?*anyopaque, n_col: c_int, argv: ?[*]?[*:0]u8, colv: ?[*]?[*:0]u8) callconv(.c) c_int {
        const t: *TabResult = @ptrCast(@alignCast(p.?));
        const n: usize = @intCast(n_col);
        t.collect(n, argv, colv) catch {
            t.rc = RC.NOMEM;
            return 1;
        };
        return 0;
    }

    fn collect(t: *TabResult, n: usize, argv: ?[*]?[*:0]u8, colv: ?[*]?[*:0]u8) !void {
        if (t.n_row == 0) {
            t.n_column = @intCast(n);
            for (0..n) |i| try t.az.append(c.gpa, c.dupZ(std.mem.span(colv.?[i].?)) orelse return error.OutOfMemory);
        } else if (t.n_column != n) {
            t.err = c.dupZ("sqlite3_get_table() called with two or more incompatible queries");
            t.rc = RC.ERROR;
            return error.Incompatible;
        }
        if (argv) |a| {
            for (0..n) |i| {
                const z: ?[*:0]u8 = if (a[i]) |v| c.dupZ(std.mem.span(v)) orelse return error.OutOfMemory else null;
                try t.az.append(c.gpa, z);
            }
        }
        t.n_row += 1;
    }
};

/// Port of sqlite3_get_table() (table.c).
pub export fn sqlite3_get_table(
    db_arg: ?*Handle,
    z_sql: ?[*:0]const u8,
    paz_result: ?*?[*]?[*:0]u8,
    pn_row: ?*c_int,
    pn_column: ?*c_int,
    pz_errmsg: ?*?[*:0]u8,
) callconv(.c) c_int {
    const db = db_arg orelse return RC.MISUSE;
    const out = paz_result orelse return RC.MISUSE;
    out.* = null;
    if (pn_column) |p| p.* = 0;
    if (pn_row) |p| p.* = 0;
    if (pz_errmsg) |p| p.* = null;
    var t: TabResult = .{};
    // Slot 0 holds the number of entries, for sqlite3_free_table().
    t.az.append(c.gpa, null) catch return RC.NOMEM;
    var rc = sqlite3_exec(db, z_sql, TabResult.callback, &t, pz_errmsg);
    if (rc == RC.ABORT) {
        freeEntries(t.az.items);
        t.az.deinit(c.gpa);
        if (t.err) |e| {
            if (pz_errmsg) |p| {
                if (p.*) |old| c.malloc.free(old);
                p.* = e;
            } else c.malloc.free(e);
        }
        c.main.setError(db, t.rc);
        return t.rc;
    }
    if (t.err) |e| c.malloc.free(e);
    if (rc != RC.OK) {
        freeEntries(t.az.items);
        t.az.deinit(c.gpa);
        return rc;
    }
    t.az.items[0] = @ptrFromInt(t.az.items.len);
    const owned = t.az.toOwnedSlice(c.gpa) catch {
        freeEntries(t.az.items);
        t.az.deinit(c.gpa);
        rc = RC.NOMEM;
        return rc;
    };
    out.* = owned[1..].ptr;
    if (pn_column) |p| p.* = @intCast(t.n_column);
    if (pn_row) |p| p.* = @intCast(t.n_row);
    return RC.OK;
}

fn freeEntries(az: []?[*:0]u8) void {
    for (az[1..]) |z| if (z) |s| c.malloc.free(s);
}

pub export fn sqlite3_free_table(az_result: ?[*]?[*:0]u8) callconv(.c) void {
    const r = az_result orelse return;
    const base = r - 1;
    const n = @intFromPtr(base[0]);
    freeEntries(base[0..n]);
    c.gpa.free(base[0..n]);
}

// ======================================================= connection info

pub export fn sqlite3_last_insert_rowid(db: ?*Handle) callconv(.c) i64 {
    return c.main.lastInsertRowid(db orelse return 0);
}

pub export fn sqlite3_set_last_insert_rowid(db: ?*Handle, rowid: i64) callconv(.c) void {
    const lk = c.lock(db);
    defer lk.unlock();
    (db orelse return).last_rowid = rowid;
}

pub export fn sqlite3_changes(db: ?*Handle) callconv(.c) c_int {
    return @truncate(c.api.changes(db orelse return 0));
}

pub export fn sqlite3_changes64(db: ?*Handle) callconv(.c) i64 {
    return c.api.changes(db orelse return 0);
}

pub export fn sqlite3_total_changes(db: ?*Handle) callconv(.c) c_int {
    return @truncate(c.api.totalChanges(db orelse return 0));
}

pub export fn sqlite3_total_changes64(db: ?*Handle) callconv(.c) i64 {
    return c.api.totalChanges(db orelse return 0);
}

pub export fn sqlite3_interrupt(db: ?*Handle) callconv(.c) void {
    (db orelse return).is_interrupted.store(true, .monotonic);
}

pub export fn sqlite3_is_interrupted(db: ?*Handle) callconv(.c) c_int {
    return @intFromBool((db orelse return 0).is_interrupted.load(.monotonic));
}

pub export fn sqlite3_get_autocommit(db: ?*Handle) callconv(.c) c_int {
    return @intFromBool(c.main.getAutocommit(db orelse return 0));
}

pub export fn sqlite3_db_name(db: ?*Handle, n: c_int) callconv(.c) ?[*:0]const u8 {
    if (n < 0) return null;
    return c.cStr(c.main.dbName(db orelse return null, @intCast(n)));
}

/// Port of sqlite3_db_filename(): the full name of database `z_db_name`
/// (main if null), "" for a temporary or in-memory database, null if
/// there is none. It is the pager's own name (sqlite3PagerFilename()),
/// the one the VFS was given, in the layout of sqlite3_filename with the
/// URI parameters of the database.
pub export fn sqlite3_db_filename(db_arg: ?*Handle, z_db_name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const db = db_arg orelse return null;
    const bt = c.main.dbNameToBtree(db, c.span(z_db_name)) orelse return null;
    return bt.pager.filenameZ();
}

pub export fn sqlite3_db_readonly(db: ?*Handle, z_db_name: ?[*:0]const u8) callconv(.c) c_int {
    const ro = c.main.dbReadonly(db orelse return -1, c.span(z_db_name)) orelse return -1;
    return @intFromBool(ro);
}

pub export fn sqlite3_txn_state(db_arg: ?*Handle, z_schema: ?[*:0]const u8) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return -1;
    var lo: usize = 0;
    var hi: usize = db.dbs.items.len;
    if (c.span(z_schema)) |s| {
        lo = build.findDbName(db, s) orelse return -1;
        hi = lo + 1;
    }
    var state: c_int = 0;
    for (db.dbs.items[lo..hi]) |d| {
        if (d.bt) |bt| state = @max(state, @as(c_int, @intFromEnum(bt.txnState())));
    }
    return state;
}

pub export fn sqlite3_limit(db_arg: ?*Handle, id: c_int, new_val: c_int) callconv(.c) c_int {
    const db = db_arg orelse return -1;
    if (id < 0 or id >= std.enums.values(c.int.Limit).len) return -1;
    return c.main.limit(db, @enumFromInt(id), new_val);
}

pub export fn sqlite3_busy_timeout(db: ?*Handle, ms: c_int) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    const h = db orelse return RC.MISUSE;
    if (c.extOf(h)) |e| e.busy = .{};
    return c.main.busyTimeout(h, ms);
}

fn busyThunk(arg: ?*anyopaque, count: i32) i32 {
    const e: *Ext = @ptrCast(@alignCast(arg.?));
    const f = e.busy.f orelse return 0;
    return f(e.busy.arg, count);
}

pub export fn sqlite3_busy_handler(db: ?*Handle, f: ?c.CBusy, arg: ?*anyopaque) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    const h = db orelse return RC.MISUSE;
    const e = c.ext(h);
    e.busy = .{ .f = f, .arg = arg };
    return c.main.busyHandler(h, if (f != null) busyThunk else null, e);
}

pub export fn sqlite3_setlk_timeout(db: ?*Handle, _: c_int, _: c_int) callconv(.c) c_int {
    // No blocking locks (SQLITE_ENABLE_SETLK_TIMEOUT): a no-op, as there.
    return if (db == null) RC.MISUSE else RC.OK;
}

/// Port of sqlite3_table_column_metadata().
pub export fn sqlite3_table_column_metadata(
    db_arg: ?*Handle,
    z_db_name: ?[*:0]const u8,
    z_table_name: ?[*:0]const u8,
    z_column_name: ?[*:0]const u8,
    pz_data_type: ?*?[*:0]const u8,
    pz_coll_seq: ?*?[*:0]const u8,
    p_not_null: ?*c_int,
    p_primary_key: ?*c_int,
    p_autoinc: ?*c_int,
) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const table_name = c.span(z_table_name) orelse return RC.MISUSE;
    var err: ?[:0]u8 = null;
    var rc = @import("../sql/prepare.zig").init(db, &err);
    var data_type: ?[:0]const u8 = null;
    var coll_seq: ?[:0]const u8 = null;
    var not_null = false;
    var primary_key = false;
    var autoinc = false;
    if (rc == RC.OK) blk: {
        const tab = build.findTable(db, table_name, c.span(z_db_name)) orelse {
            rc = RC.ERROR;
            break :blk;
        };
        if (tab.isView()) {
            rc = RC.ERROR;
            break :blk;
        }
        const col_name = c.span(z_column_name) orelse break :blk;
        const i_col = build.columnIndex(tab, col_name);
        if (i_col >= 0) {
            const col = &tab.cols[@intCast(i_col)];
            data_type = build.columnType(col, "");
            if (data_type.?.len == 0) data_type = null;
            coll_seq = build.columnColl(col);
            not_null = col.not_null != .None;
            primary_key = col.col_flags.PRIMKEY;
            autoinc = tab.i_pkey == i_col and tab.tab_flags.Autoincrement;
        } else if (tab.hasRowid() and isRowidName(col_name)) {
            data_type = "INTEGER";
            primary_key = true;
        } else {
            rc = RC.ERROR;
            break :blk;
        }
        if (coll_seq == null) coll_seq = "BINARY";
    }
    if (pz_data_type) |p| p.* = c.cStr(data_type);
    if (pz_coll_seq) |p| p.* = c.cStr(coll_seq);
    if (p_not_null) |p| p.* = @intFromBool(not_null);
    if (p_primary_key) |p| p.* = @intFromBool(primary_key);
    if (p_autoinc) |p| p.* = @intFromBool(autoinc);
    if (rc == RC.ERROR and err == null) {
        c.main.errorWithMsg(db, rc, "no such table column: {s}.{s}", .{ table_name, c.span(z_column_name) orelse "" });
    } else if (err) |m| {
        c.main.errorWithMsg(db, rc, "{s}", .{m});
    } else {
        c.main.setError(db, rc);
    }
    if (err) |m| db.gpa.free(m);
    return c.main.apiExit(db, rc);
}

fn isRowidName(z: []const u8) bool {
    return c.ctype.eqlNoCase(z, "rowid") or c.ctype.eqlNoCase(z, "_rowid_") or c.ctype.eqlNoCase(z, "oid");
}

// ================================================================ config

const DbConfig = c.main.DbConfig;

fn dbConfigOp(op: c_int) ?DbConfig {
    return switch (op) {
        1002 => .enable_fkey,
        1003 => .enable_trigger,
        1004 => .enable_fts3_tokenizer,
        1005 => .enable_load_extension,
        1006 => .no_ckpt_on_close,
        1007 => .enable_qpsg,
        1008 => .trigger_eqp,
        1009 => .reset_database,
        1010 => .defensive,
        1011 => .writable_schema,
        1012 => .legacy_alter_table,
        1013 => .dqs_dml,
        1014 => .dqs_ddl,
        1015 => .enable_view,
        1016 => .legacy_file_format,
        1017 => .trusted_schema,
        1018 => .stmt_scanstatus,
        1019 => .reverse_scanorder,
        1020 => .enable_attach_create,
        1021 => .enable_attach_write,
        1022 => .enable_comments,
        else => null,
    };
}

/// sqlite3_db_config() with its arguments taken out of the varargs by
/// the C shim (capi/varargs.c): `a` and `b` the integers, `p` the
/// pointer, `res` the int* result.
pub fn xq_db_config(db_arg: ?*Handle, op: c_int, a: i64, b: i64, p: ?*anyopaque, res: ?*c_int) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    switch (op) {
        1000 => {
            const z: [*:0]const u8 = @ptrCast(p orelse return RC.MISUSE);
            db.dbs.items[0].name = std.mem.span(z);
            return RC.OK;
        },
        1001 => {
            const sz: i32 = @intCast(a);
            const cnt: i32 = @intCast(b);
            const buf: ?[]align(8) u8 = if (p) |q| @as([*]align(8) u8, @ptrCast(@alignCast(q)))[0..@intCast(@max(sz, 0) * @max(cnt, 0))] else null;
            return c.main.dbConfigLookaside(db, buf, sz, cnt);
        },
        1023 => {
            const r = c.main.dbConfigFpDigits(db, @intCast(a));
            if (res) |o| o.* = r;
            return RC.OK;
        },
        else => {
            const cfg = dbConfigOp(op) orelse return RC.ERROR;
            const r = c.main.dbConfig(db, cfg, @intCast(a));
            if (res) |o| o.* = @intFromBool(r);
            return RC.OK;
        },
    }
}

/// sqlite3_file_control(): SQLITE_FCNTL_VFS_POINTER, and
/// SQLITE_FCNTL_FILE_POINTER for a file of a C VFS. Other operations go
/// to the file: the xFileControl of a C VFS's file, memdb's own
/// (SQLITE_FCNTL_SIZE_LIMIT, SQLITE_FCNTL_VFSNAME); the engine's other
/// files have none (SQLITE_NOTFOUND).
pub export fn sqlite3_file_control(db_arg: ?*Handle, z_db_name: ?[*:0]const u8, op: c_int, p_arg: ?*anyopaque) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const bt = c.main.dbNameToBtree(db, c.span(z_db_name)) orelse return RC.ERROR;
    const fd = bt.pager.fd;
    switch (op) {
        27 => {
            const out: *?*vfs_mod.sqlite3_vfs = @ptrCast(@alignCast(p_arg orelse return RC.MISUSE));
            out.* = vfs_mod.cVfsOf(bt.pager.vfs) orelse c.ext(db).vfs.cvfs;
            return RC.OK;
        },
        7 => {
            const out: *?*vfs_mod.sqlite3_file = @ptrCast(@alignCast(p_arg orelse return RC.MISUSE));
            out.* = vfs_mod.cFileOf(fd) orelse return RC.NOTFOUND;
            return RC.OK;
        },
        else => {
            if (vfs_mod.cFileOf(fd)) |f| {
                const fc = f.pMethods.?.xFileControl orelse return RC.NOTFOUND;
                return fc(f, op, p_arg);
            }
            return vfs_mod.fileControl(fd, op, p_arg);
        },
    }
}

pub export fn sqlite3_get_clientdata(db_arg: ?*Handle, z_name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const e = c.extOf(db_arg) orelse return null;
    const name = c.span(z_name) orelse return null;
    for (e.clientdata.items) |cd| if (std.mem.eql(u8, cd.name, name)) return cd.data;
    return null;
}

pub export fn sqlite3_set_clientdata(db_arg: ?*Handle, z_name: ?[*:0]const u8, p_data: ?*anyopaque, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const e = c.extOf(db_arg) orelse return RC.MISUSE;
    const name = c.span(z_name) orelse return RC.MISUSE;
    const del = c.cDestructor(x_destroy);
    for (e.clientdata.items, 0..) |*cd, i| {
        if (std.mem.eql(u8, cd.name, name)) {
            if (cd.x_destroy) |d| d(cd.data);
            if (p_data == null) {
                c.gpa.free(cd.name);
                _ = e.clientdata.orderedRemove(i);
            } else {
                cd.data = p_data;
                cd.x_destroy = del;
            }
            return RC.OK;
        }
    }
    if (p_data == null) return RC.OK;
    const z = c.gpa.dupeSentinel(u8, name, 0) catch {
        if (del) |d| d(p_data);
        return RC.NOMEM;
    };
    e.clientdata.append(c.gpa, .{ .name = z, .data = p_data, .x_destroy = del }) catch {
        c.gpa.free(z);
        if (del) |d| d(p_data);
        return RC.NOMEM;
    };
    return RC.OK;
}

pub export fn sqlite3_db_cacheflush(db: ?*Handle) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    return if (db == null) RC.MISUSE else RC.OK;
}

pub export fn sqlite3_db_release_memory(db: ?*Handle) callconv(.c) c_int {
    const lk = c.lock(db);
    defer lk.unlock();
    return if (db == null) RC.MISUSE else RC.OK;
}

/// The connection's mutex: null in multi-thread mode.
pub export fn sqlite3_db_mutex(db: ?*Handle) callconv(.c) ?*c.Mutex {
    return (c.extOf(db) orelse return null).mutex;
}

pub export fn sqlite3_db_status(db: ?*Handle, op: c_int, p_cur: ?*c_int, p_hiwtr: ?*c_int, reset: c_int) callconv(.c) c_int {
    var cur: i64 = 0;
    var hi: i64 = 0;
    const rc = sqlite3_db_status64(db, op, &cur, &hi, reset);
    if (rc == RC.OK) {
        if (p_cur) |p| p.* = @truncate(cur);
        if (p_hiwtr) |p| p.* = @truncate(hi);
    }
    return rc;
}

pub export fn sqlite3_db_status64(db_arg: ?*Handle, op: c_int, p_cur: ?*i64, p_hiwtr: ?*i64, reset: c_int) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const cur = p_cur orelse return RC.MISUSE;
    const hi = p_hiwtr orelse return RC.MISUSE;
    cur.* = 0;
    hi.* = 0;
    switch (op) {
        0, 4, 5, 6 => return c.malloc.dbStatus(db, @enumFromInt(op), cur, hi, reset != 0),
        10 => {
            cur.* = @intFromBool(db.n_deferred_imm_cons > 0 or db.n_deferred_cons > 0);
            return RC.OK;
        },
        // CACHE_USED and CACHE_USED_SHARED (no shared cache: the same).
        1, 11 => {
            for (db.dbs.items) |d| if (d.bt) |bt| {
                cur.* += bt.pager.memUsed();
            };
            return RC.OK;
        },
        // CACHE_HIT, CACHE_MISS, CACHE_WRITE, CACHE_SPILL.
        7, 8, 9, 12 => {
            const which: @import("xqlite_storage").pager.Pager.Stat = switch (op) {
                7 => .hit,
                8 => .miss,
                9 => .write,
                else => .spill,
            };
            for (db.dbs.items) |d| if (d.bt) |bt| {
                cur.* += bt.pager.cacheStat(which, reset != 0);
            };
            return RC.OK;
        },
        // STMT_USED: what the statements hold (the Vdbe, its arena).
        3 => {
            var v = db.vdbe;
            while (v) |x| : (v = x.next) cur.* += @intCast(@sizeOf(c.Vdbe) + x.arena.queryCapacity());
            return RC.OK;
        },
        // SCHEMA_USED and TEMPBUF_SPILL: not measured (SQLite measures
        // the schema by freeing it in a dry run, which the engine's
        // destructors do not support): zero.
        2, 13 => return RC.OK,
        else => return RC.ERROR,
    }
}

// ================================================================= hooks

fn walThunk(arg: ?*anyopaque, db: *Handle, name: [:0]const u8, n_frame: i32) i32 {
    const e: *Ext = @ptrCast(@alignCast(arg.?));
    const f = e.wal.f orelse return RC.OK;
    return f(e.wal.arg, db, name.ptr, n_frame);
}

pub export fn sqlite3_wal_hook(db_arg: ?*Handle, f: ?c.CWal, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return null;
    const e = c.ext(db);
    const old = if (db.wal_callback == walThunk) e.wal.arg else db.wal_arg;
    e.wal = .{ .f = f, .arg = arg };
    _ = c.main.walHook(db, if (f != null) walThunk else null, e);
    return old;
}

pub export fn sqlite3_wal_autocheckpoint(db: ?*Handle, n: c_int) callconv(.c) c_int {
    const h = db orelse return RC.MISUSE;
    if (c.extOf(h)) |e| e.wal = .{};
    return c.main.walAutocheckpoint(h, n);
}

pub export fn sqlite3_wal_checkpoint(db: ?*Handle, z_db: ?[*:0]const u8) callconv(.c) c_int {
    return c.main.walCheckpoint(db orelse return RC.MISUSE, c.span(z_db));
}

pub export fn sqlite3_wal_checkpoint_v2(db_arg: ?*Handle, z_db: ?[*:0]const u8, mode: c_int, pn_log: ?*c_int, pn_ckpt: ?*c_int) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    if (mode < -1 or mode > 3) return RC.MISUSE;
    return c.main.walCheckpointV2(db, c.span(z_db), @enumFromInt(mode), pn_log, pn_ckpt);
}

pub export fn sqlite3_commit_hook(db: ?*Handle, f: ?c.CCommit, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lk = c.lock(db);
    defer lk.unlock();
    const e = c.extOf(db) orelse return null;
    const old = e.commit.arg;
    e.commit = .{ .f = f, .arg = arg };
    @import("hooks.zig").sync(db.?);
    return old;
}

pub export fn sqlite3_rollback_hook(db: ?*Handle, f: ?c.CRollback, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lk = c.lock(db);
    defer lk.unlock();
    const e = c.extOf(db) orelse return null;
    const old = e.rollback.arg;
    e.rollback = .{ .f = f, .arg = arg };
    @import("hooks.zig").sync(db.?);
    return old;
}

pub export fn sqlite3_update_hook(db: ?*Handle, f: ?c.CUpdate, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lk = c.lock(db);
    defer lk.unlock();
    const e = c.extOf(db) orelse return null;
    const old = e.update.arg;
    e.update = .{ .f = f, .arg = arg };
    @import("hooks.zig").sync(db.?);
    return old;
}

pub export fn sqlite3_progress_handler(db: ?*Handle, n_ops: c_int, f: ?c.CProgress, arg: ?*anyopaque) callconv(.c) void {
    const lk = c.lock(db);
    defer lk.unlock();
    const e = c.extOf(db) orelse return;
    if (n_ops > 0 and f != null) {
        e.progress = .{ .f = f, .arg = arg };
        e.n_progress_ops = n_ops;
    } else {
        e.progress = .{};
        e.n_progress_ops = 0;
    }
    @import("hooks.zig").sync(db.?);
}

pub export fn sqlite3_unlock_notify(db: ?*Handle, x_notify: ?*const fn (?[*]?*anyopaque, c_int) callconv(.c) void, arg: ?*anyopaque) callconv(.c) c_int {
    // No shared cache, so no connection is ever blocked by another:
    // the callback runs at once, as SQLite does in that case.
    if (db == null) return RC.MISUSE;
    if (x_notify) |f| {
        var a = [1]?*anyopaque{arg};
        f(&a, 1);
    }
    return RC.OK;
}

// ============================================================ extensions

// sqlite3_load_extension() and sqlite3_enable_load_extension() are in
// loadext.zig.

pub export fn sqlite3_auto_extension(x_entry: ?*const anyopaque) callconv(.c) c_int {
    const f = x_entry orelse return RC.MISUSE;
    c.ensureInit();
    c.state.lock.lock();
    defer c.state.lock.unlock();
    for (c.state.auto_ext.items) |x| if (x == f) return RC.OK;
    c.state.auto_ext.append(c.gpa, f) catch return RC.NOMEM;
    return RC.OK;
}

pub export fn sqlite3_cancel_auto_extension(x_entry: ?*const anyopaque) callconv(.c) c_int {
    const f = x_entry orelse return 0;
    c.state.lock.lock();
    defer c.state.lock.unlock();
    for (c.state.auto_ext.items, 0..) |x, i| {
        if (x == f) {
            _ = c.state.auto_ext.orderedRemove(i);
            return 1;
        }
    }
    return 0;
}

pub export fn sqlite3_reset_auto_extension() callconv(.c) void {
    c.state.lock.lock();
    defer c.state.lock.unlock();
    c.state.auto_ext.clearAndFree(c.gpa);
}

// ================================================================ backup

pub export fn sqlite3_backup_init(dest: ?*Handle, z_dest: ?[*:0]const u8, src: ?*Handle, z_src: ?[*:0]const u8) callconv(.c) ?*backup_mod.Backup {
    const lk_src = c.lock(src);
    defer lk_src.unlock();
    const lk_dest = c.lock(dest);
    defer lk_dest.unlock();
    return backup_mod.init(dest orelse return null, c.span(z_dest) orelse "main", src orelse return null, c.span(z_src) orelse "main");
}

pub export fn sqlite3_backup_step(p: ?*backup_mod.Backup, n_page: c_int) callconv(.c) c_int {
    const lk = c.lock(if (p) |b| b.src_db else null);
    defer lk.unlock();
    return backup_mod.step(p orelse return RC.MISUSE, n_page);
}

pub export fn sqlite3_backup_finish(p_arg: ?*backup_mod.Backup) callconv(.c) c_int {
    const p = p_arg orelse return RC.OK;
    const dest = p.dest_db;
    const src = p.src_db;
    const lk_src = c.lock(src);
    const lk_dest = c.lock(dest);
    const rc = backup_mod.finish(p);
    if (dest) |d| leaveAndCloseZombie(d, lk_dest) else lk_dest.unlock();
    leaveAndCloseZombie(src, lk_src);
    return rc;
}

pub export fn sqlite3_backup_remaining(p: ?*backup_mod.Backup) callconv(.c) c_int {
    return backup_mod.remaining(p orelse return 0);
}

pub export fn sqlite3_backup_pagecount(p: ?*backup_mod.Backup) callconv(.c) c_int {
    return backup_mod.pagecount(p orelse return 0);
}

// ============================================ not supported: stubs

// ========================================================= serialization

pub export fn sqlite3_serialize(db_arg: ?*Handle, z_schema: ?[*:0]const u8, pi_size: ?*i64, m_flags: c_uint) callconv(.c) ?[*]u8 {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return null;
    const r = @import("../sql/serialize.zig").serialize(db, c.span(z_schema), m_flags);
    if (pi_size) |p| p.* = r.size;
    return r.data;
}

pub export fn sqlite3_deserialize(db_arg: ?*Handle, z_schema: ?[*:0]const u8, p_data: ?[*]u8, sz_db: i64, sz_buf: i64, m_flags: c_uint) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    if (sz_db < 0 or sz_buf < 0) return RC.MISUSE;
    return @import("../sql/serialize.zig").deserialize(db, c.span(z_schema), p_data, sz_db, sz_buf, m_flags);
}

// ============================================ not supported: stubs

// ============================================================ snapshots

const snapshot = @import("../sql/snapshot.zig");

pub export fn sqlite3_snapshot_get(db_arg: ?*Handle, z_db: ?[*:0]const u8, pp: ?*?*snapshot.Snapshot) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const out = pp orelse return RC.MISUSE;
    return snapshot.get(db, c.span(z_db), out);
}

pub export fn sqlite3_snapshot_open(db_arg: ?*Handle, z_db: ?[*:0]const u8, p: ?*snapshot.Snapshot) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    return snapshot.open(db, c.span(z_db), p orelse return RC.MISUSE);
}

pub export fn sqlite3_snapshot_free(p: ?*snapshot.Snapshot) callconv(.c) void {
    c.malloc.free(p);
}

pub export fn sqlite3_snapshot_cmp(a: ?*snapshot.Snapshot, b: ?*snapshot.Snapshot) callconv(.c) c_int {
    return snapshot.cmp(a.?, b.?);
}

pub export fn sqlite3_snapshot_recover(db_arg: ?*Handle, z_db: ?[*:0]const u8) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    return snapshot.recover(db, c.span(z_db));
}

// ==================================================== xqlite extensions

/// xqlite: make `z_name` ("sqlite", "postgres", "mariadb", "mssql",
/// "oracle" or an alias such as "pg" or "mysql") the SQL dialect of the
/// statements prepared from now on, as PRAGMA xq_dialect does.
pub export fn xqlite_set_dialect(db_arg: ?*Handle, z_name: ?[*:0]const u8) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const name = c.span(z_name) orelse return RC.MISUSE;
    const d = c.dialect.Dialect.fromName(name) orelse {
        c.main.errorWithMsg(db, RC.ERROR, "no such dialect: {s}", .{name});
        return RC.ERROR;
    };
    c.main.setDialect(db, d);
    return RC.OK;
}

/// xqlite: the name of the connection's SQL dialect.
pub export fn xqlite_dialect(db_arg: ?*Handle) callconv(.c) ?[*:0]const u8 {
    const db = db_arg orelse return null;
    return c.main.getDialect(db).name().ptr;
}

// The xq_* functions are for capi/varargs.c only: hidden outside the library.
comptime {
    @export(&xq_db_config, .{ .name = "xq_db_config", .visibility = .hidden });
}
