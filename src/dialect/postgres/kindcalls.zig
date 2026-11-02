//! The calls whose meaning depends on the type of an argument the value
//! does not tell (a timestamp, a timestamptz and a date are all TEXT; an
//! integer is an integer, a bigint or a smallint): overload.zig (call())
//! makes them calls of engine functions told that type.
//!
//!  - to_char(x, t): xq_pg_to_char(x, t, kind) (formatting.zig);
//!  - gcd(a, b), lcm(a, b): xq_pg_gcd(a, b, bits), xq_pg_lcm(a, b, bits),
//!    `bits` 32 for integers, 64 if one is a bigint, 0 if one is a
//!    numeric (builtins.zig);
//!  - timezone(zone, x) (`x AT TIME ZONE zone`): xq_pg_timezone(zone, x,
//!    kind) (dtfuncs.zig).
//!
//! A call of arguments of no known type stays: the function reads its
//! values by their storage.

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const int = @import("../../sql/sqlite_int.zig");
const operand = @import("operand.zig");
const formatting = @import("formatting.zig");

const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Kind = formatting.Kind;

/// Make call `e` of `n` (lower case) with `items` the engine function's;
/// whether it did.
pub fn call(c: *Ctx, e: *Expr, n: []const u8, items: []int.ExprListItem) Error!bool {
    const eql = std.mem.eql;
    if (items.len == 2 and eql(u8, n, "to_char")) {
        const x = items[0].expr.?;
        const k = Kind.of(operand.logical(c, x));
        if (k == .auto) return false;
        try c.toCall(e, "xq_pg_to_char", &.{ x, items[1].expr.?, try operand.int32(c, @backingInt(k)) });
        return true;
    }
    if (items.len == 2 and (eql(u8, n, "gcd") or eql(u8, n, "lcm"))) {
        const x = items[0].expr.?;
        const y = items[1].expr.?;
        const lx = operand.logical(c, x);
        const ly = operand.logical(c, y);
        const bits: i32 = if (lx == .numeric or ly == .numeric)
            0
        else if (lx == .int8 or ly == .int8)
            64
        else if (typing.intWidth(lx) != null and (typing.intWidth(ly) != null or operand.untyped(y)))
            32
        else if (typing.intWidth(ly) != null and operand.untyped(x))
            32
        else
            return false;
        try c.toCall(e, if (n[0] == 'g') "xq_pg_gcd" else "xq_pg_lcm", &.{ x, y, try operand.int32(c, bits) });
        return true;
    }
    if (items.len == 2 and eql(u8, n, "timezone")) {
        const x = items[1].expr.?;
        const k = Kind.of(operand.logical(c, x));
        if (k == .auto) return false;
        try c.toCall(e, "xq_pg_timezone", &.{ items[0].expr.?, x, try operand.int32(c, @backingInt(k)) });
        return true;
    }
    return false;
}
