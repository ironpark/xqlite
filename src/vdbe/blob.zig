//! Incremental BLOB I/O (port of vdbeblob.c): sqlite3_blob_open() and
//! the functions on its handle.
//!
//! A handle owns a small program that seeks a b-tree cursor to the row
//! and stops at OP_ResultRow. The handle then "borrows" the cursor: reads
//! and writes go straight to the row's payload (Cursor.payloadChecked(),
//! Cursor.putData()), so a write fires no trigger or update hook and does
//! not count in sqlite3_changes(). The cursor is marked as an incremental
//! blob cursor, which the b-tree invalidates when its row is replaced or
//! deleted: the handle then fails with SQLITE_ABORT. Closing the handle
//! finalizes the program, which ends the transaction it started.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const aux = @import("aux.zig");
const api = @import("api.zig");
const mem = @import("mem.zig");
const record = @import("record.zig");
const exec_mod = @import("exec.zig");
const btree = @import("../btree/btree.zig");
const int = @import("../sql/sqlite_int.zig");
const build = @import("../sql/build.zig");
const prepare = @import("../sql/prepare.zig");
const main_mod = @import("../sql/main.zig");

const Vdbe = vi.Vdbe;
const OP = vi.OP;
const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const RC = int.RC;

/// SQLITE_MAX_SCHEMA_RETRY.
const max_schema_retry = 50;

/// An open blob (Incrblob, the sqlite3_blob of C).
pub const Incrblob = struct {
    /// Size of the open blob, in bytes.
    n_byte: i32 = 0,
    /// Offset of the blob in the cursor's payload.
    i_offset: i32 = 0,
    /// The table column the handle is open on.
    i_col: u16 = 0,
    /// The cursor on the row, owned by `stmt`.
    csr: ?*btree.Cursor = null,
    /// The program holding the cursor open; null once the handle has been
    /// invalidated.
    stmt: ?*Vdbe = null,
    db: *Sqlite3,
};

/// Port of blobSeekToRow(): seek the handle's program to row `i_row`. On
/// error the program is finalized (the handle is then invalid) and the
/// message (from db.gpa) is returned in `err`.
fn seekToRow(p: *Incrblob, i_row: i64, err: *?[:0]u8) i32 {
    const db = p.db;
    const v = p.stmt.?;
    var msg: ?[:0]u8 = null;
    // Register 1 holds the rowid, set directly for speed.
    mem.setInt64(&v.mem[1], i_row);
    // A program that ran before is paused at OP_ResultRow: back up to the
    // OP_NotExists instead of starting over.
    var rc: i32 = undefined;
    if (v.pc > 4) {
        v.pc = 4;
        std.debug.assert(v.ops.items[4].opcode == OP.NotExists);
        rc = exec_mod.exec(v);
    } else {
        rc = api.step(v);
    }
    if (rc == RC.ROW) {
        const c = v.csr[0].?;
        std.debug.assert(c.e_cur_type == .btree);
        const t: u32 = if (c.n_hdr_parsed > p.i_col) c.types[p.i_col] else 0;
        if (t < 12) {
            msg = std.fmt.allocPrintSentinel(db.gpa, "cannot open value of type {s}", .{
                if (t == 0) "null" else if (t == 7) "real" else "integer",
            }, 0) catch null;
            rc = RC.ERROR;
            _ = api.finalize(v);
            p.stmt = null;
        } else {
            p.i_offset = @intCast(c.offsets[p.i_col]);
            p.n_byte = @intCast(record.serialTypeLen(t));
            p.csr = c.uc.cursor;
            p.csr.?.incrblobCursor();
        }
    }
    if (rc == RC.ROW) {
        rc = RC.OK;
    } else if (p.stmt) |s| {
        rc = api.finalize(s);
        p.stmt = null;
        if (rc == RC.OK) {
            msg = std.fmt.allocPrintSentinel(db.gpa, "no such rowid: {d}", .{i_row}, 0) catch null;
            rc = RC.ERROR;
        } else {
            msg = db.gpa.dupeSentinel(u8, main_mod.errmsg(db), 0) catch null;
        }
    }
    std.debug.assert(rc != RC.OK or msg == null);
    err.* = msg;
    return rc;
}

/// The error message of a failed open (zErr): from db.gpa, or null.
fn dupMsg(db: *Sqlite3, comptime fmt: []const u8, args: anytype) ?[:0]u8 {
    return std.fmt.allocPrintSentinel(db.gpa, fmt, args, 0) catch null;
}

/// Port of sqlite3_blob_open(): open the value of column `column` of row
/// `i_row` of table `table` in database `database` (main if null), for
/// reading and writing with `wr_flag`. The handle goes to `out` (null on
/// error, with the error left in the connection).
pub fn open(db: *Sqlite3, database: ?[]const u8, table: []const u8, column: []const u8, i_row: i64, wr_flag: bool, out: *?*Incrblob) i32 {
    out.* = null;
    var n_attempt: u32 = 0;
    var rc: i32 = RC.OK;
    var err: ?[:0]u8 = null;
    const blob = db.gpa.create(Incrblob) catch {
        db.oomFault();
        return main_mod.apiExit(db, RC.NOMEM);
    };
    blob.* = .{ .db = db };
    while (true) {
        if (err) |m| db.gpa.free(m);
        err = null;
        rc = compile(db, blob, database, table, column, wr_flag, &err);
        if (rc != RC.OK or db.malloc_failed) break;
        rc = seekToRow(blob, i_row, &err);
        n_attempt += 1;
        if (n_attempt >= max_schema_retry or rc != RC.SCHEMA) break;
    }
    if (rc == RC.OK and !db.malloc_failed) {
        out.* = blob;
    } else {
        if (blob.stmt) |s| _ = aux.finalize(s);
        db.gpa.destroy(blob);
    }
    if (err) |m| {
        main_mod.errorWithMsg(db, rc, "{s}", .{m});
        db.gpa.free(m);
    } else {
        main_mod.setError(db, rc);
    }
    return main_mod.apiExit(db, rc);
}

/// One pass of the loop of sqlite3_blob_open() up to the seek: find the
/// table and column, check them and build the program in `blob.stmt`.
fn compile(db: *Sqlite3, blob: *Incrblob, database: ?[]const u8, table: []const u8, column: []const u8, wr_flag: bool, err: *?[:0]u8) i32 {
    var arena_state = std.heap.ArenaAllocator.init(db.gpa);
    defer arena_state.deinit();
    var p: Parse = .{ .db = db, .arena = arena_state.allocator() };
    defer build.releaseTableRefs(&p);
    defer prepare.parseObjectResetLookaside(&p);

    var tab_opt = build.locateTable(&p, 0, table, database);
    if (tab_opt) |t| if (t.isVirtual()) {
        tab_opt = null;
        @import("../sql/util.zig").errorMsg(&p, "cannot open virtual table: {s}", .{table});
    };
    if (tab_opt) |t| if (!t.hasRowid()) {
        tab_opt = null;
        @import("../sql/util.zig").errorMsg(&p, "cannot open table without rowid: {s}", .{table});
    };
    if (tab_opt) |t| if (t.tab_flags.intersects(int.TF.HasGenerated)) {
        tab_opt = null;
        @import("../sql/util.zig").errorMsg(&p, "cannot open table with generated columns: {s}", .{table});
    };
    if (tab_opt) |t| if (t.isView()) {
        tab_opt = null;
        @import("../sql/util.zig").errorMsg(&p, "cannot open view: {s}", .{table});
    };
    var i_db: i32 = 0;
    if (tab_opt) |t| i_db = prepare.schemaToIndex(db, t.schema);
    const tab = tab_opt orelse return failParse(db, &p, err);
    if (i_db == 1) build.openTempDatabase(&p) catch return failParse(db, &p, err);

    // The column.
    const i_col = build.columnIndex(tab, column);
    if (i_col < 0) {
        err.* = dupMsg(db, "no such column: \"{s}\"", .{column});
        return RC.ERROR;
    }

    // A value opened for writing must not be in an index or a foreign key.
    if (wr_flag) {
        var fault: ?[]const u8 = null;
        if (db.flags.ForeignKeys) {
            // Parent key columns are indexed, which the check below finds.
            var fk = tab.u.tab.fkey;
            while (fk) |k| : (fk = k.next_from) {
                for (k.cols) |col| if (col.i_from == i_col) {
                    fault = "foreign key";
                };
            }
        }
        var idx = tab.index;
        while (idx) |x| : (idx = x.next) {
            for (x.ai_column[0..x.n_key_col]) |c| {
                // FIXME (as in SQLite): be smarter about expression indexes.
                if (c == i_col or c == int.XN_EXPR) fault = "indexed";
            }
        }
        if (fault) |f| {
            err.* = dupMsg(db, "cannot open {s} column for writing", .{f});
            return RC.ERROR;
        }
    }

    const v = aux.create(&p) catch {
        db.oomFault();
        return RC.NOMEM;
    };
    blob.stmt = v;
    // This program seeks a b-tree cursor to the row, then stops at
    // OP_ResultRow; the handle then uses the cursor. A program rather
    // than direct b-tree calls gets the transaction, locking and error
    // handling of the VDBE. Finalizing it closes the cursor and ends the
    // transaction.
    const schema = tab.schema.?;
    _ = aux.addOp4Int(v, OP.Transaction, i_db, @intFromBool(wr_flag), schema.schema_cookie, schema.i_generation);
    aux.changeP5(v, 1);
    std.debug.assert(aux.currentAddr(v) == 2 or db.malloc_failed);
    const ops = aux.addOpList(v, &.{
        // 0: OP_TableLock: without a shared cache, OP_Noop.
        .{ .opcode = OP.Noop },
        // 1: open a cursor.
        .{ .opcode = OP.OpenRead },
        // 2: seek to rowid r[1] (seekToRow() sets it).
        .{ .opcode = OP.NotExists, .p2 = 5, .p3 = 1 },
        // 3
        .{ .opcode = OP.Column, .p3 = 1 },
        // 4
        .{ .opcode = OP.ResultRow, .p1 = 1 },
        // 5
        .{ .opcode = OP.Halt },
    });
    aux.usesBtree(v, @intCast(i_db));
    if (!db.malloc_failed) {
        const o = ops.?;
        // Open the cursor for writing if asked, on the table's root.
        if (wr_flag) o[1].opcode = OP.OpenWrite;
        o[1].p2 = @intCast(tab.tnum);
        o[1].p3 = i_db;
        // The cursor thinks the table has one more column than it does:
        // OP_Column on that imaginary column reads NULL, and fills the
        // cursor's type and offset cache without any I/O.
        aux.changeP4(v, 2 + 1, .{ .int32 = @as(i32, tab.nCol()) + 1 });
        ops.?[3].p2 = tab.nCol();
        p.n_var = 0;
        p.n_mem = 1;
        p.n_tab = 1;
        aux.makeReady(v, &p);
    }
    v.parse = null;
    blob.i_col = @intCast(i_col);
    return if (db.malloc_failed) RC.NOMEM else RC.OK;
}

/// The end of a failed table lookup: the error of `p`, if any, goes to
/// `err`.
fn failParse(db: *Sqlite3, p: *Parse, err: *?[:0]u8) i32 {
    if (p.err_msg) |m| err.* = db.gpa.dupeSentinel(u8, m, 0) catch null;
    return RC.ERROR;
}

/// Port of sqlite3_blob_close(): finalize the handle's program, which
/// ends its transaction (committing it in autocommit mode).
pub fn close(p: *Incrblob) i32 {
    const s = p.stmt;
    p.db.gpa.destroy(p);
    return if (s) |v| api.finalize(v) else RC.OK;
}

const Access = enum { read, write };

/// Port of blobReadWrite().
fn readWrite(p: *Incrblob, buf: []u8, offset: i32, comptime access: Access) i32 {
    const db = p.db;
    var rc: i32 = RC.OK;
    const n: i64 = @intCast(buf.len);
    if (offset < 0 or @as(i64, offset) + n > p.n_byte) {
        // Out of range: a transient error.
        rc = RC.ERROR;
    } else if (p.stmt) |v| {
        const csr = p.csr.?;
        const at: u32 = @intCast(offset + p.i_offset);
        const r = switch (access) {
            .read => csr.payloadChecked(at, buf),
            .write => csr.putData(at, buf),
        };
        rc = if (r) |_| RC.OK else |e| int.errorCode(e);
        if (rc == RC.ABORT) {
            _ = aux.finalize(v);
            p.stmt = null;
        } else {
            v.rc = rc;
        }
    } else {
        // The handle has been invalidated.
        rc = RC.ABORT;
    }
    main_mod.setError(db, rc);
    return main_mod.apiExit(db, rc);
}

/// Port of sqlite3_blob_read(): read `buf.len` bytes from `offset`.
pub fn read(p: *Incrblob, buf: []u8, offset: i32) i32 {
    return readWrite(p, buf, offset, .read);
}

/// Port of sqlite3_blob_write(): overwrite `data.len` bytes at `offset`.
/// The size of the blob cannot change.
pub fn write(p: *Incrblob, data: []const u8, offset: i32) i32 {
    return readWrite(p, @constCast(data), offset, .write);
}

/// Port of sqlite3_blob_bytes(): the size of the blob, 0 once the handle
/// has been invalidated.
pub fn bytes(p: *const Incrblob) i32 {
    return if (p.stmt != null) p.n_byte else 0;
}

/// Port of sqlite3_blob_reopen(): move the handle to row `i_row` of the
/// same table. On error the handle is invalid from then on.
pub fn reopen(p: *Incrblob, i_row: i64) i32 {
    const db = p.db;
    var rc: i32 = undefined;
    if (p.stmt) |v| {
        v.rc = RC.OK;
        var err: ?[:0]u8 = null;
        rc = seekToRow(p, i_row, &err);
        if (rc != RC.OK) {
            if (err) |m| {
                main_mod.errorWithMsg(db, rc, "{s}", .{m});
                db.gpa.free(m);
            } else {
                main_mod.setError(db, rc);
            }
        }
        std.debug.assert(rc != RC.SCHEMA);
    } else {
        // The handle has been invalidated.
        rc = RC.ABORT;
    }
    rc = main_mod.apiExit(db, rc);
    std.debug.assert(rc == RC.OK or p.stmt == null);
    return rc;
}
