//! The types of the columns of the set-returning functions the parser
//! lowers to table-valued functions (parser.zig's generateSeries(),
//! arraySrf(), selectListSrfs()), which the core does not know: a
//! generate_series() of integers is integer, unnest() of a smallint[]
//! smallint, _pg_expandarray()'s n integer. (A typed dialect resolves
//! the arguments of such a function before the select list: resolve.zig.) PostgreSQL describes them
//! so (RowDescription, \gdesc), and its clients read numbers by it.
//! Called by overload.overload() for each column and call, typing the
//! Expr if the core did not.

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const int = @import("../../sql/sqlite_int.zig");
const operand = @import("operand.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Oom = error{OutOfMemory};

/// Type `e` if it is a column of such a function, json_extract() of one
/// (an array of several, side by side) or a field of _pg_expandarray()'s
/// record.
pub fn typeExpr(c: *Ctx, e: *Expr) Oom!void {
    if (e.xq_type != typing.unknown) return;
    const id = switch (e.op) {
        TK.COLUMN => try column(c, e, null),
        TK.FUNCTION => try call(c, e),
        else => return,
    };
    if (id != typing.unknown) e.xq_type = id;
}

fn call(c: *Ctx, e: *Expr) Oom!typing.TypeId {
    if (!operand.isCall(e)) return typing.unknown;
    const items = operand.args(e);
    if (items.len != 2) return typing.unknown;
    var buf: [64]u8 = undefined;
    const name = operand.nameOf(e, &buf);
    const key = stringOf(items[1].expr.?) orelse return typing.unknown;
    if (std.mem.eql(u8, name, "json_extract")) {
        // "$[i]": the i-th of several functions in step.
        if (!std.mem.startsWith(u8, key, "$[") or !std.mem.endsWith(u8, key, "]")) return typing.unknown;
        const i = std.fmt.parseInt(usize, key[2 .. key.len - 1], 10) catch return typing.unknown;
        return column(c, items[0].expr.?, i);
    }
    if (std.mem.eql(u8, name, "xq_pg_record_field")) {
        // _pg_expandarray()'s (x, n): an element and its subscript.
        if (std.mem.eql(u8, key, "n")) return typing.plain(.int4);
        if (!std.mem.eql(u8, key, "x")) return typing.unknown;
        const rows = rowsOf(c, items[0].expr.?) orelse return typing.unknown;
        if (!operand.calls(rows, "xq_pg_rows_expand")) return typing.unknown;
        return elementOf(c, operand.args(rows));
    }
    return typing.unknown;
}

/// The type of the value of column `e` of a FROM item (the `i`-th of the
/// functions zipped into it).
fn column(c: *Ctx, e: *const Expr, i: ?usize) Oom!typing.TypeId {
    const item = c.columnSource(e) orelse return typing.unknown;
    if (!item.fg.is_tab_func) return typing.unknown;
    const fargs = if (item.u1.func_arg) |l| l.slice() else return typing.unknown;
    const name = item.name orelse return typing.unknown;
    if (std.ascii.eqlIgnoreCase(name, "generate_series")) {
        // value: of the type of start and stop.
        if (e.i_column != 0 or fargs.len < 2 or i != null) return typing.unknown;
        const ops = [_]typing.Operand{ c.operand(fargs[0].expr.?), c.operand(fargs[1].expr.?) };
        return typing.commonOf(c, &ops);
    }
    // json_each()'s value (its column 1) over the rows parser.zig makes.
    if (!std.ascii.eqlIgnoreCase(name, "json_each") or e.i_column != 1 or fargs.len != 1) return typing.unknown;
    var rows = fargs[0].expr.?;
    if (i) |k| {
        // _pg_expandarray() in FROM: its x and n are $[0] and $[1].
        if (operand.calls(rows, "xq_pg_rows_expand")) return switch (k) {
            0 => elementOf(c, operand.args(rows)),
            1 => typing.plain(.int4),
            else => typing.unknown,
        };
        if (!operand.calls(rows, "xq_pg_rows_zip")) return typing.unknown;
        const zipped = operand.args(rows);
        if (k >= zipped.len) return typing.unknown;
        rows = zipped[k].expr.?;
    }
    // (a [, code]): overload.zig adds the code of the array's type.
    if (operand.calls(rows, "xq_pg_rows_unnest")) return elementOf(c, operand.args(rows));
    if (operand.calls(rows, "xq_pg_rows_subscripts")) return typing.plain(.int4);
    return typing.unknown;
}

/// The rows call of the FROM item whose value (or zipped value) `e` is.
fn rowsOf(c: *Ctx, e: *const Expr) ?*Expr {
    var col = e;
    var k: ?usize = null;
    if (operand.calls(e, "json_extract")) {
        const items = operand.args(e);
        const key = stringOf(items[1].expr.?) orelse return null;
        if (!std.mem.startsWith(u8, key, "$[") or !std.mem.endsWith(u8, key, "]")) return null;
        k = std.fmt.parseInt(usize, key[2 .. key.len - 1], 10) catch return null;
        col = items[0].expr.?;
    }
    const item = c.columnSource(col) orelse return null;
    if (!item.fg.is_tab_func or col.i_column != 1) return null;
    const fargs = if (item.u1.func_arg) |l| l.slice() else return null;
    if (fargs.len != 1) return null;
    const rows = fargs[0].expr.?;
    if (k) |x| {
        if (!operand.calls(rows, "xq_pg_rows_zip")) return null;
        const zipped = operand.args(rows);
        return if (x < zipped.len) zipped[x].expr.? else null;
    }
    return rows;
}

/// The element type of the array that the first of `items` is.
fn elementOf(c: *Ctx, items: []int.ExprListItem) Oom!typing.TypeId {
    if (items.len == 0) return typing.unknown;
    const t = operand.typeOfExpr(c, items[0].expr.?);
    if (t.logical != .array or t.element == .unknown) return typing.unknown;
    return c.make(t.elementType());
}

fn stringOf(e: *const Expr) ?[]const u8 {
    if (e.op != TK.STRING or !e.useUToken()) return null;
    return e.u.token orelse null;
}
