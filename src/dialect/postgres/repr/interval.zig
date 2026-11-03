//! PostgreSQL's interval (postgres/repr.zig's descriptor and the choices
//! overload.zig makes for it).
//!
//! An interval is a BLOB (src/dialect/interval.zig: a key of its length,
//! then its fields), in an older database's TEXT column its text; the
//! functions of intervals take both. A comparison compares the keys
//! (xq_pg_iv_key(): '1 mon' = '30 days'), of a BLOB column with a bound
//! of the other's length (xq_pg_iv_key() below it, xq_pg_iv_high() above
//! it), which an index on the column serves; GROUP BY and DISTINCT
//! group by the key (groupKey()); a value made text is its text
//! (xq_pg_iv_text(): ::text, ||, concat(), JSON, an array's element).

const std = @import("std");
const typing = @import("../../../sql/typing.zig");
const int = @import("../../../sql/sqlite_int.zig");
const repr = @import("../repr.zig");
const operand = @import("../operand.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Type = @import("../../../sql/types.zig").Type;
const logical = operand.logical;
const untyped = operand.untyped;
const pairOf = operand.pairOf;
const nameOf = operand.nameOf;
const isCall = operand.isCall;

/// Intervals in PostgreSQL's order (datetime.collateInterval()).
pub const interval_collation = "xq_pg_interval";

/// Whether `e` (an interval) is a BLOB: a column stored as BLOB, a call
/// of a function whose result is one.
pub fn intervalBlob(c: *const Ctx, e_arg: *const Expr) bool {
    _ = c;
    var e = e_arg;
    while (e.op == TK.COLLATE and e.left != null) e = e.left.?;
    if (blobColumn(e)) return true;
    if (!isCall(e)) return false;
    var buf: [64]u8 = undefined;
    const n = nameOf(e, &buf);
    return std.mem.startsWith(u8, n, "xq_pg_iv") or std.mem.startsWith(u8, n, "justify_");
}

/// Whether `e` is a column of a table, stored as BLOB.
fn blobColumn(e: *const Expr) bool {
    if (e.op != TK.COLUMN or !e.useYTab()) return false;
    const t = e.y.tab orelse return false;
    if (!t.isOrdinary() or e.i_column < 0) return false;
    const i: usize = @intCast(e.i_column);
    return i < t.cols.len and t.cols[i].e_ctype == .BLOB;
}

fn ivKey(c: *Ctx, e: *Expr) Error!*Expr {
    return c.call("xq_pg_iv_key", &.{e});
}

/// A comparison of intervals: of their keys; a BLOB column with < <= >
/// >= as is, the other operand the bound of its length the comparison
/// needs.
pub fn intervalCompare(c: *Ctx, e: *Expr, l: *Expr, r: *Expr) Error!bool {
    const ord = switch (e.op) {
        TK.LT, TK.LE, TK.GT, TK.GE => true,
        else => false,
    };
    if (ord and (blobColumn(l) or blobColumn(r))) {
        // The operator as the column sees it: col < x, x > col.
        const col_left = blobColumn(l);
        const op: u8 = if (col_left) e.op else switch (e.op) {
            TK.LT => TK.GT,
            TK.LE => TK.GE,
            TK.GT => TK.LT,
            else => TK.LE,
        };
        // col < x and col >= x: below every value of x's length; col <= x
        // and col > x: above every one.
        const f = if (op == TK.LT or op == TK.GE) "xq_pg_iv_key" else "xq_pg_iv_high";
        if (col_left) e.right = try c.call(f, &.{r}) else e.left = try c.call(f, &.{l});
        return true;
    }
    e.left = try ivKey(c, l);
    e.right = try ivKey(c, r);
    return true;
}

/// `x IN (a, b ...)` and `x BETWEEN a AND b` of intervals: of their keys.
pub fn intervalSet(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    if (!e.useXList()) return false;
    const list = e.x.list orelse return false;
    if (logical(c, l) != .interval) return false;
    for (list.slice()) |item| {
        const x = item.expr orelse return false;
        if (logical(c, x) != .interval and !untyped(x)) return false;
    }
    e.left = try ivKey(c, l);
    for (list.slice()) |*item| item.expr = try ivKey(c, item.expr.?);
    return true;
}

/// `e` (an interval) as text, where PostgreSQL makes one text: its
/// output (xq_pg_iv_text()).
pub fn ivText(c: *Ctx, e: *Expr) Error!*Expr {
    return c.call("xq_pg_iv_text", &.{e});
}

/// A CAST of an interval to TEXT: its text.
pub fn intervalCast(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    if (logical(c, l) != .interval or !e.useUToken()) return false;
    const z = e.u.token orelse return false;
    if (!std.ascii.eqlIgnoreCase(z, "TEXT")) return false;
    const t = e.xq_type;
    try c.toCall(e, "xq_pg_iv_text", &.{l});
    if (t != typing.unknown) e.xq_type = t;
    return true;
}

/// Whether `a op b` is an operator of intervals (pairOf()), a string
/// literal under a unary + too (x IN ('1 day') is x = +'1 day').
pub fn intervalPair(c: *const Ctx, a: *const Expr, b: *const Expr) bool {
    const plusString = struct {
        fn f(e: *const Expr) bool {
            return e.op == TK.UPLUS and e.left != null and e.left.?.op == TK.STRING;
        }
    }.f;
    if (pairOf(c, a, b, .interval)) return true;
    return (logical(c, a) == .interval and plusString(b)) or (logical(c, b) == .interval and plusString(a));
}

/// The calls of intervals: sum() and avg() of intervals are
/// xq_pg_iv_sum() and xq_pg_iv_avg() (PostgreSQL's arithmetic of
/// intervals, a BLOB), concat() and format() take an interval's text;
/// whether that changed the operands of `e`, null for another call.
pub fn intervalCall(c: *Ctx, e: *Expr, n: []const u8, items: []int.ExprListItem) Error!?bool {
    const eql = std.mem.eql;
    if (eql(u8, n, "xq_pg_part") and items.len == 4) return try datePart(c, e, items);
    if ((eql(u8, n, "sum") or eql(u8, n, "avg")) and items.len == 1 and logical(c, items[0].expr.?) == .interval) {
        try c.rename(e, if (n[0] == 's') "xq_pg_iv_sum" else "xq_pg_iv_avg");
        return false;
    }
    if (eql(u8, n, "concat") or eql(u8, n, "concat_ws") or eql(u8, n, "format")) {
        var changed = false;
        for (items) |*item| if (logical(c, item.expr.?) == .interval) {
            item.expr = try ivText(c, item.expr.?);
            changed = true;
        };
        if (changed) return true;
    }
    return null;
}

/// EXTRACT(field FROM x) and date_part(field, x) (the parser's
/// xq_pg_part(field, x, timestamp's part, extract)): of an interval
/// xq_pg_iv_extract() (numeric) or xq_pg_iv_date_part() (double
/// precision), of another value the timestamp's part, an error if that
/// field is none.
fn datePart(c: *Ctx, e: *Expr, items: []int.ExprListItem) Error!bool {
    const field = items[0].expr.?;
    const x = items[1].expr.?;
    if (logical(c, x) == .interval) {
        const extract = (typing.intLiteral(items[3].expr.?) orelse 0) == 1;
        try c.toCall(e, if (extract) "xq_pg_iv_extract" else "xq_pg_iv_date_part", &.{ field, x });
        e.xq_type = try c.named(if (extract) "numeric" else "double precision");
        return true;
    }
    const t = items[2].expr.?;
    if (t.op == TK.NULL) {
        const z: []const u8 = if (field.op == TK.STRING) field.token() else "?";
        return c.fail(field, .of("22023"), "unit \"{s}\" not recognized for type timestamp", .{z});
    }
    const subt = e.flags.SubtArg;
    e.* = t.*;
    e.flags.SubtArg = subt;
    return true;
}

pub const desc: repr.TypeRepr = .{
    .logical = .interval,
    .store = store,
    .list = intervalSet,
    .cast = intervalCast,
    .group_key = groupKey,
    .order_collation = orderCollation,
    .json_arg = jsonArg,
    .default_text = defaultText,
};

/// A value stored into an interval column: a BLOB of the column's type
/// modifier (xq_pg_iv_in(x, typmod): `interval day to hour` keeps whole
/// hours), in an older database's table TEXT (its text, no infinity:
/// what the collation xq_pg_interval reads).
fn store(t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store {
    _ = t;
    if (storage == .TEXT) return .of(.{ .def = &datetime.store_interval_text });
    return .of(.{ .def = &ivinput.in_def, .consts = .{ ivinput.typmodOfDecl(decl), 0 }, .n_consts = 1 });
}

const datetime = @import("../datetime.zig");
const ivinput = @import("../ivinput.zig");

/// GROUP BY and DISTINCT group intervals by their key ('1 mon' and '30
/// days' are one group).
fn groupKey(c: *Ctx, e: *const Expr) ?[]const u8 {
    _ = c;
    _ = e;
    return "xq_pg_iv_key";
}

/// A BLOB sorts in its order as it is (a BLOB column's index serves the
/// ORDER BY); a value that may be an older database's text in the
/// collation (which leaves BLOBs in theirs).
fn orderCollation(c: *Ctx, e: *const Expr) ?[:0]const u8 {
    return if (intervalBlob(c, e)) null else interval_collation;
}

/// An argument of a function that builds JSON: a string of its text.
fn jsonArg(c: *Ctx, item: *int.ExprListItem) Error!bool {
    item.expr = try ivText(c, item.expr.?);
    return true;
}

/// An interval's DEFAULT, stored as its BLOB's input (xq_pg_iv('2
/// hours'): parser.zig), as pg_get_expr() shows it: the constant
/// ('2 hours'::interval); null for another.
fn defaultText(a: std.mem.Allocator, z: []const u8) error{OutOfMemory}!?[]const u8 {
    // xq_pg_iv('...') of older tables, xq_pg_iv_in('...', typmod).
    const open = if (std.mem.startsWith(u8, z, "xq_pg_iv('")) "xq_pg_iv(".len else if (std.mem.startsWith(u8, z, "xq_pg_iv_in('")) "xq_pg_iv_in(".len else return null;
    if (!std.mem.endsWith(u8, z, ")")) return null;
    var s: pgcatalog.Scanner = .{ .z = z[open .. z.len - 1] };
    const t = s.next();
    var end = open + t.end;
    if (open != "xq_pg_iv(".len) {
        const rest = z[end .. z.len - 1];
        if (!std.mem.startsWith(u8, rest, ", ")) return null;
        _ = std.fmt.parseInt(i32, rest[2..], 10) catch return null;
        end = z.len - 1;
    }
    if (end != z.len - 1) return null;
    return try std.fmt.allocPrint(a, "{s}::interval", .{z[open .. open + t.end]});
}

const pgcatalog = @import("../pgcatalog.zig");
