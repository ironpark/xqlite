//! UPSERT: INSERT ... ON CONFLICT (port of upsert.c). This part builds the
//! clauses during parsing.

const std = @import("std");
const int = @import("sqlite_int.zig");
const expr_mod = @import("expr.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const Upsert = int.Upsert;
const Oom = int.Oom;

/// Port of sqlite3UpsertNew(): one ON CONFLICT clause, before `next`.
/// A null `set` means DO NOTHING.
pub fn upsertNew(p: *Parse, target: ?*ExprList, target_where: ?*Expr, set: ?*ExprList, where: ?*Expr, next: ?*Upsert) Oom!*Upsert {
    const u = try p.arena.create(Upsert);
    u.* = .{
        .target = target,
        .target_where = target_where,
        .set = set,
        .where = where,
        .is_do_update = set != null,
        .next = next,
    };
    return u;
}

/// Port of sqlite3UpsertDup(): a copy of an ON CONFLICT list.
pub fn upsertDup(a: std.mem.Allocator, u_arg: ?*Upsert) Oom!?*Upsert {
    const u = u_arg orelse return null;
    const n = try a.create(Upsert);
    n.* = .{
        .target = try expr_mod.listDup(a, u.target),
        .target_where = try expr_mod.exprDup(a, u.target_where),
        .set = try expr_mod.listDup(a, u.set),
        .where = try expr_mod.exprDup(a, u.where),
        .is_do_update = u.set != null,
        .next = try upsertDup(a, u.next),
    };
    return n;
}
