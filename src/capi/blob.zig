//! Incremental BLOB I/O (sqlite3_blob_*): the C face of the engine's port
//! of vdbeblob.c (vdbe/blob.zig). A sqlite3_blob* is its Incrblob.

const c = @import("common.zig");
const blob = @import("../vdbe/blob.zig");
const conn = @import("conn.zig");

const Handle = c.Handle;
const RC = c.RC;
const Incrblob = blob.Incrblob;

pub export fn sqlite3_blob_open(
    db_arg: ?*Handle,
    z_db: ?[*:0]const u8,
    z_table: ?[*:0]const u8,
    z_column: ?[*:0]const u8,
    i_row: i64,
    w_flag: c_int,
    pp_blob: ?*?*Incrblob,
) callconv(.c) c_int {
    const out = pp_blob orelse return RC.MISUSE;
    out.* = null;
    const db = db_arg orelse return RC.MISUSE;
    const tab = c.span(z_table) orelse return RC.MISUSE;
    const col = c.span(z_column) orelse return RC.MISUSE;
    return blob.open(db, c.span(z_db), tab, col, i_row, w_flag != 0, out);
}

pub export fn sqlite3_blob_reopen(p: ?*Incrblob, i_row: i64) callconv(.c) c_int {
    return blob.reopen(p orelse return RC.MISUSE, i_row);
}

pub export fn sqlite3_blob_close(p_arg: ?*Incrblob) callconv(.c) c_int {
    const p = p_arg orelse return RC.OK;
    const db = p.db;
    const rc = blob.close(p);
    // The program was a statement of a connection sqlite3_close_v2()
    // may be waiting on.
    conn.closeZombie(db);
    return rc;
}

pub export fn sqlite3_blob_bytes(p: ?*Incrblob) callconv(.c) c_int {
    return blob.bytes(p orelse return 0);
}

pub export fn sqlite3_blob_read(p_arg: ?*Incrblob, z: ?*anyopaque, n: c_int, off: c_int) callconv(.c) c_int {
    const p = p_arg orelse return RC.MISUSE;
    if (n < 0) return rangeError(p);
    const buf: [*]u8 = @ptrCast(z orelse if (n == 0) @as(*anyopaque, @ptrFromInt(1)) else return RC.MISUSE);
    return blob.read(p, buf[0..@intCast(n)], off);
}

pub export fn sqlite3_blob_write(p_arg: ?*Incrblob, z: ?*const anyopaque, n: c_int, off: c_int) callconv(.c) c_int {
    const p = p_arg orelse return RC.MISUSE;
    if (n < 0) return rangeError(p);
    const buf: [*]const u8 = @ptrCast(z orelse if (n == 0) @as(*const anyopaque, @ptrFromInt(1)) else return RC.MISUSE);
    return blob.write(p, buf[0..@intCast(n)], off);
}

/// A negative size: out of range, as blobReadWrite() reports it.
fn rangeError(p: *Incrblob) c_int {
    c.main.setError(p.db, RC.ERROR);
    return c.main.apiExit(p.db, RC.ERROR);
}
