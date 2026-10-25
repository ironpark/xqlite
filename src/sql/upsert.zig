//! UPSERT: INSERT ... ON CONFLICT (port of upsert.c). This part builds the
//! clauses during parsing.

const int = @import("sqlite_int.zig");

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
