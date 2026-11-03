//! PostgreSQL's numeric (postgres/repr.zig's descriptor and the choices
//! overload.zig makes for it).
//!
//! A numeric is decimal.zig's key (a BLOB in the order of the numbers,
//! maybe with its display scale after it) where it comes from a column of
//! keys or a function of decimal_sql.zig (xq_dec_add() ...), and a SQLite
//! number where it comes from a literal (1.50 is the double 1.5, typed of
//! scale 2) or a numeric column of a table made before numerics were keys.
//! The functions of keys read numbers too, so:
//!  - an operator of the numeric rows of operators.zig is its function
//!    (`a + b` is xq_dec_add(a, b)); a literal operand is its key
//!    (xq_dec('1.50'): its digits and scale, which the double lost), a
//!    column of numeric(p, s) of its scale (xq_dec(a, 1000, s), as
//!    PostgreSQL keeps it with the value);
//!  - a comparison of numerics compares keys without their scales
//!    (xq_dec_key() of what is not a column of keys: `n = 1.5` is
//!    `n = xq_dec_key('1.5')`, a constant, so that an index on n is used);
//!    of numbers only (literals, older columns) SQLite's comparison; with
//!    a double the numeric's double (xq_dec_float8()), as PostgreSQL;
//!    IN, BETWEEN and CASE x WHEN likewise;
//!  - CASE, coalesce(), greatest() ... of keys and other numerics make
//!    them all keys (xq_dec());
//!  - round(), trunc(), ceil(), floor(), abs(), sign(), mod(), div(),
//!    sum(), avg(), the casts to integers of a numeric are decimal_sql.zig's
//!    (sum() of a bigint and avg() of an integer too: PostgreSQL's are
//!    numerics); scale(), min_scale(), trim_scale() of any;
//!  - a key made text (`||`, a cast to text, an array's element, a
//!    function of text: xq_dec_text(x, scale)), a double (a cast to a
//!    float, a float function, an operator with a double:
//!    xq_dec_float8()), JSON (xq_pg_dec_json(x, scale)).

const std = @import("std");
const typing = @import("../../../sql/typing.zig");
const int = @import("../../../sql/sqlite_int.zig");
const repr = @import("../repr.zig");
const operand = @import("../operand.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Logical = @import("../../../sql/types.zig").Logical;
const Error = typing.Error;
const Type = @import("../../../sql/types.zig").Type;
const expr_mod = @import("../../../sql/expr.zig");
const operators = @import("../operators.zig");
const overload = @import("../overload.zig");
const integer = @import("../integer.zig");
const logical = operand.logical;
const untyped = operand.untyped;
const nameOf = operand.nameOf;
const isCall = operand.isCall;
const calls = operand.calls;
const args = operand.args;
const int32 = operand.int32;
const typeOfExpr = operand.typeOfExpr;

/// What a numeric value is at run time.
const Repr = enum {
    /// A key without a display scale: a column of keys, xq_dec_key().
    pure,
    /// A key, maybe with its display scale.
    key,
    /// A SQLite number (or a value of another type).
    number,
    null,
    /// Not known: a parameter, a function's result ...
    unknown,
};

pub fn numericRepr(c: *const Ctx, e: *const Expr) Repr {
    return reprOf(c, e, 0);
}

fn reprOf(c: *const Ctx, e: *const Expr, depth: u8) Repr {
    if (depth > 8) return .unknown;
    switch (e.op) {
        TK.NULL => return .null,
        TK.INTEGER, TK.FLOAT => return .number,
        TK.UMINUS => if (e.left) |l| if (numericLiteral(l)) return .number,
        TK.UPLUS, TK.COLLATE => if (e.left) |l| return reprOf(c, l, depth + 1),
        TK.COLUMN, TK.AGG_COLUMN => return columnRepr(c, e, depth),
        TK.FUNCTION, TK.AGG_FUNCTION => if (isCall(e)) {
            var buf: [64]u8 = undefined;
            const n = nameOf(e, &buf);
            if (std.mem.eql(u8, n, "xq_dec_key")) return .pure;
            if (keyFunction(n)) return .key;
            // min() and max() of keys.
            if ((std.mem.eql(u8, n, "min") or std.mem.eql(u8, n, "max")) and args(e).len == 1) return reprOf(c, args(e)[0].expr.?, depth + 1);
        },
        TK.SELECT => if (e.useXSelect()) if (e.x.select) |s| if (s.prior == null) if (s.e_list) |l| if (l.len() > 0) {
            return reprOf(c, l.at(0).expr.?, depth + 1);
        },
        else => {},
    }
    return byType(c, e);
}

/// A value of a type other than numeric is a number (or of that type).
fn byType(c: *const Ctx, e: *const Expr) Repr {
    const l = logical(c, e);
    if (l == .numeric) return .unknown;
    return if (l == .unknown) .unknown else .number;
}

/// A column of a table: a key in a STRICT BLOB column, a number in
/// another; of a FROM subquery (a view, a CTE) what its result column is.
fn columnRepr(c: *const Ctx, e: *const Expr, depth: u8) Repr {
    if (logical(c, e) != .numeric) return byType(c, e);
    if (e.useYTab()) if (e.y.tab) |t| if (t.isOrdinary() and t.tab_flags.Strict and e.i_column >= 0 and e.i_column < t.cols.len) {
        return if (t.cols[@intCast(e.i_column)].e_ctype == .BLOB) .pure else .number;
    };
    // A column of a subquery in FROM, in the contexts the name was
    // resolved in.
    var nc = c.nc;
    while (nc) |n| : (nc = n.next) {
        const src = n.src_list orelse continue;
        for (src.slice()) |*it| if (it.i_cursor == e.i_table) {
            const s = it.subquery() orelse return .unknown;
            if (s.prior != null) return .unknown;
            const list = s.e_list orelse return .unknown;
            if (e.i_column < 0 or e.i_column >= list.len()) return .unknown;
            const r = reprOf(c, list.at(@intCast(e.i_column)).expr.?, depth + 1);
            // Its columns are of the subquery, not of the contexts here.
            return if (r == .number and logical(c, list.at(@intCast(e.i_column)).expr.?) == .numeric) .unknown else r;
        };
    }
    return .unknown;
}

/// Whether the result of the function `n` is a key (decimal_sql.zig's;
/// PostgreSQL's of numerics are made them).
fn keyFunction(n: []const u8) bool {
    const i = decimal_sql.info(n) orelse return false;
    return i.key;
}

/// Whether `e` is a numeric literal: a decimal (TK_FLOAT) or an integer
/// beyond 64 bits, or one negated.
pub fn numericLiteral(e: *const Expr) bool {
    if (e.op == TK.UMINUS) return if (e.left) |l| l.op != TK.UMINUS and numericLiteral(l) else false;
    if (e.op == TK.FLOAT) return e.useUToken();
    return e.op == TK.INTEGER and e.useUToken() and typing.intLiteral(e) == null;
}

/// Make `x` a call of `name` with `x` (as it was) and `extra`, in place:
/// the Exprs that point at `x` see the call.
fn wrapIn(c: *Ctx, x: *Expr, name: []const u8, extra: []const *Expr) Error!void {
    const inner = try c.p.arena.create(Expr);
    inner.* = x.*;
    var list: [3]*Expr = undefined;
    list[0] = inner;
    for (extra, 1..) |a, i| list[i] = a;
    x.xq_type = typing.unknown;
    try c.toCall(x, name, list[0 .. 1 + extra.len]);
    // Where it was (an error's offset, an ON clause).
    x.w = inner.w;
    x.flags.set(inner.flags.only(.{ .InnerON = true, .OuterON = true }));
}

/// Make literal `x` (a numeric's or a string) the call `name('its text')`
/// in place.
fn literalCall(c: *Ctx, x: *Expr, name: []const u8) Error!void {
    if (x.op == TK.UMINUS) {
        // -1.50: '-1.50'.
        const l = x.left.?;
        const z = try std.fmt.allocPrint(c.p.arena, "-{s}", .{l.token()});
        const s = try expr_mod.expr(c.p.arena, TK.STRING, z);
        s.xq_type = typing.plain(.text);
        s.w = x.w;
        x.xq_type = typing.unknown;
        return c.toCall(x, name, &.{s});
    }
    const z = if (x.useUToken()) x.token() else "";
    const s = try expr_mod.expr(c.p.arena, TK.STRING, z);
    s.xq_type = typing.plain(.text);
    s.w = x.w;
    x.xq_type = typing.unknown;
    try c.toCall(x, name, &.{s});
}

/// `x` as a key of `name` (xq_dec, xq_dec_key): a literal its text's,
/// else the call around it.
fn toKey(c: *Ctx, x: *Expr, name: []const u8) Error!void {
    if (numericLiteral(x) or x.op == TK.STRING) return literalCall(c, x, name);
    try wrapIn(c, x, name, &.{});
}

/// The static scale of `x` as an integer constant (-1 if not known).
fn scaleConst(c: *Ctx, x: *const Expr) Error!*Expr {
    const t = typeOfExpr(c, x);
    return int32(c, if (t.logical == .numeric) (if (t.scale) |s| s else -1) else -1);
}

/// A numeric operand `x` that is or may be a key made its text
/// (xq_dec_text(x, scale)), a numeric literal its digits as written;
/// whether it changed.
pub fn numericText(c: *Ctx, x: *Expr) Error!bool {
    if (logical(c, x) != .numeric) return false;
    if (numericLiteral(x)) {
        try literalCall(c, x, "xq_dec_text");
        return true;
    }
    switch (numericRepr(c, x)) {
        .number, .null => return false,
        else => {},
    }
    try wrapIn(c, x, "xq_dec_text", &.{try scaleConst(c, x)});
    return true;
}

/// A numeric that is or may be a key made an element of an array: its
/// text (xq_dec_text(x, scale)), still typed numeric, which the array's
/// functions read as a numeric element; whether it changed.
pub fn elemText(c: *Ctx, x: *Expr) Error!bool {
    if (logical(c, x) != .numeric) return false;
    switch (numericRepr(c, x)) {
        .number, .null => return false,
        else => {},
    }
    const id = x.xq_type;
    try wrapIn(c, x, "xq_dec_text", &.{try scaleConst(c, x)});
    x.xq_type = id;
    return true;
}

/// A numeric operand that is or may be a key made a double
/// (xq_dec_float8()); whether it changed.
fn numericFloat(c: *Ctx, x: *Expr) Error!bool {
    if (logical(c, x) != .numeric) return false;
    switch (numericRepr(c, x)) {
        .number, .null => return false,
        else => {},
    }
    try wrapIn(c, x, "xq_dec_float8", &.{});
    return true;
}

/// The operands of `row` of the operator table: of a numeric row exact
/// keys (a literal's digits, a numeric(p, s) column's scale), of a float
/// row the numerics' doubles; whether one changed.
pub fn numericOperands(c: *Ctx, row: *const operators.Entry, operands: []*Expr) Error!bool {
    var changed = false;
    const f = row.func orelse {
        for (operands, row.args) |x, t| if (t == .float4 or t == .float8) {
            if (try numericFloat(c, x)) changed = true;
        };
        return changed;
    };
    if (!std.mem.startsWith(u8, f, "xq_dec_")) return false;
    for (operands) |x| changed = try exactOperand(c, x) or changed;
    return changed;
}

/// Operand `x` of a function of keys made exact: a numeric literal its key
/// (xq_dec('1.50')), a string literal too, a column of numeric(p, s) of
/// its scale; whether it changed.
fn exactOperand(c: *Ctx, x: *Expr) Error!bool {
    if (numericLiteral(x) or x.op == TK.STRING) {
        try literalCall(c, x, "xq_dec");
        return true;
    }
    if (logical(c, x) != .numeric or x.op != TK.COLUMN or numericRepr(c, x) != .pure) return false;
    const t = typeOfExpr(c, x);
    const s = t.scale orelse return false;
    if (s == 0) return false;
    const id = x.xq_type;
    try wrapIn(c, x, "xq_dec", &.{ try int32(c, 1000), try int32(c, s) });
    // Of the column's type still.
    x.xq_type = id;
    return true;
}

/// Whether `x` is a value a numeric compares with as a numeric: a
/// numeric, an integer, a string literal, NULL, a parameter.
fn numericPeer(c: *const Ctx, x: *const Expr) bool {
    const l = logical(c, x);
    return l == .numeric or typing.intWidth(l) != null or untyped(x);
}

/// Make `xs`, numerics compared with each other, keys without their
/// scales where one is a key; whether one changed.
fn compareKeys(c: *Ctx, xs: []const *Expr) Error!bool {
    var any_numeric = false;
    var all_numbers = true;
    for (xs) |x| {
        if (!numericPeer(c, x)) return false;
        if (logical(c, x) == .numeric) any_numeric = true;
        switch (numericRepr(c, x)) {
            .number, .null => {},
            else => if (!untyped(x) or logical(c, x) == .numeric) {
                all_numbers = false;
            },
        }
    }
    if (!any_numeric or all_numbers) return false;
    var changed = false;
    for (xs) |x| switch (numericRepr(c, x)) {
        .pure, .null => {},
        else => {
            try toKey(c, x, "xq_dec_key");
            changed = true;
        },
    };
    return changed;
}

/// A comparison of a numeric: of keys, or of doubles with a double.
pub fn numericCompare(c: *Ctx, l: *Expr, r: *Expr) Error!bool {
    const nl = logical(c, l) == .numeric;
    const nr = logical(c, r) == .numeric;
    if (!nl and !nr) return false;
    if (nl != nr) {
        const other = if (nl) r else l;
        if (typing.isFloat(logical(c, other))) return numericFloat(c, if (nl) l else r);
    }
    return compareKeys(c, &.{ l, r });
}

/// `x IN (...)`, `x BETWEEN a AND b` of numerics.
pub fn numericList(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    if (e.useXSelect()) {
        // x IN (SELECT y ...): x and y.
        const s = e.x.select orelse return false;
        if (s.prior != null) return false;
        const list = s.e_list orelse return false;
        if (list.len() != 1) return false;
        return compareKeys(c, &.{ l, list.at(0).expr.? });
    }
    const list = e.x.list orelse return false;
    var xs: [65]*Expr = undefined;
    if (list.len() + 1 > xs.len) return false;
    xs[0] = l;
    for (list.slice(), 1..) |item, i| xs[i] = item.expr.?;
    return compareKeys(c, xs[0 .. list.len() + 1]);
}

/// CASE of numerics: `CASE x WHEN v ...` compares keys; the values of
/// THEN and ELSE all keys if one is.
pub fn numericCase(c: *Ctx, e: *Expr) Error!bool {
    if (!e.useXList()) return false;
    const list = e.x.list orelse return false;
    const items = list.slice();
    var changed = false;
    if (e.left) |x| {
        var xs: [33]*Expr = undefined;
        if (items.len / 2 + 1 <= xs.len) {
            xs[0] = x;
            var n: usize = 1;
            var i: usize = 0;
            while (i + 1 < items.len) : (i += 2) {
                xs[n] = items[i].expr.?;
                n += 1;
            }
            changed = try compareKeys(c, xs[0..n]);
        }
    }
    var vals: [33]*Expr = undefined;
    var n: usize = 0;
    var i: usize = 1;
    while (i < items.len and n < vals.len) : (i += 2) {
        vals[n] = items[i].expr.?;
        n += 1;
    }
    if (items.len % 2 == 1 and n < vals.len) {
        vals[n] = items[items.len - 1].expr.?;
        n += 1;
    }
    return try unifyKeys(c, vals[0..n]) or changed;
}

/// Values of which one is a numeric key (the branches of CASE,
/// coalesce()'s arguments ...): the other numerics made keys (xq_dec());
/// whether one changed.
fn unifyKeys(c: *Ctx, xs: []const *Expr) Error!bool {
    var any_key = false;
    for (xs) |x| switch (numericRepr(c, x)) {
        .pure, .key => if (logical(c, x) == .numeric) {
            any_key = true;
        },
        else => {},
    };
    if (!any_key) return false;
    var changed = false;
    for (xs) |x| {
        if (x.op == TK.NULL or !numericPeer(c, x) or x.op == TK.VARIABLE) continue;
        switch (numericRepr(c, x)) {
            .pure => changed = try exactOperand(c, x) or changed,
            .key, .null => {},
            else => {
                try toKey(c, x, "xq_dec");
                changed = true;
            },
        }
    }
    return changed;
}

/// A column of a compound subquery in FROM (VALUES (1.5::numeric), (2.50)
/// ...) whose values are keys in a term and numbers in another: all keys,
/// so that they compare, group and sort as numerics.
pub fn numericColumn(c: *Ctx, e: *Expr) Error!bool {
    if (logical(c, e) != .numeric) return false;
    var nc = c.nc;
    while (nc) |n| : (nc = n.next) {
        const src = n.src_list orelse continue;
        for (src.slice()) |*it| if (it.i_cursor == e.i_table) {
            const s = it.subquery() orelse return false;
            if (s.prior == null or e.i_column < 0) return false;
            var xs: [64]*Expr = undefined;
            var k: usize = 0;
            var term: ?*int.Select = s;
            while (term) |t| : (term = t.prior) {
                const list = t.e_list orelse return false;
                if (e.i_column >= list.len() or k == xs.len) return false;
                xs[k] = list.at(@intCast(e.i_column)).expr.?;
                k += 1;
            }
            _ = try unifyKeys(c, xs[0..k]);
            return false;
        };
    }
    return false;
}

/// CAST(x AS REAL/TEXT/INTEGER/NUMERIC) of a numeric: of a key, its
/// double, text, integer, number; of a literal made text, its digits as written.
pub fn numericCast(c: *Ctx, e: *Expr) Error!bool {
    const x = e.left orelse return false;
    if (logical(c, x) != .numeric or !e.useUToken()) return false;
    const to = e.token();
    if (std.ascii.eqlIgnoreCase(to, "TEXT")) return numericText(c, x);
    if (std.ascii.eqlIgnoreCase(to, "REAL")) return numericFloat(c, x);
    const f: []const u8 = if (std.ascii.eqlIgnoreCase(to, "INTEGER"))
        "xq_dec_int8"
    else if (std.ascii.eqlIgnoreCase(to, "NUMERIC"))
        // SQLite's numeric affinity: a number.
        "xq_dec_number"
    else
        return false;
    switch (numericRepr(c, x)) {
        .number, .null => return false,
        else => {},
    }
    try wrapIn(c, x, f, &.{});
    return true;
}

/// The functions of numerics; whether `e` changed.
pub fn numericCall(c: *Ctx, e: *Expr, n: []const u8, items: []int.ExprListItem) Error!bool {
    const eql = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    const isNum = struct {
        fn f(cx: *const Ctx, item: int.ExprListItem) bool {
            return logical(cx, item.expr.?) == .numeric;
        }
    }.f;
    // The casts and functions of keys: a literal argument read as written.
    if (eql(n, "xq_dec") or eql(n, "xq_dec_key")) {
        if (items.len == 0) return false;
        const x = items[0].expr.?;
        if (!numericLiteral(x) or x.op == TK.UMINUS) return false;
        x.op = TK.STRING;
        x.xq_type = typing.plain(.text);
        return true;
    }
    if (std.mem.startsWith(u8, n, "xq_dec")) return false;
    const renamed: ?[]const u8 = blk: {
        if (items.len == 0) break :blk null;
        const first = isNum(c, items[0]);
        if ((eql(n, "round") or eql(n, "trunc")) and items.len <= 2 and first) break :blk if (eql(n, "round")) "xq_dec_round" else "xq_dec_trunc";
        if ((eql(n, "ceil") or eql(n, "ceiling")) and items.len == 1 and first) break :blk "xq_dec_ceil";
        if (eql(n, "floor") and items.len == 1 and first) break :blk "xq_dec_floor";
        if (eql(n, "abs") and items.len == 1 and first) break :blk "xq_dec_abs";
        if (eql(n, "sign") and items.len == 1 and first) break :blk "xq_dec_sign";
        if (eql(n, "mod") and items.len == 2 and (first or isNum(c, items[1]))) break :blk "xq_dec_mod";
        if (eql(n, "div") and items.len == 2) break :blk "xq_dec_div_trunc";
        if (eql(n, "scale") and items.len == 1) break :blk "xq_dec_scale";
        if (eql(n, "min_scale") and items.len == 1) break :blk "xq_dec_min_scale";
        if (eql(n, "trim_scale") and items.len == 1) break :blk "xq_dec_trim_scale";
        if (eql(n, "log") and items.len == 2) break :blk "xq_dec_log";
        if (eql(n, "width_bucket") and items.len == 4 and numericArgs(c, items[0..3])) break :blk "xq_dec_width_bucket";
        if (transcendentals.get(n)) |t| if (items.len == t[1] and numericArgs(c, items)) break :blk t[0];
        if (e.op == TK.AGG_FUNCTION or e.isWindowFunc()) {
            const l = logical(c, items[0].expr.?);
            if (eql(n, "sum") and items.len == 1 and (l == .numeric or l == .int8)) break :blk "xq_dec_sum";
            if (eql(n, "avg") and items.len == 1 and (l == .numeric or typing.intWidth(l) != null)) break :blk "xq_dec_avg";
        }
        if (first and items.len == 1) {
            // The casts to an integer type, those of funcs.zig's too.
            for (std.enums.values(integer.Width)) |w| {
                const old: []const u8 = switch (w) {
                    .int2 => "xq_pg_int2",
                    .int4 => "xq_pg_int4",
                    .int8 => "xq_pg_int8",
                };
                if (eql(n, old) or eql(n, integer.castName(w))) break :blk integer.decimalInt(w).name;
            }
        }
        break :blk null;
    };
    if (renamed) |r| {
        // Its numeric arguments (decimal_sql.zig's Info.numerics) exact.
        const exact: usize = decimal_sql.info(r).?.numerics;
        for (items[0..@min(exact, items.len)]) |item| _ = try exactOperand(c, item.expr.?);
        try c.rename(e, r);
        return true;
    }
    if (aware_functions.has(n) or numeric_engine.has(n) or overload.builderArgs(n) != .none) {
        // coalesce() ... of keys and numbers: all keys.
        if (unify_functions.has(n)) {
            var xs: [32]*Expr = undefined;
            const from: usize = if (eql(n, "iif")) 1 else 0;
            if (items.len > xs.len or items.len <= from) return false;
            for (items[from..], 0..) |item, i| xs[i] = item.expr.?;
            if (eql(n, "nullif")) return compareKeys(c, xs[0 .. items.len - from]);
            return unifyKeys(c, xs[0 .. items.len - from]);
        }
        return false;
    }
    // Another function: a key is made a double for one of doubles, text
    // for one of text, else the SQLite number such a function read before
    // numerics were keys (xq_dec_number()).
    var changed = false;
    const float = float_functions.has(n);
    const text = text_functions.has(n);
    for (items) |item| {
        const x = item.expr.?;
        if (float) {
            if (try numericFloat(c, x)) changed = true;
        } else if (text) {
            if (logical(c, x) == .numeric and !numericLiteral(x) and try numericText(c, x)) changed = true;
        } else if (logical(c, x) == .numeric) {
            switch (numericRepr(c, x)) {
                .number, .null => {},
                else => {
                    try wrapIn(c, x, "xq_dec_number", &.{});
                    changed = true;
                },
            }
        }
    }
    return changed;
}

/// sqrt() ... of numerics (decimal_math.zig), the engine function and the
/// arguments.
const transcendentals = std.StaticStringMap(struct { []const u8, usize }).initComptime(.{
    .{ "sqrt", .{ "xq_dec_sqrt", 1 } }, .{ "exp", .{ "xq_dec_exp", 1 } },   .{ "ln", .{ "xq_dec_ln", 1 } },
    .{ "log", .{ "xq_dec_log", 1 } },   .{ "log10", .{ "xq_dec_log", 1 } }, .{ "power", .{ "xq_dec_power", 2 } },
    .{ "pow", .{ "xq_dec_power", 2 } },
});

/// Which of PostgreSQL's sqrt() ... and width_bucket() arguments of
/// these types call (typing.zig's transcendental() too): the numeric one
/// (decimal_math.zig) if one is a numeric and none a double precision or
/// a real (the numeric candidate matches more of them exactly; a float
/// makes it the float8 one), else the float8 one.
pub const Candidate = struct {
    numeric: bool = false,
    float: bool = false,

    pub fn arg(ch: *Candidate, l: Logical) void {
        switch (l) {
            .numeric => ch.numeric = true,
            .float8, .float4 => ch.float = true,
            else => {},
        }
    }

    pub fn isNumeric(ch: Candidate) bool {
        return ch.numeric and !ch.float;
    }
};

fn numericArgs(c: *const Ctx, items: []const int.ExprListItem) bool {
    var ch: Candidate = .{};
    for (items) |item| ch.arg(logical(c, item.expr.?));
    return ch.isNumeric();
}

/// The engine functions that take numerics as they are, or whose
/// numeric arguments overload.zig makes what they read (arrays, JSON).
const numeric_engine = std.StaticStringMap(void).initComptime(.{
    .{"xq_pg_dec_json"},         .{"xq_pg_numeric_json"},    .{"xq_pg_elem"},          .{"xq_pg_array"},
    .{"xq_pg_array_nested"},     .{"xq_pg_array_agg"},       .{"xq_pg_any"},           .{"xq_pg_array_append"},
    .{"xq_pg_array_prepend"},    .{"xq_pg_array_set"},       .{"xq_pg_array_cat2"},    .{"xq_pg_row_json"},
    .{"xq_pg_json_ctor_object"}, .{"xq_pg_json_ctor_array"}, .{"xq_pg_json_arrayagg"}, .{"xq_pg_json_objectagg"},
    .{"xq_pg_json_agg_rows"},    .{"xq_pg_to_char"},         .{"xq_pg_gcd"},           .{"xq_pg_lcm"},
});

/// The functions of text a numeric is its text for (PostgreSQL's
/// numeric_out(), as `||` does).
const text_functions = std.StaticStringMap(void).initComptime(.{
    .{"concat"},       .{"concat_ws"}, .{"format"},  .{"length"},  .{"char_length"}, .{"octet_length"},
    .{"lower"},        .{"upper"},     .{"substr"},  .{"replace"}, .{"lpad"},        .{"rpad"},
    .{"left"},         .{"right"},     .{"reverse"}, .{"repeat"},  .{"md5"},         .{"string_agg"},
    .{"group_concat"}, .{"trim"},      .{"ltrim"},   .{"rtrim"},   .{"instr"},       .{"starts_with"},
    .{"split_part"},   .{"translate"}, .{"initcap"},
});

/// The functions that take numerics as they are (keys and numbers).
const aware_functions = std.StaticStringMap(void).initComptime(.{
    .{"count"},     .{"min"},        .{"max"},         .{"coalesce"},   .{"ifnull"},    .{"nullif"},
    .{"iif"},       .{"likely"},     .{"unlikely"},    .{"likelihood"}, .{"greatest"},  .{"least"},
    .{"lag"},       .{"lead"},       .{"first_value"}, .{"last_value"}, .{"nth_value"}, .{"typeof"},
    .{"array_agg"}, .{"row_number"}, .{"rank"},        .{"dense_rank"}, .{"ntile"},     .{"percent_rank"},
    .{"cume_dist"}, .{"pg_typeof"},
});

/// The functions whose numeric arguments are all keys if one is.
const unify_functions = std.StaticStringMap(void).initComptime(.{
    .{"coalesce"}, .{"ifnull"}, .{"nullif"}, .{"iif"}, .{"greatest"}, .{"least"}, .{"min"}, .{"max"},
});

/// The functions of doubles a numeric is converted for.
const float_functions = std.StaticStringMap(void).initComptime(.{
    .{"sqrt"}, .{"exp"},  .{"ln"},              .{"log"},     .{"log10"},  .{"power"},   .{"pow"},          .{"cbrt"},
    .{"sin"},  .{"cos"},  .{"tan"},             .{"asin"},    .{"acos"},   .{"atan"},    .{"atan2"},        .{"sinh"},
    .{"cosh"}, .{"tanh"}, .{"degrees"},         .{"radians"}, .{"random"}, .{"setseed"}, .{"width_bucket"}, .{"factorial"},
    .{"gcd"},  .{"lcm"},  .{"generate_series"},
});

pub const desc: repr.TypeRepr = .{
    .logical = .numeric,
    .store = numericStore,
    .store_into = storeInto,
    .list = numericList,
    .cast = numericCast,
    .group_key = groupKey,
    .json_arg = jsonArg,
    .default_bare = true,
    .exact = true,
};

const decimal_sql = @import("../../decimal_sql.zig");

/// A value stored into a numeric column: into one stored as keys (BLOB)
/// every value as the key of numeric(p, s) (xq_dec_key(v, p, s)), into one
/// of a table made before numerics were keys (ANY) as a number
/// (xq_dec_number(v)).
fn numericStore(t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store {
    _ = t;
    const d = decimal_sql.def;
    if (storage != .BLOB) return .all(.{ .def = d("xq_dec_number", 1) });
    if (typmodOf(decl)) |m| return .all(.{ .def = d("xq_dec_key", 3), .consts = m, .n_consts = 2, .bare = d("xq_dec_key", 1) });
    return .all(.{ .def = d("xq_dec_key", 1) });
}

/// A numeric stored into a column of a number or a string of type `t` is
/// made one (PostgreSQL's assignment cast; into an integer column:
/// integer.zig's storeColumn()).
fn storeInto(t: Type) ?*const int.FuncDef {
    const d = decimal_sql.def;
    return switch (t.logical) {
        .float8 => d("xq_dec_float8", 1),
        .float4 => d("xq_dec_float4", 1),
        .text, .varchar, .char => d("xq_dec_text", 1),
        else => null,
    };
}

/// The precision and scale of a declared `numeric(p [, s])`.
pub fn typmodOf(decl: []const u8) ?[2]i32 {
    const open = std.mem.indexOfScalar(u8, decl, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, decl, open, ')') orelse return null;
    var it = std.mem.splitScalar(u8, decl[open + 1 .. close], ',');
    const p = std.fmt.parseInt(i32, std.mem.trim(u8, it.next() orelse return null, " "), 10) catch return null;
    const s = if (it.next()) |z| std.fmt.parseInt(i32, std.mem.trim(u8, z, " "), 10) catch return null else 0;
    return .{ p, s };
}

/// GROUP BY and DISTINCT: a numeric that may carry its display scale by
/// its key without it (VALUES (1.5), (1.50) is one group), a column of
/// keys or a number as it is.
fn groupKey(c: *Ctx, e: *const Expr) ?[]const u8 {
    return switch (numericRepr(c, e)) {
        .pure, .number, .null => null,
        .key, .unknown => if (calls(e, "xq_dec_key")) null else "xq_dec_key",
    };
}

/// An argument of a function that builds JSON: a key (or what may be
/// one) its digits (xq_pg_dec_json()), a number of a known scale with
/// that scale (xq_pg_numeric_json()).
fn jsonArg(c: *Ctx, item: *int.ExprListItem) Error!bool {
    const a = item.expr.?;
    const t = typeOfExpr(c, a);
    if (calls(a, "xq_pg_dec_json") or calls(a, "xq_pg_numeric_json")) return false;
    if (numericRepr(c, a) != .number) {
        item.expr = try c.call("xq_pg_dec_json", &.{ a, try int32(c, if (t.scale) |s| s else -1) });
        return true;
    }
    const s = t.scale orelse return false;
    item.expr = try c.call("xq_pg_numeric_json", &.{ a, try int32(c, s) });
    return true;
}
