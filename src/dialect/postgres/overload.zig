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
//!  - numerics (repr/numeric.zig): their operators and functions
//!    compute with decimal.zig's keys (xq_dec_add() ...), a comparison
//!    compares keys, a numeric made text, a double or JSON is converted;
//!  - an xq_pg_jsonb() (xq_pg_json()) no frontend typed around a call
//!    whose result is jsonb (json or jsonb) is that call: jtype.zig
//!    wraps every value stored into a jsonb (json) column, before the
//!    value's type is known.
//! What depends on names and the structure of FROM, not on types (a FROM
//! item as a row value, the columns of a JSON set-returning function,
//! `*` next to one) stays in jtype.zig, before lowering.
//!
//! The choices of each type PostgreSQL stores in a BLOB form of its own
//! (numeric, interval, uuid, jsonb) are in its module (repr/*.zig); what
//! each type does for IN, BETWEEN, CAST, GROUP BY and ORDER BY this file
//! asks its descriptor (repr.zig), the others it calls in the order of
//! its operators below.

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const int = @import("../../sql/sqlite_int.zig");
const expr_mod = @import("../../sql/expr.zig");
const types = @import("types.zig");
const operators = @import("operators.zig");
const array = @import("array.zig");
const ctypes = @import("../../sql/types.zig");
const repr = @import("repr.zig");
const interval = @import("repr/interval.zig");
const uuid = @import("repr/uuid.zig");
const jsonb = @import("repr/jsonb.zig");
const numeric = @import("repr/numeric.zig");
const operand = @import("operand.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Logical = @import("../../sql/types.zig").Logical;

const logical = operand.logical;
const nameOf = operand.nameOf;
const isCall = operand.isCall;
const calls = operand.calls;
const args = operand.args;
const int32 = operand.int32;
const typeOfExpr = operand.typeOfExpr;

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
        TK.IN, TK.BETWEEN => repr.list(c, e),
        TK.CAST => repr.cast(c, e),
        TK.CASE => numeric.numericCase(c, e),
        TK.COLUMN => numeric.numericColumn(c, e),
        else => false,
    };
}

/// ORDER BY an array: in its type's order; an interval, jsonb: their
/// descriptors' (repr.orderCollation()).
pub fn orderCollation(c: *Ctx, id: typing.TypeId, e: *const Expr) ?[:0]const u8 {
    const t = typing.typeOf(c.p.db, id);
    if (t.logical == .array) return arrayCollation(t);
    return repr.orderCollation(c, id, e);
}

fn concat(c: *Ctx, e: *Expr) Error!bool {
    const l = e.left orelse return false;
    const r = e.right orelse return false;
    if (isArray(c, l) or isArray(c, r)) return arrayConcat(c, e, l, r);
    if (try uuid.uuidConcat(c, e)) return true;
    if (try numeric.numericText(c, l) or try numeric.numericText(c, r)) return true;
    // text || interval: the interval's text.
    if (logical(c, l) == .interval or logical(c, r) == .interval) {
        if (logical(c, l) == .interval) e.left = try interval.ivText(c, l);
        if (logical(c, r) == .interval) e.right = try interval.ivText(c, r);
        return true;
    }
    if (logical(c, l) == .json and logical(c, r) == .json) return c.fail(e, .of("42883"), "operator does not exist: json || json", .{});
    return jsonb.concat(c, e, l, r);
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
    if (op == .neg and numeric.numericLiteral(operands[0])) return false;
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
    if (try numeric.numericOperands(c, row, operands[0..n]) and row.func == null) return true;
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
    if (try uuid.uuidCompare(c, e)) return true;
    if (e.op != TK.IS and e.op != TK.ISNOT and logical(c, l) == .json and logical(c, r) == .json) {
        return c.fail(e, .of("42883"), "operator does not exist: json {s} json", .{opText(e.op)});
    }
    if (try numeric.numericCompare(c, l, r)) return true;
    // Chosen already.
    if (l.op == TK.COLLATE and (std.ascii.eqlIgnoreCase(l.token(), jsonb.jsonb_collation) or std.ascii.eqlIgnoreCase(l.token(), interval.interval_collation))) return false;
    if (interval.intervalPair(c, l, r)) return interval.intervalCompare(c, e, l, r);
    return jsonb.compare(c, e, l, r);
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
    if (try interval.intervalCall(c, e, n, items)) |changed| return changed;
    if (try arrayCall(c, e, n, items)) return true;
    var changed = try jsonb.textArgs(c, n, items);
    if (uuid.uuid_text_args.has(n)) for (items) |*item| {
        if (try uuid.uuidText(c, item)) changed = true;
    };
    if (try numeric.numericCall(c, e, n, items)) return true;
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
        const to_jsonb = n.len == "xq_pg_jsonb".len;
        if (isCall(v) and !calls(v, "xq_pg_jsonb") and !calls(v, "xq_pg_json") and (lv == .jsonb or (!to_jsonb and lv == .json))) {
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
    if (code_arg.elem == .uuid) return uuid.uuidText(c, item);
    // A numeric key: its text, which the element type reads.
    if (try numeric.elemText(c, x)) return true;
    const t = typeOfExpr(c, x);
    var code = code_arg;
    // A numeric keeps its own scale (1.50 and 2 together are 1.50, 2).
    if (code.elem == .numeric and code.scale == null and t.logical == .numeric) code.scale = t.scale;
    if (code.elem == .interval and t.logical == .interval) {
        // interval BLOB: an element is its text.
        item.expr = try interval.ivText(c, x);
        return true;
    }
    if (!needsElem(code, x, t)) return false;
    item.expr = try c.call("xq_pg_elem", &.{ x, try codeExpr(c, code) });
    return true;
}

/// Value `v` made an element of an array of `code`: wrapElem()'s.
fn elemValue(c: *Ctx, code: array.Code, v: *Expr) Error!*Expr {
    const t = typeOfExpr(c, v);
    if (code.elem == .interval and t.logical == .interval) return interval.ivText(c, v);
    if (code.elem == .uuid) return uuid.uuidElem(c, v);
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
    _ = try numeric.elemText(c, if (isArray(c, l)) r else l);
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
        _ = try numeric.elemText(c, items[0].expr.?);
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
        if (code.elem == .uuid) _ = try uuid.uuidText(c, &items[0]);
        // interval BLOB: compared with the elements as its text.
        if (code.elem == .interval and logical(c, x) == .interval) items[0].expr = try interval.ivText(c, x);
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
    // A uuid is its text (a JSON string), an interval BLOB a string of
    // its text, a numeric its digits.
    if (repr.of(t.logical)) |r| if (r.json_arg) |f| return f(c, item);
    item.expr = switch (t.logical) {
        .json, .jsonb => blk: {
            // A function whose result is JSON says so itself.
            if (isCall(a) and returnsJson(a)) return false;
            break :blk try c.call(if (t.logical == .jsonb) "xq_pg_jsonb" else "xq_pg_json", &.{a});
        },
        .boolean => try c.call("xq_pg_json_bool", &.{a}),
        .float4, .float8 => try c.call("xq_pg_float_json", &.{ a, try int32(c, @intFromBool(t.logical == .float4)) }),
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
