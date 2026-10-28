//! Values, and the comptime mapping between Zig types and SQLite values.
//!
//! | Zig type                          | bound as / read from                  |
//! | --------------------------------- | ------------------------------------- |
//! | `i8`..`i64`, `u8`..`u64`, any int | INTEGER (range-checked both ways)     |
//! | `comptime_int`                    | INTEGER (checked at compile time)     |
//! | `f16`..`f128`, `comptime_float`   | REAL                                  |
//! | `bool`                            | INTEGER 0 / 1 (read: nonzero is true) |
//! | `[]const u8`, `[:0]const u8`, string literals | TEXT                      |
//! | `Blob`                            | BLOB                                  |
//! | `ZeroBlob`                        | BLOB of N zero bytes (bind/result)    |
//! | `?T`                              | NULL when null, else as `T`           |
//! | `@TypeOf(null)`                   | NULL (bind/result)                    |
//! | enum                              | TEXT (the tag name), or INTEGER if the enum declares `pub const xqlite_storage: EnumStorage = .integer` or is non-exhaustive; reads accept either |
//! | `Value`                           | whatever the value is                 |
//!
//! Reads follow SQLite's conversions (sqlite3_column_int64() of the text
//! '12' is 12), with two Zig additions: NULL read into a non-optional type
//! is `error.UnexpectedNull`, and an integer that does not fit the target
//! type is `error.IntegerOverflow` instead of being truncated.
//!
//! Borrowed reads (`[]const u8`, `Blob`, `Value.text` ...) point into the
//! engine's memory and are valid until the statement is stepped, reset or
//! finalized; the `*Alloc` variants copy them with the caller's allocator.

const std = @import("std");
const engine = @import("engine.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const UsageError = errors.UsageError;

/// The fundamental datatypes of SQLite (sqlite3_column_type()).
pub const Kind = enum { integer, float, text, blob, null };

/// A dynamically typed SQLite value. Text and blobs are borrowed unless
/// the value came from an `*Alloc` function.
pub const Value = union(Kind) {
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    null,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .integer => |x| x == b.integer,
            .float => |x| x == b.float,
            .text => |x| std.mem.eql(u8, x, b.text),
            .blob => |x| std.mem.eql(u8, x, b.blob),
            .null => true,
        };
    }
};

/// Wraps bytes so that they bind as (and are read from) a BLOB rather than
/// TEXT.
pub const Blob = struct {
    data: []const u8,

    pub fn init(data: []const u8) Blob {
        return .{ .data = data };
    }
};

/// Binds (or returns, from a function) a BLOB of `len` zero bytes
/// without materializing it (sqlite3_bind_zeroblob()).
pub const ZeroBlob = struct {
    len: u31,
};

/// How an enum is stored. Text by default; declare
/// `pub const xqlite_storage: xqlite.EnumStorage = .integer;` in the enum
/// to store its integer value instead.
pub const EnumStorage = enum { text, integer };

pub fn enumStorage(comptime E: type) EnumStorage {
    if (@hasDecl(E, "xqlite_storage")) return E.xqlite_storage;
    return if (@typeInfo(E).@"enum".mode == .nonexhaustive) .integer else .text;
}

// =============================================================== sources

/// A column of the current row, read through the statement.
pub const ColumnSource = struct {
    vm: *engine.Vm,
    i: usize,

    pub fn kind(s: ColumnSource) Kind {
        return kindOf(engine.columnType(s.vm, s.i));
    }
    pub fn int64(s: ColumnSource) i64 {
        return engine.columnInt64(s.vm, s.i);
    }
    pub fn double(s: ColumnSource) f64 {
        return engine.columnDouble(s.vm, s.i);
    }
    pub fn text(s: ColumnSource) ?[:0]const u8 {
        return engine.columnText(s.vm, s.i);
    }
    pub fn blob(s: ColumnSource) ?[]const u8 {
        return engine.columnBlob(s.vm, s.i);
    }
};

/// A value object: a function argument or a constraint value.
pub const MemSource = struct {
    m: *engine.Mem,

    pub fn kind(s: MemSource) Kind {
        return kindOf(engine.valueType(s.m));
    }
    pub fn int64(s: MemSource) i64 {
        return engine.valueInt64(s.m);
    }
    pub fn double(s: MemSource) f64 {
        return engine.valueDouble(s.m);
    }
    pub fn text(s: MemSource) ?[:0]const u8 {
        return engine.valueText(s.m);
    }
    pub fn blob(s: MemSource) ?[]const u8 {
        return engine.valueBlob(s.m);
    }
};

pub fn kindOf(t: i32) Kind {
    return switch (t) {
        engine.type_integer => .integer,
        engine.type_float => .float,
        engine.type_text => .text,
        engine.type_blob => .blob,
        else => .null,
    };
}

// ================================================================= reads

pub const ReadError = UsageError || error{OutOfMemory};

/// Whether `T` is a byte slice read as text (`[]const u8`, `[:0]const u8`,
/// and, for owned reads, `[]u8` and `[:0]u8`).
fn isByteSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
}

fn hasZeroSentinel(comptime T: type) bool {
    const p = @typeInfo(T).pointer;
    return p.sentinel_ptr != null and p.sentinel().? == 0;
}

/// Whether reading `T` borrows engine memory: it is or contains a byte
/// slice, a `Blob` or a `Value`.
pub fn borrows(comptime T: type) bool {
    if (T == Value or T == Blob) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| borrows(o.child),
        .pointer => isByteSlice(T),
        .array => |a| borrows(a.child),
        .@"struct" => |s| blk: {
            for (s.field_types) |F| if (borrows(F)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn text(src: anytype) ReadError![:0]const u8 {
    return src.text() orelse error.OutOfMemory;
}

/// Read the value of `src` as `T`, borrowing text and blobs.
pub fn read(comptime T: type, src: anytype) ReadError!T {
    return readImpl(T, src, false, undefined);
}

/// Read the value of `src` as `T`, copying text and blobs with `gpa`.
/// Free the result with `free()`.
pub fn readAlloc(comptime T: type, gpa: Allocator, src: anytype) ReadError!T {
    return readImpl(T, src, true, gpa);
}

fn readImpl(comptime T: type, src: anytype, comptime owned: bool, gpa: Allocator) ReadError!T {
    const k = src.kind();
    if (T == Value) {
        return switch (k) {
            .integer => .{ .integer = src.int64() },
            .float => .{ .float = src.double() },
            .text => .{ .text = try maybeDupe(owned, gpa, try text(src)) },
            .blob => .{ .blob = try maybeDupe(owned, gpa, src.blob() orelse "") },
            .null => .null,
        };
    }
    if (@typeInfo(T) == .optional) {
        if (k == .null) return null;
        return try readImpl(@typeInfo(T).optional.child, src, owned, gpa);
    }
    if (k == .null) return error.UnexpectedNull;
    if (T == Blob) {
        // sqlite3_column_blob() is null for a zero-length value.
        return .{ .data = try maybeDupe(owned, gpa, src.blob() orelse "") };
    }
    switch (@typeInfo(T)) {
        .int => return std.math.cast(T, src.int64()) orelse error.IntegerOverflow,
        .float => return @floatCast(src.double()),
        .bool => return src.int64() != 0,
        .@"enum" => {
            if (k == .integer or k == .float) {
                return std.enums.fromInt(T, src.int64()) orelse error.InvalidEnum;
            }
            return std.meta.stringToEnum(T, try text(src)) orelse error.InvalidEnum;
        },
        .pointer => |p| {
            if (comptime !isByteSlice(T)) @compileError("xqlite: cannot read a column as " ++ @typeName(T));
            const z = try text(src);
            if (owned) {
                if (comptime hasZeroSentinel(T)) return try gpa.dupeSentinel(u8, z, 0);
                return try gpa.dupe(u8, z);
            }
            if (!p.attrs.@"const") @compileError("xqlite: a borrowed read cannot produce mutable " ++ @typeName(T) ++ "; use []const u8 or an *Alloc read");
            if (comptime hasZeroSentinel(T)) return z;
            return z[0..z.len];
        },
        else => @compileError("xqlite: cannot read a column as " ++ @typeName(T)),
    }
}

fn maybeDupe(comptime owned: bool, gpa: Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    if (!owned) return s;
    return gpa.dupe(u8, s);
}

/// Free a value returned by an `*Alloc` read (`Stmt.columnAlloc()`,
/// `Stmt.rowAlloc()`, `Iterator.nextAlloc()`, `Db.oneAlloc()` ...):
/// every byte slice, `Blob` and `Value` text or blob in it, recursively
/// through structs and optionals.
pub fn free(gpa: Allocator, value: anytype) void {
    const T = @TypeOf(value);
    if (T == Value) {
        switch (value) {
            .text, .blob => |s| gpa.free(s),
            else => {},
        }
        return;
    }
    if (T == Blob) return gpa.free(value.data);
    switch (@typeInfo(T)) {
        .optional => if (value) |v| free(gpa, v),
        .pointer => if (comptime isByteSlice(T)) gpa.free(value),
        .array => for (value) |x| free(gpa, x),
        .@"struct" => |s| inline for (s.field_names) |name| free(gpa, @field(value, name)),
        else => {},
    }
}

// ================================================================= binds

/// Bind `x` to parameter `i` (1-based) of `vm`: the engine's error, or
/// IntegerOverflow for an integer SQLite cannot hold.
pub fn bind(vm: *engine.Vm, i: usize, x: anytype) (engine.Error || error{IntegerOverflow})!void {
    const T = @TypeOf(x);
    if (T == Value) {
        return switch (x) {
            .integer => |v| engine.bindInt64(vm, i, v),
            .float => |v| engine.bindDouble(vm, i, v),
            .text => |v| engine.bindText(vm, i, v),
            .blob => |v| engine.bindBlob(vm, i, v),
            .null => engine.bindNull(vm, i),
        };
    }
    if (T == Blob) return engine.bindBlob(vm, i, x.data);
    if (T == ZeroBlob) return engine.bindZeroblob(vm, i, x.len);
    switch (@typeInfo(T)) {
        .null => return engine.bindNull(vm, i),
        .optional => return if (x) |v| bind(vm, i, v) else engine.bindNull(vm, i),
        .comptime_int => {
            if (x < std.math.minInt(i64) or x > std.math.maxInt(i64)) @compileError("xqlite: integer literal does not fit a 64-bit SQLite integer");
            return engine.bindInt64(vm, i, x);
        },
        .int => return engine.bindInt64(vm, i, std.math.cast(i64, x) orelse return error.IntegerOverflow),
        .comptime_float, .float => return engine.bindDouble(vm, i, @floatCast(x)),
        .bool => return engine.bindInt64(vm, i, @intFromBool(x)),
        .@"enum" => return switch (comptime enumStorage(T)) {
            .integer => engine.bindInt64(vm, i, std.math.cast(i64, @backingInt(x)) orelse return error.IntegerOverflow),
            .text => engine.bindText(vm, i, @tagName(x)),
        },
        .pointer => return engine.bindText(vm, i, asBytes(x)),
        else => @compileError("xqlite: cannot bind a value of type " ++ @typeName(T)),
    }
}

/// `x`, a byte slice or a pointer to a byte array (a string literal), as
/// a slice.
fn asBytes(x: anytype) []const u8 {
    const T = @TypeOf(x);
    const p = @typeInfo(T).pointer;
    if (p.size == .slice and p.child == u8) return x;
    if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return x;
    @compileError("xqlite: cannot use " ++ @typeName(T) ++ " as text; wrap bytes in xqlite.Blob for a BLOB");
}

// =============================================================== results

/// Set the result of a function call (or virtual table column) to `x`.
/// Text and blobs are copied. An error is reported as the function's
/// error with the error name as message (OutOfMemory as SQLITE_NOMEM).
pub fn setResult(ctx: *engine.Context, x: anytype) void {
    const T = @TypeOf(x);
    if (T == Value) {
        switch (x) {
            .integer => |v| engine.resultInt64(ctx, v),
            .float => |v| engine.resultDouble(ctx, v),
            .text => |v| engine.resultText(ctx, v),
            .blob => |v| engine.resultBlob(ctx, v),
            .null => engine.resultNull(ctx),
        }
        return;
    }
    if (T == Blob) return engine.resultBlob(ctx, x.data);
    if (T == ZeroBlob) return engine.resultZeroblob(ctx, x.len);
    switch (@typeInfo(T)) {
        .void, .null => engine.resultNull(ctx),
        .optional => if (x) |v| setResult(ctx, v) else engine.resultNull(ctx),
        .error_union => if (x) |v| setResult(ctx, v) else |err| setError(ctx, err),
        .comptime_int, .int => {
            const v = std.math.cast(i64, x) orelse return engine.resultError(ctx, "integer overflow");
            engine.resultInt64(ctx, v);
        },
        .comptime_float, .float => engine.resultDouble(ctx, @floatCast(x)),
        .bool => engine.resultInt64(ctx, @intFromBool(x)),
        .@"enum" => switch (comptime enumStorage(T)) {
            .integer => engine.resultInt64(ctx, std.math.cast(i64, @backingInt(x)) orelse return engine.resultError(ctx, "integer overflow")),
            .text => engine.resultText(ctx, @tagName(x)),
        },
        .pointer => engine.resultText(ctx, asBytes(x)),
        else => @compileError("xqlite: cannot return a value of type " ++ @typeName(T)),
    }
}

/// Report `err` as the error of a function call.
pub fn setError(ctx: *engine.Context, err: anyerror) void {
    switch (err) {
        error.OutOfMemory => engine.resultErrorNomem(ctx),
        error.TooBig => engine.resultErrorTooBig(ctx),
        else => engine.resultError(ctx, @errorName(err)),
    }
}
