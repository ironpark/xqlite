//! The carray() table-valued function (port of carray.c, which SQLite
//! 3.54 builds in with SQLITE_ENABLE_CARRAY): the elements of a C array
//! as rows.
//!
//!     SELECT * FROM carray($ptr, 5)              -- five int32 at $ptr
//!     SELECT * FROM carray($ptr, 10, 'char*')    -- int32, int64, double,
//!                                                -- char*, struct iovec
//!     SELECT * FROM carray(?1)                   -- sqlite3_carray_bind()
//!
//! It is the eponymous virtual table
//!
//!     CREATE TABLE x(value, pointer HIDDEN, count HIDDEN, ctype HIDDEN)
//!
//! The pointer is a pointer value of type "carray" (sqlite3_bind_pointer())
//! or, for the one-argument form, of type "carray-bind": a `Bind` that
//! sqlite3_carray_bind() makes (in the C ABI, capi/carray.zig). The rowid
//! counts from 1.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const vtab = @import("../sql/vtab.zig");
const api = @import("../vdbe/api.zig");
const ctype = @import("../util/ctype.zig");

const Sqlite3 = int.Sqlite3;
const Mem = vi.Mem;
const RC = int.RC;
const IC = vtab.INDEX_CONSTRAINT;

/// The element types (CARRAY_INT32 ... CARRAY_BLOB of sqlite3.h).
pub const INT32 = 0;
pub const INT64 = 1;
pub const DOUBLE = 2;
pub const TEXT = 3;
pub const BLOB = 4;

/// Names of the element types, for the third argument (azCarrayType).
const type_names = [_][:0]const u8{ "int32", "int64", "double", "char*", "struct iovec" };

/// struct iovec, the element of a CARRAY_BLOB array.
pub const Iovec = extern struct {
    base: ?*anyopaque,
    len: usize,
};

/// What sqlite3_carray_bind() binds (struct carray_bind): the array, its
/// length, its element type, and how to free it.
pub const Bind = extern struct {
    data: ?*anyopaque,
    n_data: c_int,
    m_flags: c_int,
    x_del: ?*const fn (?*anyopaque) callconv(.c) void,
    p_del: ?*anyopaque,
};

/// The virtual table: the base and the connection, for error messages.
const CarrayVtab = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
};

/// A cursor (carray_cursor).
const CarrayCursor = struct {
    base: vtab.VtabCursor = .{},
    gpa: std.mem.Allocator,
    i_rowid: i64 = 0,
    /// The array.
    ptr: ?*anyopaque = null,
    /// Its number of elements.
    i_cnt: i64 = 0,
    /// One of the element types.
    e_type: u8 = INT32,

    fn of(cur: *vtab.VtabCursor) *CarrayCursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }
};

/// Column numbers.
const COLUMN_VALUE = 0;
const COLUMN_POINTER = 1;
const COLUMN_COUNT = 2;
const COLUMN_CTYPE = 3;

/// Port of carrayConnect().
fn carrayConnect(db: *Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const rc = vtab.declareVtab(db, "CREATE TABLE x(value,pointer hidden,count hidden,ctype hidden)");
    if (rc == RC.OK) {
        const new = db.gpa.create(CarrayVtab) catch return RC.NOMEM;
        new.* = .{ .db = db };
        pp_vtab.* = &new.base;
    }
    return rc;
}

/// Port of carrayDisconnect().
fn carrayDisconnect(p: *vtab.Vtab) i32 {
    const t: *CarrayVtab = @fieldParentPtr("base", p);
    t.db.gpa.destroy(t);
    return RC.OK;
}

/// Port of carrayOpen().
fn carrayOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t: *CarrayVtab = @fieldParentPtr("base", p);
    const cur = t.db.gpa.create(CarrayCursor) catch return RC.NOMEM;
    cur.* = .{ .gpa = t.db.gpa };
    pp_cursor.* = &cur.base;
    return RC.OK;
}

/// Port of carrayClose().
fn carrayClose(cur: *vtab.VtabCursor) i32 {
    const c = CarrayCursor.of(cur);
    c.gpa.destroy(c);
    return RC.OK;
}

/// Port of carrayNext().
fn carrayNext(cur: *vtab.VtabCursor) i32 {
    CarrayCursor.of(cur).i_rowid += 1;
    return RC.OK;
}

fn elem(comptime T: type, c: *const CarrayCursor) T {
    const p: [*]const T = @ptrCast(@alignCast(c.ptr.?));
    return p[@intCast(c.i_rowid - 1)];
}

/// Port of carrayColumn().
fn carrayColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = CarrayCursor.of(cur);
    switch (i) {
        COLUMN_POINTER => return RC.OK,
        COLUMN_COUNT => api.resultInt64(ctx, c.i_cnt),
        COLUMN_CTYPE => api.resultTextZ(ctx, type_names[c.e_type], .static),
        else => switch (c.e_type) {
            INT32 => api.resultInt(ctx, elem(i32, c)),
            INT64 => api.resultInt64(ctx, elem(i64, c)),
            DOUBLE => api.resultDouble(ctx, elem(f64, c)),
            TEXT => {
                const z = elem(?[*:0]const u8, c);
                api.resultText(ctx, if (z) |s| std.mem.span(s) else null, .transient);
            },
            else => {
                std.debug.assert(c.e_type == BLOB);
                const v = elem(Iovec, c);
                if (v.len > 0x7fffffff) {
                    api.resultErrorTooBig(ctx);
                    return RC.TOOBIG;
                }
                const b: [*]const u8 = if (v.base) |x| @ptrCast(x) else "";
                api.resultBlob(ctx, b[0..v.len], .transient);
            },
        },
    }
    return RC.OK;
}

/// Port of carrayRowid().
fn carrayRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = CarrayCursor.of(cur).i_rowid;
    return RC.OK;
}

/// Port of carrayEof().
fn carrayEof(cur: *vtab.VtabCursor) bool {
    const c = CarrayCursor.of(cur);
    return c.i_rowid > c.i_cnt;
}

/// Port of carrayFilter(). idx_num is the plan of carrayBestIndex(): 1
/// for the pointer of sqlite3_carray_bind() alone, 2 with the count, 3
/// with the type too, 0 for no rows.
fn carrayFilter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c = CarrayCursor.of(cur);
    c.ptr = null;
    c.i_cnt = 0;
    switch (idx_num) {
        1 => if (api.valuePointer(argv[0], "carray-bind")) |p| {
            const b: *const Bind = @ptrCast(@alignCast(p));
            c.ptr = b.data;
            c.i_cnt = b.n_data;
            c.e_type = @intCast(b.m_flags & 0x07);
        },
        2, 3 => {
            c.ptr = api.valuePointer(argv[0], "carray");
            c.i_cnt = if (c.ptr != null) api.valueInt64(argv[1]) else 0;
            if (idx_num < 3) {
                c.e_type = INT32;
            } else {
                const z = api.valueText(argv[2]);
                const found = for (type_names, 0..) |name, k| {
                    if (z != null and ctype.eqlNoCase(z.?, name)) break k;
                } else null;
                if (found) |k| {
                    c.e_type = @intCast(k);
                } else {
                    const t: *CarrayVtab = @fieldParentPtr("base", cur.vtab);
                    if (z) |s| {
                        // %Q: quoted, with quotes doubled.
                        const q = std.mem.replaceOwned(u8, t.db.gpa, s, "'", "''") catch return RC.NOMEM;
                        defer t.db.gpa.free(q);
                        vtab.setErrMsg(t.db, cur.vtab, "unknown datatype: '{s}'", .{q});
                    } else {
                        vtab.setErrMsg(t.db, cur.vtab, "unknown datatype: NULL", .{});
                    }
                    return RC.ERROR;
                }
            }
        },
        else => {},
    }
    c.i_rowid = 1;
    return RC.OK;
}

/// Port of carrayBestIndex().
fn carrayBestIndex(_: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    var ptr_idx: ?usize = null;
    var cnt_idx: ?usize = null;
    var ctype_idx: ?usize = null;
    // Columns with an == constraint, usable or not.
    var seen: u32 = 0;
    for (info.constraints, 0..) |cons, i| {
        if (cons.op != IC.EQ) continue;
        if (cons.i_column >= 0) seen |= @as(u32, 1) << @intCast(cons.i_column);
        if (!cons.usable) continue;
        switch (cons.i_column) {
            COLUMN_POINTER => ptr_idx = i,
            COLUMN_COUNT => cnt_idx = i,
            COLUMN_CTYPE => ctype_idx = i,
            else => {},
        }
    }
    if (ptr_idx) |pi| {
        info.usage[pi].argv_index = 1;
        info.usage[pi].omit = true;
        info.estimated_cost = 1;
        info.estimated_rows = 100;
        info.idx_num = 1;
        if (cnt_idx) |ci| {
            info.usage[ci].argv_index = 2;
            info.usage[ci].omit = true;
            info.idx_num = 2;
            if (ctype_idx) |ti| {
                info.usage[ti].argv_index = 3;
                info.usage[ti].omit = true;
                info.idx_num = 3;
            } else if (seen & (1 << COLUMN_CTYPE) != 0) {
                // A three-argument carray() needs all three arguments.
                return RC.CONSTRAINT;
            }
        } else if (seen & (1 << COLUMN_COUNT) != 0) {
            // A two-argument carray() needs both arguments.
            return RC.CONSTRAINT;
        }
    } else {
        info.estimated_cost = 2147483647;
        info.estimated_rows = 2147483647;
        info.idx_num = 0;
    }
    return RC.OK;
}

/// The carray module (carrayModule).
pub const module: vtab.Module = .{
    .i_version = 0,
    .x_create = null,
    .x_connect = carrayConnect,
    .x_best_index = carrayBestIndex,
    .x_disconnect = carrayDisconnect,
    .x_destroy = null,
    .x_open = carrayOpen,
    .x_close = carrayClose,
    .x_filter = carrayFilter,
    .x_next = carrayNext,
    .x_eof = carrayEof,
    .x_column = carrayColumn,
    .x_rowid = carrayRowid,
};

/// Port of sqlite3CarrayRegister(): install the module when a statement
/// first names carray (sqlite3LocateTable(), with Sqlite3.enable_carray).
pub fn register(db: *Sqlite3) ?*int.Module {
    return vtab.createModuleInternal(db, "carray", &module, null, null);
}
