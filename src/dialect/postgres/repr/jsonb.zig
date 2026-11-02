//! PostgreSQL's jsonb (postgres/repr.zig's descriptor and the choices
//! overload.zig makes for it): SQLite's JSONB in a BLOB column
//! (src/dialect/jsonb.zig's canonical form), normalized text in the TEXT
//! column of an older table. Comparisons, IN, BETWEEN and ORDER BY
//! compare the sort keys (xq_pg_jsonb_key()), which read either.

const std = @import("std");
const typing = @import("../../../sql/typing.zig");
const int = @import("../../../sql/sqlite_int.zig");
const repr = @import("../repr.zig");
const operand = @import("../operand.zig");

const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Type = @import("../../../sql/types.zig").Type;
const logical = operand.logical;
const untyped = operand.untyped;
const pairOf = operand.pairOf;
const calls = operand.calls;

pub const jsonb_collation = "xq_pg_jsonb";

/// Whether `a op b` is jsonb's operator: a jsonb operand, the other
/// jsonb or of no type.
pub fn jsonbPair(c: *const Ctx, a: *const Expr, b: *const Expr) bool {
    return pairOf(c, a, b, .jsonb);
}

/// The sort key of jsonb (jfuncs.zig): what its comparisons and ORDER BY
/// compare, whether the value is a JSONB blob or text.
pub const jsonb_key = "xq_pg_jsonb_key";

/// `j IN (a, b ...)`, `j BETWEEN a AND b` of jsonb: the sort keys, as
/// compare().
pub fn keyList(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    if (logical(c, l) != .jsonb or calls(l, jsonb_key) or e.useXSelect()) return false;
    const list = (if (e.useXList()) e.x.list else null) orelse return false;
    for (list.slice()) |item| {
        const x = item.expr orelse return false;
        if (logical(c, x) != .jsonb and !untyped(x)) return false;
    }
    e.left = try c.call(jsonb_key, &.{l});
    for (list.slice()) |*item| item.expr = try c.call(jsonb_key, &.{item.expr.?});
    return true;
}

/// The functions that write any value as its text (PostgreSQL's output
/// function): a jsonb argument is its text (xq_pg_jsonb_text()).
pub fn textArgs(c: *Ctx, n: []const u8, items: []int.ExprListItem) Error!bool {
    const takes_text = std.mem.eql(u8, n, "concat") or std.mem.eql(u8, n, "concat_ws") or std.mem.eql(u8, n, "format");
    if (!takes_text) return false;
    var changed = false;
    for (items) |*item| {
        const x = item.expr orelse continue;
        if (logical(c, x) != .jsonb) continue;
        item.expr = try c.call("xq_pg_jsonb_text", &.{x});
        changed = true;
    }
    return changed;
}

/// `CAST(x AS TEXT)` of jsonb (x::text, ::varchar): its text, as the
/// JSONB blob of a column is not (xq_pg_jsonb_text()).
pub fn castText(c: *Ctx, e: *Expr) Error!bool {
    const x = e.left orelse return false;
    if (logical(c, x) != .jsonb or calls(x, "xq_pg_jsonb_text")) return false;
    if (!e.useUToken() or !std.ascii.eqlIgnoreCase(e.token(), "TEXT")) return false;
    e.left = try c.call("xq_pg_jsonb_text", &.{x});
    return true;
}

/// Whether `e` is of a text type.
pub fn isText(c: *const Ctx, e: *const Expr) bool {
    return switch (logical(c, e)) {
        .text, .varchar, .char => true,
        else => false,
    };
}

pub const desc: repr.TypeRepr = .{
    .logical = .jsonb,
    .store = store,
    .list = keyList,
    .cast = castText,
    .order_key = jsonb_key,
    .order_collation = orderCollation,
};

/// jsonb as the column keeps it: JSONB in a BLOB column, normalized text
/// in a TEXT one (a table made before), whatever the value (a column, a
/// function's blob or text: typing.storeNeeded()).
fn store(t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store {
    _ = t;
    _ = decl;
    return .{ .def = if (storage == .BLOB) &jfuncs.store_jsonb_bin else &jfuncs.store_jsonb_text };
}

const jfuncs = @import("../jfuncs.zig");

/// jsonb sorts by its key (order_key) but in the ORDER BY of a compound,
/// whose terms are its columns: there by the collation, which orders
/// text (jsonb of a TEXT column, a cast), not JSONB blobs.
fn orderCollation(c: *Ctx, e: *const Expr) ?[:0]const u8 {
    _ = c;
    _ = e;
    return jsonb_collation;
}

/// `a || b` of jsonb (after the other types' choices: overload.concat()):
/// of two jsonb (or jsonb and an operand of no type)
/// xq_pg_jsonb_concat(); jsonb || text is text, of jsonb's text.
pub fn concat(c: *Ctx, e: *Expr, l: *Expr, r: *Expr) Error!bool {
    if (!jsonbPair(c, l, r)) {
        // jsonb || text: text, of jsonb's text.
        if (logical(c, l) == .jsonb and isText(c, r)) {
            e.left = try c.call("xq_pg_jsonb_text", &.{l});
            return true;
        }
        if (logical(c, r) == .jsonb and isText(c, l)) {
            e.right = try c.call("xq_pg_jsonb_text", &.{r});
            return true;
        }
        return false;
    }
    try c.toCall(e, "xq_pg_jsonb_concat", &.{ l, r });
    return true;
}

/// A comparison with a jsonb operand (the other jsonb or of no type):
/// the sort keys compared (xq_pg_jsonb_key(), which reads a string
/// literal as jsonb, a JSONB blob or text alike).
pub fn compare(c: *Ctx, e: *Expr, l: *Expr, r: *Expr) Error!bool {
    if (calls(l, jsonb_key)) return false;
    if (!jsonbPair(c, l, r)) return false;
    e.left = try c.call(jsonb_key, &.{l});
    e.right = try c.call(jsonb_key, &.{r});
    return true;
}
