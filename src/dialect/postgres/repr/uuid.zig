//! PostgreSQL's uuid (postgres/repr.zig's descriptor and the choices
//! overload.zig makes for it): 16 bytes in a uuid column (uuid.zig's
//! functions), the text in the TEXT column of an older table.

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
const expr_mod = @import("../../../sql/expr.zig");
const logical = operand.logical;
const untyped = operand.untyped;
const nameOf = operand.nameOf;
const isCall = operand.isCall;

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

pub fn uuidCompare(c: *Ctx, e: *Expr) Error!bool {
    return uuidUnify(c, &.{ &e.left, &e.right });
}

/// `x IN (a, b ...)`, `x BETWEEN a AND b` of uuids.
pub fn uuidList(c: *Ctx, e: *Expr) Error!bool {
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
pub fn uuidCast(c: *Ctx, e: *Expr) Error!bool {
    const x = e.left orelse return false;
    if (logical(c, x) != .uuid or !std.ascii.eqlIgnoreCase(e.token(), "TEXT")) return false;
    try c.toCall(e, "xq_pg_uuid_text", &.{x});
    return true;
}

/// `u || 'x'`: PostgreSQL's text || anynonarray writes the uuid's text.
pub fn uuidConcat(c: *Ctx, e: *Expr) Error!bool {
    var changed = false;
    for ([_]*?*Expr{ &e.left, &e.right }) |o| {
        const x = o.* orelse continue;
        if (logical(c, x) != .uuid or uuidForm(x) == .text) continue;
        o.* = try c.call("xq_pg_uuid_text", &.{x});
        changed = true;
    }
    return changed;
}

/// The functions that write the text of a uuid argument (concat() ...).
pub const uuid_text_args = std.StaticStringMap(void).initComptime(.{
    .{"concat"}, .{"concat_ws"}, .{"format"},
});

/// Wrap `item`, if it is a uuid not stored as text, in its text
/// (xq_pg_uuid_text(), typed uuid still: an array's element, an argument
/// of a function that writes its arguments' text); whether it did.
pub fn uuidText(c: *Ctx, item: *int.ExprListItem) Error!bool {
    const x = item.expr.?;
    if (logical(c, x) != .uuid or uuidForm(x) == .text) return false;
    item.expr = try uuidElem(c, x);
    return true;
}

/// `x` (a uuid) as the text an array keeps of its elements.
pub fn uuidElem(c: *Ctx, x: *Expr) Error!*Expr {
    if (logical(c, x) != .uuid or uuidForm(x) == .text) return x;
    const w = try c.call("xq_pg_uuid_text", &.{x});
    w.xq_type = x.xq_type;
    return w;
}

pub const desc: repr.TypeRepr = .{
    .logical = .uuid,
    .store = store,
    .list = uuidList,
    .cast = uuidCast,
    .json_arg = uuidText,
};

/// A value stored into a uuid column: its 16 bytes, into an older
/// table's TEXT column its text.
fn store(t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store {
    _ = t;
    _ = decl;
    return .{ .def = if (storage == .TEXT) uuid_fns.store_text else uuid_fns.store };
}

const uuid_fns = @import("../uuid.zig");
