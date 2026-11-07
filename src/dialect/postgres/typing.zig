//! PostgreSQL's types of expressions (dialect.Hooks.typing, the rules of
//! sql/typing.zig), as its operator and function resolution gives them:
//!  - an integer literal is an integer if it fits 32 bits, else a bigint,
//!    else a numeric; a literal with a point or an exponent is a numeric
//!    of the scale it is written with (1.50: two digits); a string
//!    literal is text (PostgreSQL's unknown, which a result column makes
//!    text), and in arithmetic of the type of the other operand;
//!  - integers compute in the wider of their types (int4 + int4 is an
//!    integer, int4 + int8 a bigint, int4 / int4 an integer); a numeric
//!    with an integer or a numeric is a numeric whose values have the
//!    larger scale for + - % and the sum of the scales for *, of no
//!    known scale for / (PostgreSQL picks it per value) or when a scale
//!    is unknown; a float makes a double precision (real only with
//!    real); || is text;
//!  - functions return what PostgreSQL's do: count() a bigint, sum() of
//!    integers a bigint (of bigints a numeric), avg() a numeric, length()
//!    an integer, upper() text, round(x, 2) a numeric of scale 2 ...
//! A numeric made so is spelled "numeric" (PostgreSQL keeps no typmod
//! through an operator) but keeps its scale, so that it shows as many
//! digits (api/display.zig).

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const types = @import("../../sql/types.zig");
const int = @import("../../sql/sqlite_int.zig");
const funcs = @import("funcs.zig");
const jfuncs = @import("jfuncs.zig");
const datetime = @import("datetime.zig");

const TK = int.TK;
const Expr = int.Expr;
const Ctx = typing.Ctx;
const Operand = typing.Operand;
const Ret = typing.Ret;
const TypeId = typing.TypeId;
const Type = types.Type;
const Logical = types.Logical;
const Oom = error{OutOfMemory};
const unknown = typing.unknown;

pub const rules: typing.Rules = .{
    .spell = spell,
    .literal = literal,
    .operator = operator,
    .function = function,
    .value_scale = true,
    .store = store,
    .store_column = storeColumn,
    .store_forms = repr.store_forms,
    .exact_types = repr.exact_types,
    .unknown_strings = true,
    .literal_input = true,
    .overload = overload.overload,
    .unify = overload.unify,
    .order_collation = overload.orderCollation,
    .group_key = repr.groupKey,
    .order_key = repr.orderKey,
    .no_function = noFunction,
};

/// PostgreSQL's error of a call no function matches (ParseFuncOrColumn()):
/// `function f(integer, unknown) does not exist`, the types of the
/// arguments as format_type() spells them; a string literal, NULL or a
/// parameter of no type is unknown (and so is an argument whose type the
/// core does not know: a column of a SQLite table).
fn noFunction(c: *Ctx, e: *const Expr) typing.Error {
    const a = c.p.arena;
    // The name as written, without the prefix of the dialect's own.
    const z = e.token();
    var buf: [64]u8 = undefined;
    const own = if (z.len <= buf.len) ownName(std.ascii.lowerString(&buf, z)).len else z.len;
    const args: []const int.ExprListItem = if (e.useXList()) if (e.x.list) |l| l.slice() else &.{} else &.{};
    const shown = try a.alloc([]const u8, args.len);
    for (args, shown) |item, *t| t.* = argTypeName(c, item.expr.?);
    return c.failFields(e, .of("42883"), try @import("frontend.zig").functionNotExist(a, z[z.len - own ..], shown));
}

/// The name of the type of argument `x` in PostgreSQL's errors.
fn argTypeName(c: *const Ctx, x: *const Expr) []const u8 {
    if (x.op == TK.STRING or x.op == TK.NULL) return "unknown";
    const t = typing.typeOf(c.p.db, x.xq_type);
    if (t.logical == .unknown) return "unknown";
    const pgc = @import("pgcatalog.zig");
    const bt = pgc.builtinType(@import("../../sql/pg_types.zig").ofType(t)) orelse return "unknown";
    return bt.fmt;
}

/// The types stored in a BLOB form of their own (numeric, interval, uuid,
/// jsonb): their store functions, grouping and ordering.
const repr = @import("repr.zig");

/// A value stored into an integer column is read as the type's input
/// ('12' is 12, '1.5' an error), a real rounded, a numeric as a numeric
/// (integer.zig); the other types' by their descriptors.
fn storeColumn(t: Type, decl: []const u8, storage: int.COLTYPE) ?typing.Store {
    if (integer.storeColumn(t)) |s| return s;
    // varchar(n), character(n): the spaces past n dropped (funcs.zig); a
    // numeric as its text.
    if ((t.logical == .varchar or t.logical == .char) and t.length != null) return .{
        .typed = .{ .types = .initOne(.numeric), .conv = .{ .def = @import("../decimal_sql.zig").def("xq_dec_text", 1) } },
        .needed = .{
            .def = if (t.logical == .char) &funcs.store_bpchar else &funcs.store_varchar,
            .consts = .{ @intCast(@min(t.length.?, std.math.maxInt(i32))), 0 },
            .n_consts = 1,
        },
    };
    // inet, cidr: their input, written canonical (inet.zig).
    if (std.mem.eql(u8, decl, "inet")) return .of(.{ .def = &inet.cast_inet });
    if (std.mem.eql(u8, decl, "cidr")) return .of(.{ .def = &inet.cast_cidr });
    return repr.storeColumn(t, decl, storage);
}

const inet = @import("inet.zig");

const integer = @import("integer.zig");

/// A string stored into a boolean, date, time or timestamp column is
/// read as the type's input (funcs.zig's store functions, datetime.zig's
/// casts). The types stored in a BLOB form of their own (numeric,
/// interval, uuid, jsonb) have theirs in their descriptors
/// (repr.storeColumn(), asked first).
fn store(t: Type, storage: int.COLTYPE) ?*const int.FuncDef {
    _ = storage;
    return switch (t.logical) {
        .boolean => &funcs.store_boolean,
        // Read and written as PostgreSQL does: '2 hours' is '02:00:00',
        // a timestamptz is kept in UTC, '2024-02-30' is an error.
        .date => datetime.cast_date,
        .time => datetime.cast_time,
        .timestamp => datetime.cast_timestamp,
        .timestamp_tz => datetime.cast_timestamptz,
        // Read as the elements' type reads them, written canonical.
        .array => array.inputFunction(t.element),
        else => null,
    };
}

const array = @import("array.zig");

// ================================================================ numeric

/// xq_dec(x [, p, s]) and xq_dec_key(): numeric(p, s), else of the scale
/// of x (a string literal's digits: '1.50' has 2; an integer's none).
fn decType(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 0) return unknown;
    if (args.len == 3) if (typing.intArg(args[1])) |p| if (typing.intArg(args[2])) |s| {
        const sc: ?u8 = if (s >= 0) typing.clampU8(@intCast(@min(s, 255))) else 0;
        return c.make(.{ .logical = .numeric, .precision = if (p >= 1 and p <= 255) @intCast(p) else null, .scale = sc });
    };
    return numericOf(c, args[0]);
}

/// The numeric an operand is converted to.
fn numericOf(c: *Ctx, o: Operand) Oom!TypeId {
    if (typing.stringArg(o)) |z| {
        const d = @import("decimal");
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const v = d.parse(fba.allocator(), z) catch return c.make(.{ .logical = .numeric });
        return c.make(.{ .logical = .numeric, .scale = typing.clampU8(@min(v.dscale, 255)) });
    }
    if (typing.intWidth(o.logical()) != null) return c.make(.{ .logical = .numeric, .scale = 0 });
    if (o.logical() == .numeric) return c.make(.{ .logical = .numeric, .scale = o.type.scale });
    return c.make(.{ .logical = .numeric });
}

fn decArg0(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 0) return unknown;
    if (args[0].logical() == .numeric) return args[0].id;
    return numericOf(c, args[0]);
}

fn decScale0(c: *Ctx, args: []const Operand) Oom!TypeId {
    _ = args;
    return c.make(.{ .logical = .numeric, .scale = 0 });
}

fn decNoScale(c: *Ctx, args: []const Operand) Oom!TypeId {
    _ = args;
    return c.make(.{ .logical = .numeric });
}

/// xq_dec_add() ... : the scale of the operator.
fn decOperator(comptime op: u8) *const fn (c: *Ctx, args: []const Operand) Oom!TypeId {
    return struct {
        fn f(c: *Ctx, args: []const Operand) Oom!TypeId {
            if (args.len != 2) return unknown;
            const t = try operator(c, op, args[0], args[1]);
            if (t == unknown) return c.make(.{ .logical = .numeric });
            return t;
        }
    }.f;
}

/// The types of the engine functions of numerics (decimal_sql.zig) and
/// of PostgreSQL's functions of numerics only.
const numeric_functions = .{
    .{ "xq_dec", Ret{ .rule = decType } },
    .{ "xq_dec_key", Ret{ .rule = decType } },
    .{ "xq_dec_valid", Ret{ .named = "boolean" } },
    .{ "xq_dec_text", Ret{ .named = "text" } },
    .{ "xq_dec_add", Ret{ .rule = decOperator(TK.PLUS) } },
    .{ "xq_dec_sub", Ret{ .rule = decOperator(TK.MINUS) } },
    .{ "xq_dec_mul", Ret{ .rule = decOperator(TK.STAR) } },
    .{ "xq_dec_div", Ret{ .rule = decNoScale } },
    .{ "xq_dec_mod", Ret{ .rule = decOperator(TK.REM) } },
    .{ "xq_dec_div_trunc", Ret{ .rule = decScale0 } },
    .{ "xq_dec_neg", Ret{ .rule = decArg0 } },
    .{ "xq_dec_abs", Ret{ .rule = decArg0 } },
    .{ "xq_dec_ceil", Ret{ .rule = decScale0 } },
    .{ "xq_dec_floor", Ret{ .rule = decScale0 } },
    .{ "xq_dec_sign", Ret{ .rule = decScale0 } },
    .{ "xq_dec_trim_scale", Ret{ .rule = decNoScale } },
    .{ "xq_dec_round", Ret{ .rule = round } },
    .{ "xq_dec_trunc", Ret{ .rule = round } },
    .{ "xq_dec_scale", Ret{ .named = "integer" } },
    .{ "xq_dec_min_scale", Ret{ .named = "integer" } },
    .{ "xq_dec_sqrt", Ret{ .rule = decNoScale } },
    .{ "xq_dec_exp", Ret{ .rule = decNoScale } },
    .{ "xq_dec_ln", Ret{ .rule = decNoScale } },
    .{ "xq_dec_log", Ret{ .rule = decNoScale } },
    .{ "xq_dec_power", Ret{ .rule = decNoScale } },
    .{ "xq_dec_factorial", Ret{ .rule = decScale0 } },
    .{ "xq_dec_width_bucket", Ret{ .named = "integer" } },
    .{ "xq_dec_int2", Ret{ .named = "smallint" } },
    .{ "xq_dec_int4", Ret{ .named = "integer" } },
    .{ "xq_dec_int8", Ret{ .named = "bigint" } },
    .{ "xq_dec_float4", Ret{ .named = "real" } },
    .{ "xq_dec_float8", Ret{ .named = "double precision" } },
    .{ "xq_dec_number", Ret{ .rule = decNoScale } },
    .{ "xq_dec_sum", Ret{ .rule = sum } },
    .{ "xq_dec_avg", Ret{ .rule = decNoScale } },
    .{ "xq_pg_dec_json", Ret{ .named = "json" } },
    .{ "div", Ret{ .rule = decScale0 } },
    .{ "scale", Ret{ .named = "integer" } },
    .{ "min_scale", Ret{ .named = "integer" } },
    .{ "trim_scale", Ret{ .rule = decNoScale } },
};

/// PostgreSQL's choices by the types of operands (jsonb's operators, the
/// arguments of the functions that make JSON): overload.zig.
const overload = @import("overload.zig");

fn spell(t: Type, buf: *[64]u8) []const u8 {
    if (t.logical == .array) {
        if (t.element == .unknown or t.element == .array) return "text[]";
        var eb: [64]u8 = undefined;
        const z = spell(t.elementType(), &eb);
        return std.fmt.bufPrint(buf, "{s}[]", .{z}) catch "text[]";
    }
    return switch (t.logical) {
        // An operator's numeric has no typmod.
        .numeric => "numeric",
        .int1 => "smallint",
        .varchar => if (t.length) |n| std.fmt.bufPrint(buf, "character varying({d})", .{n}) catch "character varying" else "character varying",
        .char => if (t.length) |n| std.fmt.bufPrint(buf, "character({d})", .{n}) catch "character" else "character",
        else => typing.plainName(t.logical),
    };
}

fn literal(c: *Ctx, e: *const int.Expr) Oom!TypeId {
    return switch (e.op) {
        TK.INTEGER => if (typing.intLiteral(e)) |v|
            typing.plain(if (std.math.cast(i32, v) != null) .int4 else .int8)
        else
            c.make(.{ .logical = .numeric, .scale = 0 }),
        TK.FLOAT => if (typing.decimalLiteral(e)) |d| c.make(.{ .logical = .numeric, .scale = typing.clampU8(d.scale()) }) else c.make(.{ .logical = .numeric }),
        TK.STRING => typing.plain(.text),
        TK.BLOB => typing.plain(.bytes),
        else => unknown,
    };
}

fn operator(c: *Ctx, op: u8, a_arg: Operand, b_arg: ?Operand) Oom!TypeId {
    if (op == TK.CONCAT) return typing.plain(.text);
    var a = a_arg;
    var b = b_arg orelse {
        // -x, ~x.
        if (op == TK.BITNOT) return if (typing.intWidth(a.logical()) != null) a.id else unknown;
        return if (typing.isNumber(a.logical())) a.id else unknown;
    };
    // A string literal is of the type of the other operand.
    if (a.e.op == TK.STRING and b.e.op != TK.STRING) a = b;
    if (b.e.op == TK.STRING and a.e.op != TK.STRING) b = a;
    const la = a.logical();
    const lb = b.logical();
    if (la == .unknown or lb == .unknown) return unknown;
    switch (op) {
        TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => {
            const wa = typing.intWidth(la) orelse return unknown;
            const wb = typing.intWidth(lb) orelse return unknown;
            // a << n is of a's type.
            if (op == TK.LSHIFT or op == TK.RSHIFT) return c.make(.{ .logical = la });
            return c.make(.{ .logical = if (wa >= wb) la else lb });
        },
        else => {},
    }
    // The rest are numbers; the operators of other types are engine
    // functions (operators.zig), typed by their rows.
    if (typing.intWidth(la)) |wa| if (typing.intWidth(lb)) |wb| {
        // PostgreSQL has no 1-byte integer.
        const w = @max(wa, wb, 2);
        return c.make(.{ .logical = switch (w) {
            2 => .int2,
            4 => .int4,
            else => .int8,
        } });
    };
    if (typing.isFloat(la) or typing.isFloat(lb)) {
        if (!typing.isNumber(la) or !typing.isNumber(lb)) return unknown;
        return c.make(.{ .logical = if (la == .float4 and lb == .float4) .float4 else .float8 });
    }
    if (exactScale(a.type)) |sa| if (exactScale(b.type)) |sb| {
        return c.make(.{ .logical = .numeric, .scale = switch (op) {
            TK.PLUS, TK.MINUS, TK.REM => @max(sa, sb),
            TK.STAR => typing.clampU8(@as(u32, sa) + sb),
            else => null,
        } });
    };
    if (isExact(la) and isExact(lb)) return c.make(.{ .logical = .numeric });
    return unknown;
}

fn isExact(l: Logical) bool {
    return l == .numeric or typing.intWidth(l) != null;
}

/// The scale of the values of an exact number: an integer's 0; null if
/// unknown (a numeric of no declared scale, or no exact number).
fn exactScale(t: Type) ?u8 {
    if (typing.intWidth(t.logical) != null) return 0;
    if (t.logical != .numeric) return null;
    return t.scale;
}

fn function(name: []const u8) ?Ret {
    const n = ownName(name);
    if (functions.get(n)) |r| return r;
    // The casts to arrays (xq_pg_array_int4 ...), in the text of views.
    if (array.inputElem(n)) |e| return if (e == .unknown) null else Ret{ .named = array_names[@backingInt(e)] };
    // The engine functions of operators (xq_pg_date_pli() ...).
    if (operators.functionResult(n)) |t| return Ret{ .named = t.name() };
    return null;
}

const operators = @import("operators.zig");

/// `name` (lower case) without the prefix that calls a function of
/// PostgreSQL's table from the text of the schema (xq_postgres_to_json()).
pub fn ownName(name: []const u8) []const u8 {
    const prefix = "xq_postgres_";
    if (name.len > prefix.len and std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    return name;
}

const functions = std.StaticStringMap(Ret).initComptime(.{
    // Aggregates and window functions.
    .{ "count", Ret{ .named = "bigint" } },
    .{ "sum", Ret{ .rule = sum } },
    .{ "avg", Ret{ .rule = avg } },
    .{ "string_agg", Ret{ .named = "text" } },
    .{ "group_concat", Ret{ .named = "text" } },
    .{ "row_number", Ret{ .named = "bigint" } },
    .{ "rank", Ret{ .named = "bigint" } },
    .{ "dense_rank", Ret{ .named = "bigint" } },
    .{ "ntile", Ret{ .named = "integer" } },
    .{ "percent_rank", Ret{ .named = "double precision" } },
    .{ "cume_dist", Ret{ .named = "double precision" } },
    .{ "lag", Ret{ .arg = 0 } },
    .{ "lead", Ret{ .arg = 0 } },
    .{ "first_value", Ret{ .arg = 0 } },
    .{ "last_value", Ret{ .arg = 0 } },
    .{ "nth_value", Ret{ .arg = 0 } },
    // Strings (char_length and strpos are lowered to length and instr).
    .{ "length", Ret{ .named = "integer" } },
    .{ "octet_length", Ret{ .named = "integer" } },
    .{ "instr", Ret{ .named = "integer" } },
    .{ "unicode", Ret{ .named = "integer" } },
    .{ "upper", Ret{ .named = "text" } },
    .{ "lower", Ret{ .named = "text" } },
    .{ "substr", Ret{ .named = "text" } },
    .{ "trim", Ret{ .named = "text" } },
    .{ "ltrim", Ret{ .named = "text" } },
    .{ "rtrim", Ret{ .named = "text" } },
    .{ "replace", Ret{ .named = "text" } },
    .{ "lpad", Ret{ .named = "text" } },
    .{ "rpad", Ret{ .named = "text" } },
    .{ "repeat", Ret{ .named = "text" } },
    .{ "reverse", Ret{ .named = "text" } },
    .{ "left", Ret{ .named = "text" } },
    .{ "right", Ret{ .named = "text" } },
    .{ "initcap", Ret{ .named = "text" } },
    .{ "concat", Ret{ .named = "text" } },
    .{ "concat_ws", Ret{ .named = "text" } },
    .{ "char", Ret{ .named = "text" } },
    .{ "split_part", Ret{ .named = "text" } },
    .{ "translate", Ret{ .named = "text" } },
    .{ "md5", Ret{ .named = "text" } },
    .{ "sha224", Ret{ .named = "bytea" } },
    .{ "sha256", Ret{ .named = "bytea" } },
    .{ "sha384", Ret{ .named = "bytea" } },
    .{ "sha512", Ret{ .named = "bytea" } },
    .{ "encode", Ret{ .named = "text" } },
    .{ "host", Ret{ .named = "text" } },
    .{ "masklen", Ret{ .named = "integer" } },
    .{ "family", Ret{ .named = "integer" } },
    .{ "xq_pg_inet", Ret{ .named = "inet" } },
    .{ "xq_pg_cidr", Ret{ .named = "cidr" } },
    .{ "decode", Ret{ .named = "bytea" } },
    .{ "format", Ret{ .named = "text" } },
    .{ "starts_with", Ret{ .named = "boolean" } },
    // Numbers.
    .{ "abs", Ret{ .arg = 0 } },
    .{ "mod", Ret{ .rule = mod } },
    .{ "round", Ret{ .rule = round } },
    .{ "trunc", Ret{ .rule = round } },
    .{ "ceil", Ret{ .rule = ceil } },
    .{ "ceiling", Ret{ .rule = ceil } },
    .{ "floor", Ret{ .rule = ceil } },
    .{ "sign", Ret{ .rule = ceil } },
    .{ "sqrt", Ret{ .rule = transcendental } },
    .{ "exp", Ret{ .rule = transcendental } },
    .{ "ln", Ret{ .rule = transcendental } },
    .{ "log", Ret{ .rule = logType } },
    .{ "log10", Ret{ .rule = transcendental } },
    .{ "factorial", Ret{ .rule = decScale0 } },
    .{ "width_bucket", Ret{ .named = "integer" } },
    .{ "power", Ret{ .rule = transcendental } },
    .{ "pow", Ret{ .rule = transcendental } },
    .{ "random", Ret{ .named = "double precision" } },
    .{ "pi", Ret{ .named = "double precision" } },
    .{ "greatest", Ret{ .common = 0 } },
    .{ "least", Ret{ .common = 0 } },
    // Dates (now() and its synonyms: the frontend's Func.result_type).
    .{ "current_date", Ret{ .named = "date" } },
    .{ "current_time", Ret{ .named = "time with time zone" } },
    // The session.
    .{ "version", Ret{ .named = "text" } },
    .{ "current_user", Ret{ .named = "name" } },
    .{ "current_database", Ret{ .named = "name" } },
    .{ "current_schema", Ret{ .named = "name" } },
    .{ "current_setting", Ret{ .named = "text" } },
    .{ "set_config", Ret{ .named = "text" } },
    .{ "format_type", Ret{ .named = "text" } },
    .{ "gen_random_uuid", Ret{ .named = "uuid" } },
    // uuid (uuid.zig).
    .{ "uuidv4", Ret{ .named = "uuid" } },
    .{ "uuidv7", Ret{ .named = "uuid" } },
    .{ "uuid_extract_version", Ret{ .named = "smallint" } },
    .{ "uuid_extract_timestamp", Ret{ .named = "timestamp with time zone" } },
    .{ "xq_pg_uuid", Ret{ .named = "uuid" } },
    .{ "xq_pg_uuid_text", Ret{ .named = "text" } },
    .{ "nextval", Ret{ .named = "bigint" } },
    .{ "currval", Ret{ .named = "bigint" } },
    .{ "setval", Ret{ .named = "bigint" } },
    // The engine functions casts are lowered to: the cast gives its type
    // where it is lowered; these for the text of views, which keeps the
    // call.
    .{ "xq_pg_int2", Ret{ .named = "smallint" } },
    .{ "xq_pg_int4", Ret{ .named = "integer" } },
    .{ "xq_pg_int8", Ret{ .named = "bigint" } },
    .{ integer.castName(.int2), Ret{ .named = integer.Width.int2.name() } },
    .{ integer.castName(.int4), Ret{ .named = integer.Width.int4.name() } },
    .{ integer.castName(.int8), Ret{ .named = integer.Width.int8.name() } },
    // `a # b` (integer.zig): as `a | b`.
    .{ "xq_pg_int_xor", Ret{ .rule = intXor } },
    .{ "xq_pg_bool", Ret{ .named = "boolean" } },
    .{ "xq_pg_interval", Ret{ .named = "interval" } },
    // interval BLOB (datetime.zig).
    .{ "xq_pg_iv", Ret{ .named = "interval" } },
    .{ "xq_pg_iv_text", Ret{ .named = "text" } },
    .{ "xq_pg_iv_out", Ret{ .named = "text" } },
    .{ "xq_pg_iv_key", Ret{ .named = "bytea" } },
    .{ "xq_pg_iv_high", Ret{ .named = "bytea" } },
    .{ "xq_pg_iv_valid", Ret{ .named = "boolean" } },
    .{ "xq_pg_iv_sum", Ret{ .named = "interval" } },
    .{ "xq_pg_iv_avg", Ret{ .named = "interval" } },
    // ivinput.zig.
    .{ "xq_pg_iv_in", Ret{ .named = "interval" } },
    .{ "xq_pg_iv_extract", Ret{ .named = "numeric" } },
    .{ "xq_pg_iv_date_part", Ret{ .named = "double precision" } },
    .{ "make_interval", Ret{ .named = "interval" } },
    .{ "justify_hours", Ret{ .named = "interval" } },
    .{ "justify_days", Ret{ .named = "interval" } },
    .{ "justify_interval", Ret{ .named = "interval" } },
    .{ "isfinite", Ret{ .named = "boolean" } },
    .{ "xq_pg_date", Ret{ .named = "date" } },
    .{ "xq_pg_time", Ret{ .named = "time without time zone" } },
    .{ "xq_pg_timestamp", Ret{ .named = "timestamp without time zone" } },
    .{ "xq_pg_timestamptz", Ret{ .named = "timestamp with time zone" } },
    // JSON (jfuncs.zig).
    .{ "to_jsonb", Ret{ .named = "jsonb" } },
    .{ "jsonb_build_object", Ret{ .named = "jsonb" } },
    .{ "jsonb_build_array", Ret{ .named = "jsonb" } },
    .{ "jsonb_object", Ret{ .named = "jsonb" } },
    .{ "jsonb_agg", Ret{ .named = "jsonb" } },
    .{ "jsonb_object_agg", Ret{ .named = "jsonb" } },
    .{ "jsonb_set", Ret{ .named = "jsonb" } },
    .{ "jsonb_set_lax", Ret{ .named = "jsonb" } },
    .{ "jsonb_insert", Ret{ .named = "jsonb" } },
    .{ "jsonb_strip_nulls", Ret{ .named = "jsonb" } },
    .{ "jsonb_extract_path", Ret{ .named = "jsonb" } },
    .{ "jsonb_path_query_array", Ret{ .named = "jsonb" } },
    .{ "jsonb_path_query_first", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_get", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_path", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_concat", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_delete", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_delete_keys", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_delete_path", Ret{ .named = "jsonb" } },
    // jsonb stored as JSONB (jfuncs.zig).
    .{ "xq_pg_jsonb_bin", Ret{ .named = "jsonb" } },
    .{ "xq_pg_jsonb_text", Ret{ .named = "text" } },
    .{ "xq_pg_jsonb_key", Ret{ .named = "bytea" } },
    .{ "to_json", Ret{ .named = "json" } },
    .{ "json_build_object", Ret{ .named = "json" } },
    .{ "json_build_array", Ret{ .named = "json" } },
    .{ "json_object", Ret{ .named = "json" } },
    .{ "json_agg", Ret{ .named = "json" } },
    .{ "json_object_agg", Ret{ .named = "json" } },
    .{ "json_strip_nulls", Ret{ .named = "json" } },
    .{ "json_extract_path", Ret{ .named = "json" } },
    .{ "row_to_json", Ret{ .named = "json" } },
    .{ "array_to_json", Ret{ .named = "json" } },
    .{ "xq_pg_json", Ret{ .named = "json" } },
    .{ "xq_pg_json_get", Ret{ .named = "json" } },
    .{ "xq_pg_json_path", Ret{ .named = "json" } },
    .{ "xq_pg_row_json", Ret{ .named = "json" } },
    .{ "xq_pg_array_to_json", Ret{ .named = "json" } },
    .{ "xq_pg_json_agg_rows", Ret{ .named = "json" } },
    .{ "xq_pg_json_bool", Ret{ .named = "json" } },
    .{ "xq_pg_float_json", Ret{ .named = "json" } },
    .{ "xq_pg_numeric_json", Ret{ .named = "json" } },
    .{ "xq_pg_json_ctor_object", Ret{ .rule = ctorType(0) } },
    .{ "xq_pg_json_ctor_array", Ret{ .rule = ctorType(0) } },
    .{ "xq_pg_json_arrayagg", Ret{ .rule = ctorType(1) } },
    .{ "xq_pg_json_objectagg", Ret{ .rule = ctorType(2) } },
    .{ "xq_pg_jsonb_contains", Ret{ .named = "boolean" } },
    .{ "xq_pg_jsonb_exists", Ret{ .named = "boolean" } },
    .{ "xq_pg_jsonb_exists_any", Ret{ .named = "boolean" } },
    .{ "xq_pg_jsonb_exists_all", Ret{ .named = "boolean" } },
    .{ "xq_pg_jsonb_path_exists_op", Ret{ .named = "boolean" } },
    .{ "xq_pg_jsonb_path_match_op", Ret{ .named = "boolean" } },
    .{ "jsonb_path_exists", Ret{ .named = "boolean" } },
    .{ "jsonb_path_match", Ret{ .named = "boolean" } },
    .{ "xq_pg_is_json", Ret{ .named = "boolean" } },
    .{ "xq_like", Ret{ .named = "boolean" } },
    .{ "xq_ilike", Ret{ .named = "boolean" } },
    .{ "xq_pg_regex", Ret{ .named = "boolean" } },
    // Regular expressions (regexp.zig).
    .{ "xq_pg_re", Ret{ .named = "boolean" } },
    .{ "xq_pg_similar_escape", Ret{ .named = "text" } },
    .{ "similar_to_escape", Ret{ .named = "text" } },
    .{ "textregexsubstr", Ret{ .named = "text" } },
    .{ "regexp_match", Ret{ .named = "text[]" } },
    .{ "regexp_split_to_array", Ret{ .named = "text[]" } },
    .{ "regexp_replace", Ret{ .named = "text" } },
    .{ "regexp_substr", Ret{ .named = "text" } },
    .{ "regexp_count", Ret{ .named = "integer" } },
    .{ "regexp_instr", Ret{ .named = "integer" } },
    .{ "regexp_like", Ret{ .named = "boolean" } },
    // Arrays (array.zig).
    .{ "xq_pg_text_array", Ret{ .named = "text[]" } },
    .{ "xq_pg_array", Ret{ .rule = arrayOfArgs } },
    .{ "xq_pg_array_nested", Ret{ .common = 0 } },
    .{ "xq_pg_elem", Ret{ .arg = 0 } },
    .{ "xq_pg_any", Ret{ .named = "boolean" } },
    .{ "xq_pg_array_valid", Ret{ .named = "boolean" } },
    .{ "xq_pg_array_contains", Ret{ .named = "boolean" } },
    .{ "xq_pg_array_overlap", Ret{ .named = "boolean" } },
    .{ "xq_pg_subscript", Ret{ .rule = elementOf(0) } },
    .{ "xq_pg_subscript_k", Ret{ .rule = elementOf(0) } },
    .{ "xq_pg_slice", Ret{ .arg = 0 } },
    .{ "xq_pg_array_set", Ret{ .arg = 0 } },
    .{ "xq_pg_array_cat2", Ret{ .rule = firstKnown } },
    .{ "xq_pg_array_append", Ret{ .rule = appendType(0, 1) } },
    .{ "xq_pg_array_prepend", Ret{ .rule = appendType(1, 0) } },
    .{ "xq_pg_rows_unnest", Ret{ .named = "text" } },
    .{ "array_cat", Ret{ .rule = firstKnown } },
    .{ "xq_pg_array_agg", Ret{ .rule = arrayOf(0) } },
    .{ "array_agg", Ret{ .rule = arrayOf(0) } },
    .{ "xq_pg_array_agg_arrays", Ret{ .arg = 0 } },
    .{ "array_append", Ret{ .rule = appendType(0, 1) } },
    .{ "array_prepend", Ret{ .rule = appendType(1, 0) } },
    .{ "array_remove", Ret{ .arg = 0 } },
    .{ "array_replace", Ret{ .arg = 0 } },
    .{ "array_length", Ret{ .named = "integer" } },
    .{ "array_lower", Ret{ .named = "integer" } },
    .{ "array_upper", Ret{ .named = "integer" } },
    .{ "array_ndims", Ret{ .named = "integer" } },
    .{ "cardinality", Ret{ .named = "integer" } },
    .{ "array_position", Ret{ .named = "integer" } },
    .{ "array_positions", Ret{ .named = "integer[]" } },
    .{ "array_dims", Ret{ .named = "text" } },
    .{ "array_to_string", Ret{ .named = "text" } },
    .{ "string_to_array", Ret{ .named = "text[]" } },
    .{ "current_schemas", Ret{ .named = "name[]" } },
    // formatting.zig, builtins.zig, inputinfo.zig, dtfuncs.zig.
    .{ "to_char", Ret{ .named = "text" } },
    .{ "xq_pg_to_char", Ret{ .named = "text" } },
    .{ "to_number", Ret{ .named = "numeric" } },
    .{ "to_date", Ret{ .named = "date" } },
    .{ "to_timestamp", Ret{ .named = "timestamp with time zone" } },
    .{ "gcd", Ret{ .common = 0 } },
    .{ "lcm", Ret{ .common = 0 } },
    .{ "xq_pg_gcd", Ret{ .rule = gcdType } },
    .{ "xq_pg_lcm", Ret{ .rule = gcdType } },
    .{ "float8", Ret{ .named = "double precision" } },
    .{ "float4", Ret{ .named = "real" } },
    .{ "booleq", Ret{ .named = "boolean" } },
    .{ "boolne", Ret{ .named = "boolean" } },
    .{ "interval_hash", Ret{ .named = "integer" } },
    .{ "pg_input_is_valid", Ret{ .named = "boolean" } },
    .{ "xq_pg_rows_input_error", Ret{ .named = "text" } },
    .{ "date_trunc", Ret{ .rule = truncType } },
    .{ "date_bin", Ret{ .named = "timestamp without time zone" } },
    .{ "timezone", Ret{ .rule = zoneType } },
    .{ "xq_pg_timezone", Ret{ .rule = zoneType } },
    .{ "xq_pg_at_time_zone", Ret{ .rule = zoneType } },
} ++ numeric_functions);

/// xq_pg_gcd(a, b, bits): of `bits` 0 a numeric, else the common type.
fn gcdType(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 3) return unknown;
    if ((typing.intArg(args[2]) orelse 0) == 0) return c.make(.{ .logical = .numeric });
    return typing.commonOf(c, args[0..2]);
}

/// date_trunc(unit, x): of a date a timestamptz, else x's type.
fn truncType(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 2) return unknown;
    return switch (args[1].logical()) {
        .date => c.named("timestamp with time zone"),
        .timestamp, .timestamp_tz, .interval => args[1].id,
        else => unknown,
    };
}

/// timezone(zone, x): of a timestamp a timestamptz, of a timestamptz (a
/// date) a timestamp, of a time a timetz.
fn zoneType(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len < 2) return unknown;
    return switch (args[1].logical()) {
        .timestamp => c.named("timestamp with time zone"),
        .timestamp_tz, .date => c.named("timestamp without time zone"),
        .time, .time_tz => c.named("time with time zone"),
        else => unknown,
    };
}

/// The spelling of the array of each element type (array.Elem).
const array_names = blk: {
    var names: [std.enums.values(array.Elem).len][]const u8 = undefined;
    for (std.enums.values(array.Elem), 0..) |e, i| names[i] = e.typeName() ++ "[]";
    break :blk names;
};

/// The type of the elements of the array that argument `i` is.
fn elementOf(comptime i: usize) *const fn (c: *Ctx, args: []const Operand) Oom!TypeId {
    return struct {
        fn f(c: *Ctx, args: []const Operand) Oom!TypeId {
            if (i >= args.len) return unknown;
            const t = args[i].type;
            if (t.logical != .array or t.element == .unknown) return unknown;
            return c.make(t.elementType());
        }
    }.f;
}

/// The array of the type of argument `i`.
fn arrayOf(comptime i: usize) *const fn (c: *Ctx, args: []const Operand) Oom!TypeId {
    return struct {
        fn f(c: *Ctx, args: []const Operand) Oom!TypeId {
            if (i >= args.len) return unknown;
            return arrayOfType(c, args[i]);
        }
    }.f;
}

fn arrayOfType(c: *Ctx, o: Operand) Oom!TypeId {
    if (o.e.op == TK.STRING) return c.named("text[]");
    const t = o.type;
    if (t.logical == .unknown) return unknown;
    // An array of arrays is an array of a dimension more.
    if (t.logical == .array) return o.id;
    return c.make(t.arrayOf());
}

/// array_append(a, x): the array's type, else the array of x's.
fn appendType(comptime arr: usize, comptime elem: usize) *const fn (c: *Ctx, args: []const Operand) Oom!TypeId {
    return struct {
        fn f(c: *Ctx, args: []const Operand) Oom!TypeId {
            if (args.len != 2) return unknown;
            if (args[arr].type.logical == .array) return args[arr].id;
            return arrayOfType(c, args[elem]);
        }
    }.f;
}

/// The type of the first argument of a known type.
fn firstKnown(c: *Ctx, args: []const Operand) Oom!TypeId {
    _ = c;
    for (args) |a| if (a.id != unknown) return a.id;
    return unknown;
}

/// The type of the JSON constructors of SQL/JSON (JSON_OBJECT() ...):
/// jsonb if bit 1 of their flags argument (`i`) is set (RETURNING
/// jsonb), else json.
fn ctorType(comptime i: usize) *const fn (c: *Ctx, args: []const Operand) Oom!TypeId {
    return struct {
        fn f(c: *Ctx, args: []const Operand) Oom!TypeId {
            _ = c;
            if (i >= args.len) return unknown;
            const v = typing.intArg(args[i]) orelse 0;
            return typing.plain(if (v & 1 != 0) .jsonb else .json);
        }
    }.f;
}

/// ARRAY[...] (xq_pg_array()): the array of the common type of the
/// values; a text[] of strings and NULLs.
fn arrayOfArgs(c: *Ctx, args: []const Operand) Oom!TypeId {
    const id = try typing.commonOf(c, args);
    if (id == unknown) {
        for (args) |a| if (a.e.op != TK.STRING and a.e.op != TK.NULL) return unknown;
        return c.named("text[]");
    }
    const t = typing.typeOf(c.p.db, id);
    if (t.logical == .array) return id;
    return c.make(t.arrayOf());
}

/// sum(): of a smallint or an integer a bigint, of a bigint a numeric, of
/// a numeric a numeric of its scale, of a float that float.
fn sum(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    return switch (args[0].logical()) {
        .int1, .int2, .int4 => typing.plain(.int8),
        .int8 => c.make(.{ .logical = .numeric, .scale = 0 }),
        .numeric => c.make(.{ .logical = .numeric, .scale = args[0].type.scale }),
        .float4, .float8, .interval => args[0].id,
        else => unknown,
    };
}

/// avg(): of an exact number a numeric (its scale PostgreSQL's per value),
/// of a float a double precision.
fn avg(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const l = args[0].logical();
    if (isExact(l)) return c.make(.{ .logical = .numeric });
    if (typing.isFloat(l)) return typing.plain(.float8);
    if (l == .interval) return typing.plain(.interval);
    return unknown;
}

fn mod(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 2) return unknown;
    return operator(c, TK.REM, args[0], args[1]);
}

/// xq_pg_int_xor(a, b): the type of `a | b`.
fn intXor(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 2) return unknown;
    return operator(c, TK.BITOR, args[0], args[1]);
}

/// round(x) and trunc(x): of a numeric a numeric of scale 0, else a
/// double precision (round(1) is round(1::float8)); round(x, n) a numeric
/// of scale n.
fn round(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 0) return unknown;
    const l = args[0].logical();
    if (args.len == 2) {
        if (!typing.isNumber(l) and args[0].e.op != TK.STRING) return unknown;
        const n = typing.intArg(args[1]) orelse return c.make(.{ .logical = .numeric });
        return c.make(.{ .logical = .numeric, .scale = typing.clampU8(@intCast(std.math.clamp(n, 0, 255))) });
    }
    if (l == .numeric) return c.make(.{ .logical = .numeric, .scale = 0 });
    if (typing.isNumber(l)) return typing.plain(.float8);
    return unknown;
}

/// ceil(), floor(), sign(): of a numeric a numeric of scale 0, of another
/// number a double precision.
fn ceil(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const l = args[0].logical();
    if (l == .numeric) return c.make(.{ .logical = .numeric, .scale = 0 });
    if (typing.isNumber(l)) return typing.plain(.float8);
    return unknown;
}

/// sqrt(), exp(), ln(), log(), log10(), power(): a numeric (of no known
/// scale) if an argument is one and none is a double precision or a real
/// (PostgreSQL's choice of the numeric function), else a double
/// precision.
fn transcendental(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 0) return unknown;
    var ch: repr.numeric.Candidate = .{};
    for (args) |a| {
        const l = a.logical();
        // Not a number before a float: no such function.
        if (!ch.float and !typing.isNumber(l) and l != .unknown) return unknown;
        ch.arg(l);
    }
    return if (ch.isNumeric()) c.make(.{ .logical = .numeric }) else typing.plain(.float8);
}

/// log(x) as transcendental(); log(b, x) is numeric's only.
fn logType(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 2) return c.make(.{ .logical = .numeric });
    return transcendental(c, args);
}
