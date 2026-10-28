//! A prepared statement (sqlite3_stmt), made by `Db.prepare()`.
//!
//! Life cycle:
//!
//!     var stmt = try db.prepare("SELECT id, name FROM users WHERE age > ?");
//!     defer stmt.finalize();
//!     try stmt.bind(.{30});
//!     var it = stmt.iterator(struct { id: i64, name: []const u8 });
//!     while (try it.next()) |u| { ... u.name is valid until the next next() ... }
//!
//! Lifetimes, in short: finalize every `Stmt` before closing its `Db`;
//! bound values are copied; borrowed reads (`[]const u8`, `Blob`,
//! `Value.text` ...) are valid until the next step(), reset(), bind() or
//! finalize() of the statement, and `*Alloc` reads are owned by the
//! caller. The full rules are in docs/zig-api.md ("값의 수명 규칙").

const std = @import("std");
const engine = @import("engine.zig");
const errors = @import("errors.zig");
const value = @import("value.zig");
const Conn = @import("conn.zig").Conn;

const Allocator = std.mem.Allocator;
const Error = errors.Error;
const Kind = value.Kind;
const Stmt = @This();

vm: *engine.Vm,
conn: Conn,
/// The column of each field of the named struct last read by row(),
/// next() or an Iterator.
row_cache: FieldCache = .{},
/// The parameter of each field of the named struct last bound by bind().
bind_cache: FieldCache = .{},

/// Free the statement (sqlite3_finalize()). Errors of the last step have
/// already been returned by step(), so none is reported here. Unlike
/// sqlite3_finalize(), it leaves the connection's last error as it was,
/// so that an error survives `defer stmt.finalize()` for Db.lastError().
pub fn finalize(s: *Stmt) void {
    const saved = s.conn.saveError();
    defer saved.restore();
    engine.finalize(s.vm);
    s.* = undefined;
}

/// Rewind the statement so that it can be stepped again from the start
/// (sqlite3_reset()). Bindings are kept.
pub fn reset(s: *Stmt) void {
    engine.reset(s.vm);
}

/// Set every parameter to NULL (sqlite3_clear_bindings()).
pub fn clearBindings(s: *Stmt) void {
    engine.clearBindings(s.vm);
}

/// Run the statement to its next row (sqlite3_step()): true if there is
/// a row to read, false when the statement is done. Stepping a statement
/// that is done starts it again.
pub fn step(s: *Stmt) Error!bool {
    return s.conn.check(engine.step(s.vm));
}

/// Bind `args`, resetting the statement and clearing any earlier
/// bindings first:
///
/// * a tuple binds by position: `.{ 1, "x", null }` binds ?1, ?2, ?3. It
///   must have exactly as many values as the statement has parameters.
/// * a struct binds by name: field `id` binds `:id`, `@id` or `$id`.
///   Every field must name a parameter, and every parameter must be
///   covered.
///
/// See value.zig for how each Zig type is bound. Values are copied. If
/// bind() fails, every parameter is left NULL.
pub fn bind(s: *Stmt, args: anytype) Error!void {
    const T = @TypeOf(args);
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("xqlite: bind() takes a tuple or a struct, not " ++ @typeName(T));
    engine.reset(s.vm);
    const n_param = engine.bindParameterCount(s.vm);
    const fields = info.@"struct".field_names;
    if (fields.len != n_param) {
        engine.clearBindings(s.vm);
        return s.conn.usage(error.ParameterCountMismatch, "bind: the statement has {d} parameters, got {d} values", .{ n_param, fields.len });
    }
    // Each of the n_param parameters gets a value (distinct fields name
    // distinct parameters), so the earlier ones need not be cleared
    // first, only after a failure.
    errdefer engine.clearBindings(s.vm);
    if (info.@"struct".is_tuple) {
        inline for (fields, 0..) |name, i| try s.bindAt(i + 1, @field(args, name));
    } else {
        const map = try s.parameterMap(T);
        inline for (fields, 0..) |name, k| try s.bindAt(map[k], @field(args, name));
    }
}

/// The parameter (`:name`, `@name` or `$name`) of each field of the
/// struct `T`, from the cache if `T` was bound last.
fn parameterMap(s: *Stmt, comptime T: type) Error![@typeInfo(T).@"struct".field_names.len]u16 {
    const names = @typeInfo(T).@"struct".field_names;
    const epoch = engine.reprepareCount(s.vm);
    if (s.bind_cache.lookup(T, epoch)) |map| return map[0..names.len].*;
    var map: [names.len]u16 = undefined;
    inline for (names, 0..) |name, k| {
        const i = s.parameterIndexAny(name) orelse
            return s.conn.usage(error.UnknownParameter, "bind: no parameter :{s}, @{s} or ${s}", .{ name, name, name });
        map[k] = @intCast(i);
    }
    s.bind_cache.store(T, epoch, &map);
    return map;
}

/// The index of parameter `:name`, `@name` or `$name`.
fn parameterIndexAny(s: *Stmt, comptime name: []const u8) ?usize {
    inline for (.{ ":", "@", "$" }) |prefix| {
        const i = engine.bindParameterIndex(s.vm, prefix ++ name);
        if (i != 0) return i;
    }
    return null;
}

/// Bind one value to parameter `i` (1-based, as in SQL `?1`). Unlike
/// bind(), this neither resets the statement nor checks the count: call
/// reset() first if the statement has been stepped.
pub fn bindAt(s: *Stmt, i: usize, x: anytype) Error!void {
    return value.bind(s.vm, i, x) catch |err| switch (err) {
        error.IntegerOverflow => s.conn.usage(error.IntegerOverflow, "bind: parameter {d}: the integer does not fit a 64-bit SQLite integer", .{i}),
        else => |e| s.conn.fail(e),
    };
}

/// Bind one value to the parameter named `name` (with its prefix, e.g.
/// ":id"). As bindAt(), no reset.
pub fn bindName(s: *Stmt, name: []const u8, x: anytype) Error!void {
    const i = engine.bindParameterIndex(s.vm, name);
    if (i == 0) return s.conn.usage(error.UnknownParameter, "bind: no parameter {s}", .{name});
    return s.bindAt(i, x);
}

/// Reset, bind `args` and run the statement to completion, ignoring any
/// rows. For INSERT, UPDATE, DELETE and DDL.
pub fn exec(s: *Stmt, args: anytype) Error!void {
    try s.bind(args);
    while (try s.step()) {}
}

/// The number of parameters (sqlite3_bind_parameter_count()).
pub fn parameterCount(s: *const Stmt) usize {
    return engine.bindParameterCount(s.vm);
}

/// The name of parameter `i` (1-based) with its prefix, or null for `?`.
pub fn parameterName(s: *const Stmt, i: usize) ?[]const u8 {
    return engine.bindParameterName(s.vm, i);
}

/// The index of the parameter named `name` (prefix included), or null.
pub fn parameterIndex(s: *const Stmt, name: []const u8) ?usize {
    const i = engine.bindParameterIndex(s.vm, name);
    return if (i == 0) null else i;
}

// ================================================================ columns

/// The number of result columns (sqlite3_column_count()).
pub fn columnCount(s: *const Stmt) usize {
    return engine.columnCount(s.vm);
}

/// The name of result column `i` (the AS alias, if any). Valid until the
/// statement is finalized.
pub fn columnName(s: *Stmt, i: usize) []const u8 {
    return engine.columnName(s.vm, i) orelse "";
}

/// The declared type of result column `i` if it is a table column.
pub fn columnDecltype(s: *Stmt, i: usize) ?[]const u8 {
    return engine.columnDecltype(s.vm, i);
}

/// The datatype of column `i` of the current row.
pub fn columnKind(s: *Stmt, i: usize) Kind {
    return value.kindOf(engine.columnType(s.vm, i));
}

/// The index of the result column named `name` (ASCII case-insensitive).
pub fn columnIndex(s: *Stmt, name: []const u8) ?usize {
    for (0..s.columnCount()) |i| {
        if (std.ascii.eqlIgnoreCase(s.columnName(i), name)) return i;
    }
    return null;
}

/// Column `i` of the current row as `T`. Text and blobs are borrowed (see
/// the lifetime rules at the top of this file).
pub fn column(s: *Stmt, comptime T: type, i: usize) Error!T {
    return s.columnImpl(T, i, false, undefined);
}

/// Column `i` of the current row as `T`, with text and blobs copied with
/// `gpa`. Free the result with `xqlite.free(gpa, x)`.
pub fn columnAlloc(s: *Stmt, comptime T: type, gpa: Allocator, i: usize) Error!T {
    return s.columnImpl(T, i, true, gpa);
}

fn columnImpl(s: *Stmt, comptime T: type, i: usize, comptime owned: bool, gpa: Allocator) Error!T {
    if (i >= s.columnCount()) {
        return s.conn.usage(error.ColumnIndexOutOfRange, "column {d} of a statement with {d} columns", .{ i, s.columnCount() });
    }
    const src: value.ColumnSource = .{ .vm = s.vm, .i = i };
    const r = if (owned) value.readAlloc(T, gpa, src) else value.read(T, src);
    return r catch |err| switch (err) {
        error.OutOfMemory => s.conn.outOfMemory(),
        else => |e| s.conn.usage(e, "column {d} ({s}) read as {s}: {s}", .{ i, s.columnName(i), @typeName(T), @errorName(e) }),
    };
}

// =================================================================== rows

/// How a row type maps to the columns:
/// * a struct (not a tuple): each field by name, ASCII case-insensitively;
/// * a tuple (`struct { i64, []const u8 }`): field k is column k;
/// * an array (`[3]i64`): element k is column k;
/// * anything else (`i64`, `?[]const u8`, `Value` ...): column 0.
fn RowMap(comptime T: type) type {
    if (isNamedStruct(T)) return [@typeInfo(T).@"struct".field_names.len]u16;
    return void;
}

/// A struct read field by field (named or a tuple); Blob and ZeroBlob
/// are values of one column.
fn isRowStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and T != value.Blob and T != value.ZeroBlob;
}

fn isNamedStruct(comptime T: type) bool {
    return isRowStruct(T) and !@typeInfo(T).@"struct".is_tuple;
}

/// The column of each field of `T`, resolved by name once per statement
/// (and again after a schema change recompiles it), then taken from
/// the cache.
fn rowMap(s: *Stmt, comptime T: type) Error!RowMap(T) {
    if (RowMap(T) == void) return {};
    const names = @typeInfo(T).@"struct".field_names;
    const epoch = engine.reprepareCount(s.vm);
    if (s.row_cache.lookup(T, epoch)) |map| return map[0..names.len].*;
    var map: RowMap(T) = undefined;
    inline for (names, 0..) |name, k| {
        const i = s.columnIndex(name) orelse
            return s.conn.usage(error.ColumnNotFound, "row: no result column named \"{s}\" for field {s}.{s}", .{ name, @typeName(T), name });
        map[k] = @intCast(i);
    }
    s.row_cache.store(T, epoch, &map);
    return map;
}

fn readRow(s: *Stmt, comptime T: type, map: RowMap(T), comptime owned: bool, gpa: Allocator) Error!T {
    if (comptime isRowStruct(T)) {
        const info = @typeInfo(T).@"struct";
        if (info.is_tuple and info.field_names.len > s.columnCount()) {
            return s.conn.usage(error.ColumnIndexOutOfRange, "row: {s} has {d} fields but the statement {d} columns", .{ @typeName(T), info.field_names.len, s.columnCount() });
        }
        var out: T = undefined;
        inline for (info.field_names, info.field_types, 0..) |name, F, k| {
            const col: usize = if (comptime info.is_tuple) k else map[k];
            @field(out, name) = s.columnImpl(F, col, owned, gpa) catch |err| {
                if (owned) inline for (info.field_names[0..k]) |done| value.free(gpa, @field(out, done));
                return err;
            };
        }
        return out;
    } else if (comptime @typeInfo(T) == .array) {
        const n = @typeInfo(T).array.len;
        if (n > s.columnCount()) {
            return s.conn.usage(error.ColumnIndexOutOfRange, "row: {s} has {d} elements but the statement {d} columns", .{ @typeName(T), n, s.columnCount() });
        }
        var out: T = undefined;
        for (&out, 0..) |*x, k| {
            x.* = s.columnImpl(@typeInfo(T).array.child, k, owned, gpa) catch |err| {
                if (owned) for (out[0..k]) |done| value.free(gpa, done);
                return err;
            };
        }
        return out;
    } else {
        return s.columnImpl(T, 0, owned, gpa);
    }
}

/// The current row as `T` (see RowMap for how fields map to columns).
/// Text and blobs are borrowed until the next step.
pub fn row(s: *Stmt, comptime T: type) Error!T {
    return s.readRow(T, try s.rowMap(T), false, undefined);
}

/// The current row as `T`, with text and blobs copied with `gpa`. Free it
/// with `xqlite.free(gpa, row)`.
pub fn rowAlloc(s: *Stmt, comptime T: type, gpa: Allocator) Error!T {
    return s.readRow(T, try s.rowMap(T), true, gpa);
}

/// Step and read the next row as `T`, or null when the statement is done
/// (then the next call starts it again, as step() does; an Iterator
/// stops instead). The field-to-column mapping of a struct `T` is
/// cached in the statement, as for an Iterator.
pub fn next(s: *Stmt, comptime T: type) Error!?T {
    if (!try s.step()) return null;
    return try s.row(T);
}

/// An iterator over the remaining rows of the statement, as `T`.
pub fn iterator(s: *Stmt, comptime T: type) Iterator(T) {
    return .{ .stmt = s };
}

/// Iterates over the rows of a statement. The column-to-field mapping of
/// a struct `T` is resolved once, on the first row, and cached in the
/// statement.
pub fn Iterator(comptime T: type) type {
    return struct {
        stmt: *Stmt,
        /// The statement is done: next() keeps returning null rather than
        /// starting it again.
        done: bool = false,

        const Self = @This();

        /// The next row, borrowing its text and blobs: they are valid
        /// until the next call to next() or nextAlloc() (or any other step,
        /// reset or finalize of the statement).
        pub fn next(it: *Self) Error!?T {
            return it.nextImpl(false, undefined);
        }

        /// The next row, with its text and blobs copied with `gpa`: the
        /// caller owns it and frees it with `xqlite.free(gpa, row)`.
        pub fn nextAlloc(it: *Self, gpa: Allocator) Error!?T {
            return it.nextImpl(true, gpa);
        }

        fn nextImpl(it: *Self, comptime owned: bool, gpa: Allocator) Error!?T {
            if (it.done) return null;
            if (!try it.stmt.step()) {
                it.done = true;
                return null;
            }
            return try it.stmt.readRow(T, try it.stmt.rowMap(T), owned, gpa);
        }
    };
}

/// A cache of the column or parameter of each field of one struct type,
/// valid until the statement is recompiled (engine.reprepareCount()).
/// Structs with more than `max_fields` fields are not cached.
const FieldCache = struct {
    /// typeId() of the struct; null while empty.
    key: ?*const anyopaque = null,
    epoch: u32 = 0,
    map: [max_fields]u16 = undefined,

    const max_fields = 32;

    fn lookup(c: *const FieldCache, comptime T: type, epoch: u32) ?*const [max_fields]u16 {
        if (c.key != typeId(T) or c.epoch != epoch) return null;
        return &c.map;
    }

    fn store(c: *FieldCache, comptime T: type, epoch: u32, map: []const u16) void {
        if (map.len > max_fields) return;
        c.* = .{ .key = typeId(T), .epoch = epoch };
        @memcpy(c.map[0..map.len], map);
    }
};

/// An address that stands for type `T` at run time.
fn typeId(comptime T: type) *const anyopaque {
    return &struct {
        const Type = T;
        var id: u8 = 0;
    }.id;
}

/// The SQL text of the statement.
pub fn sql(s: *const Stmt) []const u8 {
    return engine.sqlText(s.vm) orelse "";
}

/// Whether the statement makes no direct change to the database
/// (sqlite3_stmt_readonly()).
pub fn isReadOnly(s: *const Stmt) bool {
    return engine.stmtReadonly(s.vm);
}

/// The engine's statement, for the low-level API (`xqlite.sql.api`).
pub fn raw(s: *Stmt) *engine.Vm {
    return s.vm;
}
