//! The WebAssembly module for browsers and other JavaScript hosts
//! (wasm32-freestanding, `zig build wasm`): a small C-shaped API over the
//! Zig API (Db, Stmt), exported as `xq_*`. The JavaScript glue is
//! examples/wasm/xqlite.mjs; docs/wasm.md lists every export and import.
//!
//! Handles are pointers into linear memory (u32), strings are a pointer
//! and a length in bytes (UTF-8), allocated by the caller with
//! xq_malloc() and freed with xq_free(). Calls that can fail return a
//! result code (0 OK, 100 ROW, 101 DONE, else the SQLite error code);
//! xq_errmsg() has the message.
//!
//! Databases live in the host's files (vfs/host.zig, open flag
//! `open_host`) or in a memory file system shared by the connections of
//! this instance (the default): a host that implements nothing but the
//! clock and randomness still gets a working database.

const std = @import("std");
const xqlite = @import("xqlite");

const Db = xqlite.Db;
const Stmt = xqlite.Stmt;

const gpa = std.heap.wasm_allocator;

/// The host's random bytes (crypto.getRandomValues()).
extern "env" fn xq_host_random(buf: [*]u8, len: usize) void;

/// std.Io for this target: nothing but randomness (and a sleep that
/// returns at once); the clock comes from xq_host_now_ms (util/platform.zig)
/// and the files from the VFS.
const io: std.Io = .{ .userdata = null, .vtable = &io_vtable };
const io_vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.random = hostRandom;
    break :blk v;
};

fn hostRandom(_: ?*anyopaque, buf: []u8) void {
    xq_host_random(buf.ptr, buf.len);
}

/// A crash ends the call with a trap, which the host sees as an exception.
pub const panic = std.debug.no_panic;
/// std.debug has no stderr here (only debug tracing would print).
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const std_options_debug_io: std.Io = io;

/// The memory file system of the connections that do not use the host's
/// files, created on first use and shared by all of them.
var mem_vfs: ?xqlite.MemVfs = null;
/// The host VFS, shared by the connections that use it.
var host_vfs: ?xqlite.HostVfs = null;

/// A connection and the details of its last error.
const Conn = struct {
    db: Db = undefined,
    is_open: bool = false,
    diag: xqlite.Diagnostics = .{},
    /// The message of the last error, NUL-terminated.
    msg: [xqlite.Diagnostics.max_message + 1]u8 = undefined,

    fn code(c: *Conn) i32 {
        return @backingInt(c.diag.code);
    }

    /// The result code of a failed call (the diagnostics have it).
    fn fail(c: *Conn, err: xqlite.Error) i32 {
        if (c.diag.code == .ok) {
            const msg = @errorName(err);
            c.diag.set(err, .@"error", msg, null);
        }
        return c.code();
    }
};

const Statement = struct {
    stmt: Stmt,
    conn: *Conn,
};

const open_read_only = 1;
const open_host = 2;

// ============================================================== memory

export fn xq_malloc(n: usize) ?[*]u8 {
    const m = gpa.alloc(u8, @max(n, 1)) catch return null;
    return m.ptr;
}

export fn xq_free(p: ?[*]u8, n: usize) void {
    if (p) |q| gpa.free(q[0..@max(n, 1)]);
}

// ========================================================= connections

/// Open the database `path` (":memory:" for a private one). `flags`: 1
/// read-only, 2 in the host's files (else the shared memory file
/// system). Returns the connection even when opening failed (check
/// xq_errcode(), then xq_close() it), or 0 if out of memory.
export fn xq_open(path_ptr: [*]const u8, path_len: usize, flags: u32) ?*Conn {
    const c = gpa.create(Conn) catch return null;
    c.* = .{};
    const v = if (flags & open_host != 0) blk: {
        if (host_vfs == null) host_vfs = .init(gpa, io);
        break :blk host_vfs.?.interface();
    } else blk: {
        if (mem_vfs == null) mem_vfs = .init(gpa, io);
        break :blk mem_vfs.?.interface();
    };
    c.db = Db.open(gpa, io, path_ptr[0..path_len], .{
        .read_only = flags & open_read_only != 0,
        .vfs = .{ .custom = v },
        .diagnostics = &c.diag,
    }) catch return c;
    c.is_open = true;
    return c;
}

/// Close the connection; every statement must be finalized. Returns 0,
/// or 5 (BUSY) with statements still open.
export fn xq_close(c: *Conn) i32 {
    if (c.is_open) c.db.tryClose() catch |err| return c.fail(err);
    gpa.destroy(c);
    return 0;
}

/// The extended result code of the last failed call (0 if none).
export fn xq_errcode(c: *Conn) i32 {
    return c.code();
}

/// The message of the last failed call, NUL-terminated.
export fn xq_errmsg(c: *Conn) [*:0]const u8 {
    const m = c.diag.message();
    @memcpy(c.msg[0..m.len], m);
    c.msg[m.len] = 0;
    return c.msg[0..m.len :0].ptr;
}

/// Run every statement of the SQL text, discarding rows.
export fn xq_exec(c: *Conn, sql_ptr: [*]const u8, sql_len: usize) i32 {
    c.diag.clear();
    c.db.exec(sql_ptr[0..sql_len]) catch |err| return c.fail(err);
    return 0;
}

/// Set the SQL dialect by name, as PRAGMA xq_dialect does.
export fn xq_set_dialect(c: *Conn, name_ptr: [*]const u8, name_len: usize) i32 {
    const d = std.meta.stringToEnum(xqlite.Dialect, name_ptr[0..name_len]) orelse {
        c.diag.set(error.Misuse, .misuse, "unknown dialect", null);
        return c.code();
    };
    c.db.setDialect(d);
    return 0;
}

export fn xq_changes(c: *Conn) f64 {
    return @floatFromInt(c.db.changes());
}

export fn xq_last_insert_rowid(c: *Conn) i64 {
    return c.db.lastInsertRowid();
}

// ========================================================== statements

/// Compile one statement; 0 on error (see xq_errmsg()).
export fn xq_prepare(c: *Conn, sql_ptr: [*]const u8, sql_len: usize) ?*Statement {
    c.diag.clear();
    const s = gpa.create(Statement) catch return null;
    s.* = .{ .stmt = c.db.prepare(sql_ptr[0..sql_len]) catch {
        gpa.destroy(s);
        return null;
    }, .conn = c };
    return s;
}

/// 100 (ROW) with a row to read, 101 (DONE), or an error code.
export fn xq_step(s: *Statement) i32 {
    s.conn.diag.clear();
    const row = s.stmt.step() catch |err| return s.conn.fail(err);
    return if (row) 100 else 101;
}

export fn xq_reset(s: *Statement) void {
    s.stmt.reset();
}

export fn xq_finalize(s: *Statement) void {
    s.stmt.finalize();
    gpa.destroy(s);
}

/// Bind parameter `i` (1-based). Values are copied.
export fn xq_bind_null(s: *Statement, i: u32) i32 {
    return bind(s, i, null);
}

export fn xq_bind_int64(s: *Statement, i: u32, x: i64) i32 {
    return bind(s, i, x);
}

export fn xq_bind_double(s: *Statement, i: u32, x: f64) i32 {
    return bind(s, i, x);
}

export fn xq_bind_text(s: *Statement, i: u32, p: [*]const u8, n: usize) i32 {
    return bind(s, i, p[0..n]);
}

fn bind(s: *Statement, i: u32, x: anytype) i32 {
    s.stmt.bindAt(i, x) catch |err| return s.conn.fail(err);
    return 0;
}

export fn xq_column_count(s: *Statement) u32 {
    return @intCast(s.stmt.columnCount());
}

/// The name of column `i`, NUL-terminated.
export fn xq_column_name(s: *Statement, i: u32) [*:0]const u8 {
    const n = s.stmt.columnName(i);
    // The engine's names are NUL-terminated.
    return @ptrCast(n.ptr);
}

/// The type of column `i` of the row: 1 integer, 2 float, 3 text,
/// 4 blob, 5 null (SQLITE_INTEGER ...).
export fn xq_column_type(s: *Statement, i: u32) i32 {
    return switch (s.stmt.columnKind(i)) {
        .integer => 1,
        .float => 2,
        .text => 3,
        .blob => 4,
        .null => 5,
    };
}

export fn xq_column_int64(s: *Statement, i: u32) i64 {
    return s.stmt.column(?i64, i) catch null orelse 0;
}

export fn xq_column_double(s: *Statement, i: u32) f64 {
    return s.stmt.column(?f64, i) catch null orelse 0;
}

/// Column `i` as text (or the bytes of a blob); xq_column_bytes() has
/// the length. Valid until the next step, reset or finalize.
export fn xq_column_text(s: *Statement, i: u32) ?[*]const u8 {
    const t = columnBytes(s, i) orelse return null;
    return t.ptr;
}

export fn xq_column_bytes(s: *Statement, i: u32) usize {
    const t = columnBytes(s, i) orelse return 0;
    return t.len;
}

fn columnBytes(s: *Statement, i: u32) ?[]const u8 {
    if (s.stmt.columnKind(i) == .blob) {
        const b = s.stmt.column(?xqlite.Blob, i) catch return null;
        return if (b) |x| x.data else null;
    }
    return s.stmt.column(?[]const u8, i) catch null;
}
