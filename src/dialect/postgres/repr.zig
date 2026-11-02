//! The types PostgreSQL stores as a BLOB of a form of its own, each also
//! in the TEXT (or ANY) column of a table made before it had that form:
//! numeric (decimal.zig's key; a number in an older table), interval
//! (interval.zig's key and fields; its text), uuid (16 bytes; its text),
//! jsonb (SQLite's JSONB; normalized text). One descriptor per type
//! (TypeRepr), in a module of its own (repr/*.zig) with the choices
//! overload.zig makes for it; the typing rules (typing.zig) and
//! overload.zig ask the descriptors here instead of naming each type.
//!
//! The text of each form, which every viewer and build shows, is outside
//! the dialect: src/dialect/repr.zig. What stays where it is, by type:
//!  - what the frontend writes for a DEFAULT of the type (parser.zig: a
//!    constant made its BLOB) and into the text the schema keeps
//!    (ddltype.zig: the calls overload.zig chose, by the shape of the
//!    tree, before names are resolved);
//!  - the choices of operators and functions that mix types (overload.zig:
//!    `||`, comparisons, the arguments of concat() and of the array
//!    functions), which call the type modules in the order they are made;
//!  - the binary form on the wire (server/pg/values.zig: a codec per
//!    type).

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const int = @import("../../sql/sqlite_int.zig");
const types = @import("../../sql/types.zig");

const Expr = int.Expr;
const Ctx = typing.Ctx;
const Error = typing.Error;
const Type = types.Type;
const Logical = types.Logical;
const Oom = error{OutOfMemory};

/// What PostgreSQL does with the values of a type stored in a BLOB form
/// of its own. Every function is of values (or columns) of that type.
pub const TypeRepr = struct {
    logical: Logical,
    /// The store function of a column of the type (typing.Rules
    /// .store_column): by its storage (BLOB, else an older table's TEXT
    /// or ANY) and declared type (numeric(p, s)).
    store: *const fn (t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store,
    /// The function a value of the type stored into a column of another
    /// type `t` goes through (PostgreSQL's assignment cast: a numeric
    /// into a double column), null for none.
    store_into: ?*const fn (t: Type) ?*const int.FuncDef = null,
    /// `x IN (a, b ...)`, `x BETWEEN a AND b` with operands of the type;
    /// whether it changed `e` (list()).
    list: ?*const fn (c: *Ctx, e: *Expr) Error!bool = null,
    /// A CAST of a value of the type (`x::text`); whether it changed `e`.
    cast: ?*const fn (c: *Ctx, e: *Expr) Error!bool = null,
    /// The function GROUP BY and DISTINCT group term `e` by
    /// (typing.Rules.group_key), null for the values themselves.
    group_key: ?*const fn (c: *Ctx, e: *const Expr) ?[]const u8 = null,
    /// The function ORDER BY sorts by (typing.Rules.order_key).
    order_key: ?[:0]const u8 = null,
    /// The collation ORDER BY term `e` sorts with
    /// (typing.Rules.order_collation), null for the default.
    order_collation: ?*const fn (c: *Ctx, e: *const Expr) ?[:0]const u8 = null,
    /// An argument of a function that builds JSON (overload.zig's
    /// builders) made what the function reads; whether it did. Null:
    /// overload.zig's own (jsonb's, with json's).
    json_arg: ?*const fn (c: *Ctx, item: *int.ExprListItem) Error!bool = null,
    /// The text pg_get_expr() shows of a stored DEFAULT `z` that is no
    /// BLOB literal (an interval's xq_pg_iv('2 hours')), null if it is
    /// not of the type's form (pgcatalog.defaultText()).
    default_text: ?*const fn (a: std.mem.Allocator, z: []const u8) Oom!?[]const u8 = null,
    /// A constant DEFAULT stored as the BLOB shows as the constant's
    /// digits, as written (a numeric: 0, not 0.00 of the column's scale);
    /// else as its text cast to the type ('…'::uuid).
    default_bare: bool = false,
    /// Its number literals compute exactly, where SQLite's doubles do not
    /// (typing.Rules.exact_types: 1.5 is a numeric).
    exact: bool = false,
};

pub const interval = @import("repr/interval.zig");
pub const uuid = @import("repr/uuid.zig");
pub const jsonb = @import("repr/jsonb.zig");
pub const numeric = @import("repr/numeric.zig");

/// Every descriptor. list() asks them in this order; the conditions of
/// their `list` are of operands of their own type, so that no two apply
/// to one Expr (an interval set, a uuid, a jsonb, a numeric: a numeric
/// IN takes integers and string literals with it, not uuids).
pub const all = [_]*const TypeRepr{ &interval.desc, &uuid.desc, &jsonb.desc, &numeric.desc };

/// The descriptor of type `l`, null if PostgreSQL keeps its values as
/// SQLite does.
pub fn of(l: Logical) ?*const TypeRepr {
    inline for (all) |r| if (r.logical == l) return r;
    return null;
}

/// The types whose values may be in more than one form
/// (typing.Rules.store_forms).
pub const store_forms: std.EnumSet(Logical) = blk: {
    var s: std.EnumSet(Logical) = .empty;
    for (all) |r| s.insert(r.logical);
    break :blk s;
};

/// The types whose literals compute exactly (typing.Rules.exact_types).
pub const exact_types: std.EnumSet(Logical) = blk: {
    var s: std.EnumSet(Logical) = .empty;
    for (all) |r| if (r.exact) s.insert(r.logical);
    break :blk s;
};

/// typing.Rules.store_column: a column of a type of a descriptor by its
/// store; a column of another type by the store_into of the type of the
/// value (only for values of that type).
pub fn storeColumn(t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store {
    if (of(t.logical)) |r| return r.store(t, decl, storage);
    inline for (all) |r| if (r.store_into) |f| if (f(t)) |def| return .{ .def = def, .only = r.logical };
    return null;
}

/// `x IN (...)`, `x BETWEEN a AND b`: the first descriptor whose `list`
/// applies.
pub fn list(c: *Ctx, e: *Expr) Error!bool {
    inline for (all) |r| if (r.list) |f| if (try f(c, e)) return true;
    return false;
}

/// A CAST: by the type of the value cast.
pub fn cast(c: *Ctx, e: *Expr) Error!bool {
    const x = e.left orelse return false;
    const r = of(typing.typeOf(c.p.db, x.xq_type).logical) orelse return false;
    const f = r.cast orelse return false;
    return f(c, e);
}

/// typing.Rules.group_key.
pub fn groupKey(c: *Ctx, id: typing.TypeId, e: *const Expr) ?[]const u8 {
    const r = of(typing.typeOf(c.p.db, id).logical) orelse return null;
    const f = r.group_key orelse return null;
    return f(c, e);
}

/// typing.Rules.order_key.
pub fn orderKey(c: *Ctx, id: typing.TypeId) ?[:0]const u8 {
    const r = of(typing.typeOf(c.p.db, id).logical) orelse return null;
    return r.order_key;
}

/// The collation of an ORDER BY of a type of a descriptor (overload.zig's
/// orderCollation(), which also orders arrays).
pub fn orderCollation(c: *Ctx, id: typing.TypeId, e: *const Expr) ?[:0]const u8 {
    const r = of(typing.typeOf(c.p.db, id).logical) orelse return null;
    const f = r.order_collation orelse return null;
    return f(c, e);
}
