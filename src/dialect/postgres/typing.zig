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
const datetime = @import("datetime.zig");

const TK = int.TK;
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
    .unknown_strings = true,
    .overload = overload.overload,
    .order_collation = overload.orderCollation,
};

/// A string stored into a boolean, numeric, date, time, timestamp or
/// interval column is read as the type's input (funcs.zig's store
/// functions, datetime.zig's casts).
fn store(t: Type) ?*const int.FuncDef {
    return switch (t.logical) {
        .boolean => &funcs.store_boolean,
        .numeric => &funcs.store_numeric,
        // Read and written as PostgreSQL does: '2 hours' is '02:00:00',
        // a timestamptz is kept in UTC, '2024-02-30' is an error.
        .date => datetime.cast_date,
        .time => datetime.cast_time,
        .timestamp => datetime.cast_timestamp,
        .timestamp_tz => datetime.cast_timestamptz,
        .interval => datetime.cast_interval,
        else => null,
    };
}

/// PostgreSQL's choices by the types of operands (jsonb's operators, the
/// arguments of the functions that make JSON): overload.zig.
const overload = @import("overload.zig");

fn spell(t: Type, buf: *[64]u8) []const u8 {
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
    .{ "log", Ret{ .rule = transcendental } },
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
    .{ "nextval", Ret{ .named = "bigint" } },
    .{ "currval", Ret{ .named = "bigint" } },
    .{ "setval", Ret{ .named = "bigint" } },
    // The engine functions casts are lowered to: the cast gives its type
    // where it is lowered; these for the text of views, which keeps the
    // call.
    .{ "xq_pg_int2", Ret{ .named = "smallint" } },
    .{ "xq_pg_int4", Ret{ .named = "integer" } },
    .{ "xq_pg_int8", Ret{ .named = "bigint" } },
    .{ "xq_pg_bool", Ret{ .named = "boolean" } },
    .{ "xq_pg_interval", Ret{ .named = "interval" } },
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
    // Arrays are no column type: their text literal, of the type spelled
    // with [] (an unknown type of that name).
    .{ "xq_pg_text_array", Ret{ .named = "text[]" } },
    .{ "xq_pg_array", Ret{ .rule = arrayLiteral } },
});

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

/// ARRAY[...] (xq_pg_array()): an integer[] of integer literals, a
/// numeric[] of number literals, else a text[].
fn arrayLiteral(c: *Ctx, args: []const Operand) Oom!TypeId {
    var all_int = true;
    for (args) |a| {
        var e = a.e;
        while ((e.op == TK.UMINUS or e.op == TK.UPLUS) and e.left != null) e = e.left.?;
        switch (e.op) {
            TK.INTEGER => {},
            TK.FLOAT => all_int = false,
            else => return c.named("text[]"),
        }
    }
    if (args.len == 0) return c.named("text[]");
    return c.named(if (all_int) "integer[]" else "numeric[]");
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

/// sqrt(), exp(), ln(), log(), power(): a numeric (of no known scale) if
/// an argument is one, else a double precision.
fn transcendental(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 0) return unknown;
    for (args) |a| {
        if (a.logical() == .numeric) return c.make(.{ .logical = .numeric });
        if (!typing.isNumber(a.logical())) return unknown;
    }
    return typing.plain(.float8);
}
