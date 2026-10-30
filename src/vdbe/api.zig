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
const printf = @import("../sql/printf.zig");
const malloc = @import("../sql/malloc.zig");
const thunk = @import("../util/thunk.zig");

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
            // A statement with saved SQL returns SQLITE_SCHEMA, so that
            // step() compiles it again.
            const r = if (v.prep_flags & aux.PREPARE_SAVESQL != 0) aux.transferError(v) else RC.ERROR;
            return r & db.err_mask;
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
    if (rc == RC.DONE and db.auto_commit) {
        std.debug.assert(v.rc == RC.OK);
        v.rc = doWalCallbacks(db);
        if (v.rc != RC.OK) rc = RC.ERROR;
    } else if (rc != RC.DONE and v.prep_flags & aux.PREPARE_SAVESQL != 0) {
        // A statement with saved SQL returns the error of the program
        // (an extended code, SQLITE_SCHEMA for a reprepare), also set on
        // the connection.
        rc = aux.transferError(v);
    }
    db.err_code = rc;
    if (db.malloc_failed) {
        v.rc = RC.NOMEM;
        malloc.oomClear(db);
    }
    return rc & db.err_mask;
}

/// Port of doWalCallbacks(): after a commit, call the WAL hook for every
/// database whose WAL grew.
fn doWalCallbacks(db: *Sqlite3) i32 {
    var rc: i32 = RC.OK;
    for (db.dbs.items) |d| {
        const bt = d.bt orelse continue;
        const n_entry = bt.pager.walCallback();
        if (n_entry > 0 and rc == RC.OK) {
            if (db.wal_callback) |cb| rc = cb(db.wal_arg, db, d.name, @intCast(n_entry));
        }
    }
    return rc;
}

/// SQLITE_MAX_SCHEMA_RETRY.
const max_schema_retry = 50;

/// Port of sqlite3_step(). Returns RC.ROW, RC.DONE or an error code. A
/// statement that finds the schema changed is compiled again and rerun.
pub fn step(v: *Vdbe) i32 {
    const db = v.db;
    var cnt: u32 = 0;
    var rc = stepOnce(v);
    while (rc == RC.SCHEMA and cnt < max_schema_retry) : (rc = stepOnce(v)) {
        cnt += 1;
        const saved_pc = v.pc;
        rc = @import("../sql/prepare.zig").reprepare(v);
        if (rc != RC.OK) {
            // The error of compiling the statement again, which is in
            // the connection, becomes that of the statement.
            if (!db.malloc_failed) {
                aux.setErrMsg(v, db.gpa.dupeSentinel(u8, main_mod.errmsg(db), 0) catch null);
                rc = main_mod.apiExit(db, rc);
                v.rc = rc;
            } else {
                aux.setErrMsg(v, null);
                rc = RC.NOMEM;
                v.rc = rc;
            }
            break;
        }
        _ = reset(v);
        // OP_Init must not trace the statement again (tag-20220401a).
        if (saved_pc >= 0) v.min_write_file_format = 254;
    }
    return rc;
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
        m.flags = .{ .Null = true };
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
    if (v.result_row) |row| {
        if (i < v.n_res_column) return &row[i];
    }
    v.null_mem = .{ .flags = .{ .Null = true } };
    return &v.null_mem;
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

/// Port of sqlite3_stmt_isexplain(): 1 for EXPLAIN, 2 for EXPLAIN QUERY
/// PLAN, else 0.
pub fn stmtIsExplain(v: *Vdbe) u8 {
    return @intCast(v.explain);
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
        const k = if (v.explain == 2) i + 8 else i;
        return explain_names[k];
    }
    return valueText(colNameMem(v, i, var_) orelse return null);
}

const explain_names = [_][:0]const u8{
    "addr", "opcode", "p1",      "p2",     "p3", "p4", "p5", "comment",
    "id",   "parent", "notused", "detail",
};

/// explain_names in native UTF-16.
const explain_names16 = blk: {
    var out: [explain_names.len][:0]const u16 = undefined;
    for (explain_names, 0..) |name, j| {
        var a: [name.len:0]u16 = undefined;
        for (name, 0..) |ch, x| a[x] = ch;
        const final = a;
        out[j] = &final;
    }
    break :blk out;
};

/// The slot of name `var_` (COLNAME_*) of column `i`: the COLNAME_NAME and
/// COLNAME_DECLTYPE slots of every statement, the origin slots of a
/// statement compiled with column metadata (Vdbe.col_meta).
fn colNameMem(v: *Vdbe, i: usize, var_: usize) ?*Mem {
    if (var_ < vi.COLNAME_N) {
        if (v.col_names.len == 0) return null;
        return &v.col_names[i + var_ * v.n_res_alloc];
    }
    if (v.col_meta.len == 0) return null;
    return &v.col_meta[i + (var_ - vi.COLNAME_N) * v.n_res_alloc];
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
        if (m.db) |db| db.oomFault();
        return null;
    }) orelse return null;
    return z[0..@intCast(m.n) :0];
}

/// Port of sqlite3_value_text16(), sqlite3_value_text16le() and
/// sqlite3_value_text16be(): the value as NUL-terminated UTF-16 text in
/// `enc` (ENC.UTF16LE or UTF16BE), null for NULL. As in SQLite the value
/// is converted in place, so the text lives until the value is converted
/// again or changes (mem.toUtf8()).
pub fn valueText16(m: *Mem, enc: u8) ?[*]const u8 {
    const z = mem.valueText(m, enc) catch {
        if (m.db) |db| db.oomFault();
        return null;
    };
    return if (z) |p| @ptrCast(p) else null;
}

/// Port of sqlite3_value_bytes16(): the size of the value in UTF-16
/// (native byte order), converting it as valueText16() does.
pub fn valueBytes16(m: *Mem) usize {
    return @intCast(mem.valueBytes(m, @import("utf.zig").UTF16NATIVE) catch 0);
}

/// Port of sqlite3_column_text16().
pub fn columnText16(v: *Vdbe, i: usize) ?[*]const u8 {
    const r = valueText16(columnMem(v, i), @import("utf.zig").UTF16NATIVE);
    columnMallocFailure(v);
    return r;
}

/// Port of sqlite3_column_bytes16().
pub fn columnBytes16(v: *Vdbe, i: usize) usize {
    const r = valueBytes16(columnMem(v, i));
    columnMallocFailure(v);
    return r;
}

/// Port of columnName() with useType UTF-16: name `var_` of column `i`
/// as UTF-16, converted in place like valueText16().
pub fn columnName16(v: *Vdbe, i: usize, var_: usize) ?[*]const u8 {
    if (i >= v.n_res_column) return null;
    if (v.explain != 0) {
        // The fixed EXPLAIN names (azExplainColNames16data).
        if (var_ != vi.COLNAME_NAME) return null;
        const k = if (v.explain == 2) i + 8 else i;
        return @ptrCast(explain_names16[k].ptr);
    }
    const m = colNameMem(v, i, var_) orelse return null;
    return valueText16(m, @import("utf.zig").UTF16NATIVE);
}

/// Port of sqlite3_value_blob().
pub fn valueBlob(m: *Mem) ?[]const u8 {
    if (m.flags.intersects(.{ .Blob = true, .Str = true })) {
        if (m.flags.Zero) mem.expandBlob(m) catch return null;
        m.flags.Blob = true;
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

/// Port of sqlite3_value_pointer(): the pointer of a pointer value of
/// type `ptype` (sqlite3_result_pointer()), or null.
pub fn valuePointer(m: *const Mem, ptype: [:0]const u8) ?*anyopaque {
    if (m.flags.only(MEM.TypeMask.with(.{ .Term = true, .Subtype = true })) == MEM{ .Null = true, .Term = true, .Subtype = true } and
        m.e_subtype == 'p' and std.mem.eql(u8, std.mem.span(m.u.z_ptype), ptype))
    {
        return @ptrCast(m.z);
    }
    return null;
}

/// Port of sqlite3_value_subtype().
pub fn valueSubtype(m: *const Mem) u32 {
    return if (m.flags.Subtype) m.e_subtype else 0;
}

/// Port of sqlite3_value_nochange().
pub fn valueNochange(m: *const Mem) bool {
    return m.isNullNochng();
}

/// Port of sqlite3_value_frombind().
pub fn valueFrombind(m: *const Mem) bool {
    return m.flags.FromBind;
}

/// Port of sqlite3_value_dup(): a copy not tied to any connection, in
/// memory from sqlite3_malloc(), or null on OOM. Free it with
/// valueFree().
pub fn valueDup(orig: ?*const Mem) ?*Mem {
    const o = orig orelse return null;
    const new = malloc.allocator.create(Mem) catch return null;
    new.* = .{ .u = o.u, .z = o.z, .n = o.n, .flags = o.flags, .enc = o.enc, .e_subtype = o.e_subtype };
    new.flags.Dyn = false;
    if (new.flags.intersects(.{ .Str = true, .Blob = true })) {
        new.flags.clear(.{ .Static = true, .Dyn = true });
        new.flags.Ephem = true;
        mem.makeWriteable(new) catch {
            valueFree(new);
            return null;
        };
    } else if (new.flags.Null) {
        // Pointer values are not duplicated.
        new.flags.clear(.{ .Term = true, .Subtype = true });
    }
    return new;
}

/// Port of sqlite3_value_free().
pub fn valueFree(m: ?*Mem) void {
    const v = m orelse return;
    mem.release(v);
    malloc.allocator.destroy(v);
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
    m.flags = .{ .Null = true };
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
        const code = int.errorCode(err);
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
        vi.SQLITE_FLOAT => bindDouble(v, i, if (value.flags.Real) value.u.r else @floatFromInt(value.u.i)),
        vi.SQLITE_BLOB => if (value.flags.Zero)
            bindZeroblob(v, i, value.u.n_zero)
        else
            bindBlob(v, i, value.bytes()),
        vi.SQLITE_TEXT => bindTextEnc(v, i, value.bytes(), value.enc),
        else => bindNull(v, i),
    };
}

/// bindText() of text in encoding `enc`, converted to UTF-8 (C's
/// bindText() with an encoding: sqlite3VdbeChangeEncoding()).
fn bindTextEnc(v: *Vdbe, i: usize, text: []const u8, enc: u8) i32 {
    if (enc == ENC.UTF8 or enc == 0) return bindText(v, i, text);
    const rc = bindStr(v, i, text, enc);
    if (rc != RC.OK) return rc;
    mem.changeEncoding(&v.vars[i - 1], ENC.UTF8) catch {
        main_mod.setError(v.db, RC.NOMEM);
        return RC.NOMEM;
    };
    return RC.OK;
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
    _ = resultZeroblob64(ctx, n);
}

/// Port of sqlite3_result_zeroblob64(), with its result code: RC.TOOBIG
/// (and the error set) past SQLITE_LIMIT_LENGTH.
pub fn resultZeroblob64(ctx: *Context, n: u64) i32 {
    const db = ctx.out.db.?;
    if (n > @as(u64, @intCast(db.limit(.length)))) {
        resultErrorTooBig(ctx);
        return RC.TOOBIG;
    }
    mem.setZeroBlob(ctx.out, @intCast(n));
    return RC.OK;
}

/// Port of invokeValueDestructor(): a value that will not be used is
/// freed, and the result is a TOOBIG error.
fn invokeValueDestructor(ctx: *Context, z: []const u8, del: Destructor) void {
    switch (del) {
        .dynamic => if (ctx.out.db) |db| db.gpa.free(@constCast(z)),
        .func => |f| f(@ptrCast(@constCast(z.ptr))),
        else => {},
    }
    resultErrorTooBig(ctx);
}

/// Port of sqlite3_result_text64() for SQLITE_UTF8.
pub fn resultText64(ctx: *Context, z: []const u8, del: Destructor) void {
    if (z.len > 0x7fffffff) return invokeValueDestructor(ctx, z, del);
    setResultStr(ctx, z, ENC.UTF8, del);
    _ = mem.zeroTerminateIfAble(ctx.out);
}

/// Port of sqlite3_result_text64() for SQLITE_UTF8_ZT: text followed by
/// a NUL byte. With .dynamic the allocation is z.len + 1 bytes.
pub fn resultTextZ(ctx: *Context, z: [:0]const u8, del: Destructor) void {
    const db = ctx.out.db.?;
    if (z.len > 0x7fffffff or z.len > db.limit(.length)) {
        switch (del) {
            .dynamic => db.gpa.free(@constCast(z)),
            .func => |f| f(@ptrCast(@constCast(z.ptr))),
            else => {},
        }
        return resultErrorTooBig(ctx);
    }
    mem.setTextZ(ctx.out, z, del) catch |err| switch (err) {
        error.TooBig => resultErrorTooBig(ctx),
        error.OutOfMemory => resultErrorNomem(ctx),
    };
}

/// Ownership of the sqlite3_str handed to resultStr() (SQLITE_COPY,
/// SQLITE_XFER).
pub const StrOwn = enum { copy, xfer };

/// Port of sqlite3_result_str(): the content of `p` as the result. With
/// .xfer the buffer is moved into the result and `p` left empty; with
/// .copy `p` is unchanged.
pub fn resultStr(ctx: *Context, p: *printf.StrAccum, own: StrOwn) void {
    if (p.acc_error == 0) {
        if (p.n_char == 0) {
            resultTextZ(ctx, "", .static);
            p.reset();
        } else if (own == .copy) {
            setResultStr(ctx, p.slice(), ENC.UTF8, .transient);
        } else {
            const z = p.finish() orelse return resultErrorNomem(ctx);
            resultTextZ(ctx, z, .dynamic);
            p.* = printf.StrAccum.init(p.gpa, &.{}, p.mx_alloc);
        }
    } else if (p.acc_error == printf.NOMEM) {
        resultErrorNomem(ctx);
    } else {
        resultErrorTooBig(ctx);
    }
}

/// Port of sqlite3_result_value(): a copy of `value`.
pub fn resultValue(ctx: *Context, value: *const Mem) void {
    mem.copy(ctx.out, value) catch return resultErrorNomem(ctx);
    mem.changeEncoding(ctx.out, ctx.enc) catch resultErrorNomem(ctx);
}

/// Port of sqlite3_result_subtype().
pub fn resultSubtype(ctx: *Context, subtype: u32) void {
    ctx.out.e_subtype = @truncate(subtype);
    ctx.out.flags.Subtype = true;
}

/// Port of sqlite3_result_error(): fail the function with `msg`.
pub fn resultError(ctx: *Context, msg: []const u8) void {
    ctx.is_error = RC.ERROR;
    mem.setStr(ctx.out, msg, ENC.UTF8, .transient) catch {};
}

/// Port of sqlite3_result_error_code().
pub fn resultErrorCode(ctx: *Context, code: i32) void {
    ctx.is_error = if (code != 0) code else -1;
    if (ctx.out.flags.Null) {
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
    if (ctx.out.db) |db| db.oomFault();
}

/// Port of unixCurrentTimeInt64() (os_unix.c): the current time as a
/// julian day number times 86400000. The Vfs has no xCurrentTimeInt64
/// yet, so every connection uses the system clock.
pub fn osCurrentTimeInt64() i64 {
    const unix_epoch: i64 = 24405875 * @as(i64, 8640000);
    const now = @import("../util/platform.zig").now();
    return unix_epoch + 1000 * now.sec + @divTrunc(now.nsec, 1000000);
}

/// Port of sqlite3StmtCurrentTime(): the time of the current statement
/// (julian day times 86400000), read once per sqlite3_step(). A context
/// without a statement reads the clock each time, as with
/// SQLITE_ENABLE_STAT4.
pub fn stmtCurrentTime(ctx: *Context) i64 {
    var i_time: i64 = 0;
    const pi_time = if (ctx.vdbe) |v| &v.i_current_time else &i_time;
    if (pi_time.* == 0) pi_time.* = osCurrentTimeInt64();
    return pi_time.*;
}

/// Port of sqlite3NotPureFunc() (vdbeaux.c): false, with an error set,
/// if the function runs as OP_PureFunc (in an index, CHECK constraint or
/// generated column), where non-deterministic results are not allowed.
pub fn notPureFunc(ctx: *Context) bool {
    const v = ctx.vdbe orelse return true;
    const op = &v.ops.items[@intCast(ctx.i_op)];
    if (op.opcode == vi.OP.PureFunc) {
        // P5 holds the NC_SelfRef flags of the expression (resolveExprStep()).
        const nc = int.NC.fromInt(op.p5);
        const z_context = if (nc.IsCheck)
            "a CHECK constraint"
        else if (nc.GenCol)
            "a generated column"
        else
            "an index";
        const gpa = ctx.out.db.?.gpa;
        const msg = printf.mprintf(gpa, "non-deterministic use of %s() in %s", &.{
            .{ .str = ctx.func.name }, .{ .str = z_context },
        }) catch {
            resultErrorNomem(ctx);
            return false;
        };
        defer gpa.free(msg);
        resultError(ctx, msg);
        return false;
    }
    return true;
}

/// Port of sqlite3_user_data().
pub fn userData(ctx: *const Context) ?*anyopaque {
    return ctx.func.user_data;
}

/// Port of sqlite3_context_db_handle().
pub fn contextDbHandle(ctx: *const Context) *Sqlite3 {
    return ctx.out.db.?;
}

/// Port of sqlite3_get_auxdata(): the auxiliary data of argument `i_arg`
/// of this function call, or for a negative `i_arg` of the statement;
/// null if there is none.
pub fn getAuxdata(ctx: *const Context, i_arg: i32) ?*anyopaque {
    const v = ctx.vdbe orelse return null;
    var p = v.aux_data;
    while (p) |aux_data| : (p = aux_data.next_aux) {
        if (aux_data.i_aux_arg == i_arg and (aux_data.i_aux_op == ctx.i_op or i_arg < 0)) {
            return aux_data.aux;
        }
    }
    return null;
}

/// Port of sqlite3_set_auxdata(): keep `aux` as the auxiliary data of
/// argument `i_arg` (of the statement if negative); `x_delete` frees it
/// when it is replaced or no longer needed.
pub fn setAuxdata(ctx: *Context, i_arg: i32, p_aux: ?*anyopaque, x_delete: ?int.DestructorFn) void {
    const v = ctx.vdbe orelse {
        if (x_delete) |del| del(p_aux);
        return;
    };
    var p = v.aux_data;
    const found: *vi.AuxData = while (p) |aux_data| : (p = aux_data.next_aux) {
        if (aux_data.i_aux_arg == i_arg and (aux_data.i_aux_op == ctx.i_op or i_arg < 0)) {
            if (aux_data.x_delete_aux) |del| del(aux_data.aux);
            break aux_data;
        }
    } else blk: {
        const new = v.db.gpa.create(vi.AuxData) catch {
            if (x_delete) |del| del(p_aux);
            return;
        };
        new.* = .{ .i_aux_op = ctx.i_op, .i_aux_arg = i_arg, .aux = null, .x_delete_aux = null, .next_aux = v.aux_data };
        v.aux_data = new;
        if (ctx.is_error == 0) ctx.is_error = -1;
        break :blk new;
    };
    found.aux = p_aux;
    found.x_delete_aux = x_delete;
}

/// The type of the auxiliary data that `x_delete` (a typed destructor,
/// `fn (*T) void`) frees.
fn AuxType(comptime x_delete: anytype) type {
    return @typeInfo(@TypeOf(x_delete)).@"fn".param_types[0].?;
}

/// setAuxdata() of typed data, freed by the typed destructor `x_delete`.
pub fn setAuxdataTyped(ctx: *Context, i_arg: i32, comptime x_delete: anytype, p_aux: AuxType(x_delete)) void {
    setAuxdata(ctx, i_arg, p_aux, int.destructor(x_delete));
}

/// getAuxdata() of data set by setAuxdataTyped() with the same
/// `x_delete`, which gives its type.
pub fn getAuxdataTyped(ctx: *const Context, i_arg: i32, comptime x_delete: anytype) ?AuxType(x_delete) {
    return thunk.downcast(AuxType(x_delete), getAuxdata(ctx, i_arg) orelse return null);
}

/// Port of sqlite3_aggregate_context(): `n` zeroed bytes kept for the
/// aggregate across calls; null if `n` is 0 and none was made yet.
pub fn aggregateContext(ctx: *Context, n: usize) ?[]u8 {
    const m = ctx.mem.?;
    if (!m.flags.Agg) {
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
        m.flags = .{ .Agg = true };
        m.u = .{ .def = ctx.func };
        @memset(m.z.?[0..n], 0);
        m.n = @intCast(n);
    }
    return m.z.?[0..@intCast(m.n)];
}

// ================================================================== tests

const OP = vi.OP;

/// A connection with no databases, for programs that use none.
fn testDb(db: *Sqlite3) void {
    db.* = .{ .gpa = malloc.dbAllocator(db) };
}

test "api: run a hand-assembled program" {
    var db: Sqlite3 = undefined;
    testDb(&db);
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
    var db: Sqlite3 = undefined;
    testDb(&db);
    db.vfs = mv.interface();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var p: int.Parse = .{ .db = &db, .arena = arena.allocator() };
    const v = try aux.create(&p);
    const a = v.alloc();
    var sort_flags = [_]u8{ int.KeyInfoOrder.desc, 0 };
    var coll = [_]?*const int.CollSeq{ null, null };
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
        var db: Sqlite3 = undefined;
        testDb(&db);
        db.vfs = mv.interface();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var p: int.Parse = .{ .db = &db, .arena = arena.allocator() };
        const v = try aux.create(&p);
        const a = v.alloc();
        var sort_flags = [_]u8{ 0, 0 };
        var coll = [_]?*const int.CollSeq{ null, null };
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
    var db: Sqlite3 = undefined;
    testDb(&db);
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

// ============================================================ scan status

/// SQLITE_SCANSTAT_* metrics.
pub const SCANSTAT = struct {
    pub const NLOOP = 0;
    pub const NVISIT = 1;
    pub const EST = 2;
    pub const NAME = 3;
    pub const EXPLAIN = 4;
    pub const SELECTID = 5;
    pub const PARENTID = 6;
    pub const NCYCLE = 7;
    pub const COMPLEX = 1;
};

/// Port of sqlite3_stmt_scanstatus_v2(): metric `op` of entry `i_scan`
/// (loops only, unless `flags` has SCANSTAT_COMPLEX) into `out`, whose
/// type is the metric's (i64, f64, a C string or i32). Returns 0, or 1
/// if there is no such entry. A statement compiled without
/// SQLITE_DBCONFIG_STMT_SCANSTATUS has no entries.
pub fn scanStatus(v: *Vdbe, i_scan_arg: i32, op: i32, flags: i32, out: *anyopaque) i32 {
    if (op < SCANSTAT.NLOOP or op > SCANSTAT.NCYCLE) return 1;
    const ops = if (v.frame) |f| vi.rootFrame(f).ops else v.ops.items;
    const stats = v.op_stats;
    const Out = struct {
        fn as(comptime T: type, p: *anyopaque) *T {
            return @ptrCast(@alignCast(p));
        }
    };
    var i_scan = i_scan_arg;
    if (i_scan < 0) {
        if (op != SCANSTAT.NCYCLE) return 1;
        var res: u64 = 0;
        for (stats) |s| res +%= s.n_cycle;
        Out.as(i64, out).* = @bitCast(res);
        return 0;
    }
    var idx: usize = 0;
    if (flags & SCANSTAT.COMPLEX != 0) {
        idx = @intCast(i_scan);
    } else {
        // Without COMPLEX, only the entries of loops (with a name).
        while (idx < v.scans.items.len) : (idx += 1) {
            if (v.scans.items[idx].name != null) {
                i_scan -= 1;
                if (i_scan < 0) break;
            }
        }
    }
    if (idx >= v.scans.items.len) return 1;
    const scan = &v.scans.items[idx];
    const exec_count = struct {
        fn f(st: []const vi.OpStat, addr: i32) i64 {
            if (addr <= 0) return -1;
            if (@as(usize, @intCast(addr)) >= st.len) return 0;
            return @bitCast(st[@intCast(addr)].n_exec);
        }
    }.f;
    switch (op) {
        SCANSTAT.NLOOP => Out.as(i64, out).* = exec_count(stats, scan.addr_loop),
        SCANSTAT.NVISIT => Out.as(i64, out).* = exec_count(stats, scan.addr_visit),
        SCANSTAT.EST => {
            var r: f64 = 1.0;
            var x = scan.n_est;
            while (x < 100) {
                x += 10;
                r *= 0.5;
            }
            Out.as(f64, out).* = r * @as(f64, @floatFromInt(@import("../sql/util.zig").logEstToInt(x)));
        },
        SCANSTAT.NAME => Out.as(?[*:0]const u8, out).* = if (scan.name) |z| z.ptr else null,
        SCANSTAT.EXPLAIN => Out.as(?[*:0]const u8, out).* = if (scan.addr_explain != 0) ops[@intCast(scan.addr_explain)].p4.z else null,
        SCANSTAT.SELECTID => Out.as(i32, out).* = if (scan.addr_explain != 0) ops[@intCast(scan.addr_explain)].p1 else -1,
        SCANSTAT.PARENTID => Out.as(i32, out).* = if (scan.addr_explain != 0) ops[@intCast(scan.addr_explain)].p2 else -1,
        SCANSTAT.NCYCLE => {
            var res: i64 = 0;
            if (scan.addr_range[0] == 0) {
                res = -1;
            } else if (stats.len == ops.len) {
                var ii: usize = 0;
                while (ii < scan.addr_range.len) : (ii += 2) {
                    var i_ins = scan.addr_range[ii];
                    const i_end = scan.addr_range[ii + 1];
                    if (i_ins == 0) break;
                    if (i_ins > 0) {
                        while (i_ins <= i_end) : (i_ins += 1) res +%= @bitCast(stats[@intCast(i_ins)].n_cycle);
                    } else {
                        // Every instruction on cursor i_end that counts.
                        for (ops, stats) |o, s| {
                            if (o.p1 != i_end) continue;
                            if (o.opcode.opflags() & @import("opcodes.zig").OPFLG.NCYCLE == 0) continue;
                            res +%= @bitCast(s.n_cycle);
                        }
                    }
                }
            }
            Out.as(i64, out).* = res;
        },
        else => return 1,
    }
    return 0;
}

/// Port of sqlite3_stmt_scanstatus_reset(): zero the counters.
pub fn scanStatusReset(v: *Vdbe) void {
    @memset(v.op_stats, .{});
}
