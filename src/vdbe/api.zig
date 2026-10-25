//! The statement and value interfaces: sqlite3_step(), sqlite3_column_*(),
//! sqlite3_bind_*(), sqlite3_value_*() and sqlite3_result_*() (port of
//! vdbeapi.c).

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const aux = @import("aux.zig");
const exec_mod = @import("exec.zig");
const int = @import("../sql/sqlite_int.zig");
const main_mod = @import("../sql/main.zig");

const Vdbe = vi.Vdbe;
const Mem = vi.Mem;
const MEM = vi.MEM;
const ENC = vi.ENC;
const Context = vi.Context;
const Destructor = vi.Destructor;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;

/// Port of sqlite3Step(): run the statement to its next row.
fn stepOnce(v: *Vdbe) i32 {
    const db = v.db;
    var rc: i32 = undefined;
    if (v.e_vdbe_state != .run) {
        if (v.e_vdbe_state == .halt) {
            // Reset automatically, as without SQLITE_OMIT_AUTORESET.
            _ = reset(v);
        }
        std.debug.assert(v.e_vdbe_state == .ready);
        if (v.expired != 0) {
            v.rc = RC.SCHEMA;
            return RC.ERROR & db.err_mask;
        }
        if (db.n_vdbe_active == 0) db.is_interrupted.store(false, .monotonic);
        db.n_vdbe_active += 1;
        if (!v.read_only) db.n_vdbe_write += 1;
        if (v.is_reader) db.n_vdbe_read += 1;
        v.pc = 0;
        v.e_vdbe_state = .run;
    }
    if (v.explain != 0) {
        rc = aux.list(v);
    } else {
        db.n_vdbe_exec += 1;
        rc = exec_mod.exec(v);
        db.n_vdbe_exec -= 1;
    }
    if (rc == RC.ROW) {
        db.err_code = RC.ROW;
        return RC.ROW;
    }
    v.result_row = null;
    db.err_code = rc;
    if (db.malloc_failed) {
        v.rc = RC.NOMEM;
        db.malloc_failed = false;
    }
    return rc & db.err_mask;
}

/// Port of sqlite3_step(). Returns RC.ROW, RC.DONE or an error code.
pub fn step(v: *Vdbe) i32 {
    // Reprepare on RC.SCHEMA comes with sqlite3_prepare_v2().
    return stepOnce(v);
}

/// Port of sqlite3_reset().
pub fn reset(v: *Vdbe) i32 {
    const rc = aux.reset(v);
    aux.rewind(v);
    return rc;
}

/// Port of sqlite3_finalize().
pub fn finalize(v: *Vdbe) i32 {
    return aux.finalize(v);
}

/// Port of sqlite3_clear_bindings().
pub fn clearBindings(v: *Vdbe) void {
    for (v.vars) |*m| {
        mem.release(m);
        m.flags = MEM.Null;
    }
}

/// Port of sqlite3_changes64().
pub fn changes(db: *const Sqlite3) i64 {
    return db.n_change;
}

/// Port of sqlite3_total_changes64().
pub fn totalChanges(db: *const Sqlite3) i64 {
    return db.n_total_change;
}

// ================================================================ columns

/// Port of sqlite3_column_count().
pub fn columnCount(v: *const Vdbe) usize {
    return v.n_res_column;
}

/// Port of sqlite3_data_count(): columns in the current row.
pub fn dataCount(v: *const Vdbe) usize {
    if (v.result_row == null) return 0;
    return v.n_res_column;
}

/// Port of columnMem(): the value of column `i` (a NULL outside a row).
fn columnMem(v: *Vdbe, i: usize) *Mem {
    const null_mem = struct {
        var m: Mem = .{ .flags = MEM.Null };
    };
    if (v.result_row) |row| {
        if (i < v.n_res_column) return &row[i];
    }
    null_mem.m = .{ .flags = MEM.Null };
    return &null_mem.m;
}

/// Port of columnMallocFailure().
fn columnMallocFailure(v: *Vdbe) void {
    if (v.db.malloc_failed) v.rc = RC.NOMEM;
}

pub fn columnType(v: *Vdbe, i: usize) i32 {
    return mem.valueType(columnMem(v, i));
}

pub fn columnInt64(v: *Vdbe, i: usize) i64 {
    return valueInt64(columnMem(v, i));
}

pub fn columnDouble(v: *Vdbe, i: usize) f64 {
    return valueDouble(columnMem(v, i));
}

/// Port of sqlite3_column_text(): null for NULL.
pub fn columnText(v: *Vdbe, i: usize) ?[:0]const u8 {
    const r = valueText(columnMem(v, i));
    columnMallocFailure(v);
    return r;
}

/// Port of sqlite3_column_blob(): null for NULL or an empty blob.
pub fn columnBlob(v: *Vdbe, i: usize) ?[]const u8 {
    const r = valueBlob(columnMem(v, i));
    columnMallocFailure(v);
    return r;
}

pub fn columnBytes(v: *Vdbe, i: usize) usize {
    return valueBytes(columnMem(v, i));
}

pub fn columnValue(v: *Vdbe, i: usize) *Mem {
    return columnMem(v, i);
}

/// Port of sqlite3_column_name() and friends: name `var_` (COLNAME_*) of
/// column `i`.
pub fn columnNameOf(v: *Vdbe, i: usize, var_: usize) ?[:0]const u8 {
    if (i >= v.n_res_column) return null;
    if (v.explain != 0) {
        if (var_ != vi.COLNAME_NAME) return null;
        const names = [_][:0]const u8{
            "addr", "opcode", "p1", "p2", "p3", "p4", "p5", "comment",
            "id",   "parent", "notused", "detail",
        };
        const k = if (v.explain == 2) i + 8 else i;
        return names[k];
    }
    if (v.col_names.len == 0) return null;
    return valueText(&v.col_names[i + var_ * v.n_res_alloc]);
}

pub fn columnName(v: *Vdbe, i: usize) ?[:0]const u8 {
    return columnNameOf(v, i, vi.COLNAME_NAME);
}

pub fn columnDecltype(v: *Vdbe, i: usize) ?[:0]const u8 {
    return columnNameOf(v, i, vi.COLNAME_DECLTYPE);
}

// ================================================================= values

/// Port of sqlite3_value_int64().
pub fn valueInt64(m: *Mem) i64 {
    return mem.intValue(m);
}

pub fn valueInt(m: *Mem) i32 {
    return @truncate(mem.intValue(m));
}

pub fn valueDouble(m: *Mem) f64 {
    return mem.realValue(m);
}

/// Port of sqlite3_value_text(): the value as UTF-8 text; null for NULL.
pub fn valueText(m: *Mem) ?[:0]const u8 {
    const z = (mem.valueText(m, ENC.UTF8) catch {
        if (m.db) |db| db.malloc_failed = true;
        return null;
    }) orelse return null;
    return z[0..@intCast(m.n) :0];
}

/// Port of sqlite3_value_blob().
pub fn valueBlob(m: *Mem) ?[]const u8 {
    if (m.flags & (MEM.Blob | MEM.Str) != 0) {
        if (m.flags & MEM.Zero != 0) mem.expandBlob(m) catch return null;
        m.flags |= MEM.Blob;
        if (m.n == 0) return null;
        return m.bytes();
    }
    return valueText(m);
}

/// Port of sqlite3_value_bytes().
pub fn valueBytes(m: *Mem) usize {
    return @intCast(mem.valueBytes(m, ENC.UTF8) catch 0);
}

/// Port of sqlite3_value_type(): one of vi.SQLITE_INTEGER etc.
pub fn valueType(m: *const Mem) i32 {
    return mem.valueType(m);
}

/// Port of sqlite3_value_numeric_type().
pub fn valueNumericType(m: *Mem) i32 {
    return mem.valueNumericType(m);
}

/// Port of sqlite3_value_subtype().
pub fn valueSubtype(m: *const Mem) u32 {
    return if (m.flags & MEM.Subtype != 0) m.e_subtype else 0;
}

/// Port of sqlite3_value_nochange().
pub fn valueNochange(m: *const Mem) bool {
    return m.isNullNochng();
}

/// Port of sqlite3_value_frombind().
pub fn valueFrombind(m: *const Mem) bool {
    return m.flags & MEM.FromBind != 0;
}

// =============================================================== bindings

/// Port of vdbeUnbind(): prepare parameter `i` (1-based) for a new value.
fn unbind(v: *Vdbe, i: usize) i32 {
    if (v.e_vdbe_state != .ready) {
        main_mod.errorWithMsg(v.db, RC.MISUSE, "bad parameter or other API misuse", .{});
        return RC.MISUSE;
    }
    if (i < 1 or i > v.n_var) {
        main_mod.setError(v.db, RC.RANGE);
        return RC.RANGE;
    }
    const m = &v.vars[i - 1];
    mem.release(m);
    m.flags = MEM.Null;
    v.db.err_code = RC.OK;
    // Statements whose plan depends on bound values (expmask) would be
    // reprepared here; that comes with sqlite3_prepare_v2().
    return RC.OK;
}

pub fn bindNull(v: *Vdbe, i: usize) i32 {
    return unbind(v, i);
}

pub fn bindInt64(v: *Vdbe, i: usize, value: i64) i32 {
    const rc = unbind(v, i);
    if (rc == RC.OK) mem.setInt64(&v.vars[i - 1], value);
    return rc;
}

pub fn bindDouble(v: *Vdbe, i: usize, value: f64) i32 {
    const rc = unbind(v, i);
    if (rc == RC.OK) mem.setDouble(&v.vars[i - 1], value);
    return rc;
}

/// Port of sqlite3_bind_text(). The text is copied.
pub fn bindText(v: *Vdbe, i: usize, text: []const u8) i32 {
    return bindStr(v, i, text, ENC.UTF8);
}

/// Port of sqlite3_bind_blob(). The blob is copied.
pub fn bindBlob(v: *Vdbe, i: usize, blob: []const u8) i32 {
    return bindStr(v, i, blob, 0);
}

fn bindStr(v: *Vdbe, i: usize, z: []const u8, enc: u8) i32 {
    const rc = unbind(v, i);
    if (rc != RC.OK) return rc;
    mem.setStr(&v.vars[i - 1], z, enc, .transient) catch |err| {
        const code = main_mod.errorCode(err);
        main_mod.setError(v.db, code);
        return code;
    };
    return RC.OK;
}

pub fn bindZeroblob(v: *Vdbe, i: usize, n: i32) i32 {
    const rc = unbind(v, i);
    if (rc == RC.OK) mem.setZeroBlob(&v.vars[i - 1], n);
    return rc;
}

/// Port of sqlite3_bind_value(): bind a copy of `value`.
pub fn bindValue(v: *Vdbe, i: usize, value: *Mem) i32 {
    return switch (mem.valueType(value)) {
        vi.SQLITE_INTEGER => bindInt64(v, i, value.u.i),
        vi.SQLITE_FLOAT => bindDouble(v, i, if (value.flags & MEM.Real != 0) value.u.r else @floatFromInt(value.u.i)),
        vi.SQLITE_BLOB => if (value.flags & MEM.Zero != 0)
            bindZeroblob(v, i, value.u.n_zero)
        else
            bindBlob(v, i, value.bytes()),
        vi.SQLITE_TEXT => bindText(v, i, value.bytes()),
        else => bindNull(v, i),
    };
}

/// Port of sqlite3_bind_parameter_count().
pub fn bindParameterCount(v: *const Vdbe) usize {
    return @intCast(v.n_var);
}

/// Port of sqlite3_bind_parameter_name(): null for nameless parameters.
pub fn bindParameterName(v: *const Vdbe, i: usize) ?[]const u8 {
    for (v.vlist) |entry| {
        if (entry.num == i) return entry.name;
    }
    return null;
}

/// Port of sqlite3_bind_parameter_index(): 0 if there is no such name.
pub fn bindParameterIndex(v: *const Vdbe, name: []const u8) usize {
    for (v.vlist) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return @intCast(entry.num);
    }
    return 0;
}

// ================================================================ results

/// Port of sqlite3_result_null().
pub fn resultNull(ctx: *Context) void {
    mem.setNull(ctx.out);
}

pub fn resultInt64(ctx: *Context, value: i64) void {
    mem.setInt64(ctx.out, value);
}

pub fn resultInt(ctx: *Context, value: i32) void {
    mem.setInt64(ctx.out, value);
}

pub fn resultDouble(ctx: *Context, value: f64) void {
    mem.setDouble(ctx.out, value);
}

/// Port of setResultStrOrError().
fn setResultStr(ctx: *Context, z: ?[]const u8, enc: u8, del: Destructor) void {
    mem.setStr(ctx.out, z, enc, del) catch |err| switch (err) {
        error.TooBig => resultErrorTooBig(ctx),
        error.OutOfMemory => resultErrorNomem(ctx),
    };
}

/// Port of sqlite3_result_text().
pub fn resultText(ctx: *Context, z: ?[]const u8, del: Destructor) void {
    setResultStr(ctx, z, ENC.UTF8, del);
}

/// Port of sqlite3_result_blob().
pub fn resultBlob(ctx: *Context, z: []const u8, del: Destructor) void {
    setResultStr(ctx, z, 0, del);
}

/// Port of sqlite3_result_zeroblob64().
pub fn resultZeroblob(ctx: *Context, n: u64) void {
    const db = ctx.out.db.?;
    if (n > @as(u64, @intCast(db.limit(.length)))) return resultErrorTooBig(ctx);
    mem.setZeroBlob(ctx.out, @intCast(n));
}

/// Port of sqlite3_result_value(): a copy of `value`.
pub fn resultValue(ctx: *Context, value: *const Mem) void {
    mem.copy(ctx.out, value) catch resultErrorNomem(ctx);
}

/// Port of sqlite3_result_subtype().
pub fn resultSubtype(ctx: *Context, subtype: u32) void {
    ctx.out.e_subtype = @truncate(subtype);
    ctx.out.flags |= MEM.Subtype;
}

/// Port of sqlite3_result_error(): fail the function with `msg`.
pub fn resultError(ctx: *Context, msg: []const u8) void {
    ctx.is_error = RC.ERROR;
    mem.setStr(ctx.out, msg, ENC.UTF8, .transient) catch {};
}

/// Port of sqlite3_result_error_code().
pub fn resultErrorCode(ctx: *Context, code: i32) void {
    ctx.is_error = if (code != 0) code else -1;
    if (ctx.out.flags & MEM.Null != 0) {
        mem.setStr(ctx.out, @import("../sql/util.zig").errStr(code), ENC.UTF8, .static) catch {};
    }
}

/// Port of sqlite3_result_error_toobig().
pub fn resultErrorTooBig(ctx: *Context) void {
    ctx.is_error = RC.TOOBIG;
    mem.setStr(ctx.out, "string or blob too big", ENC.UTF8, .static) catch {};
}

/// Port of sqlite3_result_error_nomem().
pub fn resultErrorNomem(ctx: *Context) void {
    mem.setNull(ctx.out);
    ctx.is_error = RC.NOMEM;
    if (ctx.out.db) |db| db.malloc_failed = true;
}

/// Port of sqlite3_user_data().
pub fn userData(ctx: *const Context) ?*anyopaque {
    return ctx.func.user_data;
}

/// Port of sqlite3_context_db_handle().
pub fn contextDbHandle(ctx: *const Context) *Sqlite3 {
    return ctx.out.db.?;
}

/// Port of sqlite3_aggregate_context(): `n` zeroed bytes kept for the
/// aggregate across calls; null if `n` is 0 and none was made yet.
pub fn aggregateContext(ctx: *Context, n: usize) ?[]u8 {
    const m = ctx.mem.?;
    if (m.flags & MEM.Agg == 0) {
        // createAggContext()
        if (n == 0) {
            mem.setNull(m);
            m.z = null;
            return null;
        }
        mem.clearAndResize(m, n) catch {
            resultErrorNomem(ctx);
            return null;
        };
        m.flags = MEM.Agg;
        m.u = .{ .def = ctx.func };
        @memset(m.z.?[0..n], 0);
        m.n = @intCast(n);
    }
    return m.z.?[0..@intCast(m.n)];
}

// ================================================================== tests

const OP = vi.OP;

/// A connection with no databases, for programs that use none.
fn testDb() Sqlite3 {
    return .{ .gpa = std.testing.allocator };
}

test "api: run a hand-assembled program" {
    var db = testDb();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var p: int.Parse = .{ .db = &db, .arena = arena.allocator() };
    const v = try aux.create(&p);
    // r1 = 6; r2 = 7; r3 = r1 * r2; r4 = 'x' || 'y'; result r3, r4; loop 3x
    _ = aux.addOp2(v, OP.Integer, 6, 1);
    _ = aux.addOp2(v, OP.Integer, 7, 2);
    _ = aux.addOp3(v, OP.Multiply, 1, 2, 3);
    _ = aux.addOp4(v, OP.String8, 0, 5, 0, .{ .z = "x" });
    _ = aux.addOp4(v, OP.String8, 0, 6, 0, .{ .z = "y" });
    _ = aux.addOp3(v, OP.Concat, 6, 5, 4);
    _ = aux.addOp2(v, OP.Integer, 3, 7);
    const loop = aux.addOp2(v, OP.ResultRow, 3, 2);
    _ = aux.addOp3(v, OP.DecrJumpZero, 7, 0, 0);
    _ = aux.addOp2(v, OP.Goto, 0, loop);
    aux.jumpHere(v, loop + 1);
    _ = aux.addOp0(v, OP.Halt);
    aux.jumpHere(v, 0);
    _ = aux.addOp2(v, OP.Goto, 0, 1);
    p.n_mem = 7;
    aux.setNumCols(v, 2);
    aux.makeReady(v, &p);

    var rows: u32 = 0;
    while (true) {
        const rc = step(v);
        if (rc != RC.ROW) {
            try std.testing.expectEqual(RC.DONE, rc);
            break;
        }
        rows += 1;
        try std.testing.expectEqual(@as(i64, 42), columnInt64(v, 0));
        try std.testing.expectEqualStrings("xy", columnText(v, 1).?);
        try std.testing.expectEqual(vi.SQLITE_TEXT, columnType(v, 1));
    }
    try std.testing.expectEqual(@as(u32, 3), rows);
    try std.testing.expectEqual(RC.OK, finalize(v));
}

test "api: sorter and ephemeral table" {
    const vfs_mod = @import("../vfs/mem.zig");
    var mv = vfs_mod.MemVfs.init(std.testing.allocator, std.testing.io);
    defer mv.deinit();
    var db = testDb();
    db.vfs = mv.interface();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var p: int.Parse = .{ .db = &db, .arena = arena.allocator() };
    const v = try aux.create(&p);
    const a = v.alloc();
    var sort_flags = [_]u8{ int.KeyInfoOrder.desc, 0 };
    var coll = [_]?*int.CollSeq{ null, null };
    const ki = try a.create(vi.KeyInfo);
    ki.* = .{ .n_key_field = 1, .n_all_field = 2, .db = &db, .sort_flags = &sort_flags, .coll = &coll };

    // Sort (k, v) records by k descending; ties keep insertion order, as
    // in SQLite.
    _ = aux.addOp4(v, OP.SorterOpen, 0, 2, 0, .{ .keyinfo = ki });
    const vals = [_][2]i32{ .{ 2, 10 }, .{ 5, 20 }, .{ 2, 30 }, .{ 9, 40 } };
    for (vals) |kv| {
        _ = aux.addOp2(v, OP.Integer, kv[0], 1);
        _ = aux.addOp2(v, OP.Integer, kv[1], 2);
        _ = aux.addOp3(v, OP.MakeRecord, 1, 2, 3);
        _ = aux.addOp2(v, OP.SorterInsert, 0, 3);
    }
    _ = aux.addOp3(v, OP.OpenPseudo, 1, 4, 2);
    const sort = aux.addOp2(v, OP.SorterSort, 0, 0);
    const body = aux.addOp3(v, OP.SorterData, 0, 4, 1);
    _ = aux.addOp3(v, OP.Column, 1, 0, 5);
    _ = aux.addOp3(v, OP.Column, 1, 1, 6);
    _ = aux.addOp2(v, OP.ResultRow, 5, 2);
    _ = aux.addOp2(v, OP.SorterNext, 0, body);
    aux.jumpHere(v, sort);
    // An ephemeral table: insert rowids 1..3, then count them.
    _ = aux.addOp2(v, OP.OpenEphemeral, 2, 1);
    for (0..3) |_| {
        _ = aux.addOp2(v, OP.NewRowid, 2, 7);
        _ = aux.addOp2(v, OP.Integer, 1, 8);
        _ = aux.addOp3(v, OP.MakeRecord, 8, 1, 9);
        _ = aux.addOp3(v, OP.Insert, 2, 9, 7);
    }
    _ = aux.addOp2(v, OP.Count, 2, 10);
    _ = aux.addOp2(v, OP.Null, 0, 11);
    _ = aux.addOp2(v, OP.ResultRow, 10, 2);
    _ = aux.addOp0(v, OP.Halt);
    aux.jumpHere(v, 0);
    _ = aux.addOp2(v, OP.Goto, 0, 1);
    p.n_mem = 11;
    p.n_tab = 3;
    aux.setNumCols(v, 2);
    aux.makeReady(v, &p);

    const want = [_][2]i64{ .{ 9, 40 }, .{ 5, 20 }, .{ 2, 10 }, .{ 2, 30 } };
    for (want) |w| {
        try std.testing.expectEqual(RC.ROW, step(v));
        try std.testing.expectEqual(w[0], columnInt64(v, 0));
        try std.testing.expectEqual(w[1], columnInt64(v, 1));
    }
    try std.testing.expectEqual(RC.ROW, step(v));
    try std.testing.expectEqual(@as(i64, 3), columnInt64(v, 0));
    try std.testing.expectEqual(RC.DONE, step(v));
    try std.testing.expectEqual(RC.OK, finalize(v));
}

test "api: sorter order and ties for each key type" {
    const vfs_mod = @import("../vfs/mem.zig");
    var mv = vfs_mod.MemVfs.init(std.testing.allocator, std.testing.io);
    defer mv.deinit();
    inline for (.{ int.Aff.integer, int.Aff.text, int.Aff.real, int.Aff.blob }) |aff| {
        var db = testDb();
        db.vfs = mv.interface();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var p: int.Parse = .{ .db = &db, .arena = arena.allocator() };
        const v = try aux.create(&p);
        const a = v.alloc();
        var sort_flags = [_]u8{ 0, 0 };
        var coll = [_]?*int.CollSeq{ null, null };
        const ki = try a.create(vi.KeyInfo);
        ki.* = .{ .n_key_field = 1, .n_all_field = 2, .db = &db, .sort_flags = &sort_flags, .coll = &coll };

        // for i in 1..500: insert (i*7919 % 97 [cast], i)
        const n = 500;
        _ = aux.addOp4(v, OP.SorterOpen, 0, 2, 0, .{ .keyinfo = ki });
        _ = aux.addOp2(v, OP.Integer, n, 1);
        _ = aux.addOp2(v, OP.Integer, 7919, 5);
        _ = aux.addOp2(v, OP.Integer, 97, 6);
        const top = aux.addOp3(v, OP.Multiply, 5, 1, 2);
        _ = aux.addOp3(v, OP.Remainder, 6, 2, 2);
        // The blob case mixes types: odd keys become text.
        if (aff == int.Aff.blob) {
            _ = aux.addOp2(v, OP.Integer, 2, 7);
            _ = aux.addOp3(v, OP.Remainder, 7, 2, 8);
            const skip = aux.addOp1(v, OP.IfNot, 8);
            _ = aux.addOp2(v, OP.Cast, 2, int.Aff.text);
            aux.jumpHere(v, skip);
        } else {
            _ = aux.addOp2(v, OP.Cast, 2, aff);
        }
        _ = aux.addOp2(v, OP.SCopy, 1, 3);
        _ = aux.addOp3(v, OP.MakeRecord, 2, 2, 4);
        _ = aux.addOp2(v, OP.SorterInsert, 0, 4);
        _ = aux.addOp3(v, OP.AddImm, 1, -1, 0);
        _ = aux.addOp2(v, OP.If, 1, top);
        _ = aux.addOp3(v, OP.OpenPseudo, 1, 9, 2);
        const sort = aux.addOp2(v, OP.SorterSort, 0, 0);
        const body = aux.addOp3(v, OP.SorterData, 0, 9, 1);
        _ = aux.addOp3(v, OP.Column, 1, 0, 10);
        _ = aux.addOp3(v, OP.Column, 1, 1, 11);
        _ = aux.addOp2(v, OP.ResultRow, 10, 2);
        _ = aux.addOp2(v, OP.SorterNext, 0, body);
        aux.jumpHere(v, sort);
        _ = aux.addOp0(v, OP.Halt);
        aux.jumpHere(v, 0);
        _ = aux.addOp2(v, OP.Goto, 0, 1);
        p.n_mem = 11;
        p.n_tab = 2;
        aux.setNumCols(v, 2);
        aux.makeReady(v, &p);

        var rows: usize = 0;
        var prev_key: Mem = .{ .db = &db };
        defer mem.release(&prev_key);
        var prev_seq: i64 = 0;
        while (step(v) == RC.ROW) : (rows += 1) {
            const key = columnValue(v, 0);
            const seq = columnInt64(v, 1);
            if (rows > 0) {
                const c = @import("serial.zig").memCompare(&prev_key, key, null);
                try std.testing.expect(c <= 0);
                // Inserted with decreasing i: ties come out in that order.
                if (c == 0) try std.testing.expect(seq < prev_seq);
            }
            try mem.copy(&prev_key, key);
            prev_seq = seq;
        }
        try std.testing.expectEqual(@as(usize, n), rows);
        try std.testing.expectEqual(RC.OK, finalize(v));
    }
}

test "api: an OpenDup cursor outlives the original" {
    const vfs_mod = @import("../vfs/mem.zig");
    var mv = vfs_mod.MemVfs.init(std.testing.allocator, std.testing.io);
    defer mv.deinit();
    var db = testDb();
    db.vfs = mv.interface();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var p: int.Parse = .{ .db = &db, .arena = arena.allocator() };
    const v = try aux.create(&p);
    _ = aux.addOp2(v, OP.OpenEphemeral, 0, 1);
    _ = aux.addOp2(v, OP.Integer, 5, 1);
    _ = aux.addOp3(v, OP.MakeRecord, 1, 1, 2);
    _ = aux.addOp3(v, OP.Insert, 0, 2, 1);
    _ = aux.addOp2(v, OP.OpenDup, 1, 0);
    _ = aux.addOp1(v, OP.Close, 0);
    _ = aux.addOp2(v, OP.Count, 1, 3);
    _ = aux.addOp2(v, OP.ResultRow, 3, 1);
    _ = aux.addOp0(v, OP.Halt);
    aux.jumpHere(v, 0);
    _ = aux.addOp2(v, OP.Goto, 0, 1);
    p.n_mem = 3;
    p.n_tab = 2;
    aux.setNumCols(v, 1);
    aux.makeReady(v, &p);
    try std.testing.expectEqual(RC.ROW, step(v));
    try std.testing.expectEqual(@as(i64, 1), columnInt64(v, 0));
    try std.testing.expectEqual(RC.DONE, step(v));
    try std.testing.expectEqual(RC.OK, finalize(v));
}
