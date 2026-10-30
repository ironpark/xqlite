//! Oracle's date arithmetic, after a statement is parsed: `d + n` and
//! `d - n` add days to a date, `d1 - d2` is the number of days between
//! two dates. Dates are text (datetime.zig), so where the parser knows an
//! operand is a date (Parser.dateKindOf(): SYSDATE, TO_DATE(), date
//! literals, DATE/TIMESTAMP columns of the tables in scope) the node
//! becomes SQLite's date arithmetic (exact to the millisecond):
//!
//!   d + n    datetime(d, n || ' days')
//!   d - n    datetime(d, (-n) || ' days')
//!   d1 - d2  (unixepoch(d1, 'subsec') - unixepoch(d2, 'subsec')) / 86400.0
//!
//! (a TIMESTAMP operand gives a DATE, as in Oracle; TIMESTAMP - TIMESTAMP
//! is a number of days, not an INTERVAL). Other operands keep SQLite's
//! arithmetic.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;

const Scope = std.ArrayList([]const tree.FromItem);

pub fn statement(p: *Parser, s: parser.Statement) Error!void {
    var scope: Scope = .empty;
    switch (s) {
        .tree => |t| try stmt(p, t, &scope),
        .multi => |list| for (list) |t| try stmt(p, t, &scope),
        else => {},
    }
}

fn targetItem(p: *Parser, q: tree.QName, alias: ?tree.Name) Error![]const tree.FromItem {
    const items = try p.arena.alloc(tree.FromItem, 1);
    items[0] = .{ .source = .{ .table = q }, .alias = if (alias) |a| .{ .name = a } else null };
    return items;
}

fn stmt(p: *Parser, s: tree.Stmt, scope: *Scope) Error!void {
    switch (s) {
        .select => |x| try select(p, x, scope),
        .insert => |x| {
            if (x.source) |src| try select(p, src, scope);
        },
        .update => |x| {
            try scope.append(p.arena, try targetItem(p, x.table, x.alias));
            try scope.append(p.arena, x.from);
            defer scope.items.len -= 2;
            for (x.sets) |set| try expr(p, set.value, scope);
            if (x.where) |w| try expr(p, w, scope);
        },
        .delete => |x| {
            try scope.append(p.arena, try targetItem(p, x.table, x.alias));
            defer scope.items.len -= 1;
            if (x.where) |w| try expr(p, w, scope);
        },
        .create_table => |x| {
            for (x.columns) |c| for (c.constraints) |cc| switch (cc.kind) {
                .check => |e| try expr(p, e, scope),
                .default => |e| try expr(p, e, scope),
                .generated => |g| try expr(p, g.e, scope),
                else => {},
            };
            if (x.as_select) |sel| try select(p, sel, scope);
        },
        .create_view => |x| try select(p, x.select, scope),
        .explain => |inner| try stmt(p, inner.*, scope),
        else => {},
    }
}

fn select(p: *Parser, s: *tree.Select, scope: *Scope) Error!void {
    if (s.with) |w| for (w.ctes) |cte| try select(p, cte.select, scope);
    try body(p, s.body, scope);
    // ORDER BY sees the FROM of a single query.
    const from: []const tree.FromItem = if (s.body.* == .core) s.body.core.from else &.{};
    try scope.append(p.arena, from);
    defer scope.items.len -= 1;
    for (s.order_by) |it| try expr(p, it.expr, scope);
    if (s.limit) |x| try expr(p, x, scope);
    if (s.offset) |x| try expr(p, x, scope);
}

fn body(p: *Parser, b: *tree.Body, scope: *Scope) Error!void {
    switch (b.*) {
        .core => |c| try core(p, c, scope),
        .values => |rows| for (rows) |row| for (row) |x| try expr(p, x, scope),
        .compound => |c| {
            try body(p, c.left, scope);
            try body(p, c.right, scope);
        },
        .nested => |s| try select(p, s, scope),
    }
}

fn core(p: *Parser, c: *tree.Core, scope: *Scope) Error!void {
    try fromItems(p, c.from, scope);
    try scope.append(p.arena, c.from);
    defer scope.items.len -= 1;
    for (c.cols) |rc| switch (rc) {
        .expr => |x| try expr(p, x.e, scope),
        else => {},
    };
    for (c.from) |it| if (it.on) |on| try expr(p, on, scope);
    if (c.where) |w| try expr(p, w, scope);
    for (c.group_by) |g| try expr(p, g, scope);
    if (c.having) |h| try expr(p, h, scope);
}

fn fromItems(p: *Parser, items: []const tree.FromItem, scope: *Scope) Error!void {
    for (items) |it| switch (it.source) {
        .subquery => |s| try select(p, s, scope),
        .nested => |inner| try fromItems(p, inner, scope),
        else => {},
    };
}

fn expr(p: *Parser, e: *Expr, scope: *Scope) Error!void {
    switch (e.kind) {
        .exists, .subquery => |s| return select(p, s, scope),
        .in_select => |x| {
            try expr(p, x.e, scope);
            return select(p, x.sel, scope);
        },
        else => {},
    }
    var it = parser.Children.of(e);
    while (it.next()) |child| try expr(p, @constCast(child), scope);
    if (e.kind != .binary) return;
    const b = e.kind.binary;
    if (b.op != .add and b.op != .sub) return;
    const kl = try p.dateKindOf(b.l, scope.items);
    const kr = try p.dateKindOf(b.r, scope.items);
    if (kl == .none and kr == .none) return;
    if (b.op == .sub and kl != .none and kr != .none) {
        // (unixepoch(d1, 'subsec') - unixepoch(d2, 'subsec')) / 86400.0
        const diff = try tree.expr(p.arena, e.pos, e.end, .{ .binary = .{ .op = .sub, .l = try epoch(p, b.l, true), .r = try epoch(p, b.r, true) } });
        const day = try tree.expr(p.arena, e.pos, e.pos, .{ .float = "86400.0" });
        e.kind = .{ .div = .{ .kind = .sqlite, .l = diff, .r = day } };
        return;
    }
    if (b.op == .sub and kl == .none) return;
    // date + n, n + date, date - n: datetime(d, (+/-n) || ' days')
    // (SQLite adds the days in milliseconds, rounded).
    const d = if (kl != .none) b.l else b.r;
    var n = if (kl != .none) b.r else b.l;
    if (b.op == .sub) n = try tree.expr(p.arena, n.pos, n.end, .{ .unary = .{ .op = .neg, .e = n } });
    const days = try tree.expr(p.arena, n.pos, n.end, .{ .concat = .{ .args = try p.list(&.{ n, try p.stringAt(n.pos, " days") }), .null_policy = .propagate } });
    const f = try p.new(tree.Func, .{ .name = .{ .text = "datetime", .pos = e.pos }, .args = try p.list(&.{ d, days }) });
    e.kind = .{ .func = f };
    try p.date_nodes.put(p.arena, e, .date);
}

/// unixepoch(x [, 'subsec']): the seconds of a date (with the fraction).
fn epoch(p: *Parser, x: *Expr, subsec: bool) Error!*Expr {
    if (subsec) return call(p, "unixepoch", &.{ x, try p.stringAt(x.pos, "subsec") }, x);
    return call(p, "unixepoch", &.{x}, x);
}

fn call(p: *Parser, name: []const u8, args: []const *Expr, at: *const Expr) Error!*Expr {
    const f = try p.new(tree.Func, .{ .name = .{ .text = name, .pos = at.pos }, .args = try p.list(args) });
    return tree.expr(p.arena, at.pos, at.end, .{ .func = f });
}
