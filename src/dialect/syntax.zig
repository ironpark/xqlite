//! Grammar the dialects' parsers share (docs/sqlparse.md): the pieces
//! of syntax that every dialect reads the same way into the syntax tree
//! IR, up to a few options (src/ir/tree.zig).
//!
//! Each function takes the dialect's parser `p` (anytype) and uses:
//!  - `p.c`, its cursor (pkg/sqlparse), for the tokens, the arena and
//!    the errors; keywords are written in upper case, the cursor
//!    compares them as the dialect does (folded or not);
//!  - the dialect's functions given as comptime arguments (`operand`:
//!    the expression at the precedence the construct reads), or for
//!    windowClauses() `p.exprList()` and `p.sortList()`.
//! A missing keyword fails as the cursor's expectKw() does (Oracle's
//! ORA-00905, else the dialect's syntax error).

const std = @import("std");
const tree = @import("../ir/tree.zig");
const sqlparse = @import("sqlparse");

const Error = sqlparse.Error;
const Expr = tree.Expr;

/// `CASE [operand] WHEN a THEN b ... [ELSE e] END`, at CASE. Without a
/// WHEN it fails as a missing keyword.
pub fn caseExpr(p: anytype, comptime operand: anytype) Error!*Expr {
    const c = &p.c;
    const pos = c.here();
    try c.expectKw("CASE");
    const value: ?*Expr = if (c.isKw("WHEN")) null else try operand(p);
    var whens: std.ArrayList(*Expr) = .empty;
    while (c.eatKw("WHEN")) {
        try whens.append(c.arena, try operand(p));
        try c.expectKw("THEN");
        try whens.append(c.arena, try operand(p));
    }
    if (whens.items.len == 0) return c.missingKeyword();
    const else_: ?*Expr = if (c.eatKw("ELSE")) try operand(p) else null;
    try c.expectKw("END");
    return tree.expr(c.arena, pos, @max(pos, c.lastEnd()), .{ .case = .{ .operand = value, .whens = whens.items, .@"else" = else_ } });
}

/// What a dialect's ORDER BY items read.
pub const SortOptions = struct {
    /// NULLS FIRST/LAST, and without it NULLs sort as if larger than any
    /// value (PostgreSQL, Oracle: last ascending, first descending).
    nulls: bool = false,
    /// `USING <` and `USING >` (PostgreSQL); another operator is
    /// `p.unsupported(pos, what)`.
    using: bool = false,
};

/// `expr [ASC | DESC] ..., ...`: the items of ORDER BY.
pub fn sortList(p: anytype, comptime operand: anytype, comptime opts: SortOptions) Error![]tree.SortItem {
    const c = &p.c;
    var out: std.ArrayList(tree.SortItem) = .empty;
    while (true) {
        var item: tree.SortItem = .{ .expr = try operand(p) };
        if (c.eatKw("ASC")) {
            item.dir = .asc;
        } else if (c.eatKw("DESC")) {
            item.dir = .desc;
        } else if (opts.using and c.isKw("USING")) {
            const at = c.advance().start;
            if (c.eatOp("<")) item.dir = .asc else if (c.eatOp(">")) item.dir = .desc else return p.unsupported(at, "ORDER BY USING with this operator");
        }
        if (opts.nulls) {
            if (c.eatKw("NULLS")) {
                if (c.eatKw("FIRST")) {
                    item.nulls = .first;
                } else {
                    try c.expectKw("LAST");
                    item.nulls = .last;
                }
            } else item.nulls = if (item.dir == .desc) .first else .last;
        }
        try out.append(c.arena, item);
        if (!c.eatComma()) break;
    }
    return out.items;
}

/// What a dialect's window frames read.
pub const FrameOptions = struct {
    /// GROUPS as a unit, after ROWS and RANGE.
    groups: bool = false,
    /// EXCLUDE CURRENT ROW | GROUP | TIES | NO OTHERS.
    exclude: bool = true,
};

/// `[PARTITION BY ...] [ORDER BY ...] [frame]`: the clauses of a window
/// specification after its base window name, into `w`, with
/// `p.exprList()` and `p.sortList()`; `bound` reads the expression of a
/// frame bound.
pub fn windowClauses(p: anytype, w: *tree.WindowSpec, comptime bound: anytype, comptime opts: FrameOptions) Error!void {
    const c = &p.c;
    if (try c.optKws(&.{ "PARTITION", "BY" })) w.partition = try p.exprList();
    if (try c.optKws(&.{ "ORDER", "BY" })) w.order_by = try p.sortList();
    w.frame = try frame(p, bound, opts);
}

/// `{ROWS | RANGE | GROUPS} {bound | BETWEEN bound AND bound} [EXCLUDE
/// ...]`, null if there is none.
pub fn frame(p: anytype, comptime bound: anytype, comptime opts: FrameOptions) Error!?tree.Frame {
    const c = &p.c;
    var f: tree.Frame = .{
        .unit = if (c.eatKw("ROWS")) .rows else if (c.eatKw("RANGE")) .range else if (opts.groups and c.eatKw("GROUPS")) .groups else return null,
        .start = undefined,
        .end = null,
    };
    if (c.eatKw("BETWEEN")) {
        f.start = try frameBound(p, bound);
        try c.expectKw("AND");
        f.end = try frameBound(p, bound);
    } else f.start = try frameBound(p, bound);
    if (opts.exclude and c.eatKw("EXCLUDE")) {
        if (c.eatKw("CURRENT")) {
            try c.expectKw("ROW");
            f.exclude = .current_row;
        } else if (c.eatKw("GROUP")) {
            f.exclude = .group;
        } else if (c.eatKw("TIES")) {
            f.exclude = .ties;
        } else {
            try c.expectKw("NO");
            try c.expectKw("OTHERS");
            f.exclude = .no_others;
        }
    }
    return f;
}

/// `UNBOUNDED {PRECEDING | FOLLOWING} | CURRENT ROW | expr {PRECEDING |
/// FOLLOWING}`.
pub fn frameBound(p: anytype, comptime bound: anytype) Error!tree.Bound {
    const c = &p.c;
    if (c.eatKw("UNBOUNDED")) {
        if (c.eatKw("PRECEDING")) return .{ .kind = .unbounded_preceding };
        try c.expectKw("FOLLOWING");
        return .{ .kind = .unbounded_following };
    }
    if (c.eatKw("CURRENT")) {
        try c.expectKw("ROW");
        return .{ .kind = .current_row };
    }
    const e = try bound(p);
    if (c.eatKw("PRECEDING")) return .{ .kind = .preceding, .expr = e };
    try c.expectKw("FOLLOWING");
    return .{ .kind = .following, .expr = e };
}
