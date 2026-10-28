//! Operations shared by the bit-flag sets of the port.
//!
//! Each set of C flag macros (MEM_*, EP_*, SF_*, ...) is a
//! `packed struct(uN)` of bools, one per C bit and at the same bit
//! position, so that a single flag is tested and set as a field
//! (`m.flags.Int`, `e.flags.Leaf = true`). Tests and updates of several
//! flags at once (C: `(x & (A|B))!=0`, `x |= A|B`) go through the methods
//! below, which work on the backing integer: one AND, OR or compare, as in
//! C. A flag set declares them with
//!
//!     const ops = flags.Ops(@This());
//!     pub const int = ops.int;
//!     ...
//!
//! and checks its layout against the C constants with checkBits().

const std = @import("std");

/// The methods of the packed-struct flag set `T`.
pub fn Ops(comptime T: type) type {
    const I = @typeInfo(T).@"struct".backing_integer.?;
    return struct {
        /// The flags as C stores them.
        pub inline fn int(f: T) I {
            return @bitCast(f);
        }

        /// The flags of the C value `i`.
        pub inline fn fromInt(i: I) T {
            return @bitCast(i);
        }

        /// Whether any flag of `m` is set (C: `(f & m)!=0`).
        pub inline fn intersects(f: T, m: T) bool {
            return int(f) & int(m) != 0;
        }

        /// Whether every flag of `m` is set (C: `(f & m)==m`).
        pub inline fn contains(f: T, m: T) bool {
            return int(f) & int(m) == int(m);
        }

        /// Whether no flag is set (C: `f==0`).
        pub inline fn isEmpty(f: T) bool {
            return int(f) == 0;
        }

        /// The flags of `f` and of `m` (C: `f | m`).
        pub inline fn with(f: T, m: T) T {
            return fromInt(int(f) | int(m));
        }

        /// The flags of `f` not in `m` (C: `f & ~m`).
        pub inline fn without(f: T, m: T) T {
            return fromInt(int(f) & ~int(m));
        }

        /// The flags of `f` also in `m` (C: `f & m`).
        pub inline fn only(f: T, m: T) T {
            return fromInt(int(f) & int(m));
        }

        /// Sets the flags of `m` (C: `f |= m`).
        pub inline fn set(f: *T, m: T) void {
            f.* = with(f.*, m);
        }

        /// Clears the flags of `m` (C: `f &= ~m`).
        pub inline fn clear(f: *T, m: T) void {
            f.* = without(f.*, m);
        }
    };
}

/// Checks at compile time that each field of the flag set `T` sits at the
/// bits of the C constant of the same name in `c`, an anonymous struct of
/// integers (`.{ .Null = 0x0001, ... }`): a bool field at the one bit of
/// its constant, a wider field at the bits of its mask. Fields named with
/// a leading underscore are padding (bits C leaves unused) and have no
/// constant. Every constant of `c` must be a field.
pub fn checkBits(comptime T: type, comptime c: anytype) void {
    comptime {
        const info = @typeInfo(T).@"struct";
        const I = info.backing_integer.?;
        for (info.field_names, info.field_types) |name, F| {
            if (name[0] == '_') continue;
            if (!@hasField(@TypeOf(c), name)) @compileError(@typeName(T) ++ "." ++ name ++ " has no C constant");
            const want: I = @field(c, name);
            const got: I = ((@as(I, 1) << @bitSizeOf(F)) - 1) << @bitOffsetOf(T, name);
            if (got != want) @compileError(std.fmt.comptimePrint("{s}.{s} is 0x{x}, C has 0x{x}", .{ @typeName(T), name, got, want }));
        }
        for (@typeInfo(@TypeOf(c)).@"struct".field_names) |name| {
            if (!@hasField(T, name)) @compileError(@typeName(T) ++ " lacks field " ++ name);
        }
    }
}

test Ops {
    const F = packed struct(u8) {
        a: bool = false,
        b: bool = false,
        _2: u5 = 0,
        h: bool = false,

        const ops = Ops(@This());
        pub const int = ops.int;
        pub const fromInt = ops.fromInt;
        pub const intersects = ops.intersects;
        pub const contains = ops.contains;
        pub const with = ops.with;
        pub const without = ops.without;
        pub const only = ops.only;
        pub const set = ops.set;
        pub const clear = ops.clear;
    };
    comptime checkBits(F, .{ .a = 0x01, .b = 0x02, .h = 0x80 });
    var f: F = .{ .a = true };
    try std.testing.expect(f.intersects(.{ .a = true, .b = true }));
    try std.testing.expect(!f.contains(.{ .a = true, .b = true }));
    f.set(.{ .b = true, .h = true });
    try std.testing.expectEqual(@as(u8, 0x83), f.int());
    f.clear(.{ .a = true });
    try std.testing.expectEqual(F{ .b = true, .h = true }, f);
    try std.testing.expectEqual(F{ .h = true }, f.only(.{ .h = true, .a = true }));
    try std.testing.expectEqual(F.fromInt(0x82), f.without(.{}).with(.{}));
}
