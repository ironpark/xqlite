//! The operands of VDBE instructions as types of their own: a register,
//! a cursor, a label and an address are all numbers in the program, but
//! the code generator should not be able to pass one for another.
//! `OP.kinds()` (opcodes.zig) says what each operand of each opcode is,
//! and `aux.emit()` checks its arguments against it when the statement
//! is compiled.
//!
//! `.from()` and `.int()` convert where the number is all there is: the
//! cursor and register fields of the parse tree (Expr.i_table,
//! SrcItem.i_cursor), the operands of an instruction already coded, an
//! operand whose meaning depends on its opcode, a number written into
//! text.

const std = @import("std");
const OP = @import("opcodes.zig").OP;

/// A register: r[1] is the first, `none` (0) is no register.
pub const Reg = enum(i32) {
    none = 0,
    _,

    pub fn from(i: i32) Reg {
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(r: Reg) i32 {
        return @backingInt(r);
    }

    /// The register `i` after this one, of a run of registers.
    pub fn at(r: Reg, i: anytype) Reg {
        return @fromBackingInt(@intCast(@backingInt(r) + @as(i32, @intCast(i))));
    }

    pub fn isNone(r: Reg) bool {
        return r == .none;
    }
};

/// A cursor number.
pub const Cursor = enum(i32) {
    /// Cursor 0, the first a statement allocates: where a small fixed
    /// program (the schema table's, the AUTOINCREMENT counters',
    /// sqlite3_blob_open()'s) opens its table without allocating it.
    first = 0,
    _,

    pub fn from(i: i32) Cursor {
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(c: Cursor) i32 {
        return @backingInt(c);
    }

    /// The cursor `i` after this one (the indexes of a table follow it).
    pub fn at(c: Cursor, i: anytype) Cursor {
        return @fromBackingInt(@intCast(@backingInt(c) + @as(i32, @intCast(i))));
    }

    /// How far after `base` this cursor is: the `i` of `base.at(i)`.
    pub fn offsetFrom(c: Cursor, base: Cursor) usize {
        return @intCast(@backingInt(c) - @backingInt(base));
    }
};

/// A place in the program that is not known yet (aux.newLabel()): a
/// negative number until the program is finished.
pub const Label = enum(i32) {
    _,

    pub fn from(i: i32) Label {
        std.debug.assert(i < 0);
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(l: Label) i32 {
        return @backingInt(l);
    }
};

/// The address of an instruction.
pub const Addr = enum(i32) {
    _,

    pub fn from(i: i32) Addr {
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(a: Addr) i32 {
        return @backingInt(a);
    }

    /// The instruction `n` after this one.
    pub fn plus(a: Addr, n: anytype) Addr {
        return @fromBackingInt(@intCast(@backingInt(a) + @as(i32, @intCast(n))));
    }
};

/// Where a jump goes, for a parameter that takes a Label or an Addr
/// (`Jump.of()`); `none` (0) is no jump.
pub const Jump = enum(i32) {
    none = 0,
    _,

    pub fn int(j: Jump) i32 {
        return @backingInt(j);
    }

    /// A Label or an Addr as a Jump, for a place that takes either.
    pub fn of(x: anytype) Jump {
        if (@TypeOf(x) != Label and @TypeOf(x) != Addr and @TypeOf(x) != Jump) @compileError("not a Label or an Addr: " ++ @typeName(@TypeOf(x)));
        return @fromBackingInt(x.int());
    }
};

/// What an operand is.
pub const Kind = enum {
    /// A number, or not used.
    int,
    reg,
    cursor,
    /// Where to jump: a Label or an Addr.
    jump,
    /// An address that is not P2 of a jump, so a label in it would never
    /// be resolved: an Addr only.
    addr,
};

/// The number of an argument of aux.emit() for an operand of `kind`.
pub inline fn value(comptime op: ?OP, comptime n: usize, comptime kind: Kind, arg: anytype) i32 {
    const T = @TypeOf(arg);
    const name = (if (op) |o| @tagName(o) else "the opcode's") ++ " P" ++ .{'1' + n};
    // 0 is "not used" for an operand of any kind but a cursor, where 0 is
    // a cursor like any other (Cursor.first).
    if (T == comptime_int) {
        if (arg != 0 and kind != .int) @compileError(name ++ " is a " ++ @tagName(kind) ++ ", not a number");
        if (kind == .cursor) @compileError(name ++ " is a cursor, not a number (Cursor.first is cursor 0)");
        return arg;
    }
    switch (kind) {
        .int => switch (@typeInfo(T)) {
            .int => return @intCast(arg),
            .bool => return @intFromBool(arg),
            else => @compileError(name ++ " is a number, not " ++ @typeName(T)),
        },
        .reg => if (T != Reg) @compileError(name ++ " is a register, not " ++ @typeName(T)),
        .cursor => if (T != Cursor) @compileError(name ++ " is a cursor, not " ++ @typeName(T)),
        .jump => if (T != Label and T != Addr and T != Jump) @compileError(name ++ " is a jump (Label or Addr), not " ++ @typeName(T)),
        .addr => if (T != Addr) @compileError(name ++ " is an address, not " ++ @typeName(T)),
    }
    return @backingInt(arg);
}
