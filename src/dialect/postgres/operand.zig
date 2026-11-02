//! What overload.zig and the type modules (repr/*.zig) ask of a resolved,
//! typed Expr: its type, whether it is of no type of its own, which
//! function it calls.

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const int = @import("../../sql/sqlite_int.zig");
const expr_mod = @import("../../sql/expr.zig");
const ctypes = @import("../../sql/types.zig");
const pg_typing = @import("typing.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Logical = ctypes.Logical;

/// The logical type of `e` (unknown if it has none).
pub fn logical(c: *const Ctx, e: *const Expr) Logical {
    return typing.typeOf(c.p.db, e.xq_type).logical;
}

/// An operand of no type of its own (PostgreSQL's unknown): a string
/// literal, NULL, a parameter of no known type.
pub fn untyped(e: *const Expr) bool {
    return e.op == TK.STRING or e.op == TK.NULL or (e.op == TK.VARIABLE and e.xq_type == typing.unknown);
}

/// Whether `a op b` is an operator of type `l`: an operand of `l`, the
/// other of `l` or of no type.
pub fn pairOf(c: *const Ctx, a: *const Expr, b: *const Expr, l: Logical) bool {
    const la = logical(c, a);
    const lb = logical(c, b);
    return (la == l and (lb == l or untyped(b))) or (lb == l and untyped(a));
}

/// The name of call `e`, lower case, without PostgreSQL's prefix in the
/// text of the schema (pg_typing.ownName()); "" if it is too long to be
/// one of ours.
pub fn nameOf(e: *const Expr, buf: *[64]u8) []const u8 {
    const z = e.token();
    if (z.len > buf.len) return "";
    return pg_typing.ownName(std.ascii.lowerString(buf, z));
}

pub fn isCall(e: *const Expr) bool {
    return (e.op == TK.FUNCTION or e.op == TK.AGG_FUNCTION) and e.useUToken() and e.useXList();
}

/// Whether `e` calls `name`.
pub fn calls(e: *const Expr, name: []const u8) bool {
    if (!isCall(e)) return false;
    var buf: [64]u8 = undefined;
    return std.mem.eql(u8, nameOf(e, &buf), name);
}

pub fn args(e: *const Expr) []int.ExprListItem {
    return if (e.x.list) |l| l.slice() else &.{};
}

pub fn int32(c: *Ctx, v: i32) Error!*Expr {
    const x = try expr_mod.exprInt32(c.p.arena, v);
    x.xq_type = typing.plain(.int4);
    return x;
}

pub fn typeOfExpr(c: *const Ctx, e: *const Expr) ctypes.Type {
    return typing.typeOf(c.p.db, e.xq_type);
}
