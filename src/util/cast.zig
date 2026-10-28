//! Narrowing casts that work around ziglang/zig#37127. Zig 0.17 lowers an
//! @intCast from a signed integer to a narrower unsigned one as
//! `trunc nsw`, so a value with the top bit of the destination set (255
//! into a u8, 15 into a u4) is poison in optimized builds, and comparisons
//! with it are folded away. Going through the unsigned type of the
//! source's width first gives `trunc nuw`. Use these for such casts (an
//! i32 operand into a small enum or int); drop them once the compiler is
//! fixed.

const std = @import("std");

/// @intCast(x) to `T`.
pub inline fn intCast(comptime T: type, x: anytype) T {
    const From = @TypeOf(x);
    const from = @typeInfo(From).int;
    const to = @typeInfo(T).int;
    if (from.signedness == .signed and to.signedness == .unsigned and to.bits < from.bits) {
        const U = @Int(.unsigned, from.bits);
        return @intCast(@as(U, @intCast(x)));
    }
    return @intCast(x);
}

/// @enumFromInt(x) to `E`.
pub inline fn enumFromInt(comptime E: type, x: anytype) E {
    return @enumFromInt(intCast(@typeInfo(E).@"enum".tag_type, x));
}

test "values with the top bit set survive" {
    const S = struct {
        noinline fn top(p: *const i32) bool {
            return intCast(u8, p.*) == 255;
        }
        noinline fn tag(p: *const i32) bool {
            return enumFromInt(enum(u4) { a = 0, b = 15 }, p.*) == .b;
        }
    };
    var v: i32 = 255;
    std.mem.doNotOptimizeAway(&v);
    try std.testing.expect(S.top(&v));
    v = 15;
    try std.testing.expect(S.tag(&v));
}
