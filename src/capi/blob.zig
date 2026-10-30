//! Incremental BLOB I/O (sqlite3_blob_*), emulated with SQL: the engine
//! has no cursor-level blob access yet. A read selects the value; a
//! write reads it, patches it in memory and stores it back with an
//! UPDATE of that row. The results are those of SQLite, with these
//! differences: a write is a real UPDATE (it fires triggers, counts in
//! sqlite3_changes() and costs the size of the whole value), and a
//! handle does not expire when its row changes.

const std = @import("std");
const c = @import("common.zig");
const stmt = @import("stmt.zig");

const Handle = c.Handle;
const RC = c.RC;

const Blob = struct {
    db: *Handle,
    /// SELECT "col" FROM "db"."tab" WHERE rowid = ?1
    read: *c.Vdbe,
    /// UPDATE "db"."tab" SET "col" = ?1 WHERE rowid = ?2 (with flags).
    write: ?*c.Vdbe,
    rowid: i64 = 0,
    n_bytes: c_int = 0,
    is_text: bool = false,
};

fn quoteIdent(out: *std.ArrayList(u8), z: []const u8) !void {
    try out.append(c.gpa, '"');
    for (z) |ch| {
        if (ch == '"') try out.append(c.gpa, '"');
        try out.append(c.gpa, ch);
    }
    try out.append(c.gpa, '"');
}

fn prepareSql(db: *Handle, parts: []const []const u8, idents: []const []const u8) ?*c.Vdbe {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(c.gpa);
    for (parts, 0..) |p, i| {
        sql.appendSlice(c.gpa, p) catch return null;
        if (i < idents.len) quoteIdent(&sql, idents[i]) catch return null;
    }
    var v: ?*c.Vdbe = null;
    _ = stmt.sqlite3_prepare_v2(db, sql.items.ptr, @intCast(sql.items.len), &v, null);
    return v;
}

/// Move the blob to row `rowid`: its size and type, or an error.
fn seek(b: *Blob, rowid: i64) c_int {
    const v = b.read;
    _ = stmt.sqlite3_reset(v);
    _ = stmt.sqlite3_bind_int64(v, 1, rowid);
    const rc = stmt.sqlite3_step(v);
    if (rc != RC.ROW) {
        const r = stmt.sqlite3_reset(v);
        if (r != RC.OK) return r;
        c.main.errorWithMsg(b.db, RC.ERROR, "no such rowid: {d}", .{rowid});
        return RC.ERROR;
    }
    const t = stmt.sqlite3_column_type(v, 0);
    if (t != c.vi.SQLITE_BLOB and t != c.vi.SQLITE_TEXT) {
        const name = switch (t) {
            c.vi.SQLITE_INTEGER => "integer",
            c.vi.SQLITE_FLOAT => "real",
            else => "null",
        };
        _ = stmt.sqlite3_reset(v);
        c.main.errorWithMsg(b.db, RC.ERROR, "cannot open value of type {s}", .{name});
        return RC.ERROR;
    }
    b.is_text = t == c.vi.SQLITE_TEXT;
    b.n_bytes = stmt.sqlite3_column_bytes(v, 0);
    b.rowid = rowid;
    _ = stmt.sqlite3_reset(v);
    return RC.OK;
}

pub export fn sqlite3_blob_open(
    db_arg: ?*Handle,
    z_db: ?[*:0]const u8,
    z_table: ?[*:0]const u8,
    z_column: ?[*:0]const u8,
    i_row: i64,
    w_flag: c_int,
    pp_blob: ?*?*Blob,
) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const out = pp_blob orelse return RC.MISUSE;
    out.* = null;
    const db = db_arg orelse return RC.MISUSE;
    const dbn = c.span(z_db) orelse "main";
    const tab = c.span(z_table) orelse return RC.MISUSE;
    const col = c.span(z_column) orelse return RC.MISUSE;
    const read = prepareSql(db, &.{ "SELECT ", " FROM ", ".", " WHERE rowid = ?1" }, &.{ col, dbn, tab }) orelse
        return c.main.errcode(db);
    var write: ?*c.Vdbe = null;
    if (w_flag != 0) {
        write = prepareSql(db, &.{ "UPDATE ", ".", " SET ", " = ?1 WHERE rowid = ?2" }, &.{ dbn, tab, col }) orelse {
            _ = stmt.sqlite3_finalize(read);
            return c.main.errcode(db);
        };
    }
    const b = c.gpa.create(Blob) catch {
        _ = stmt.sqlite3_finalize(read);
        _ = stmt.sqlite3_finalize(write);
        return RC.NOMEM;
    };
    b.* = .{ .db = db, .read = read, .write = write };
    const rc = seek(b, i_row);
    if (rc != RC.OK) {
        const saved = c.main.errmsg(db);
        const msg = c.gpa.dupe(u8, saved) catch null;
        _ = stmt.sqlite3_finalize(read);
        _ = stmt.sqlite3_finalize(write);
        c.gpa.destroy(b);
        if (msg) |m| {
            c.main.errorWithMsg(db, rc, "{s}", .{m});
            c.gpa.free(m);
        }
        return rc;
    }
    c.main.setError(db, RC.OK);
    out.* = b;
    return RC.OK;
}

pub export fn sqlite3_blob_reopen(b_arg: ?*Blob, i_row: i64) callconv(.c) c_int {
    const lk = c.lock(if (b_arg) |b| b.db else null);
    defer lk.unlock();
    const b = b_arg orelse return RC.MISUSE;
    return seek(b, i_row);
}

pub export fn sqlite3_blob_close(b_arg: ?*Blob) callconv(.c) c_int {
    const b = b_arg orelse return RC.OK;
    _ = stmt.sqlite3_finalize(b.read);
    _ = stmt.sqlite3_finalize(b.write);
    c.gpa.destroy(b);
    return RC.OK;
}

pub export fn sqlite3_blob_bytes(b_arg: ?*Blob) callconv(.c) c_int {
    return (b_arg orelse return 0).n_bytes;
}

/// The current value of the blob's row, from its read statement (valid
/// until it is reset).
fn current(b: *Blob) ?[]const u8 {
    const v = b.read;
    _ = stmt.sqlite3_reset(v);
    _ = stmt.sqlite3_bind_int64(v, 1, b.rowid);
    if (stmt.sqlite3_step(v) != RC.ROW) return null;
    const n: usize = @intCast(stmt.sqlite3_column_bytes(v, 0));
    const p: [*]const u8 = @ptrCast(stmt.sqlite3_column_blob(v, 0) orelse return "");
    return p[0..n];
}

pub export fn sqlite3_blob_read(b_arg: ?*Blob, z: ?*anyopaque, n: c_int, off: c_int) callconv(.c) c_int {
    const lk = c.lock(if (b_arg) |b| b.db else null);
    defer lk.unlock();
    const b = b_arg orelse return RC.MISUSE;
    if (n < 0 or off < 0 or @as(i64, n) + off > b.n_bytes) {
        c.main.setError(b.db, RC.ERROR);
        return RC.ERROR;
    }
    const data = current(b) orelse {
        _ = stmt.sqlite3_reset(b.read);
        c.main.setError(b.db, RC.ABORT);
        return RC.ABORT;
    };
    defer _ = stmt.sqlite3_reset(b.read);
    if (data.len != @as(usize, @intCast(b.n_bytes))) {
        c.main.setError(b.db, RC.ABORT);
        return RC.ABORT;
    }
    const dst: [*]u8 = @ptrCast(z orelse return RC.MISUSE);
    @memcpy(dst[0..@intCast(n)], data[@intCast(off)..][0..@intCast(n)]);
    return RC.OK;
}

pub export fn sqlite3_blob_write(b_arg: ?*Blob, z: ?*const anyopaque, n: c_int, off: c_int) callconv(.c) c_int {
    const lk = c.lock(if (b_arg) |b| b.db else null);
    defer lk.unlock();
    const b = b_arg orelse return RC.MISUSE;
    const w = b.write orelse {
        c.main.setError(b.db, RC.READONLY);
        return RC.READONLY;
    };
    if (n < 0 or off < 0 or @as(i64, n) + off > b.n_bytes) {
        c.main.setError(b.db, RC.ERROR);
        return RC.ERROR;
    }
    const data = current(b) orelse {
        _ = stmt.sqlite3_reset(b.read);
        c.main.setError(b.db, RC.ABORT);
        return RC.ABORT;
    };
    const copy = c.gpa.dupe(u8, data) catch {
        _ = stmt.sqlite3_reset(b.read);
        return RC.NOMEM;
    };
    defer c.gpa.free(copy);
    _ = stmt.sqlite3_reset(b.read);
    const src: [*]const u8 = @ptrCast(z orelse return RC.MISUSE);
    @memcpy(copy[@intCast(off)..][0..@intCast(n)], src[0..@intCast(n)]);
    _ = stmt.sqlite3_reset(w);
    _ = if (b.is_text)
        stmt.sqlite3_bind_text(w, 1, copy.ptr, @intCast(copy.len), null)
    else
        stmt.sqlite3_bind_blob(w, 1, copy.ptr, @intCast(copy.len), null);
    _ = stmt.sqlite3_bind_int64(w, 2, b.rowid);
    _ = stmt.sqlite3_step(w);
    const rc = stmt.sqlite3_reset(w);
    _ = stmt.sqlite3_clear_bindings(w);
    return rc;
}
