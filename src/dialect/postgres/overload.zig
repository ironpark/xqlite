//! PostgreSQL's choices by the types of operands (typing.Rules.overload
//! and .order_collation, see sql/typing.zig), made on the resolved
//! statement once its operands are typed: a column of a table, of a
//! subquery, a CTE or a view, a cast, a function's result.
//!
//!  - `a || b` with a jsonb operand (the other jsonb or of no type: a
//!    string literal, NULL, a parameter) is xq_pg_jsonb_concat(a, b);
//!    `a - b` with a jsonb left operand xq_pg_jsonb_delete(), or
//!    xq_pg_jsonb_delete_keys() if b is an array; `json || json` is an
//!    error, as in PostgreSQL;
//!  - `->`, `->>`, `#>`, `#>>` (xq_pg_json_get() ...) of a jsonb operand
//!    call jsonb's functions (their results are normalized), of json
//!    json's (the text as written);
//!  - a comparison with a jsonb operand compares in jsonb's order
//!    (collation xq_pg_jsonb on the left operand), a string literal read
//!    as jsonb (xq_pg_jsonb()); `json = json` is an error; ORDER BY a
//!    jsonb value sorts in jsonb's order (orderCollation(), for the
//!    ORDER BY of a query, an aggregate and a window);
//!  - an argument of a function that builds JSON (to_json(),
//!    json_build_object(), json_agg(), xq_pg_row_json() ... : builders)
//!    is wrapped so that the function sees what it is (jfuncs.zig):
//!    json/jsonb in xq_pg_json()/xq_pg_jsonb() (the JSON subtype), a
//!    boolean in xq_pg_json_bool(), an array in xq_pg_array_to_json(), a
//!    double precision or real in xq_pg_float_json() (PostgreSQL's
//!    float8out() spelling: 100, 1e+20), a numeric of a known scale in
//!    xq_pg_numeric_json() (its digits: 1.50); json_agg() of rows or
//!    arrays is xq_pg_json_agg_rows() (a line break between them),
//!    array_to_json() of an array xq_pg_array_to_json();
//!  - an xq_pg_jsonb() (xq_pg_json()) no frontend typed around a call
//!    whose result is jsonb (json or jsonb) is that call: jtype.zig
//!    wraps every value stored into a jsonb (json) column, before the
//!    value's type is known.
//! What depends on names and the structure of FROM, not on types (a FROM
//! item as a row value, the columns of a JSON set-returning function,
//! `*` next to one) stays in jtype.zig, before lowering.

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const int = @import("../../sql/sqlite_int.zig");
const expr_mod = @import("../../sql/expr.zig");
const pg_typing = @import("typing.zig");
const types = @import("types.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Logical = @import("../../sql/types.zig").Logical;

pub fn overload(c: *Ctx, e: *Expr) Error!bool {
    return switch (e.op) {
        TK.CONCAT => concat(c, e),
        TK.MINUS => minus(c, e),
        TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE, TK.IS, TK.ISNOT => compare(c, e),
        TK.FUNCTION, TK.AGG_FUNCTION => call(c, e),
        else => false,
    };
}

/// ORDER BY a jsonb value: in jsonb's order.
pub fn orderCollation(c: *Ctx, id: typing.TypeId) ?[:0]const u8 {
    return if (typing.typeOf(c.p.db, id).logical == .jsonb) jsonb_collation else null;
}

const jsonb_collation = "xq_pg_jsonb";

fn logical(c: *const Ctx, e: *const Expr) Logical {
    return typing.typeOf(c.p.db, e.xq_type).logical;
}

/// An operand of no type of its own (PostgreSQL's unknown): a string
/// literal, NULL, a parameter of no known type.
fn untyped(e: *const Expr) bool {
    return e.op == TK.STRING or e.op == TK.NULL or (e.op == TK.VARIABLE and e.xq_type == typing.unknown);
}

/// Whether `a op b` is jsonb's operator: a jsonb operand, the other
/// jsonb or of no type.
fn jsonbPair(c: *const Ctx, a: *const Expr, b: *const Expr) bool {
    const la = logical(c, a);
    const lb = logical(c, b);
    return (la == .jsonb and (lb == .jsonb or untyped(b))) or (lb == .jsonb and untyped(a));
}

fn concat(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (logical(c, l) == .json and logical(c, r) == .json) return c.fail(e, .of("42883"), "operator does not exist: json || json", .{});
    if (!jsonbPair(c, l, r)) return false;
    try c.toCall(e, "xq_pg_jsonb_concat", &.{ l, r });
    return true;
}

fn minus(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (logical(c, l) != .jsonb) return false;
    try c.toCall(e, if (arrayOf(c, r) != null) "xq_pg_jsonb_delete_keys" else "xq_pg_jsonb_delete", &.{ l, r });
    return true;
}

fn compare(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (e.op != TK.IS and e.op != TK.ISNOT and logical(c, l) == .json and logical(c, r) == .json) {
        return c.fail(e, .of("42883"), "operator does not exist: json {s} json", .{opText(e.op)});
    }
    // Chosen already.
    if (l.op == TK.COLLATE and std.ascii.eqlIgnoreCase(l.token(), jsonb_collation)) return false;
    if (!jsonbPair(c, l, r)) return false;
    // The literal is read as jsonb.
    var left = l;
    if (l.op == TK.STRING) left = try c.call("xq_pg_jsonb", &.{l});
    if (r.op == TK.STRING) e.right = try c.call("xq_pg_jsonb", &.{r});
    e.left = try c.collate(left, jsonb_collation);
    return true;
}

fn opText(op: u8) []const u8 {
    return switch (op) {
        TK.NE => "<>",
        TK.LT => "<",
        TK.LE => "<=",
        TK.GT => ">",
        TK.GE => ">=",
        else => "=",
    };
}

/// The name of call `e`, lower case, without PostgreSQL's prefix in the
/// text of the schema (pg_typing.ownName()); "" if it is too long to be
/// one of ours.
fn nameOf(e: *const Expr, buf: *[64]u8) []const u8 {
    const z = e.token();
    if (z.len > buf.len) return "";
    return pg_typing.ownName(std.ascii.lowerString(buf, z));
}

fn isCall(e: *const Expr) bool {
    return (e.op == TK.FUNCTION or e.op == TK.AGG_FUNCTION) and e.useUToken() and e.useXList();
}

/// Whether `e` calls `name`.
fn calls(e: *const Expr, name: []const u8) bool {
    if (!isCall(e)) return false;
    var buf: [64]u8 = undefined;
    return std.mem.eql(u8, nameOf(e, &buf), name);
}

fn args(e: *const Expr) []int.ExprListItem {
    return if (e.x.list) |l| l.slice() else &.{};
}

fn call(c: *Ctx, e: *Expr) Error!bool {
    if (!isCall(e)) return false;
    var buf: [64]u8 = undefined;
    const n = nameOf(e, &buf);
    const items = args(e);
    // The operators of jsonb operands.
    for (variants) |v| if (std.mem.eql(u8, n, v[0])) {
        if (items.len > 0 and logical(c, items[0].expr.?) == .jsonb) try c.rename(e, v[1]);
        return false;
    };
    var changed = false;
    const b = builderArgs(n);
    for (items, 0..) |*item, i| if (b.takes(i)) {
        if (try wrapArg(c, item)) changed = true;
    };
    if (std.mem.eql(u8, n, "json_agg") and items.len == 1 and (calls(items[0].expr.?, "xq_pg_row_json") or calls(items[0].expr.?, "xq_pg_array_to_json"))) {
        // json_agg() of rows or arrays: a line break between them.
        try c.rename(e, "xq_pg_json_agg_rows");
    } else if (std.mem.eql(u8, n, "array_to_json") and items.len >= 1 and items.len <= 2) {
        if (arrayOf(c, items[0].expr.?)) |num| {
            const p = c.p;
            var list = try expr_mod.listAppend(p, null, items[0].expr.?);
            list = try expr_mod.listAppend(p, list, if (items.len > 1) items[1].expr.? else try int32(c, 0));
            list = try expr_mod.listAppend(p, list, try int32(c, @intFromBool(num)));
            e.x = .{ .list = list };
            try c.rename(e, "xq_pg_array_to_json");
            changed = true;
        }
    } else if ((std.mem.eql(u8, n, "xq_pg_jsonb") or std.mem.eql(u8, n, "xq_pg_json")) and e.xq_type == typing.unknown and items.len == 1) {
        // A value stored into a jsonb/json column (jtype.zig) that is
        // jsonb/json already.
        const v = items[0].expr.?;
        const lv = logical(c, v);
        const jsonb = n.len == "xq_pg_jsonb".len;
        if (isCall(v) and !calls(v, "xq_pg_jsonb") and !calls(v, "xq_pg_json") and (lv == .jsonb or (!jsonb and lv == .json))) {
            const subt = e.flags.SubtArg;
            e.* = v.*;
            e.flags.SubtArg = subt;
            changed = true;
        }
    }
    return changed;
}

/// json's functions of `->`, `->>`, `#>`, `#>>` and jsonb's.
const variants = [_]struct { []const u8, []const u8 }{
    .{ "xq_pg_json_get", "xq_pg_jsonb_get" },
    .{ "xq_pg_json_get_text", "xq_pg_jsonb_get_text" },
    .{ "xq_pg_json_path", "xq_pg_jsonb_path" },
    .{ "xq_pg_json_path_text", "xq_pg_jsonb_path_text" },
};

fn int32(c: *Ctx, v: i32) Error!*Expr {
    const x = try expr_mod.exprInt32(c.p.arena, v);
    x.xq_type = typing.plain(.int4);
    return x;
}

/// If `e` is an array (text[], int[] ..., ARRAY[...]: of a type spelled
/// with []), whether its elements are numbers.
fn arrayOf(c: *const Ctx, e: *const Expr) ?bool {
    const z = typing.spelling(c.p.db, e.xq_type) orelse return null;
    if (!std.mem.endsWith(u8, z, "[]")) return null;
    return types.isNumeric(z[0 .. z.len - 2]);
}

/// Wrap argument `item` of a function that builds JSON so that the
/// function sees what it is (jfuncs.zig); whether it did.
fn wrapArg(c: *Ctx, item: *int.ExprListItem) Error!bool {
    const a = item.expr.?;
    const t = typing.typeOf(c.p.db, a.xq_type);
    item.expr = switch (t.logical) {
        .json, .jsonb => blk: {
            // A function whose result is JSON says so itself.
            if (isCall(a) and returnsJson(a)) return false;
            break :blk try c.call(if (t.logical == .jsonb) "xq_pg_jsonb" else "xq_pg_json", &.{a});
        },
        .boolean => try c.call("xq_pg_json_bool", &.{a}),
        .float4, .float8 => try c.call("xq_pg_float_json", &.{ a, try int32(c, @intFromBool(t.logical == .float4)) }),
        .numeric => blk: {
            const s = t.scale orelse return false;
            break :blk try c.call("xq_pg_numeric_json", &.{ a, try int32(c, s) });
        },
        else => blk: {
            const num = arrayOf(c, a) orelse return false;
            break :blk try c.call("xq_pg_array_to_json", &.{ a, try int32(c, 0), try int32(c, @intFromBool(num)) });
        },
    };
    return true;
}

/// Whether call `e` is of a function that says what JSON its result is
/// (as an argument of a function that builds JSON: jfuncs.zig reads its
/// subtype), or a boolean or an array of its own.
fn returnsJson(e: *const Expr) bool {
    var buf: [64]u8 = undefined;
    return json_calls.has(nameOf(e, &buf));
}

const json_calls = std.StaticStringMap(void).initComptime(.{
    .{"to_jsonb"},                  .{"jsonb_build_object"},     .{"jsonb_build_array"},       .{"jsonb_object"},
    .{"jsonb_agg"},                 .{"jsonb_object_agg"},       .{"jsonb_set"},               .{"jsonb_set_lax"},
    .{"jsonb_insert"},              .{"jsonb_strip_nulls"},      .{"jsonb_extract_path"},      .{"jsonb_path_query_array"},
    .{"jsonb_path_query_first"},    .{"xq_pg_jsonb"},            .{"xq_pg_jsonb_get"},         .{"xq_pg_jsonb_path"},
    .{"xq_pg_jsonb_concat"},        .{"xq_pg_jsonb_delete"},     .{"xq_pg_jsonb_delete_keys"}, .{"xq_pg_jsonb_delete_path"},
    .{"to_json"},                   .{"json_build_object"},      .{"json_build_array"},        .{"json_object"},
    .{"json_agg"},                  .{"json_object_agg"},        .{"json_strip_nulls"},        .{"json_extract_path"},
    .{"row_to_json"},               .{"array_to_json"},          .{"xq_pg_json"},              .{"xq_pg_json_get"},
    .{"xq_pg_json_path"},           .{"xq_pg_row_json"},         .{"xq_pg_array_to_json"},     .{"xq_pg_json_agg_rows"},
    .{"xq_pg_json_bool"},           .{"xq_pg_float_json"},       .{"xq_pg_numeric_json"},      .{"xq_pg_jsonb_contains"},
    .{"xq_pg_jsonb_exists"},        .{"xq_pg_jsonb_exists_any"}, .{"xq_pg_jsonb_exists_all"},  .{"xq_pg_jsonb_path_exists_op"},
    .{"xq_pg_jsonb_path_match_op"}, .{"jsonb_path_exists"},      .{"jsonb_path_match"},        .{"xq_pg_is_json"},
    .{"xq_pg_bool"},                .{"xq_like"},                .{"xq_ilike"},                .{"starts_with"},
    .{"xq_pg_text_array"},
});

/// Which arguments of a function are values it makes JSON of.
pub const Builder = enum {
    none,
    first,
    all,
    after_first,
    first_two,
    /// The values of name/value pairs (xq_pg_row_json()).
    odd,

    pub fn takes(b: Builder, i: usize) bool {
        return switch (b) {
            .none => false,
            .first => i == 0,
            .all => true,
            .after_first => i > 0,
            .first_two => i < 2,
            .odd => i % 2 == 1,
        };
    }
};

/// The arguments of function `n` (lower case) that it makes JSON of.
pub fn builderArgs(n: []const u8) Builder {
    const map = std.StaticStringMap(Builder).initComptime(.{
        .{ "to_json", .first },                     .{ "to_jsonb", .first },            .{ "json_agg", .first },
        .{ "jsonb_agg", .first },                   .{ "xq_pg_json_agg_rows", .first }, .{ "row_to_json", .first },
        .{ "xq_pg_json_arrayagg", .first },         .{ "json_build_object", .all },     .{ "jsonb_build_object", .all },
        .{ "json_build_array", .all },              .{ "jsonb_build_array", .all },     .{ "xq_pg_json_ctor_object", .after_first },
        .{ "xq_pg_json_ctor_array", .after_first }, .{ "json_object_agg", .first_two }, .{ "jsonb_object_agg", .first_two },
        .{ "xq_pg_json_objectagg", .first_two },    .{ "xq_pg_row_json", .odd },
    });
    return map.get(n) orelse .none;
}
