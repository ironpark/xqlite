//! PostgreSQL's choices by the types of operands (typing.Rules.overload
//! and .order_collation, see sql/typing.zig), made on the resolved
//! statement once its operands are typed: a column of a table, of a
//! subquery, a CTE or a view, a cast, a function's result.
//!
//!  - an arithmetic or bit operator (+ - * / %, unary -, & | << >>) is
//!    the row of operators.zig's table its operands' types choose: the
//!    engine's own operator for numbers, an engine function for dates,
//!    times, timestamps, intervals and jsonb's `-` (date + 1 is
//!    xq_pg_date_pli(d, 1)); `date + text` is an error. An operand of no
//!    known type leaves the operator to SQLite, except jsonb's `-`, which
//!    takes any right operand (as before the table: a SQLite column);
//!  - `a || b` with a jsonb operand (the other jsonb or of no type: a
//!    string literal, NULL, a parameter) is xq_pg_jsonb_concat(a, b);
//!    `json || json` is an error, as in PostgreSQL. `||` is not in the
//!    table: PostgreSQL's is text || anynonarray, of any type;
//!  - `->`, `->>`, `#>`, `#>>` (xq_pg_json_get() ...) of a jsonb operand
//!    call jsonb's functions (their results are normalized), of json
//!    json's (the text as written);
//!  - a comparison with a jsonb operand compares in jsonb's order
//!    (collation xq_pg_jsonb on the left operand), a string literal read
//!    as jsonb (xq_pg_jsonb()); `json = json` is an error; ORDER BY a
//!    jsonb value sorts in jsonb's order (orderCollation(), for the
//!    ORDER BY of a query, an aggregate and a window); intervals (BLOBs)
//!    compare by their keys and sort as BLOBs (an older database's TEXT
//!    in the collation xq_pg_interval): "intervals" below;
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
//!  - numerics (the section "numeric"): their operators and functions
//!    compute with decimal.zig's keys (xq_dec_add() ...), a comparison
//!    compares keys, a numeric made text, a double or JSON is converted;
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
const operators = @import("operators.zig");
const array = @import("array.zig");
const ctypes = @import("../../sql/types.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Logical = @import("../../sql/types.zig").Logical;

pub fn overload(c: *Ctx, e: *Expr) Error!bool {
    // An Expr of the schema's text (a view's, moved out of it by a
    // window's rewrite or a flattening) means what that text says: the
    // choices of this dialect are written there as functions.
    if (e.flags.FromDDL) return false;
    return switch (e.op) {
        TK.CONCAT => concat(c, e),
        TK.MINUS => minus(c, e),
        TK.PLUS, TK.STAR, TK.SLASH, TK.REM, TK.UMINUS, TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => arith(c, e),
        TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE, TK.IS, TK.ISNOT => compare(c, e),
        TK.FUNCTION, TK.AGG_FUNCTION => call(c, e),
        TK.IN, TK.BETWEEN => (try intervalSet(c, e)) or (try uuidList(c, e)) or (try keyList(c, e)) or (try numericList(c, e)),
        TK.CAST => (try intervalCast(c, e)) or (try uuidCast(c, e)) or (try castText(c, e)) or (try numericCast(c, e)),
        TK.CASE => numericCase(c, e),
        TK.COLUMN => numericColumn(c, e),
        else => false,
    };
}

/// ORDER BY an interval or an array: in its type's order. jsonb sorts by
/// its key (orderKey()) but in the ORDER BY of a compound, whose terms
/// are its columns: there by the collation, which orders text (jsonb of
/// a TEXT column, a cast), not JSONB blobs.
pub fn orderCollation(c: *Ctx, id: typing.TypeId, e: *const Expr) ?[:0]const u8 {
    const t = typing.typeOf(c.p.db, id);
    if (t.logical == .array) return arrayCollation(t);
    return switch (t.logical) {
        .jsonb => jsonb_collation,
        // A BLOB sorts in its order as it is (a BLOB column's index
        // serves the ORDER BY); a value that may be an older database's
        // text in the collation (which leaves BLOBs in theirs).
        .interval => if (intervalBlob(c, e)) null else interval_collation,
        else => null,
    };
}

const jsonb_collation = "xq_pg_jsonb";
/// Intervals in PostgreSQL's order (datetime.collateInterval()).
const interval_collation = "xq_pg_interval";

// ============================================================ intervals
//
// An interval is a BLOB (src/dialect/interval.zig: a key of its length,
// then its fields), in an older database's TEXT column its text; the
// functions of intervals take both. A comparison compares the keys
// (xq_pg_iv_key(): '1 mon' = '30 days'), of a BLOB column with a bound
// of the other's length (xq_pg_iv_key() below it, xq_pg_iv_high() above
// it), which an index on the column serves; GROUP BY and DISTINCT
// group by the key (groupKey()); a value made text is its text
// (xq_pg_iv_text(): ::text, ||, concat(), JSON, an array's element).

/// Whether `e` (an interval) is a BLOB: a column stored as BLOB, a call
/// of a function whose result is one.
fn intervalBlob(c: *const Ctx, e_arg: *const Expr) bool {
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
fn intervalCompare(c: *Ctx, e: *Expr, l: *Expr, r: *Expr) Error!bool {
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
fn intervalSet(c: *Ctx, e: *Expr) Error!bool {
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

/// The function a GROUP BY or DISTINCT groups values of type `id` by
/// (typing.Rules.group_key): an interval's key; a numeric that may carry
/// its display scale its key without it (VALUES (1.5), (1.50) is one
/// group), a column of keys or a number as it is.
pub fn groupKey(c: *Ctx, id: typing.TypeId, e: *const Expr) ?[]const u8 {
    return switch (typing.typeOf(c.p.db, id).logical) {
        .interval => "xq_pg_iv_key",
        .numeric => switch (numericRepr(c, e)) {
            .pure, .number, .null => null,
            .key, .unknown => if (calls(e, "xq_dec_key")) null else "xq_dec_key",
        },
        else => null,
    };
}

/// `e` (an interval) as text, where PostgreSQL makes one text: its
/// output (xq_pg_iv_text()).
fn ivText(c: *Ctx, e: *Expr) Error!*Expr {
    return c.call("xq_pg_iv_text", &.{e});
}

/// A CAST of an interval to TEXT: its text.
fn intervalCast(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    if (logical(c, l) != .interval or !e.useUToken()) return false;
    const z = e.u.token orelse return false;
    if (!std.ascii.eqlIgnoreCase(z, "TEXT")) return false;
    const t = e.xq_type;
    try c.toCall(e, "xq_pg_iv_text", &.{l});
    if (t != typing.unknown) e.xq_type = t;
    return true;
}

fn logical(c: *const Ctx, e: *const Expr) Logical {
    return typing.typeOf(c.p.db, e.xq_type).logical;
}

/// An operand of no type of its own (PostgreSQL's unknown): a string
/// literal, NULL, a parameter of no known type.
fn untyped(e: *const Expr) bool {
    return e.op == TK.STRING or e.op == TK.NULL or (e.op == TK.VARIABLE and e.xq_type == typing.unknown);
}

/// Whether `a op b` is an operator of intervals (pairOf()), a string
/// literal under a unary + too (x IN ('1 day') is x = +'1 day').
fn intervalPair(c: *const Ctx, a: *const Expr, b: *const Expr) bool {
    const plusString = struct {
        fn f(e: *const Expr) bool {
            return e.op == TK.UPLUS and e.left != null and e.left.?.op == TK.STRING;
        }
    }.f;
    if (pairOf(c, a, b, .interval)) return true;
    return (logical(c, a) == .interval and plusString(b)) or (logical(c, b) == .interval and plusString(a));
}

/// Whether `a op b` is jsonb's operator: a jsonb operand, the other
/// jsonb or of no type.
fn jsonbPair(c: *const Ctx, a: *const Expr, b: *const Expr) bool {
    return pairOf(c, a, b, .jsonb);
}

/// Whether `a op b` is an operator of type `l`: an operand of `l`, the
/// other of `l` or of no type.
fn pairOf(c: *const Ctx, a: *const Expr, b: *const Expr, l: Logical) bool {
    const la = logical(c, a);
    const lb = logical(c, b);
    return (la == l and (lb == l or untyped(b))) or (lb == l and untyped(a));
}

fn concat(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (isArray(c, l) or isArray(c, r)) return arrayConcat(c, e, l, r);
    if (try uuidConcat(c, e)) return true;
    if (try numericText(c, l) or try numericText(c, r)) return true;
    // text || interval: the interval's text.
    if (logical(c, l) == .interval or logical(c, r) == .interval) {
        if (logical(c, l) == .interval) e.left = try ivText(c, l);
        if (logical(c, r) == .interval) e.right = try ivText(c, r);
        return true;
    }
    if (logical(c, l) == .json and logical(c, r) == .json) return c.fail(e, .of("42883"), "operator does not exist: json || json", .{});
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

/// Whether `e` is of a text type.
fn isText(c: *const Ctx, e: *const Expr) bool {
    return switch (logical(c, e)) {
        .text, .varchar, .char => true,
        else => false,
    };
}

/// `a - b`: the table's, but jsonb minus an operand of no type the table
/// knows (a SQLite column, an int[]) deletes it, a key or the keys of
/// an array.
fn minus(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (logical(c, l) == .jsonb and argOf(c, r) == null) {
        try c.toCall(e, if (arrayOf(c, r) != null) "xq_pg_jsonb_delete_keys" else "xq_pg_jsonb_delete", &.{ l, r });
        return true;
    }
    return arith(c, e);
}

/// What operand `x` is to the table: a string literal PostgreSQL's
/// unknown, a parameter or NULL one that never fails the statement, null
/// for an operand of no type the table knows.
fn argOf(c: *const Ctx, x: *const Expr) ?operators.Arg {
    switch (x.op) {
        TK.STRING => return .literal,
        TK.NULL, TK.VARIABLE => return .loose,
        else => {},
    }
    const t = operators.T.of(typing.typeOf(c.p.db, x.xq_type), typing.spelling(c.p.db, x.xq_type)) orelse return null;
    return .{ .known = t };
}

/// An arithmetic or bit operator by operators.zig's table: an engine
/// function's row makes it a call; a parameter takes the type of the
/// row's operand (`ts + $1`: an interval).
fn arith(c: *Ctx, e: *Expr) Error!bool {
    const op: operators.Op = switch (e.op) {
        TK.PLUS => .add,
        TK.MINUS => .sub,
        TK.STAR => .mul,
        TK.SLASH => .div,
        TK.REM => .mod,
        TK.UMINUS => .neg,
        TK.BITAND => .bit_and,
        TK.BITOR => .bit_or,
        TK.LSHIFT => .shl,
        TK.RSHIFT => .shr,
        else => return false,
    };
    var operands: [2]*Expr = undefined;
    var ops: [2]operators.Arg = undefined;
    operands[0] = e.left orelse return false;
    // -1.5: a literal (a number until a numeric's operator reads it).
    if (op == .neg and numericLiteral(operands[0])) return false;
    const n: usize = if (op == .neg) 1 else 2;
    if (n == 2) operands[1] = e.right orelse return false;
    var known = false;
    var loose = false;
    for (operands[0..n], ops[0..n]) |x, *a| {
        a.* = argOf(c, x) orelse return false;
        switch (a.*) {
            .known => known = true,
            .loose => loose = true,
            .literal => {},
        }
    }
    // Literals only: SQLite's.
    if (!known) return false;
    const r = operators.resolve(op, ops[0..n]);
    const row = switch (r) {
        .entry => |row| row,
        else => {
            // A parameter or NULL may be of any type.
            if (loose) return false;
            var buf: [160]u8 = undefined;
            const msg = operators.message(r, op, ops[0..n], &buf);
            return c.fail(e, if (r == .not_unique) .of("42725") else .of("42883"), "{s}", .{msg});
        },
    };
    for (operands[0..n], ops[0..n], row.args) |x, a, t| if (a == .loose and x.op == TK.VARIABLE and logical(c, x) != t.logical()) {
        try typing.retypeParam(c.p, x, try c.named(t.name()));
    };
    if (try numericOperands(c, row, operands[0..n]) and row.func == null) return true;
    const f = row.func orelse {
        // A string literal is read as the integer the row takes ('a' + 1
        // is invalid input for type integer, as in PostgreSQL), not by
        // SQLite's affinity.
        var changed = false;
        for (operands[0..n], ops[0..n], row.args, 0..) |x, a, t, i| if (a == .literal) {
            const cast = intInput(t) orelse continue;
            const w = try c.call(cast, &.{x});
            if (i == 0) e.left = w else e.right = w;
            changed = true;
        };
        return changed;
    };
    try c.toCall(e, f, operands[0..n]);
    return true;
}

/// The cast that reads a string as an integer of type `t`.
pub fn intInput(t: operators.T) ?[]const u8 {
    return switch (t) {
        .int2 => "xq_pg_int2",
        .int4 => "xq_pg_int4",
        .int8 => "xq_pg_int8",
        else => null,
    };
}

fn compare(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (isArray(c, l) or isArray(c, r)) return arrayCompare(c, e, l, r);
    if (try uuidCompare(c, e)) return true;
    if (e.op != TK.IS and e.op != TK.ISNOT and logical(c, l) == .json and logical(c, r) == .json) {
        return c.fail(e, .of("42883"), "operator does not exist: json {s} json", .{opText(e.op)});
    }
    if (try numericCompare(c, l, r)) return true;
    // Chosen already.
    if (l.op == TK.COLLATE and (std.ascii.eqlIgnoreCase(l.token(), jsonb_collation) or std.ascii.eqlIgnoreCase(l.token(), interval_collation))) return false;
    if (intervalPair(c, l, r)) return intervalCompare(c, e, l, r);
    // jsonb (JSONB blob or text): the sort keys compared
    // (xq_pg_jsonb_key(), which reads a string literal as jsonb).
    if (calls(l, jsonb_key)) return false;
    if (!jsonbPair(c, l, r)) return false;
    e.left = try c.call(jsonb_key, &.{l});
    e.right = try c.call(jsonb_key, &.{r});
    return true;
}

/// The sort key of jsonb (jfuncs.zig): what its comparisons and ORDER BY
/// compare, whether the value is a JSONB blob or text.
pub const jsonb_key = "xq_pg_jsonb_key";

/// ORDER BY a jsonb value: by its sort key (Rules.order_key).
pub fn orderKey(c: *Ctx, id: typing.TypeId) ?[:0]const u8 {
    return if (typing.typeOf(c.p.db, id).logical == .jsonb) jsonb_key else null;
}

/// `j IN (a, b ...)`, `j BETWEEN a AND b` of jsonb: the sort keys, as
/// compare().
fn keyList(c: *Ctx, e: *Expr) Error!bool {
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
fn textArgs(c: *Ctx, n: []const u8, items: []int.ExprListItem) Error!bool {
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
fn castText(c: *Ctx, e: *Expr) Error!bool {
    const x = e.left orelse return false;
    if (logical(c, x) != .jsonb or calls(x, "xq_pg_jsonb_text")) return false;
    if (!e.useUToken() or !std.ascii.eqlIgnoreCase(e.token(), "TEXT")) return false;
    e.left = try c.call("xq_pg_jsonb_text", &.{x});
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
    if (try intervalCall(c, e, n, items)) |changed| return changed;
    if (try arrayCall(c, e, n, items)) return true;
    var changed = try textArgs(c, n, items);
    if (uuid_text_args.has(n)) for (items) |*item| {
        if (try uuidText(c, item)) changed = true;
    };
    if (try numericCall(c, e, n, items)) return true;
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
            list = try expr_mod.listAppend(p, list, try int32(c, num));
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

/// The calls of intervals: sum() and avg() of intervals are
/// xq_pg_iv_sum() and xq_pg_iv_avg() (PostgreSQL's arithmetic of
/// intervals, a BLOB), concat() and format() take an interval's text;
/// whether that changed the operands of `e`, null for another call.
fn intervalCall(c: *Ctx, e: *Expr, n: []const u8, items: []int.ExprListItem) Error!?bool {
    const eql = std.mem.eql;
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

/// If `e` is an array (text[], int[] ..., ARRAY[...]), what its elements
/// are as JSON: 0 strings, 1 numbers, 2 booleans (xq_pg_array_to_json()).
fn arrayOf(c: *const Ctx, e: *const Expr) ?i32 {
    const t = typing.typeOf(c.p.db, e.xq_type);
    if (t.logical != .array) return null;
    const el = array.Elem.of(t.element);
    return if (el.isNumber()) 1 else if (el == .boolean) 2 else 0;
}

// ================================================================ arrays

fn isArray(c: *const Ctx, e: *const Expr) bool {
    return logical(c, e) == .array;
}

fn typeOfExpr(c: *const Ctx, e: *const Expr) ctypes.Type {
    return typing.typeOf(c.p.db, e.xq_type);
}

/// The collation arrays of type `t` compare and sort with: element by
/// element, numbers by value.
fn arrayCollation(t: ctypes.Type) [:0]const u8 {
    const el = array.Elem.of(t.element);
    return if (el.isNumber()) array.collation_number else array.collation_text;
}

/// An integer literal of `code`.
fn codeExpr(c: *Ctx, code: array.Code) Error!*Expr {
    const x = try expr_mod.exprInt32(c.p.arena, @intCast(code.encode()));
    x.xq_type = typing.plain(.int4);
    return x;
}

/// Whether a value of type `t` stored as an element of `code` needs its
/// text made (xq_pg_elem()): a boolean's t/f, a real's digits, a
/// numeric's scale, a string read as the element type.
fn needsElem(code: array.Code, e: *const Expr, t: ctypes.Type) bool {
    if (e.op == TK.NULL) return false;
    if (e.op == TK.STRING) return code.elem != .text and code.elem != .unknown;
    return switch (code.elem) {
        .boolean, .float4 => true,
        .numeric => code.scale != null and code.scale.? > 0 and t.logical != .text,
        .bytea => t.logical == .bytes,
        // A jsonb column's value is a JSONB blob: its text.
        .jsonb => t.logical == .jsonb,
        else => false,
    };
}

/// Wrap `item` in xq_pg_elem(item, code) if it needs it; whether it did.
fn wrapElem(c: *Ctx, item: *int.ExprListItem, code_arg: array.Code) Error!bool {
    const x = item.expr.?;
    if (calls(x, "xq_pg_elem")) return false;
    if (code_arg.elem == .uuid) return uuidText(c, item);
    // A numeric key: its text, which the element type reads.
    if (try elemText(c, x)) return true;
    const t = typeOfExpr(c, x);
    var code = code_arg;
    // A numeric keeps its own scale (1.50 and 2 together are 1.50, 2).
    if (code.elem == .numeric and code.scale == null and t.logical == .numeric) code.scale = t.scale;
    if (code.elem == .interval and t.logical == .interval) {
        // interval BLOB: an element is its text.
        item.expr = try ivText(c, x);
        return true;
    }
    if (!needsElem(code, x, t)) return false;
    item.expr = try c.call("xq_pg_elem", &.{ x, try codeExpr(c, code) });
    return true;
}

/// Value `v` made an element of an array of `code`: wrapElem()'s.
fn elemValue(c: *Ctx, code: array.Code, v: *Expr) Error!*Expr {
    const t = typeOfExpr(c, v);
    if (code.elem == .interval and t.logical == .interval) return ivText(c, v);
    if (code.elem == .uuid) return uuidElem(c, v);
    if (needsElem(code, v, t)) return c.call("xq_pg_elem", &.{ v, try codeExpr(c, code) });
    return v;
}

/// `a || b` with an array operand: of two arrays (or an array and a
/// string literal or NULL, which PostgreSQL reads as an array)
/// array_cat(), of an array and an element array_append() or
/// array_prepend().
fn arrayConcat(c: *Ctx, e: *Expr, l: *Expr, r: *Expr) Error!bool {
    const la = isArray(c, l) or l.op == TK.STRING or l.op == TK.NULL;
    const ra = isArray(c, r) or r.op == TK.STRING or r.op == TK.NULL;
    if (la and ra) {
        try c.toCall(e, "xq_pg_array_cat2", &.{ l, r });
        return true;
    }
    _ = try elemText(c, if (isArray(c, l)) r else l);
    if (isArray(c, l)) {
        const code = array.Code.ofArray(typeOfExpr(c, l));
        const v = try elemValue(c, code, r);
        try c.toCall(e, "xq_pg_array_append", &.{ l, v });
        return true;
    }
    const code = array.Code.ofArray(typeOfExpr(c, r));
    const v = try elemValue(c, code, l);
    try c.toCall(e, "xq_pg_array_prepend", &.{ v, r });
    return true;
}

/// A comparison of arrays: a string literal read as the other's type,
/// the arrays in PostgreSQL's order (collation xq_pg_array[_num]).
fn arrayCompare(c: *Ctx, e: *Expr, l: *Expr, r: *Expr) Error!bool {
    if (l.op == TK.COLLATE and (std.ascii.eqlIgnoreCase(l.token(), array.collation_text) or std.ascii.eqlIgnoreCase(l.token(), array.collation_number))) return false;
    const t = if (isArray(c, l)) typeOfExpr(c, l) else typeOfExpr(c, r);
    var left = l;
    if (l.op == TK.STRING) left = try c.call(array.inputName(t.element), &.{l});
    if (r.op == TK.STRING) e.right = try c.call(array.inputName(t.element), &.{r});
    e.left = try c.collate(left, arrayCollation(t));
    return true;
}

/// The choices of the calls of arrays; whether one changed `e`.
fn arrayCall(c: *Ctx, e: *Expr, n: []const u8, items: []int.ExprListItem) Error!bool {
    const eql = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (eql(n, "xq_pg_array")) {
        if (items.len == 0) return false;
        var nested = false;
        for (items) |item| if (isArray(c, item.expr.?)) {
            nested = true;
        };
        if (nested) {
            try c.rename(e, "xq_pg_array_nested");
            return false;
        }
        var ops: [64]typing.Operand = undefined;
        if (items.len > ops.len) return false;
        for (items, 0..) |item, i| ops[i] = c.operand(item.expr.?);
        const id = try typing.commonOf(c, ops[0..items.len]);
        if (id == typing.unknown) return false;
        const code = array.Code.ofValue(typing.typeOf(c.p.db, id));
        // interval BLOB: the elements become text (wrapElem()), the array
        // stays an interval[].
        if (code.elem == .interval and !code.nested and e.xq_type == typing.unknown) e.xq_type = try c.make(typing.typeOf(c.p.db, id).arrayOf());
        var changed = false;
        for (items) |*item| changed = try wrapElem(c, item, code) or changed;
        return changed;
    }
    if (eql(n, "xq_pg_array_agg") or eql(n, "array_agg")) {
        if (items.len != 1) return false;
        const x = items[0].expr.?;
        if (isArray(c, x)) {
            try c.rename(e, "xq_pg_array_agg_arrays");
            return false;
        }
        const tx = typeOfExpr(c, x);
        if (tx.logical == .interval and e.xq_type == typing.unknown) e.xq_type = try c.make(tx.arrayOf());
        return wrapElem(c, &items[0], array.Code.ofValue(tx));
    }
    if (eql(n, "xq_pg_jsonb_contains")) {
        if (items.len == 2 and (isArray(c, items[0].expr.?) or isArray(c, items[1].expr.?))) try c.rename(e, "xq_pg_array_contains");
        return false;
    }
    if (eql(n, "xq_pg_any")) {
        if (items.len != 4) return false;
        _ = try elemText(c, items[0].expr.?);
        const x = items[0].expr.?;
        const a = items[1].expr.?;
        const ta = typeOfExpr(c, a);
        const tx = typeOfExpr(c, x);
        // (A text may be an array's text: the catalog's columns of types
        // it has not, an expression of a SQLite table.)
        if (typing.isNumber(ta.logical) or ta.logical == .boolean) {
            return c.fail(e, .of("42809"), "op ANY/ALL (array) requires array on right side", .{});
        }
        // A parameter of no type is of the other's.
        if (a.op == TK.VARIABLE and a.xq_type == typing.unknown and tx.logical != .array and x.xq_type != typing.unknown) {
            // (Of a type of no Logical, name: a text[].)
            try typing.retypeParam(c.p, a, if (tx.logical == .unknown) try c.named("text[]") else try c.make(tx.arrayOf()));
        } else if (x.op == TK.VARIABLE and x.xq_type == typing.unknown and ta.logical == .array and ta.element != .unknown) {
            try typing.retypeParam(c.p, x, try c.make(ta.elementType()));
        }
        var code = array.Code.ofArray(typeOfExpr(c, a));
        if (code.elem == .unknown and x.op != TK.STRING) code = array.Code.ofValue(typeOfExpr(c, x));
        if (code.elem == .unknown or code.nested) return false;
        // A uuid as the text of the elements.
        if (code.elem == .uuid) _ = try uuidText(c, &items[0]);
        // interval BLOB: compared with the elements as its text.
        if (code.elem == .interval and logical(c, x) == .interval) items[0].expr = try ivText(c, x);
        var list = e.x.list;
        list = try expr_mod.listAppend(c.p, list, try codeExpr(c, code));
        e.x = .{ .list = list };
        return true;
    }
    if (eql(n, "xq_pg_subscript")) {
        if (items.len < 2) return false;
        const t = typeOfExpr(c, items[0].expr.?);
        // jsonb's subscripts (j['a'][0]): the path of them (#>: a key of
        // an object, an index of an array, of a scalar none).
        if (t.logical == .jsonb) {
            var steps: [64]*Expr = undefined;
            if (items.len - 1 > steps.len) return false;
            for (items[1..], 0..) |s, i| steps[i] = s.expr.?;
            const path = try c.call("xq_pg_array", steps[0 .. items.len - 1]);
            e.xq_type = typing.unknown;
            try c.toCall(e, "xq_pg_jsonb_path", &.{ items[0].expr.?, path });
            return true;
        }
        if (t.logical != .array or t.element == .unknown) return false;
        var list = e.x.list;
        list = try expr_mod.listAppend(c.p, list, try codeExpr(c, array.Code.ofArray(t)));
        e.x = .{ .list = list };
        try c.rename(e, "xq_pg_subscript_k");
        return true;
    }
    if (eql(n, "xq_pg_rows_unnest")) {
        if (items.len != 1) return false;
        const t = typeOfExpr(c, items[0].expr.?);
        if (t.logical != .array or t.element == .unknown) return false;
        var list = e.x.list;
        list = try expr_mod.listAppend(c.p, list, try codeExpr(c, array.Code.ofArray(t)));
        e.x = .{ .list = list };
        return true;
    }
    // The value made an element of an array of a type.
    const value_arg: ?struct { usize, usize } = if (eql(n, "array_append") or eql(n, "xq_pg_array_append"))
        .{ 0, 1 }
    else if (eql(n, "array_prepend") or eql(n, "xq_pg_array_prepend"))
        .{ 1, 0 }
    else if (eql(n, "array_replace"))
        .{ 0, 2 }
    else if (eql(n, "xq_pg_array_set"))
        .{ 0, 1 }
    else
        null;
    if (value_arg) |va| {
        if (items.len <= @max(va[0], va[1])) return false;
        const t = typeOfExpr(c, items[va[0]].expr.?);
        if (t.logical != .array) return false;
        return wrapElem(c, &items[va[1]], array.Code.ofArray(t));
    }
    return false;
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
        // A uuid is its text (a JSON string).
        .uuid => return uuidText(c, item),
        .float4, .float8 => try c.call("xq_pg_float_json", &.{ a, try int32(c, @intFromBool(t.logical == .float4)) }),
        .numeric => blk: {
            if (calls(a, "xq_pg_dec_json") or calls(a, "xq_pg_numeric_json")) return false;
            // A key (or what may be one): its digits.
            if (numericRepr(c, a) != .number) break :blk try c.call("xq_pg_dec_json", &.{ a, try int32(c, if (t.scale) |s| s else -1) });
            const s = t.scale orelse return false;
            break :blk try c.call("xq_pg_numeric_json", &.{ a, try int32(c, s) });
        },
        // interval BLOB: a string of its text.
        .interval => try ivText(c, a),
        else => blk: {
            const num = arrayOf(c, a) orelse return false;
            break :blk try c.call("xq_pg_array_to_json", &.{ a, try int32(c, 0), try int32(c, num) });
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
    .{"to_jsonb"},                   .{"jsonb_build_object"},        .{"jsonb_build_array"},       .{"jsonb_object"},
    .{"jsonb_agg"},                  .{"jsonb_object_agg"},          .{"jsonb_set"},               .{"jsonb_set_lax"},
    .{"jsonb_insert"},               .{"jsonb_strip_nulls"},         .{"jsonb_extract_path"},      .{"jsonb_path_query_array"},
    .{"jsonb_path_query_first"},     .{"xq_pg_jsonb"},               .{"xq_pg_jsonb_get"},         .{"xq_pg_jsonb_path"},
    .{"xq_pg_jsonb_concat"},         .{"xq_pg_jsonb_delete"},        .{"xq_pg_jsonb_delete_keys"}, .{"xq_pg_jsonb_delete_path"},
    .{"to_json"},                    .{"json_build_object"},         .{"json_build_array"},        .{"json_object"},
    .{"json_agg"},                   .{"json_object_agg"},           .{"json_strip_nulls"},        .{"json_extract_path"},
    .{"row_to_json"},                .{"array_to_json"},             .{"xq_pg_json"},              .{"xq_pg_json_get"},
    .{"xq_pg_json_path"},            .{"xq_pg_row_json"},            .{"xq_pg_array_to_json"},     .{"xq_pg_json_agg_rows"},
    .{"xq_pg_json_bool"},            .{"xq_pg_float_json"},          .{"xq_pg_numeric_json"},      .{"xq_pg_jsonb_contains"},
    .{"xq_pg_dec_json"},             .{"xq_pg_jsonb_exists"},        .{"xq_pg_jsonb_exists_any"},  .{"xq_pg_jsonb_exists_all"},
    .{"xq_pg_jsonb_path_exists_op"}, .{"xq_pg_jsonb_path_match_op"}, .{"jsonb_path_exists"},       .{"jsonb_path_match"},
    .{"xq_pg_is_json"},              .{"xq_pg_bool"},                .{"xq_like"},                 .{"xq_ilike"},
    .{"starts_with"},                .{"xq_pg_text_array"},
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

// ================================================================ numeric
//
// A numeric is decimal.zig's key (a BLOB in the order of the numbers,
// maybe with its display scale after it) where it comes from a column of
// keys or a function of decimal_sql.zig (xq_dec_add() ...), and a SQLite
// number where it comes from a literal (1.50 is the double 1.5, typed of
// scale 2) or a numeric column of a table made before numerics were keys.
// The functions of keys read numbers too, so:
//  - an operator of the numeric rows of operators.zig is its function
//    (`a + b` is xq_dec_add(a, b)); a literal operand is its key
//    (xq_dec('1.50'): its digits and scale, which the double lost), a
//    column of numeric(p, s) of its scale (xq_dec(a, 1000, s), as
//    PostgreSQL keeps it with the value);
//  - a comparison of numerics compares keys without their scales
//    (xq_dec_key() of what is not a column of keys: `n = 1.5` is
//    `n = xq_dec_key('1.5')`, a constant, so that an index on n is used);
//    of numbers only (literals, older columns) SQLite's comparison; with
//    a double the numeric's double (xq_dec_float8()), as PostgreSQL;
//    IN, BETWEEN and CASE x WHEN likewise;
//  - CASE, coalesce(), greatest() ... of keys and other numerics make
//    them all keys (xq_dec());
//  - round(), trunc(), ceil(), floor(), abs(), sign(), mod(), div(),
//    sum(), avg(), the casts to integers of a numeric are decimal_sql.zig's
//    (sum() of a bigint and avg() of an integer too: PostgreSQL's are
//    numerics); scale(), min_scale(), trim_scale() of any;
//  - a key made text (`||`, a cast to text, an array's element, a
//    function of text: xq_dec_text(x, scale)), a double (a cast to a
//    float, a float function, an operator with a double:
//    xq_dec_float8()), JSON (xq_pg_dec_json(x, scale)).

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

fn numericRepr(c: *const Ctx, e: *const Expr) Repr {
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
            if (key_functions.has(n)) return .key;
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

/// The functions whose result is a key (decimal_sql.zig's, and PostgreSQL's
/// of numerics made them).
const key_functions = std.StaticStringMap(void).initComptime(.{
    .{"xq_dec"},           .{"xq_dec_add"},  .{"xq_dec_sub"},        .{"xq_dec_mul"},   .{"xq_dec_div"},
    .{"xq_dec_mod"},       .{"xq_dec_neg"},  .{"xq_dec_abs"},        .{"xq_dec_ceil"},  .{"xq_dec_floor"},
    .{"xq_dec_div_trunc"}, .{"xq_dec_sign"}, .{"xq_dec_trim_scale"}, .{"xq_dec_round"}, .{"xq_dec_trunc"},
    .{"xq_dec_sum"},       .{"xq_dec_avg"},
});

/// Whether `e` is a numeric literal: a decimal (TK_FLOAT) or an integer
/// beyond 64 bits, or one negated.
fn numericLiteral(e: *const Expr) bool {
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
fn numericText(c: *Ctx, x: *Expr) Error!bool {
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
fn elemText(c: *Ctx, x: *Expr) Error!bool {
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
fn numericOperands(c: *Ctx, row: *const operators.Entry, operands: []*Expr) Error!bool {
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
fn numericCompare(c: *Ctx, l: *Expr, r: *Expr) Error!bool {
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
fn numericList(c: *Ctx, e: *Expr) Error!bool {
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
fn numericCase(c: *Ctx, e: *Expr) Error!bool {
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
fn numericColumn(c: *Ctx, e: *Expr) Error!bool {
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
fn numericCast(c: *Ctx, e: *Expr) Error!bool {
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
fn numericCall(c: *Ctx, e: *Expr, n: []const u8, items: []int.ExprListItem) Error!bool {
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
    if (std.mem.startsWith(u8, n, "xq_dec") or key_functions.has(n)) return false;
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
        if (e.op == TK.AGG_FUNCTION or e.isWindowFunc()) {
            const l = logical(c, items[0].expr.?);
            if (eql(n, "sum") and items.len == 1 and (l == .numeric or l == .int8)) break :blk "xq_dec_sum";
            if (eql(n, "avg") and items.len == 1 and (l == .numeric or typing.intWidth(l) != null)) break :blk "xq_dec_avg";
        }
        if (first and items.len == 1) {
            if (eql(n, "xq_pg_int2")) break :blk "xq_dec_int2";
            if (eql(n, "xq_pg_int4")) break :blk "xq_dec_int4";
            if (eql(n, "xq_pg_int8")) break :blk "xq_dec_int8";
        }
        break :blk null;
    };
    if (renamed) |r| {
        // The value (the first argument; both of mod() and div()) exact.
        const exact: usize = if (eql(r, "xq_dec_mod") or eql(r, "xq_dec_div_trunc")) 2 else 1;
        for (items[0..@min(exact, items.len)]) |item| _ = try exactOperand(c, item.expr.?);
        try c.rename(e, r);
        return true;
    }
    if (aware_functions.has(n) or numeric_engine.has(n) or builderArgs(n) != .none) {
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

// ================================================================ uuid

/// How a uuid operand is stored: the 16 bytes of a uuid column (and of
/// the functions that make one), the text of a uuid column of an older
/// table (stored as TEXT), or either (another expression: a subscript of
/// a uuid[], a CASE ...). By the SQLite affinity of a column, which a
/// subquery's or a view's column has from the column it reads.
const UuidForm = enum { bytes, text, either };

const uuid_bytes_calls = std.StaticStringMap(void).initComptime(.{
    .{"xq_pg_uuid"}, .{"uuidv4"}, .{"uuidv7"},
});

fn uuidForm(e_arg: *const Expr) UuidForm {
    var e = e_arg;
    while ((e.op == TK.COLLATE or e.op == TK.UPLUS) and e.left != null) e = e.left.?;
    switch (e.op) {
        TK.COLUMN, TK.AGG_COLUMN => return switch (expr_mod.affinity(e)) {
            int.Aff.blob => .bytes,
            int.Aff.text => .text,
            else => .either,
        },
        TK.FUNCTION => {
            if (!isCall(e)) return .either;
            var buf: [64]u8 = undefined;
            const n = nameOf(e, &buf);
            if (uuid_bytes_calls.has(n)) return .bytes;
            if (std.mem.eql(u8, n, "xq_pg_uuid_text")) return .text;
            return .either;
        },
        else => return .either,
    }
}

/// Whether `e` is a uuid operand of a comparison: of type uuid, or of
/// no type of its own (a string literal, a parameter, NULL).
fn uuidOperand(c: *const Ctx, e: *const Expr) bool {
    // (`x IN (a)` is `x = +a`.)
    var x = e;
    while (x.op == TK.UPLUS and x.left != null) x = x.left.?;
    return logical(c, x) == .uuid or untyped(x);
}

/// Bring the operands `ops` of a comparison of uuids (one of them of
/// type uuid, the others too or of no type) to one form: the text if one
/// is a column stored as text (an older table: its index is used), else
/// the bytes, so that a uuid column is compared as it is stored and its
/// index is used (a literal or a parameter is read once, at its place:
/// xq_pg_uuid('...') is a constant). Whether it changed one.
fn uuidUnify(c: *Ctx, ops: []const *?*Expr) Error!bool {
    var any = false;
    var text = false;
    for (ops) |o| {
        const x = o.* orelse return false;
        if (!uuidOperand(c, x)) return false;
        if (logical(c, x) == .uuid) any = true;
        if (uuidForm(x) == .text) text = true;
    }
    if (!any) return false;
    const want: UuidForm = if (text) .text else .bytes;
    var changed = false;
    for (ops) |o| {
        const x = o.*.?;
        if (x.op == TK.NULL or uuidForm(x) == want) continue;
        o.* = try c.call(if (text) "xq_pg_uuid_text" else "xq_pg_uuid", &.{x});
        changed = true;
    }
    return changed;
}

fn uuidCompare(c: *Ctx, e: *Expr) Error!bool {
    return uuidUnify(c, &.{ &e.left, &e.right });
}

/// `x IN (a, b ...)`, `x BETWEEN a AND b` of uuids.
fn uuidList(c: *Ctx, e: *Expr) Error!bool {
    if (!e.useXList()) return false;
    const list = e.x.list orelse return false;
    const items = list.slice();
    if (items.len > 64) return false;
    var ops: [65]*?*Expr = undefined;
    ops[0] = &e.left;
    for (items, 1..) |*item, i| ops[i] = &item.expr;
    return uuidUnify(c, ops[0 .. items.len + 1]);
}

/// A uuid cast to text is its text (uuid_out()), not SQLite's text of
/// its bytes.
fn uuidCast(c: *Ctx, e: *Expr) Error!bool {
    const x = e.left orelse return false;
    if (logical(c, x) != .uuid or !std.ascii.eqlIgnoreCase(e.token(), "TEXT")) return false;
    try c.toCall(e, "xq_pg_uuid_text", &.{x});
    return true;
}

/// `u || 'x'`: PostgreSQL's text || anynonarray writes the uuid's text.
fn uuidConcat(c: *Ctx, e: *Expr) Error!bool {
    var changed = false;
    for ([_]*?*Expr{ &e.left, &e.right }) |o| {
        const x = o.* orelse continue;
        if (logical(c, x) != .uuid or uuidForm(x) == .text) continue;
        o.* = try c.call("xq_pg_uuid_text", &.{x});
        changed = true;
    }
    return changed;
}

/// The engine functions that take numerics as they are, or whose
/// numeric arguments overload.zig makes what they read (arrays, JSON).
const numeric_engine = std.StaticStringMap(void).initComptime(.{
    .{"xq_pg_dec_json"},         .{"xq_pg_numeric_json"},    .{"xq_pg_elem"},          .{"xq_pg_array"},
    .{"xq_pg_array_nested"},     .{"xq_pg_array_agg"},       .{"xq_pg_any"},           .{"xq_pg_array_append"},
    .{"xq_pg_array_prepend"},    .{"xq_pg_array_set"},       .{"xq_pg_array_cat2"},    .{"xq_pg_row_json"},
    .{"xq_pg_json_ctor_object"}, .{"xq_pg_json_ctor_array"}, .{"xq_pg_json_arrayagg"}, .{"xq_pg_json_objectagg"},
    .{"xq_pg_json_agg_rows"},
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

/// The functions that write the text of a uuid argument (concat() ...).
const uuid_text_args = std.StaticStringMap(void).initComptime(.{
    .{"concat"}, .{"concat_ws"}, .{"format"},
});

/// Wrap `item`, if it is a uuid not stored as text, in its text
/// (xq_pg_uuid_text(), typed uuid still: an array's element, an argument
/// of a function that writes its arguments' text); whether it did.
fn uuidText(c: *Ctx, item: *int.ExprListItem) Error!bool {
    const x = item.expr.?;
    if (logical(c, x) != .uuid or uuidForm(x) == .text) return false;
    item.expr = try uuidElem(c, x);
    return true;
}

/// `x` (a uuid) as the text an array keeps of its elements.
fn uuidElem(c: *Ctx, x: *Expr) Error!*Expr {
    if (logical(c, x) != .uuid or uuidForm(x) == .text) return x;
    const w = try c.call("xq_pg_uuid_text", &.{x});
    w.xq_type = x.xq_type;
    return w;
}
