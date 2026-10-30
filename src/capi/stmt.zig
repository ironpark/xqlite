//! Prepared statements: sqlite3_prepare*(), sqlite3_step(), the
//! bindings and the columns.

const std = @import("std");
const c = @import("common.zig");
const func = @import("func.zig");
const conn = @import("conn.zig");

const Handle = c.Handle;
const Vdbe = c.Vdbe;
const Mem = c.Mem;
const RC = c.RC;
const aux = @import("../vdbe/aux.zig");
const prepare_mod = @import("../sql/prepare.zig");
const tokenize = @import("../parse/tokenize.zig");
const TK = @import("../parse/grammar.zig").TK;

// =============================================================== prepare

fn prepare(db_arg: ?*Handle, z_sql: ?[*]const u8, n_byte: c_int, prep_flags: c_uint, pp_stmt: ?*?*Vdbe, pz_tail: ?*?[*]const u8) c_int {
    const out = pp_stmt orelse return RC.MISUSE;
    out.* = null;
    if (pz_tail) |t| t.* = z_sql;
    const db = db_arg orelse return RC.MISUSE;
    const sql = z_sql orelse return RC.MISUSE;
    const flags: u8 = @truncate(prep_flags & aux.PREPARE_MASK);
    const text = c.cSliceZ(sql, n_byte);
    var rc: c_int = undefined;
    if (n_byte < 0 or text.len < @as(usize, @intCast(n_byte))) {
        // The text ends at its NUL: parsed in place.
        var tail: [:0]const u8 = "";
        rc = prepare_mod.prepareV3Z(db, text.ptr[0..text.len :0], flags, out, &tail);
        if (pz_tail) |t| t.* = tail.ptr;
    } else {
        var tail: []const u8 = "";
        rc = prepare_mod.prepareV3(db, text, flags, out, &tail);
        if (pz_tail) |t| t.* = sql + (text.len - tail.len);
    }
    return rc;
}

pub export fn sqlite3_prepare(db: ?*Handle, z_sql: ?[*]const u8, n_byte: c_int, pp_stmt: ?*?*Vdbe, pz_tail: ?*?[*]const u8) callconv(.c) c_int {
    return prepare(db, z_sql, n_byte, 0, pp_stmt, pz_tail);
}

pub export fn sqlite3_prepare_v2(db: ?*Handle, z_sql: ?[*]const u8, n_byte: c_int, pp_stmt: ?*?*Vdbe, pz_tail: ?*?[*]const u8) callconv(.c) c_int {
    return prepare(db, z_sql, n_byte, 0, pp_stmt, pz_tail);
}

pub export fn sqlite3_prepare_v3(db: ?*Handle, z_sql: ?[*]const u8, n_byte: c_int, prep_flags: c_uint, pp_stmt: ?*?*Vdbe, pz_tail: ?*?[*]const u8) callconv(.c) c_int {
    return prepare(db, z_sql, n_byte, prep_flags, pp_stmt, pz_tail);
}

/// The *16 variants: the text is converted to UTF-8, prepared, and the
/// tail mapped back to the UTF-16 input.
fn prepare16(db_arg: ?*Handle, z_sql: ?*const anyopaque, n_byte: c_int, prep_flags: c_uint, pp_stmt: ?*?*Vdbe, pz_tail: ?*?*const anyopaque) c_int {
    const out = pp_stmt orelse return RC.MISUSE;
    out.* = null;
    if (pz_tail) |t| t.* = z_sql;
    const db = db_arg orelse return RC.MISUSE;
    const sql16 = c.utf16Slice(z_sql orelse return RC.MISUSE, n_byte);
    const sql8 = c.utf16ToUtf8(sql16, false) orelse return RC.NOMEM;
    defer c.gpa.free(sql8);
    var tail: ?[*]const u8 = null;
    const rc = prepare(db, sql8.ptr, @intCast(sql8.len), prep_flags, out, &tail);
    if (pz_tail) |t| {
        const consumed = sql8[0 .. @intFromPtr(tail.?) - @intFromPtr(sql8.ptr)];
        var units: usize = 0;
        var i: usize = 0;
        while (i < consumed.len) {
            const l = std.unicode.utf8ByteSequenceLength(consumed[i]) catch 1;
            units += if (l == 4) 2 else 1;
            i += l;
        }
        t.* = @ptrCast(sql16.ptr + @min(units, sql16.len));
    }
    return rc;
}

pub export fn sqlite3_prepare16(db: ?*Handle, z_sql: ?*const anyopaque, n_byte: c_int, pp_stmt: ?*?*Vdbe, pz_tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepare16(db, z_sql, n_byte, 0, pp_stmt, pz_tail);
}

pub export fn sqlite3_prepare16_v2(db: ?*Handle, z_sql: ?*const anyopaque, n_byte: c_int, pp_stmt: ?*?*Vdbe, pz_tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepare16(db, z_sql, n_byte, 0, pp_stmt, pz_tail);
}

pub export fn sqlite3_prepare16_v3(db: ?*Handle, z_sql: ?*const anyopaque, n_byte: c_int, prep_flags: c_uint, pp_stmt: ?*?*Vdbe, pz_tail: ?*?*const anyopaque) callconv(.c) c_int {
    return prepare16(db, z_sql, n_byte, prep_flags, pp_stmt, pz_tail);
}

// ================================================ step, reset, finalize

/// The trace and profile callbacks are called by the engine (OP_Init,
/// OP_Trace, OP_ResultRow, the end of the run; see callbacks.zig).
pub export fn sqlite3_step(v_arg: ?*Vdbe) callconv(.c) c_int {
    return c.api.step(v_arg orelse return RC.MISUSE);
}

pub export fn sqlite3_reset(v_arg: ?*Vdbe) callconv(.c) c_int {
    return c.api.reset(v_arg orelse return RC.OK);
}

pub export fn sqlite3_finalize(v_arg: ?*Vdbe) callconv(.c) c_int {
    const v = v_arg orelse return RC.OK;
    const db = v.db;
    const rc = c.api.finalize(v);
    conn.closeZombie(db);
    return rc;
}

pub export fn sqlite3_clear_bindings(v_arg: ?*Vdbe) callconv(.c) c_int {
    c.api.clearBindings(v_arg orelse return RC.OK);
    return RC.OK;
}

// ============================================================== bindings

fn idx(i: c_int) usize {
    return if (i < 0) 0 else @intCast(i);
}

/// Call the destructor the application passed for a value the engine
/// has copied (anything but SQLITE_STATIC and SQLITE_TRANSIENT).
fn done(del: ?*const anyopaque, p: ?*const anyopaque) void {
    if (c.cDestructor(del)) |f| if (p != null) f(@constCast(p));
}

pub export fn sqlite3_bind_null(v: ?*Vdbe, i: c_int) callconv(.c) c_int {
    return c.api.bindNull(v orelse return RC.MISUSE, idx(i));
}

pub export fn sqlite3_bind_int(v: ?*Vdbe, i: c_int, x: c_int) callconv(.c) c_int {
    return c.api.bindInt64(v orelse return RC.MISUSE, idx(i), x);
}

pub export fn sqlite3_bind_int64(v: ?*Vdbe, i: c_int, x: i64) callconv(.c) c_int {
    return c.api.bindInt64(v orelse return RC.MISUSE, idx(i), x);
}

pub export fn sqlite3_bind_double(v: ?*Vdbe, i: c_int, x: f64) callconv(.c) c_int {
    return c.api.bindDouble(v orelse return RC.MISUSE, idx(i), x);
}

fn bindBlob(v_arg: ?*Vdbe, i: c_int, z: ?*const anyopaque, n: u64, del: ?*const anyopaque) c_int {
    defer done(del, z);
    const v = v_arg orelse return RC.MISUSE;
    const p: [*]const u8 = @ptrCast(z orelse return c.api.bindNull(v, idx(i)));
    if (n > std.math.maxInt(c_int)) {
        _ = c.api.bindNull(v, idx(i));
        return RC.TOOBIG;
    }
    return c.api.bindBlob(v, idx(i), p[0..@intCast(n)]);
}

pub export fn sqlite3_bind_blob(v: ?*Vdbe, i: c_int, z: ?*const anyopaque, n: c_int, del: ?*const anyopaque) callconv(.c) c_int {
    return bindBlob(v, i, z, @intCast(@max(n, 0)), del);
}

pub export fn sqlite3_bind_blob64(v: ?*Vdbe, i: c_int, z: ?*const anyopaque, n: u64, del: ?*const anyopaque) callconv(.c) c_int {
    return bindBlob(v, i, z, n, del);
}

/// Bind `n` bytes of text in encoding `enc` (SQLITE_UTF8, SQLITE_UTF8_ZT
/// or a UTF-16 one), all of it up to a NUL if `n` is negative.
fn bindText(v_arg: ?*Vdbe, i: c_int, z: ?*const anyopaque, n: i64, del: ?*const anyopaque, enc: u8) c_int {
    defer done(del, z);
    const v = v_arg orelse return RC.MISUSE;
    const p = z orelse return c.api.bindNull(v, idx(i));
    switch (enc) {
        2, 3, 4 => {
            const s16 = c.utf16Slice(p, n);
            const s8 = c.utf16ToUtf8(s16, enc == 3) orelse return RC.NOMEM;
            defer c.gpa.free(s8);
            return c.api.bindText(v, idx(i), s8);
        },
        else => {
            const s = c.cSlice(@ptrCast(p), n);
            if (s.len > std.math.maxInt(c_int)) {
                _ = c.api.bindNull(v, idx(i));
                return RC.TOOBIG;
            }
            return c.api.bindText(v, idx(i), s);
        },
    }
}

pub export fn sqlite3_bind_text(v: ?*Vdbe, i: c_int, z: ?[*]const u8, n: c_int, del: ?*const anyopaque) callconv(.c) c_int {
    return bindText(v, i, z, n, del, 1);
}

pub export fn sqlite3_bind_text64(v: ?*Vdbe, i: c_int, z: ?[*]const u8, n: u64, del: ?*const anyopaque, enc: u8) callconv(.c) c_int {
    const len: i64 = if (n > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(n);
    return bindText(v, i, z, len, del, enc);
}

pub export fn sqlite3_bind_text16(v: ?*Vdbe, i: c_int, z: ?*const anyopaque, n: c_int, del: ?*const anyopaque) callconv(.c) c_int {
    return bindText(v, i, z, n, del, 4);
}

pub export fn sqlite3_bind_value(v: ?*Vdbe, i: c_int, value: ?*const Mem) callconv(.c) c_int {
    const vv = v orelse return RC.MISUSE;
    return c.api.bindValue(vv, idx(i), @constCast(value orelse return c.api.bindNull(vv, idx(i))));
}

pub export fn sqlite3_bind_zeroblob(v: ?*Vdbe, i: c_int, n: c_int) callconv(.c) c_int {
    return c.api.bindZeroblob(v orelse return RC.MISUSE, idx(i), @max(n, 0));
}

pub export fn sqlite3_bind_zeroblob64(v_arg: ?*Vdbe, i: c_int, n: u64) callconv(.c) c_int {
    const v = v_arg orelse return RC.MISUSE;
    if (n > @as(u64, @intCast(v.db.limit(.length)))) return RC.TOOBIG;
    return c.api.bindZeroblob(v, idx(i), @intCast(n));
}

pub export fn sqlite3_bind_pointer(v_arg: ?*Vdbe, i: c_int, p: ?*anyopaque, z_type: ?[*:0]const u8, del: ?*const anyopaque) callconv(.c) c_int {
    const v = v_arg orelse {
        done(del, p);
        return RC.MISUSE;
    };
    const rc = c.api.bindNull(v, idx(i));
    if (rc != RC.OK) {
        done(del, p);
        return rc;
    }
    c.mem.setPointer(&v.vars[idx(i) - 1], p, z_type, func.pointerDestructor(p, del));
    return RC.OK;
}

pub export fn sqlite3_bind_parameter_count(v: ?*Vdbe) callconv(.c) c_int {
    return @intCast(c.api.bindParameterCount(v orelse return 0));
}

pub export fn sqlite3_bind_parameter_name(v: ?*Vdbe, i: c_int) callconv(.c) ?[*:0]const u8 {
    const name = c.api.bindParameterName(v orelse return null, idx(i)) orelse return null;
    return @ptrCast(name.ptr);
}

pub export fn sqlite3_bind_parameter_index(v: ?*Vdbe, z_name: ?[*:0]const u8) callconv(.c) c_int {
    return @intCast(c.api.bindParameterIndex(v orelse return 0, c.span(z_name) orelse return 0));
}

pub export fn sqlite3_transfer_bindings(from_arg: ?*Vdbe, to_arg: ?*Vdbe) callconv(.c) c_int {
    const from = from_arg orelse return RC.MISUSE;
    const to = to_arg orelse return RC.MISUSE;
    if (from.n_var != to.n_var) return RC.ERROR;
    for (0..@intCast(from.n_var)) |i| {
        const rc = c.api.bindValue(to, i + 1, &from.vars[i]);
        if (rc != RC.OK) return rc;
    }
    c.api.clearBindings(from);
    return RC.OK;
}

// =============================================================== columns

fn col(i: c_int) usize {
    return if (i < 0) std.math.maxInt(u32) else @intCast(i);
}

pub export fn sqlite3_column_count(v: ?*Vdbe) callconv(.c) c_int {
    return @intCast(c.api.columnCount(v orelse return 0));
}

pub export fn sqlite3_data_count(v: ?*Vdbe) callconv(.c) c_int {
    return @intCast(c.api.dataCount(v orelse return 0));
}

pub export fn sqlite3_column_type(v: ?*Vdbe, i: c_int) callconv(.c) c_int {
    return c.api.columnType(v orelse return c.vi.SQLITE_NULL, col(i));
}

pub export fn sqlite3_column_int(v: ?*Vdbe, i: c_int) callconv(.c) c_int {
    return @truncate(c.api.columnInt64(v orelse return 0, col(i)));
}

pub export fn sqlite3_column_int64(v: ?*Vdbe, i: c_int) callconv(.c) i64 {
    return c.api.columnInt64(v orelse return 0, col(i));
}

pub export fn sqlite3_column_double(v: ?*Vdbe, i: c_int) callconv(.c) f64 {
    return c.api.columnDouble(v orelse return 0, col(i));
}

pub export fn sqlite3_column_text(v: ?*Vdbe, i: c_int) callconv(.c) ?[*:0]const u8 {
    return c.cStr(c.api.columnText(v orelse return null, col(i)));
}

pub export fn sqlite3_column_blob(v: ?*Vdbe, i: c_int) callconv(.c) ?*const anyopaque {
    const b = c.api.columnBlob(v orelse return null, col(i)) orelse return null;
    return b.ptr;
}

pub export fn sqlite3_column_bytes(v: ?*Vdbe, i: c_int) callconv(.c) c_int {
    return @intCast(c.api.columnBytes(v orelse return 0, col(i)));
}

pub export fn sqlite3_column_bytes16(v: ?*Vdbe, i: c_int) callconv(.c) c_int {
    const t = c.api.columnText(v orelse return 0, col(i)) orelse return 0;
    return @intCast(c.utf16Bytes(t));
}

pub export fn sqlite3_column_value(v: ?*Vdbe, i: c_int) callconv(.c) ?*Mem {
    return c.api.columnValue(v orelse return null, col(i));
}

pub export fn sqlite3_column_name(v: ?*Vdbe, i: c_int) callconv(.c) ?[*:0]const u8 {
    return c.cStr(c.api.columnName(v orelse return null, col(i)));
}

pub export fn sqlite3_column_decltype(v: ?*Vdbe, i: c_int) callconv(.c) ?[*:0]const u8 {
    return c.cStr(c.api.columnDecltype(v orelse return null, col(i)));
}

// Built without SQLITE_ENABLE_COLUMN_METADATA, as SQLite's default:
// the statement does not record where a column comes from.

pub export fn sqlite3_column_database_name(_: ?*Vdbe, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}

pub export fn sqlite3_column_table_name(_: ?*Vdbe, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}

pub export fn sqlite3_column_origin_name(_: ?*Vdbe, _: c_int) callconv(.c) ?[*:0]const u8 {
    return null;
}

// The UTF-16 results: the engine keeps text in UTF-8 only, and these
// would need a converted copy that lives as long as the column value.

pub export fn sqlite3_column_text16(_: ?*Vdbe, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_column_name16(_: ?*Vdbe, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_column_decltype16(_: ?*Vdbe, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_column_database_name16(_: ?*Vdbe, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_column_table_name16(_: ?*Vdbe, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_column_origin_name16(_: ?*Vdbe, _: c_int) callconv(.c) ?*const anyopaque {
    return null;
}

// ============================================================ statements

pub export fn sqlite3_sql(v: ?*Vdbe) callconv(.c) ?[*:0]const u8 {
    return c.cStr((v orelse return null).sql);
}

pub export fn sqlite3_normalized_sql(_: ?*Vdbe) callconv(.c) ?[*:0]const u8 {
    // SQLITE_ENABLE_NORMALIZE is not built in.
    return null;
}

/// Port of sqlite3VdbeExpandSql(): the SQL of the statement with its
/// parameters replaced by their values, from sqlite3_malloc().
pub export fn sqlite3_expanded_sql(v_arg: ?*Vdbe) callconv(.c) ?[*:0]u8 {
    const v = v_arg orelse return null;
    return expandSql(v, v.sql orelse return null);
}

/// sqlite3VdbeExpandSql() of `raw` (the statement's SQL or the comment
/// of a trigger), from sqlite3_malloc().
pub fn expandSql(v: *Vdbe, raw: [:0]const u8) ?[*:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(c.gpa);
    expand(v, raw, &out) catch {
        out.deinit(c.gpa);
        return null;
    };
    const z = out.toOwnedSliceSentinel(c.gpa, 0) catch return null;
    return z.ptr;
}

fn expand(v: *Vdbe, raw: [:0]const u8, out: *std.ArrayList(u8)) !void {
    const a = c.gpa;
    if (v.db.n_vdbe_exec > 1) {
        // Nested (a statement of a trigger or function): each line as an
        // SQL comment.
        var it = std.mem.splitScalar(u8, raw, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try out.append(a, '\n');
            first = false;
            try out.appendSlice(a, "-- ");
            try out.appendSlice(a, line);
        }
        return;
    }
    if (v.n_var == 0) return out.appendSlice(a, raw);
    var next_index: usize = 1;
    var i: usize = 0;
    while (i < raw.len) {
        // The next host parameter.
        var start = i;
        var tok_len: usize = 0;
        while (start < raw.len) {
            const t = tokenize.getToken(raw[start..].ptr);
            if (t.tk == TK.VARIABLE) {
                tok_len = t.len;
                break;
            }
            start += t.len;
        }
        try out.appendSlice(a, raw[i..start]);
        if (start >= raw.len) break;
        const tok = raw[start..][0..tok_len];
        i = start + tok_len;
        var index: usize = undefined;
        if (tok[0] == '?') {
            index = if (tok.len > 1) std.fmt.parseInt(usize, tok[1..], 10) catch 0 else next_index;
        } else {
            index = c.api.bindParameterIndex(v, tok);
        }
        if (index < 1 or index > @as(usize, @intCast(v.n_var))) continue;
        next_index = @max(index + 1, next_index);
        try appendValue(out, &v.vars[index - 1]);
    }
}

fn appendValue(out: *std.ArrayList(u8), m: *Mem) !void {
    const a = c.gpa;
    switch (c.mem.valueType(m)) {
        c.vi.SQLITE_INTEGER => try out.print(a, "{d}", .{m.u.i}),
        c.vi.SQLITE_FLOAT => {
            const r = c.api.valueDouble(m);
            const z = try c.printf.mprintf(a, "%!.15g", &.{.{ .double = r }});
            defer a.free(z);
            try out.appendSlice(a, z);
        },
        c.vi.SQLITE_TEXT => {
            try out.append(a, '\'');
            for (c.api.valueText(m) orelse "") |ch| {
                if (ch == '\'') try out.append(a, '\'');
                try out.append(a, ch);
            }
            try out.append(a, '\'');
        },
        c.vi.SQLITE_BLOB => {
            if (m.flags.Zero) {
                try out.print(a, "zeroblob({d})", .{m.u.n_zero});
            } else {
                try out.appendSlice(a, "x'");
                for (c.api.valueBlob(m) orelse "") |b| try out.print(a, "{x:0>2}", .{b});
                try out.append(a, '\'');
            }
        },
        else => try out.appendSlice(a, "NULL"),
    }
}

pub export fn sqlite3_stmt_readonly(v: ?*Vdbe) callconv(.c) c_int {
    return @intFromBool((v orelse return 1).read_only);
}

pub export fn sqlite3_stmt_isexplain(v: ?*Vdbe) callconv(.c) c_int {
    return c.api.stmtIsExplain(v orelse return 0);
}

/// Changing the EXPLAIN mode of a prepared statement is not supported;
/// asking for the mode it has succeeds.
pub export fn sqlite3_stmt_explain(v_arg: ?*Vdbe, mode: c_int) callconv(.c) c_int {
    const v = v_arg orelse return RC.MISUSE;
    if (mode < 0 or mode > 2) return RC.ERROR;
    if (mode == c.api.stmtIsExplain(v)) return RC.OK;
    return RC.ERROR;
}

pub export fn sqlite3_stmt_busy(v: ?*Vdbe) callconv(.c) c_int {
    return @intFromBool((v orelse return 0).e_vdbe_state == .run);
}

pub export fn sqlite3_stmt_status(v_arg: ?*Vdbe, op: c_int, reset: c_int) callconv(.c) c_int {
    const v = v_arg orelse return 0;
    if (op < 1 or op >= v.counters.len) return 0;
    const i: usize = @intCast(op);
    const n = v.counters[i];
    if (reset != 0) v.counters[i] = 0;
    return @bitCast(n);
}

pub export fn sqlite3_db_handle(v: ?*Vdbe) callconv(.c) ?*Handle {
    return (v orelse return null).db;
}

pub export fn sqlite3_next_stmt(db: ?*Handle, prev: ?*Vdbe) callconv(.c) ?*Vdbe {
    if (prev) |p| return p.next;
    return (db orelse return null).vdbe;
}

pub export fn sqlite3_expired(v: ?*Vdbe) callconv(.c) c_int {
    return (v orelse return 1).expired;
}

// SQLITE_ENABLE_STMT_SCANSTATUS is not built in: no loop is reported.

pub export fn sqlite3_stmt_scanstatus(_: ?*Vdbe, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

pub export fn sqlite3_stmt_scanstatus_v2(_: ?*Vdbe, _: c_int, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

pub export fn sqlite3_stmt_scanstatus_reset(_: ?*Vdbe) callconv(.c) void {}

// The carray extension (SQLITE_ENABLE_CARRAY) is not built in.

pub export fn sqlite3_carray_bind_v2(v: ?*Vdbe, _: c_int, data: ?*anyopaque, _: c_int, _: c_int, del: ?*const anyopaque, p_del: ?*anyopaque) callconv(.c) c_int {
    if (c.cDestructor(del)) |f| f(p_del orelse data);
    if (v) |s| c.main.errorWithMsg(s.db, RC.ERROR, "xqlite does not support sqlite3_carray_bind()", .{});
    return RC.ERROR;
}

pub export fn sqlite3_carray_bind(v: ?*Vdbe, i: c_int, data: ?*anyopaque, n: c_int, flags: c_int, del: ?*const anyopaque) callconv(.c) c_int {
    return sqlite3_carray_bind_v2(v, i, data, n, flags, del, null);
}
