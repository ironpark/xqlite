//! The types of expressions in the core: Expr.xq_type, a TypeId.
//!
//! A frontend knows the type of some expressions (a comparison is a
//! boolean, a cast is of its target type) and stamps it on the Expr it
//! lowers (ir/lower.zig); name resolution carries types further (a
//! column of a FROM subquery, a CTE or a view takes the type of the
//! subquery's result column, a scalar subquery that of its first column,
//! a column of a table of a dialect the catalog's type: resolve.zig).
//! generateColumnTypes() (select.zig) gives a result column without a
//! declared type of its own the spelling of its type as declared type
//! (sqlite3_column_decltype()) and keeps the Type in the statement
//! (Vdbe.xq_col_types). Code generation reads types in two places only
//! ("code generation" below): the width of integer arithmetic, which a
//! dialect checks (dialect.Arith: PostgreSQL's `integer out of range`),
//! and the function a value stored into a column of a type goes through
//! (Rules.store). What a dialect chooses by the types of operands
//! (Rules.overload: PostgreSQL's jsonb operators) it writes into the
//! resolved Exprs, which are compiled as any others. A statement compiled
//! in SQLite's dialect has no types, so its bytecode is SQLite's.
//!
//! A TypeId is a u16 (it fits in the padding of an Expr), 0 for no type
//! known. Ids stay valid as long as the connection: an Expr that lives
//! as long as the schema (CHECK, generated column and index expressions,
//! resolved when the schema is read) may hold one.
//!  - the plain types, one per Logical without parameters, under a
//!    spelling of their own (plain_names: "boolean", "integer"), have the
//!    fixed ids @intFromEnum(logical), the same in every connection;
//!  - every other type, a type with parameters (numeric(10,2),
//!    varchar(20)) or the spelling of a dialect ("int4", "DECIMAL(6,2)",
//!    "SIGNED"), is interned per connection (ConnState.types, Interner):
//!    its Type and its spelling, kept so that the declared type of a
//!    result column is the frontend's text byte for byte. The interner
//!    only grows; it is freed with the connection.

const std = @import("std");
const types = @import("types.zig");
const int = @import("sqlite_int.zig");
const dialect_mod = @import("../dialect/dialect.zig");
const Dialect = dialect_mod.Dialect;
const catalog = @import("../catalog/catalog.zig");

const Type = types.Type;
const Logical = types.Logical;

pub const TypeId = u16;

/// No type known.
pub const unknown: TypeId = 0;

const n_logical = std.enums.values(Logical).len;

/// The first id of the interner: after the fixed ids.
const first_interned: TypeId = n_logical;

/// The spelling of each plain type (its fixed id), as a declared type.
const plain_names = blk: {
    var names: [n_logical][:0]const u8 = undefined;
    for (std.enums.values(Logical)) |l| names[@backingInt(l)] = switch (l) {
        .unknown => "",
        .boolean => "boolean",
        .int1 => "tinyint",
        .int2 => "smallint",
        .int4 => "integer",
        .int8 => "bigint",
        .float4 => "real",
        .float8 => "double precision",
        .numeric => "numeric",
        .text => "text",
        .varchar => "varchar",
        .char => "char",
        .bytes => "bytea",
        .date => "date",
        .time => "time",
        .time_tz => "time with time zone",
        .timestamp => "timestamp",
        .timestamp_tz => "timestamp with time zone",
        .interval => "interval",
        .uuid => "uuid",
        .json => "json",
        .jsonb => "jsonb",
        // An array of elements of no known type.
        .array => "anyarray",
    };
    break :blk names;
};

/// The fixed id of the plain type `l` (unknown for .unknown).
pub fn plain(l: Logical) TypeId {
    return @backingInt(l);
}

/// The spelling of the plain type `l` (its fixed id): PostgreSQL's
/// ("integer", "double precision"); "" for .unknown.
pub fn plainName(l: Logical) [:0]const u8 {
    return plain_names[@backingInt(l)];
}

/// The boolean of comparisons and logical operations.
pub const boolean = plain(.boolean);

fn isPlain(t: Type) bool {
    return t.length == null and t.precision == null and t.scale == null and t.element == .unknown;
}

/// A type of the interner: what the id means.
pub const Entry = struct {
    type: Type,
    /// The spelling, as written in the dialect that named the type.
    name: [:0]const u8,
};

/// The types of a connection beyond the plain ones (ConnState.types).
pub const Interner = struct {
    /// By id - first_interned.
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The id of each (dialect, spelling): the key is the dialect's byte
    /// then the spelling, owned, followed by a NUL outside the key (an
    /// entry's name is the key's tail).
    ids: std.StringHashMapUnmanaged(TypeId) = .empty,

    pub fn deinit(in: *Interner, gpa: std.mem.Allocator) void {
        var it = in.ids.keyIterator();
        while (it.next()) |k| gpa.free(k.ptr[0 .. k.len + 1]);
        in.ids.deinit(gpa);
        in.entries.deinit(gpa);
        in.* = .{};
    }

    /// The id of the type spelled `z` in `dialect` (read by
    /// types.parse()).
    pub fn add(in: *Interner, gpa: std.mem.Allocator, dialect: Dialect, z: []const u8) error{OutOfMemory}!TypeId {
        if (z.len == 0) return unknown;
        const t = types.parse(dialect, z);
        if (isPlain(t) and t.logical != .unknown and std.mem.eql(u8, z, plain_names[@backingInt(t.logical)])) return plain(t.logical);
        // The key, with the NUL that ends the name.
        var buf: [64]u8 = undefined;
        const mem = if (z.len + 2 <= buf.len) buf[0 .. z.len + 2] else try gpa.alloc(u8, z.len + 2);
        defer if (mem.ptr != @as([*]u8, &buf)) gpa.free(mem);
        mem[0] = @backingInt(dialect);
        @memcpy(mem[1..][0..z.len], z);
        mem[z.len + 1] = 0;
        if (in.ids.get(mem[0 .. z.len + 1])) |id| return id;
        // Full: the type without its spelling and parameters.
        if (in.entries.items.len >= std.math.maxInt(TypeId) - first_interned) return if (isPlain(t)) plain(t.logical) else unknown;
        const owned = try gpa.dupe(u8, mem);
        errdefer gpa.free(owned);
        const key = owned[0 .. z.len + 1];
        const id: TypeId = @intCast(first_interned + in.entries.items.len);
        try in.entries.append(gpa, .{ .type = t, .name = owned[1 .. z.len + 1 :0] });
        errdefer in.entries.items.len -= 1;
        try in.ids.put(gpa, key, id);
        return id;
    }

    /// The id of type `t` under the spelling `name` in `dialect`: a type
    /// a typing rule makes (Rules.spell()), whose spelling may say less
    /// than the type (PostgreSQL spells the sum of two numeric(6,2)
    /// "numeric", the values keep their two digits).
    pub fn addType(in: *Interner, gpa: std.mem.Allocator, dialect: Dialect, t: Type, name: []const u8) error{OutOfMemory}!TypeId {
        if (t.logical == .unknown) return unknown;
        if (std.meta.eql(types.parse(dialect, name), t)) return in.add(gpa, dialect, name);
        // The key: the dialect's byte with the high bit set, the type
        // (logical, which parameters, the parameters, an array's
        // element), then the spelling.
        var head: [10]u8 = undefined;
        head[0] = @backingInt(dialect) | 0x80;
        head[1] = @backingInt(t.logical);
        head[2] = @as(u8, @intFromBool(t.length != null)) | @as(u8, @intFromBool(t.precision != null)) << 1 | @as(u8, @intFromBool(t.scale != null)) << 2;
        head[3] = t.precision orelse 0;
        head[4] = t.scale orelse 0;
        std.mem.writeInt(u32, head[5..9], t.length orelse 0, .little);
        head[9] = @backingInt(t.element);
        const owned = try gpa.alloc(u8, head.len + name.len + 1);
        var keep = false;
        defer if (!keep) gpa.free(owned);
        @memcpy(owned[0..head.len], &head);
        @memcpy(owned[head.len..][0..name.len], name);
        owned[owned.len - 1] = 0;
        const key = owned[0 .. owned.len - 1];
        if (in.ids.get(key)) |id| return id;
        if (in.entries.items.len >= std.math.maxInt(TypeId) - first_interned) return if (isPlain(t)) plain(t.logical) else unknown;
        const id: TypeId = @intCast(first_interned + in.entries.items.len);
        try in.entries.append(gpa, .{ .type = t, .name = owned[head.len .. owned.len - 1 :0] });
        errdefer in.entries.items.len -= 1;
        try in.ids.put(gpa, key, id);
        keep = true;
        return id;
    }

    /// The entry of `id`; null for unknown or an id of no type.
    pub fn get(in: *const Interner, id: TypeId) ?Entry {
        if (id == unknown) return null;
        if (id < first_interned) return .{ .type = .{ .logical = @fromBackingInt(@intCast(id)) }, .name = plain_names[id] };
        const i = id - first_interned;
        if (i >= in.entries.items.len) return null;
        return in.entries.items[i];
    }
};

/// The id of the type spelled `z` in `dialect`, for connection `db`.
pub fn intern(db: *int.Sqlite3, dialect: Dialect, z: []const u8) error{OutOfMemory}!TypeId {
    return db.xq.types.add(db.gpa, dialect, z);
}

/// The Type of id `id` of connection `db` (.unknown for unknown).
pub fn typeOf(db: *const int.Sqlite3, id: TypeId) Type {
    return if (db.xq.types.get(id)) |e| e.type else .{ .logical = .unknown };
}

/// The spelling of id `id` of connection `db`, as a declared type; null
/// for unknown.
pub fn spelling(db: *const int.Sqlite3, id: TypeId) ?[:0]const u8 {
    return if (db.xq.types.get(id)) |e| e.name else null;
}

/// The type of an Expr of operator `op` whatever its operands: the
/// boolean of comparisons and logical operations, else unknown. For
/// Exprs no frontend typed (SQLite text: views, the schema), at name
/// resolution (resolve.zig).
pub fn ofOp(op: u8) TypeId {
    return switch (op) {
        TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE, TK.IS, TK.ISNOT, TK.AND, TK.OR, TK.NOT, TK.IN, TK.EXISTS, TK.BETWEEN, TK.ISNULL, TK.NOTNULL, TK.TRUTH, TK.TRUEFALSE => boolean,
        else => unknown,
    };
}

/// Whether statements being compiled on `db` are typed: those of a
/// dialect, not SQLite's, nor the schema or SQL of the engine (which is
/// SQLite's), so that SQLite's statements stay exactly SQLite's.
pub fn active(db: *const int.Sqlite3) bool {
    return db.xq.lang.dialect != .sqlite and !db.init.busy;
}

// ============================================================ the rules

const Oom = error{OutOfMemory};
/// What a rule may fail with: an error of the statement, left in the
/// Parse (Ctx.fail()).
pub const Error = error{ OutOfMemory, Failed };
const TK = int.TK;
const Expr = int.Expr;
const expr_mod = @import("expr.zig");
const resolve = @import("resolve.zig");
const callback = @import("callback.zig");
const util = @import("util.zig");

/// An operand of a rule: an Expr (typed) and its type.
pub const Operand = struct {
    id: TypeId,
    type: Type,
    e: *const Expr,

    pub fn logical(o: Operand) Logical {
        return o.type.logical;
    }
};

/// What a function returns (Rules.function()).
pub const Ret = union(enum) {
    /// The type of this spelling in the dialect.
    named: []const u8,
    /// The type of argument `i` (unknown without one).
    arg: u8,
    /// The common type (common()) of the arguments from `i` on.
    common: u8,
    /// What the dialect computes from the arguments.
    rule: *const fn (c: *Ctx, args: []const Operand) Oom!TypeId,
};

/// The typing rules of a dialect (dialect.Hooks.typing): the types of
/// the Exprs whose type depends on the dialect, from those of their
/// operands. typeTree() applies them after names are resolved, to every
/// Expr the frontend did not type (the frontend's types, a column's,
/// stay), innermost first.
pub const Rules = struct {
    /// The dialect's name of type `t`, a type the rules make (the sum of
    /// two decimals, the common type of two branches): the declared type
    /// of a result column of that type. May say less than `t`
    /// (PostgreSQL's "numeric" of a numeric of scale 2).
    spell: *const fn (t: Type, buf: *[64]u8) []const u8,
    /// The type of a literal: TK_INTEGER, TK_FLOAT, TK_STRING, TK_BLOB,
    /// TK_NULL.
    literal: *const fn (c: *Ctx, e: *const Expr) Oom!TypeId,
    /// The type of arithmetic, concatenation and bit operations: `op`
    /// (TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_REM, TK_CONCAT,
    /// TK_BITAND, TK_BITOR, TK_LSHIFT, TK_RSHIFT; TK_UMINUS and
    /// TK_BITNOT with `b` null).
    operator: *const fn (c: *Ctx, op: u8, a: Operand, b: ?Operand) Oom!TypeId,
    /// The return type of the function called `name` (lower case, as the
    /// frontend lowered it: SQLite's built-ins, the dialect's functions,
    /// engine functions); null to try core_functions (coalesce(),
    /// nullif() ...).
    function: *const fn (name: []const u8) ?Ret,
    /// The functions a frontend wraps a value in to store it into a
    /// column (MariaDB's xq_coerce(v, ...)): the value is their first
    /// argument (assign()).
    store_wrappers: []const []const u8 = &.{},
    /// The function (of one argument) a value stored into a column of
    /// type `t` (the catalog's) goes through, null for none: PostgreSQL
    /// reads a string stored into a boolean or numeric column as the
    /// type's input ('yes', '1.50'). INSERT and UPDATE code it on the
    /// value of every column it names (storeFunctions()), so a
    /// parameter bound as text is read too. For the conversions that
    /// need no frontend: a frontend that wraps stored values itself
    /// (store_wrappers) needs none. `storage` is the column's STRICT type
    /// (the representation of the type may differ by it: PostgreSQL's
    /// interval is TEXT in the tables of older databases, BLOB in newer
    /// ones; PostgreSQL's uuid is 16 bytes, the text of an older table's
    /// TEXT column; PostgreSQL's jsonb is JSONB in a BLOB column, text
    /// in a TEXT one).
    store: ?*const fn (t: Type, storage: int.COLTYPE) ?*const int.FuncDef = null,
    /// The store function of a column of type `t` and SQLite storage
    /// `storage` (its STRICT type), when it depends on more than the
    /// type (`decl`: the declared type as written): constants after the
    /// value, every value through it, or only values of a type
    /// (PostgreSQL's numeric: xq_dec_key(v, p, s) into a BLOB column,
    /// xq_dec_number(v) into a column of numbers, a numeric made the
    /// number of an integer column). Asked before `store`; null to ask
    /// `store`.
    store_column: ?*const fn (t: Type, decl: []const u8, storage: int.COLTYPE) ?Store = null,
    /// The types whose values may be in more than one form, so that a
    /// value of the type, stored into a column with a store function,
    /// goes through it too (storeNeeded()): PostgreSQL's uuid is a
    /// column's 16 bytes or an older column's text, an interval a BLOB or
    /// an older database's text, jsonb JSONB or text, a numeric a key or
    /// a number (its postgres/repr.zig).
    store_forms: std.EnumSet(Logical) = .empty,
    /// A numeric value has a scale of its own (PostgreSQL's: 1 and 2.50
    /// together are 1 and 2.50), so that the common type of numerics of
    /// different scales has none; else the common type has the larger
    /// scale (DECIMAL(3,2) and INT: 1.00 and 2.50).
    value_scale: bool = false,
    /// A string literal is of no type of its own in a common type (the
    /// values of a CASE, coalesce(), a compound's column): of the type
    /// of the others, text if all are strings (PostgreSQL's unknown).
    unknown_strings: bool = false,
    /// The choices the dialect makes by the types of operands
    /// (PostgreSQL's operator and function resolution: jsonb's `||`, the
    /// arguments of the functions that make JSON): called by typeTree()
    /// for every Expr, after its operands are typed and before its own
    /// type is computed (an Expr the frontend typed too). It may call
    /// another function of the same kind (Ctx.rename()), make an
    /// operator a call (Ctx.toCall()), wrap operands in calls or COLLATE
    /// (Ctx.call(), Ctx.collate()) or fail the statement (Ctx.fail()).
    /// Each choice must be made once: typeTree() may see an Expr again.
    /// Returns whether it changed the operands of `e`. Not called for
    /// the SQL the schema keeps (a view's query, a trigger's program:
    /// Parse.xq_schema_text), which means what it says in every dialect:
    /// a frontend writes its choices into that text itself (PostgreSQL's
    /// ddltype.zig).
    overload: ?*const fn (c: *Ctx, e: *Expr) Error!bool = null,
    /// The collation an ORDER BY sorts values of type `id` with (jsonb's
    /// order), null for the default; as overload, not in the schema's
    /// SQL. `e` is the term (a column of a compound's: its number), by
    /// which the collation may differ (PostgreSQL's interval: a BLOB
    /// sorts as it is, text in a collation).
    order_collation: ?*const fn (c: *Ctx, id: TypeId, e: *const Expr) ?[:0]const u8 = null,
    /// The types whose number literals compute exactly where SQLite's
    /// doubles do not (PostgreSQL's numeric: 1.5 is a decimal):
    /// Parse.xq_exact_numeric, as for a call of a FUNC.XQ_EXACT function.
    exact_types: std.EnumSet(types.Logical) = .empty,
    /// The function (of one argument) a GROUP BY or DISTINCT groups
    /// values of type `id` by, null for the values themselves:
    /// PostgreSQL's interval, whose equal values ('1 mon', '30 days') are
    /// not the same bytes, groups by its key (groupBy()). `e` is the term,
    /// by which the key may differ (PostgreSQL's numeric: a computed value
    /// that may carry its display scale groups by its key without it, a
    /// column of keys as it is). As overload, not in the schema's SQL.
    group_key: ?*const fn (c: *Ctx, id: TypeId, e: *const Expr) ?[]const u8 = null,
    /// The function an ORDER BY sorts values of type `id` by (a sort key
    /// whose bytes are in the type's order: PostgreSQL's jsonb, a BLOB a
    /// collation cannot order), null for none; before order_collation,
    /// as it. A term so wrapped is a result column no more; the terms of
    /// a compound, which can only be result columns, are left as they
    /// are.
    order_key: ?*const fn (c: *Ctx, id: TypeId) ?[:0]const u8 = null,
};

/// The functions whose type is the same in every dialect.
const core_functions = std.StaticStringMap(Ret).initComptime(.{
    .{ "coalesce", Ret{ .common = 0 } },
    .{ "ifnull", Ret{ .common = 0 } },
    .{ "nullif", Ret{ .arg = 0 } },
    .{ "iif", Ret{ .common = 1 } },
    .{ "likely", Ret{ .arg = 0 } },
    .{ "unlikely", Ret{ .arg = 0 } },
    .{ "likelihood", Ret{ .arg = 0 } },
    .{ "min", Ret{ .rule = minMax } },
    .{ "max", Ret{ .rule = minMax } },
});

/// min(x) and max(x), aggregates, are of the type of x; min(a, b ...),
/// scalars, of the common type.
fn minMax(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 1) return args[0].id;
    return commonOf(c, args);
}

/// What the rules work with: the statement and the dialect's rules.
pub const Ctx = struct {
    p: *int.Parse,
    dialect: Dialect,
    rules: *const Rules,
    /// The context the Exprs were resolved in (for the calls a rule
    /// makes: call()); null outside typeTree().
    nc: ?*int.NameContext = null,

    /// The type spelled `z` in the dialect.
    pub fn named(c: *Ctx, z: []const u8) Oom!TypeId {
        return intern(c.p.db, c.dialect, z);
    }

    /// The id of `t`, under the dialect's spelling of it (Rules.spell).
    pub fn make(c: *Ctx, t: Type) Oom!TypeId {
        if (t.logical == .unknown) return unknown;
        var buf: [64]u8 = undefined;
        return c.p.db.xq.types.addType(c.p.db.gpa, c.dialect, t, c.rules.spell(t, &buf));
    }

    pub fn operand(c: *const Ctx, e: *const Expr) Operand {
        return .{ .id = e.xq_type, .type = typeOf(c.p.db, e.xq_type), .e = e };
    }

    /// A call of function `name` with `args` (Exprs resolved and typed),
    /// made by a rule after names were resolved: resolved as the
    /// resolver resolves a call (resolve.resolveNewCall()) and typed. In
    /// the place of its first argument, it takes that argument's
    /// EP_SubtArg (an argument of a function that reads subtypes).
    pub fn call(c: *Ctx, name: []const u8, args: []const *Expr) Error!*Expr {
        const p = c.p;
        var list: ?*int.ExprList = null;
        for (args) |a| {
            // A window function copied out of the Expr it was (toCall()'s
            // `e`, now this call) is its window's owner again, as after
            // resolveAlias()'s swap.
            if (a.flags.WinFunc) if (a.y.win) |win| {
                win.owner = a;
            };
            list = try expr_mod.listAppend(p, list, a);
        }
        if (exactFunction(p, name, args.len)) p.xq_exact_numeric = true;
        const e = try expr_mod.exprAlloc(p.arena, TK.FUNCTION, int.Token.init(name), true);
        e.x = .{ .list = list };
        e.flags.HasFunc = true;
        expr_mod.setHeight(e);
        if (args.len > 0 and args[0].flags.SubtArg) e.flags.SubtArg = true;
        if (c.nc) |nc| resolve.resolveNewCall(nc, e);
        e.xq_type = try exprType(c, e);
        return e;
    }

    /// Make `e` (an operator, resolved) a call of `name` with `args`, in
    /// place (call(); its type is computed again).
    pub fn toCall(c: *Ctx, e: *Expr, name: []const u8, args: []const *Expr) Error!void {
        const x = try c.call(name, args);
        x.flags.set(e.flags.only(.{ .SubtArg = true }));
        x.xq_type = e.xq_type;
        e.* = x.*;
        if (e.xq_type == unknown) e.xq_type = try exprType(c, e);
    }

    /// Call function `name` rather than the one `e` calls (a call
    /// resolved): one of the same kind (scalar, aggregate or window
    /// function), as code generation looks it up by name again; the
    /// window of a window function is told.
    pub fn rename(c: *Ctx, e: *Expr, name: []const u8) Oom!void {
        const p = c.p;
        if (exactFunction(p, name, if (e.x.list) |l| l.len() else 0)) p.xq_exact_numeric = true;
        e.u = .{ .token = try p.arena.dupeSentinel(u8, name, 0) };
        if (e.isWindowFunc()) {
            const n: i32 = if (e.x.list) |l| @intCast(l.len()) else 0;
            if (callback.findFunction(p.db, name, n, p.db.enc, false)) |d| e.y.win.?.w_func = d;
        }
    }

    /// `e COLLATE coll`, typed as `e`.
    pub fn collate(c: *Ctx, e: *Expr, coll: []const u8) Oom!*Expr {
        const x = try expr_mod.addCollateString(c.p, e, coll);
        x.xq_type = e.xq_type;
        return x;
    }

    /// Fail the statement with an error about `e`.
    pub fn fail(c: *Ctx, e: *const Expr, state: int.ErrorState, comptime fmt: []const u8, args: anytype) error{Failed} {
        util.errorMsg(c.p, fmt, args);
        util.errorIs(c.p, state);
        // At the text of its leftmost operand that has one (an operator
        // a frontend made has none of its own).
        var x = e;
        while (x.useWJoin() or x.w.ofst == 0) {
            const next = if (x.left) |l| l else if (x.useXList() and x.x.list != null and x.x.list.?.len() > 0) x.x.list.?.at(0).expr.? else break;
            x = next;
        }
        expr_mod.recordErrorOffsetOfExpr(c.p, x);
        if (c.nc) |nc| nc.n_nc_err += 1;
        return error.Failed;
    }

    /// The operand `o` stands for: through a cast no frontend typed (the
    /// `CAST(a AS REAL) / b` that MariaDB's and Oracle's frontends divide
    /// by, so that 7 / 2 is 3.5).
    pub fn throughCast(c: *const Ctx, o: Operand) Operand {
        if (o.e.op == TK.CAST and o.id == unknown) if (o.e.left) |l| return c.operand(l);
        return o;
    }
};

/// The Ctx of statement `p`, null if its dialect has no rules.
fn ctxOf(p: *int.Parse) ?Ctx {
    const d = p.db.xq.lang.dialect;
    const rules = @import("../dialect/dialect.zig").hooks(p.db).typing orelse return null;
    return .{ .p = p, .dialect = d, .rules = rules };
}

/// Type the Exprs of `e` (resolved in `nc`) that have no type yet,
/// innermost first, by the rules of the statement's dialect; the
/// parameters compared with, or computed with, an operand of a known
/// type (inferParams()); and the choices the dialect makes by the types
/// of operands (Rules.overload). After the names of `e` are resolved
/// (resolve.zig), for a statement typed (active()). The subqueries of `e`
/// were typed as they were resolved. Fails if a rule failed the
/// statement (the error is in the Parse); a failed allocation leaves
/// Exprs untyped (and the connection's malloc_failed set).
pub fn typeTree(nc: *int.NameContext, e: *Expr) int.ParseError!void {
    const p = nc.parse;
    var c = ctxOf(p) orelse return;
    c.nc = nc;
    _ = walk(&c, e) catch |err| switch (err) {
        error.OutOfMemory => p.db.oomFault(),
        error.Failed => return error.ParseFailed,
    };
}

/// Type `e` and what is under it; whether a rule changed the operands
/// of an Expr of it (so that the heights above are recomputed).
fn walk(c: *Ctx, e: *Expr) Error!bool {
    var changed = false;
    if (!e.flags.intersects(.{ .TokenOnly = true, .Leaf = true })) {
        if (e.left) |l| changed = try walk(c, l) or changed;
        if (e.right) |r| changed = try walk(c, r) or changed;
        if (e.useXList()) if (e.x.list) |list| for (list.slice()) |item| if (item.expr) |x| {
            changed = try walk(c, x) or changed;
        };
        // The ORDER BY of an aggregate (f(x ORDER BY y): a TK_ORDER on the
        // left of the call), the window of a window function.
        if (e.op == TK.ORDER and e.useXList()) if (e.x.list) |list| {
            changed = try keyList(c, list, false) or changed;
            changed = try orderByList(c, list) or changed;
        };
        if (e.useYWin()) if (e.y.win) |w| {
            if (w.partition) |list| {
                for (list.slice()) |item| if (item.expr) |x| {
                    _ = try walk(c, x);
                };
                _ = try keyList(c, list, true);
            }
            if (w.order_by) |list| {
                for (list.slice()) |item| if (item.expr) |x| {
                    _ = try walk(c, x);
                };
                _ = try keyList(c, list, true);
                _ = try orderByList(c, list);
            }
            if (w.filter) |x| _ = try walk(c, x);
        };
    }
    if (changed) expr_mod.setHeight(e);
    try inferParams(c, e);
    if (c.rules.overload) |f| if (c.p.xq_schema_text == 0 and try f(c, e)) {
        expr_mod.setHeight(e);
        changed = true;
    };
    if (e.xq_type == unknown) e.xq_type = try exprType(c, e);
    return changed;
}

/// The terms of ORDER BY (PARTITION BY) list `list` (typed) made the
/// keys of their types (Rules.group_key), so that values equal but not
/// the same (PostgreSQL's '1 mon' and '30 days') sort as peers: `all`
/// the terms (a window's: its peers, its partitions), else all but the
/// last (whose ties do not matter, and whose values an index on them
/// orders). Whether one changed.
fn keyList(c: *Ctx, list: *int.ExprList, all: bool) Error!bool {
    if (c.p.xq_schema_text > 0) return false;
    const f = c.rules.group_key orelse return false;
    const items = list.slice();
    var changed = false;
    for (items, 0..) |*item, i| {
        if (!all and i + 1 == items.len) break;
        const x = item.expr orelse continue;
        const name = f(c, x.xq_type, x) orelse continue;
        item.expr = try c.call(name, &.{x});
        item.u = .{ .x = .{} };
        changed = true;
    }
    return changed;
}

/// The ORDER BY of `s`, a query that is no compound (resolved in `nc`):
/// keyList()'s keys (a term that stood for a result column is that
/// column's copy, resolved: now an expression of its own). For a
/// statement typed (active()).
pub fn orderKeys(nc: *int.NameContext, s: *int.Select) void {
    const p = nc.parse;
    if (p.xq_schema_text > 0 or s.prior != null or s.next != null) return;
    const list = s.order_by orelse return;
    var c = ctxOf(p) orelse return;
    c.nc = nc;
    _ = keyList(&c, list, false) catch |err| switch (err) {
        error.OutOfMemory => p.db.oomFault(),
        error.Failed => {},
    };
}

/// The collation Rules.order_collation gives the items of ORDER BY list
/// `list` (typed) by their types; whether one changed.
fn orderByList(c: *Ctx, list: *int.ExprList) Error!bool {
    if (c.p.xq_schema_text > 0) return false;
    var changed = false;
    // Rules.order_key: the term wrapped in the key function.
    if (c.rules.order_key) |k| for (list.slice()) |*item| {
        const x = item.expr orelse continue;
        // (A key is of a type of no key: not wrapped twice.)
        if (x.op == TK.COLLATE) continue;
        const name = k(c, x.xq_type) orelse continue;
        item.expr = try c.call(name, &.{x});
        changed = true;
    };
    const f = c.rules.order_collation orelse return changed;
    for (list.slice()) |*item| {
        const x = item.expr orelse continue;
        if (x.op == TK.COLLATE) continue;
        const coll = f(c, x.xq_type, x) orelse continue;
        item.expr = try c.collate(x, coll);
        changed = true;
    }
    return changed;
}

/// The collation of ORDER BY term `item` of a query (resolved, typed) by
/// its type (Rules.order_collation): a term that is a result column
/// number or alias, now that it stands for that column (`id`: the type of
/// that column, for the terms of a compound, which are numbers). For a
/// statement typed (active()).
pub fn orderTerm(p: *int.Parse, item: *int.ExprListItem, id: TypeId, compound: bool) void {
    if (p.xq_schema_text > 0) return;
    var c = ctxOf(p) orelse return;
    const x = item.expr orelse return;
    if (x.op == TK.COLLATE) return;
    // Rules.order_key: the term an expression of its own (a compound's
    // can only be a column: its type's collation, if any).
    if (!compound) if (c.rules.order_key) |k| if (k(&c, id)) |name| {
        item.expr = c.call(name, &.{x}) catch return p.db.oomFault();
        item.u.x.order_by_col = 0;
        return;
    };
    const f = c.rules.order_collation orelse return;
    const coll = f(&c, id, x) orelse return;
    item.expr = c.collate(x, coll) catch return p.db.oomFault();
}

/// The collation ORDER BY term `e` (an expression, resolved and typed)
/// sorts with by its type, null for its own (Rules.order_collation). For
/// a statement typed (active()).
pub fn orderCollation(p: *int.Parse, e: *const Expr) ?[:0]const u8 {
    if (p.xq_schema_text > 0) return null;
    var c = ctxOf(p) orelse return null;
    const f = c.rules.order_collation orelse return null;
    if (e.op == TK.COLLATE) return null;
    return f(&c, e.xq_type, e);
}

/// The GROUP BY of `s` (its names resolved in `nc`, typed) by the keys
/// of the dialect's types (Rules.group_key): a term of such a type is
/// its key, which no longer stands for a result column; a DISTINCT that
/// is no aggregate and has a result column of such a type is a GROUP BY
/// of its result columns (as SQLite makes some DISTINCTs). For a
/// statement typed (active()); not in the schema's SQL.
pub fn groupBy(nc: *int.NameContext, s: *int.Select) void {
    const p = nc.parse;
    if (p.xq_schema_text > 0) return;
    var c = ctxOf(p) orelse return;
    c.nc = nc;
    const f = c.rules.group_key orelse return;
    groupByKeys(&c, f, s) catch |err| switch (err) {
        error.OutOfMemory => p.db.oomFault(),
        error.Failed => {},
    };
}

fn groupByKeys(c: *Ctx, f: *const fn (c: *Ctx, id: TypeId, e: *const Expr) ?[]const u8, s: *int.Select) Error!void {
    if (s.group_by) |gb| {
        for (gb.slice()) |*item| {
            const x = item.expr orelse continue;
            const name = f(c, x.xq_type, x) orelse continue;
            item.expr = try c.call(name, &.{x});
            item.u = .{ .x = .{} };
        }
        return;
    }
    if (!s.sel_flags.Distinct or s.sel_flags.Aggregate or s.win != null) return;
    const list = s.e_list orelse return;
    for (list.slice()) |item| {
        if (f(c, item.expr.?.xq_type, item.expr.?) != null) break;
    } else return;
    var gb: ?*int.ExprList = null;
    for (list.slice()) |item| {
        const x = (try expr_mod.exprDup(c.p.arena, item.expr.?)).?;
        const term = if (f(c, x.xq_type, x)) |name| try c.call(name, &.{x}) else x;
        gb = try expr_mod.listAppend(c.p, gb, term);
    }
    s.group_by = gb;
    s.sel_flags.Distinct = false;
    s.sel_flags.Aggregate = true;
}

/// ORDER BY term `e` (an expression, resolved in `nc` and typed) wrapped
/// in the function its type sorts by (Rules.order_key), null if none.
pub fn orderKey(nc: *int.NameContext, e: *Expr) int.ParseError!?*Expr {
    const p = nc.parse;
    if (p.xq_schema_text > 0 or e.op == TK.COLLATE) return null;
    var c = ctxOf(p) orelse return null;
    c.nc = nc;
    const k = c.rules.order_key orelse return null;
    const name = k(&c, e.xq_type) orelse return null;
    return c.call(name, &.{e}) catch |err| switch (err) {
        error.OutOfMemory => {
            p.db.oomFault();
            return error.ParseFailed;
        },
        error.Failed => return error.ParseFailed,
    };
}

/// The type of `e`, whose operands are typed.
fn exprType(c: *Ctx, e: *Expr) Oom!TypeId {
    switch (e.op) {
        TK.INTEGER, TK.FLOAT, TK.STRING, TK.BLOB, TK.NULL => {
            const id = try c.rules.literal(c, e);
            // A number literal of PostgreSQL's numeric (1.5, 1e3, an
            // integer past bigint) is exact (Parse.xq_exact_numeric).
            if (e.op != TK.STRING and c.rules.exact_types.contains(typeOf(c.p.db, id).logical)) c.p.xq_exact_numeric = true;
            return id;
        },
        TK.UPLUS, TK.COLLATE => return if (e.left) |l| l.xq_type else unknown,
        TK.PLUS, TK.MINUS, TK.STAR, TK.SLASH, TK.REM, TK.CONCAT, TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => {
            const l = e.left orelse return unknown;
            const r = e.right orelse return unknown;
            return c.rules.operator(c, e.op, c.operand(l), c.operand(r));
        },
        TK.UMINUS, TK.BITNOT => {
            const l = e.left orelse return unknown;
            return c.rules.operator(c, e.op, c.operand(l), null);
        },
        TK.CASE => {
            // The THEN values and the ELSE value.
            const list = (if (e.useXList()) e.x.list else null) orelse return unknown;
            const items = list.slice();
            var m: Common = .{};
            var i: usize = 1;
            while (i < items.len) : (i += 2) try m.add(c, items[i].expr.?);
            if (items.len % 2 == 1) try m.add(c, items[items.len - 1].expr.?);
            return m.result();
        },
        TK.FUNCTION, TK.AGG_FUNCTION => return functionType(c, e),
        TK.VARIABLE => {
            // A parameter typed elsewhere in the statement (?1 twice).
            if (e.i_column < 1) return unknown;
            const i: usize = @intCast(e.i_column - 1);
            const params = c.p.xq_param_types.items;
            return if (i < params.len) params[i] else unknown;
        },
        TK.SELECT => return if (e.useXSelect()) columnOfCtx(c, e.x.select.?, 0) else unknown,
        else => return unknown,
    }
}

fn functionType(c: *Ctx, e: *Expr) Oom!TypeId {
    if (!e.useUToken()) return unknown;
    const z = e.u.token orelse return unknown;
    var buf: [64]u8 = undefined;
    if (z.len > buf.len) return unknown;
    var name = std.ascii.lowerString(&buf, z);
    // SQLite's built-in under the name the dialect shadows.
    const sqlite_prefix = "xq_sqlite_";
    const ret = c.rules.function(name) orelse core_functions.get(name) orelse blk: {
        if (!std.mem.startsWith(u8, name, sqlite_prefix)) return unknown;
        name = name[sqlite_prefix.len..];
        break :blk c.rules.function(name) orelse core_functions.get(name) orelse return unknown;
    };
    var ops: [32]Operand = undefined;
    var n: usize = 0;
    if (e.useXList()) if (e.x.list) |list| for (list.slice()) |item| {
        if (n == ops.len) break;
        ops[n] = c.operand(item.expr.?);
        n += 1;
    };
    const args = ops[0..n];
    return switch (ret) {
        .named => |t| c.named(t),
        .arg => |i| if (i < args.len) args[i].id else unknown,
        .common => |i| if (i < args.len) commonOf(c, args[i..]) else unknown,
        .rule => |f| f(c, args),
    };
}

/// The common type of the values of a CASE, a compound's column ...:
/// NULL literals are of any type; an operand of no known type makes it
/// unknown.
const Common = struct {
    acc: ?Operand = null,
    failed: bool = false,
    /// A string literal left out (Rules.unknown_strings).
    string: ?Operand = null,

    fn add(m: *Common, c: *Ctx, e: *const Expr) Oom!void {
        if (m.failed or e.op == TK.NULL) return;
        const o = c.operand(e);
        if (c.rules.unknown_strings and e.op == TK.STRING) {
            if (m.string == null) m.string = o;
            return;
        }
        if (o.id == unknown) {
            m.failed = true;
            return;
        }
        const a = m.acc orelse {
            m.acc = o;
            return;
        };
        const id = try common(c, a, o) orelse {
            m.failed = true;
            return;
        };
        m.acc = .{ .id = id, .type = typeOf(c.p.db, id), .e = a.e };
    }

    fn result(m: *const Common) TypeId {
        if (m.failed) return unknown;
        if (m.acc) |a| return a.id;
        return if (m.string) |o| o.id else unknown;
    }
};

/// The common type of `args` (Common).
pub fn commonOf(c: *Ctx, args: []const Operand) Oom!TypeId {
    var m: Common = .{};
    for (args) |a| try m.add(c, a.e);
    return m.result();
}

/// Whether `l` is an integer type, and its width in bytes.
pub fn intWidth(l: Logical) ?u8 {
    return switch (l) {
        .int1 => 1,
        .int2 => 2,
        .int4 => 4,
        .int8 => 8,
        else => null,
    };
}

pub fn isFloat(l: Logical) bool {
    return l == .float4 or l == .float8;
}

/// Whether `l` is a number: an integer, a float, a numeric.
pub fn isNumber(l: Logical) bool {
    return intWidth(l) != null or isFloat(l) or l == .numeric;
}

/// Whether `l` is a character string.
pub fn isString(l: Logical) bool {
    return l == .text or l == .varchar or l == .char;
}

/// The decimal digits an integer of width `w` has (as a numeric(p,0)).
pub fn intDigits(l: Logical) ?u8 {
    return switch (l) {
        .int1 => 3,
        .int2 => 5,
        .int4 => 10,
        .int8 => 19,
        else => null,
    };
}

/// The precision and scale of `t` as an exact number: an integer is a
/// numeric(digits, 0); null for a numeric of no declared precision or
/// for another type.
pub fn exact(t: Type) ?struct { p: u32, s: u32 } {
    if (intDigits(t.logical)) |d| return .{ .p = d, .s = 0 };
    if (t.logical != .numeric) return null;
    const p = t.precision orelse return null;
    return .{ .p = p, .s = t.scale orelse 0 };
}

/// The type the values of operands `a` and `b` have together: the same
/// type; the wider integer; a numeric of the larger scale for exact
/// numbers; double precision for numbers with a float; a string of no
/// length for strings (text with a text); null if there is none.
pub fn common(c: *Ctx, a: Operand, b: Operand) Oom!?TypeId {
    if (a.id == b.id) return a.id;
    const la = a.logical();
    const lb = b.logical();
    if (la == .unknown or lb == .unknown) return null;
    if (c.rules.value_scale and isNumber(la) and isNumber(lb) and !isFloat(la) and !isFloat(lb) and (la == .numeric or lb == .numeric)) {
        const sa = if (la == .numeric) a.type.scale else 0;
        const sb = if (lb == .numeric) b.type.scale else 0;
        const same = sa != null and sb != null and sa.? == sb.?;
        return try c.make(.{ .logical = .numeric, .scale = if (same) sa else null });
    }
    if (la == lb) switch (la) {
        .numeric => {
            const x = exact(a.type) orelse return try c.make(.{ .logical = .numeric, .scale = scaleOf(a.type, b.type) });
            const y = exact(b.type) orelse return try c.make(.{ .logical = .numeric, .scale = scaleOf(a.type, b.type) });
            const s = @max(x.s, y.s);
            return try c.make(.{ .logical = .numeric, .precision = clampU8(@max(x.p -| x.s, y.p -| y.s) + s), .scale = clampU8(s) });
        },
        .varchar, .char, .bytes => return try c.make(.{ .logical = la, .length = if (a.type.length != null and b.type.length != null) @max(a.type.length.?, b.type.length.?) else null }),
        // Arrays of the same element type.
        .array => return if (a.type.element == b.type.element and a.type.element != .unknown) a.id else null,
        // The same type under two spellings, or with other parameters.
        else => return a.id,
    };
    if (intWidth(la)) |wa| if (intWidth(lb)) |wb| return if (wa >= wb) a.id else b.id;
    if ((la == .numeric or intWidth(la) != null) and (lb == .numeric or intWidth(lb) != null)) {
        // An integer with a numeric: the numeric's scale, digits enough
        // for both.
        const n = if (la == .numeric) a.type else b.type;
        const i = if (la == .numeric) lb else la;
        const x = exact(n) orelse return try c.make(.{ .logical = .numeric, .scale = n.scale });
        const d = intDigits(i).?;
        return try c.make(.{ .logical = .numeric, .precision = clampU8(@max(x.p -| x.s, d) + x.s), .scale = clampU8(x.s) });
    }
    if (isNumber(la) and isNumber(lb)) return try c.make(.{ .logical = .float8 });
    if (isString(la) and isString(lb)) {
        if (la == .text) return a.id;
        if (lb == .text) return b.id;
        return try c.make(.{ .logical = .varchar });
    }
    return null;
}

/// The larger of the scales of `a` and `b`, null unless both are known.
fn scaleOf(a: Type, b: Type) ?u8 {
    const x = a.scale orelse (if (intWidth(a.logical) != null) @as(u8, 0) else return null);
    const y = b.scale orelse (if (intWidth(b.logical) != null) @as(u8, 0) else return null);
    return @max(x, y);
}

pub fn clampU8(v: u32) u8 {
    return @intCast(@min(v, 255));
}

/// The type of column `i` of the result of `s` (a statement's SELECT, a
/// subquery: the last term of a compound, whose `prior`s are the others):
/// the common type of the column of every term (Common), else unknown.
/// Of the leftmost term without rules. For a statement typed (active()).
pub fn columnOf(p: *int.Parse, s: *int.Select, i: usize) Oom!TypeId {
    var c = ctxOf(p) orelse {
        var left = s;
        while (left.prior) |pr| left = pr;
        const list = left.e_list orelse return unknown;
        return if (i < list.len()) list.at(i).expr.?.xq_type else unknown;
    };
    return columnOfCtx(&c, s, i);
}

fn columnOfCtx(c: *Ctx, s: *int.Select, i: usize) Oom!TypeId {
    var m: Common = .{};
    var it: ?*int.Select = s;
    while (it) |term| : (it = term.prior) {
        const list = term.e_list orelse return unknown;
        if (i >= list.len()) return unknown;
        try m.add(c, list.at(i).expr.?);
    }
    return m.result();
}

// ======================================================= code generation
//
// What code generation reads of types, only for a statement typed
// (active(): an Expr of SQLite's dialect has no type, a table no store
// function), so that SQLite's bytecode stays SQLite's.

/// P5 of the opcode of arithmetic `e` (TK_PLUS, TK_MINUS, TK_STAR,
/// TK_SLASH, TK_REM, TK_UMINUS): the width of its integer type when the
/// dialect fails outside its range (dialect.Arith.width()), else 0.
pub fn arithWidth(p: *const int.Parse, e: *const Expr) u16 {
    if (e.xq_type == unknown or !active(p.db)) return 0;
    return dialect_mod.hooks(p.db).arith.width(typeOf(p.db, e.xq_type).logical);
}

/// What a value stored into a column goes through (storeFunctions()):
/// `def` of the value and `consts` after it.
pub const Store = struct {
    def: *const int.FuncDef,
    consts: [2]i32 = .{ 0, 0 },
    n_consts: u2 = 0,
    /// Every value, not only those storeNeeded() picks.
    always: bool = false,
    /// Only the values of this type (PostgreSQL's numeric stored into a
    /// column of another type: a key made a number or text).
    only: ?Logical = null,

    /// Whether value `e` goes through it.
    pub fn needed(s: Store, db: *const int.Sqlite3, e: *const Expr) bool {
        if (s.only) |l| return typeOf(db, e.xq_type).logical == l;
        return s.always or storeNeeded(db, e);
    }

    /// Whether the values of column `i` of query `sel` (INSERT ... SELECT)
    /// go through it.
    pub fn neededColumn(s: Store, p: *int.Parse, sel: *int.Select, i: usize) bool {
        const l = s.only orelse return true;
        const id = columnOf(p, sel, i) catch return true;
        return typeOf(p.db, id).logical == l;
    }
};

/// What each column of `t` (by index) is stored through (Rules.store_column
/// and Rules.store, by the column's type in the catalog), null if no
/// column has it; from the statement's memory.
pub fn storeFunctions(p: *int.Parse, t: *int.Table) Oom!?[]const ?Store {
    if (!active(p.db)) return null;
    const rules = dialect_mod.hooks(p.db).typing orelse return null;
    if (rules.store == null and rules.store_column == null) return null;
    if (!t.isOrdinary()) return null;
    const m = (catalog.metaOf(p.db, t) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => null,
    }) orelse return null;
    var out: ?[]?Store = null;
    for (m.columns) |*col| {
        const i = for (t.cols, 0..) |*tc, k| {
            if (std.ascii.eqlIgnoreCase(tc.name(), col.name)) break k;
        } else continue;
        const st: Store = blk: {
            if (rules.store_column) |sc| if (sc(col.type, col.decl_type orelse "", t.cols[i].e_ctype)) |s| break :blk s;
            const f = rules.store orelse continue;
            break :blk .{ .def = f(col.type, t.cols[i].e_ctype) orelse continue };
        };
        const list = out orelse blk: {
            const x = try p.arena.alloc(?Store, t.cols.len);
            @memset(x, null);
            out = x;
            break :blk x;
        };
        list[i] = st;
    }
    return out;
}

/// Whether value `e`, stored into a column with a store function, may
/// need it: a parameter, or a value of no known type or of a string
/// type (a number, a boolean expression, a column of the same type are
/// stored as they are), or of a type whose values may be in more than
/// one form (Rules.store_forms: PostgreSQL's interval may be text or a
/// BLOB), stored as the column keeps it.
pub fn storeNeeded(db: *const int.Sqlite3, e: *const Expr) bool {
    if (e.op == TK.VARIABLE) return true;
    const l = typeOf(db, e.xq_type).logical;
    return switch (l) {
        .unknown, .text, .varchar, .char => true,
        else => if (dialect_mod.hooks(db).typing) |rules| rules.store_forms.contains(l) else false,
    };
}

// ============================================================ parameters

/// Give the parameters among the operands of `e` the type of the operand
/// they meet: `col = ?`, `? + 1`, `x BETWEEN ? AND ?`, `x IN (?, ?)`,
/// `CASE x WHEN ? ...`.
fn inferParams(c: *Ctx, e: *Expr) Oom!void {
    switch (e.op) {
        TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE, TK.IS, TK.ISNOT, TK.PLUS, TK.MINUS, TK.STAR, TK.SLASH, TK.REM, TK.CONCAT, TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => {
            if (e.left) |l| if (e.right) |r| try pair(c, l, r);
        },
        TK.BETWEEN, TK.IN => {
            const l = e.left orelse return;
            if (!e.useXList()) return;
            const list = e.x.list orelse return;
            for (list.slice()) |item| try pair(c, l, item.expr.?);
        },
        TK.CASE => {
            const l = e.left orelse return;
            const list = (if (e.useXList()) e.x.list else null) orelse return;
            const items = list.slice();
            var i: usize = 0;
            while (i + 1 < items.len) : (i += 2) try pair(c, l, items[i].expr.?);
        },
        else => {},
    }
}

fn pair(c: *Ctx, a_arg: *Expr, b_arg: *Expr) Oom!void {
    const a = peel(a_arg);
    const b = peel(b_arg);
    if (a.op == TK.VARIABLE and a.xq_type == unknown) {
        try bindParam(c.p, a, b.xq_type);
    } else if (b.op == TK.VARIABLE and b.xq_type == unknown) {
        try bindParam(c.p, b, a.xq_type);
    }
}

/// `e` without the unary + and COLLATE around it (`x IN (?)` is lowered
/// to `x = +?`).
fn peel(e_arg: *Expr) *Expr {
    var e = e_arg;
    while ((e.op == TK.UPLUS or e.op == TK.COLLATE) and e.left != null) e = e.left.?;
    return e;
}

/// Give parameter `v` the type `id`, and record it as the type of its
/// number (Parse.xq_param_types, the first type found).
fn bindParam(p: *int.Parse, v: *Expr, id: TypeId) Oom!void {
    if (v.op != TK.VARIABLE or v.xq_type != unknown or id == unknown) return;
    v.xq_type = id;
    if (v.i_column < 1) return;
    const i: usize = @intCast(v.i_column - 1);
    const list = &p.xq_param_types;
    if (list.items.len <= i) try list.appendNTimes(p.arena, unknown, i + 1 - list.items.len);
    if (list.items[i] == unknown) list.items[i] = id;
}

/// Give parameter `v` the type `id` a dialect's rule chose for it rather
/// than the type of the operand it met (inferParams(): PostgreSQL's
/// `ts + $1` is timestamp + interval), and record it as the type of its
/// number unless another Expr gave that number another type first.
pub fn retypeParam(p: *int.Parse, v: *Expr, id: TypeId) Oom!void {
    if (v.op != TK.VARIABLE or id == unknown) return;
    const old = v.xq_type;
    v.xq_type = id;
    if (v.i_column < 1) return;
    const i: usize = @intCast(v.i_column - 1);
    const list = &p.xq_param_types;
    if (list.items.len <= i) try list.appendNTimes(p.arena, unknown, i + 1 - list.items.len);
    if (list.items[i] == unknown or list.items[i] == old) list.items[i] = id;
}

/// `e` is stored into a column of type `id` (INSERT VALUES, UPDATE SET):
/// a parameter that is the value gets that type, through the functions
/// the frontend wraps stored values in (Rules.store_wrappers). For a
/// statement typed (active()).
pub fn assign(p: *int.Parse, e_arg: *Expr, id: TypeId) void {
    if (id == unknown) return;
    const c = ctxOf(p) orelse return;
    var e = peel(e_arg);
    while (e.op == TK.FUNCTION and e.useUToken() and e.useXList()) {
        const z = e.u.token orelse return;
        const list = e.x.list orelse return;
        if (list.len() == 0) return;
        for (c.rules.store_wrappers) |w| {
            if (std.ascii.eqlIgnoreCase(w, z)) break;
        } else return;
        e = peel(list.at(0).expr.?);
    }
    bindParam(p, e, id) catch p.db.oomFault();
}

/// The types of the parameters of `p` (Parse.xq_param_types) as Types,
/// `n` of them (allocated from `a`), for the statement
/// (Vdbe.xq_param_types); empty if none is known.
pub fn paramTypes(p: *const int.Parse, a: std.mem.Allocator, n: usize) Oom![]Type {
    const ids = p.xq_param_types.items;
    for (ids) |id| {
        if (id != unknown) break;
    } else return &.{};
    const out = try a.alloc(Type, n);
    for (out, 0..) |*t, i| t.* = if (i < ids.len) typeOf(p.db, ids[i]) else .{ .logical = .unknown };
    return out;
}

// ============================================================ literals

/// The integer an operand is, if it is an integer literal (`2` of
/// round(x, 2), `-1`).
pub fn intArg(o: Operand) ?i64 {
    const e = o.e;
    if (e.op == TK.INTEGER) return intLiteral(e);
    if (e.op == TK.UMINUS) if (e.left) |l| if (l.op == TK.INTEGER) return if (intLiteral(l)) |v| -%v else null;
    return null;
}

/// The characters of string literal `e` (TK_STRING), null for another
/// Expr.
pub fn stringLength(e: *const Expr) ?u32 {
    if (e.op != TK.STRING or !e.useUToken()) return null;
    const z = e.u.token orelse return 0;
    const n = std.unicode.utf8CountCodepoints(z) catch z.len;
    return @intCast(@min(n, std.math.maxInt(u32)));
}

/// The text of string literal `e`, null for another Expr.
pub fn stringArg(o: Operand) ?[]const u8 {
    if (o.e.op != TK.STRING or !o.e.useUToken()) return null;
    return o.e.u.token orelse "";
}

/// The value of integer literal `e` (TK_INTEGER), null beyond 64 bits.
pub fn intLiteral(e: *const Expr) ?i64 {
    if (e.flags.IntValue) return e.u.value;
    const z = e.u.token orelse return null;
    if (z.len > 2 and z[0] == '0' and (z[1] == 'x' or z[1] == 'X')) {
        const u = std.fmt.parseInt(u64, z[2..], 16) catch return null;
        return @bitCast(u);
    }
    return std.fmt.parseInt(i64, z, 10) catch null;
}

/// The digits of a decimal literal: `int_digits` before the point
/// (leading zeros not counted), `frac_digits` after it, and the exponent
/// if it has one ("1.50": 1, 2, null; "1.5e3": 1, 1, 3).
pub const Decimal = struct {
    int_digits: u32 = 0,
    frac_digits: u32 = 0,
    exponent: ?i32 = null,

    /// The scale of its value: the digits after the point once the
    /// exponent moved it.
    pub fn scale(d: Decimal) u32 {
        const s: i64 = @as(i64, d.frac_digits) - (d.exponent orelse 0);
        return @intCast(std.math.clamp(s, 0, 1000));
    }

    /// The digits of its value (at least 1, at least the scale).
    pub fn precision(d: Decimal) u32 {
        const s = d.scale();
        const i: i64 = @as(i64, d.int_digits) + (d.exponent orelse 0);
        return @max(@as(u32, @intCast(std.math.clamp(i, 0, 1000))) + s, s, 1);
    }
};

/// The Decimal of the text of a number literal (TK_INTEGER, TK_FLOAT);
/// null if it is none (hexadecimal).
pub fn decimalLiteral(e: *const Expr) ?Decimal {
    if (e.flags.IntValue) {
        var v: u32 = @intCast(@max(e.u.value, 0));
        var d: Decimal = .{};
        while (v > 0) : (v /= 10) d.int_digits += 1;
        return d;
    }
    const z = e.u.token orelse return null;
    var d: Decimal = .{};
    var i: usize = 0;
    var leading = true;
    while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) {
        if (leading and z[i] == '0') continue;
        leading = false;
        d.int_digits += 1;
    }
    if (i < z.len and z[i] == '.') {
        i += 1;
        while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) d.frac_digits += 1;
    }
    if (i < z.len and (z[i] == 'e' or z[i] == 'E')) {
        d.exponent = std.fmt.parseInt(i32, z[i + 1 ..], 10) catch return null;
        i = z.len;
    }
    if (i != z.len) return null;
    return d;
}

test Interner {
    const gpa = std.testing.allocator;
    var in: Interner = .{};
    defer in.deinit(gpa);
    try std.testing.expectEqual(boolean, try in.add(gpa, .postgres, "boolean"));
    try std.testing.expectEqual(plain(.int4), try in.add(gpa, .postgres, "integer"));
    const int4 = try in.add(gpa, .postgres, "int4");
    try std.testing.expect(int4 >= first_interned);
    try std.testing.expectEqual(int4, try in.add(gpa, .postgres, "int4"));
    try std.testing.expectEqualStrings("int4", in.get(int4).?.name);
    try std.testing.expectEqual(Logical.int4, in.get(int4).?.type.logical);
    const dec = try in.add(gpa, .mariadb, "DECIMAL(6,2)");
    try std.testing.expectEqual(Type{ .logical = .numeric, .precision = 6, .scale = 2 }, in.get(dec).?.type);
    try std.testing.expectEqualStrings("DECIMAL(6,2)", in.get(dec).?.name);
    // The same spelling is another type in another dialect.
    const f_pg = try in.add(gpa, .postgres, "float");
    const f_my = try in.add(gpa, .mariadb, "float");
    try std.testing.expect(f_pg != f_my);
    try std.testing.expectEqual(Logical.float8, in.get(f_pg).?.type.logical);
    try std.testing.expectEqual(Logical.float4, in.get(f_my).?.type.logical);
    // A spelling of no known type keeps its text.
    const s = try in.add(gpa, .mariadb, "SIGNED");
    try std.testing.expectEqualStrings("SIGNED", in.get(s).?.name);
    try std.testing.expectEqual(Logical.unknown, in.get(s).?.type.logical);
    try std.testing.expectEqual(@as(?Entry, null), in.get(unknown));
    try std.testing.expectEqual(unknown, try in.add(gpa, .postgres, ""));
}

test "Interner.addType: a type under a spelling that says less" {
    const gpa = std.testing.allocator;
    var in: Interner = .{};
    defer in.deinit(gpa);
    // PostgreSQL's numeric of scale 2 spelled "numeric".
    const n2 = try in.addType(gpa, .postgres, .{ .logical = .numeric, .scale = 2 }, "numeric");
    try std.testing.expect(n2 >= first_interned);
    try std.testing.expectEqual(n2, try in.addType(gpa, .postgres, .{ .logical = .numeric, .scale = 2 }, "numeric"));
    try std.testing.expectEqual(Type{ .logical = .numeric, .scale = 2 }, in.get(n2).?.type);
    try std.testing.expectEqualStrings("numeric", in.get(n2).?.name);
    // Another scale is another type; the spelling's own type is the
    // plain id.
    try std.testing.expect(n2 != try in.addType(gpa, .postgres, .{ .logical = .numeric, .scale = 3 }, "numeric"));
    try std.testing.expectEqual(plain(.numeric), try in.addType(gpa, .postgres, .{ .logical = .numeric }, "numeric"));
    try std.testing.expectEqual(plain(.int4), try in.addType(gpa, .postgres, .{ .logical = .int4 }, "integer"));
    // A spelling that reads back as the type is add()'s id.
    const d = try in.addType(gpa, .mariadb, .{ .logical = .numeric, .precision = 6, .scale = 2 }, "decimal(6,2)");
    try std.testing.expectEqual(d, try in.add(gpa, .mariadb, "decimal(6,2)"));
    try std.testing.expectEqual(unknown, try in.addType(gpa, .postgres, .{ .logical = .unknown }, "x"));
}

test decimalLiteral {
    const T = struct {
        fn expect(z: [:0]const u8, p: u32, s: u32) !void {
            var buf: [32]u8 = undefined;
            @memcpy(buf[0..z.len], z);
            buf[z.len] = 0;
            const e: Expr = .{ .op = TK.FLOAT, .u = .{ .token = buf[0..z.len :0] } };
            const d = decimalLiteral(&e).?;
            try std.testing.expectEqual(p, d.precision());
            try std.testing.expectEqual(s, d.scale());
        }
    };
    try T.expect("1.50", 3, 2);
    try T.expect("0.5", 1, 1);
    try T.expect(".25", 2, 2);
    try T.expect("12", 2, 0);
    try T.expect("1e3", 4, 0);
    try T.expect("1.5e-3", 4, 4);
    try T.expect("12.5E1", 3, 0);
    const e: Expr = .{ .op = TK.INTEGER, .flags = .{ .IntValue = true }, .u = .{ .value = 1234 } };
    try std.testing.expectEqual(@as(u32, 4), decimalLiteral(&e).?.precision());
    try std.testing.expectEqual(@as(?i64, 1234), intLiteral(&e));
}

/// Whether `name` with `n_arg` arguments is a function that computes
/// exact numerics (FUNC.XQ_EXACT: decimal_sql.zig's), which makes the
/// statement compute as its dialect chose (Parse.xq_exact_numeric).
fn exactFunction(p: *int.Parse, name: []const u8, n_arg: usize) bool {
    const d = callback.findFunction(p.db, name, @intCast(n_arg), p.db.enc, false) orelse return false;
    return d.func_flags.XQ_EXACT;
}
