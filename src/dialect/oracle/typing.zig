//! Oracle's types of expressions (dialect.Hooks.typing, the rules of
//! sql/typing.zig): numbers are NUMBER.
//!  - a number literal is a NUMBER, a string literal a CHAR(n) of its
//!    length ('' is NULL, of no type);
//!  - arithmetic of numbers (and of strings, converted) is a NUMBER, a
//!    BINARY_DOUBLE if an operand is one (BINARY_FLOAT with only
//!    BINARY_FLOATs); a DATE plus or minus a number a DATE, the
//!    difference of two DATEs a NUMBER; || a VARCHAR2 of the lengths'
//!    sum (at most 32767, else of no known length);
//!  - functions: COUNT(), SUM(), AVG() and the numeric functions a
//!    NUMBER (of a BINARY_DOUBLE that), LENGTH() a NUMBER, UPPER() and
//!    the other string functions a VARCHAR2, TO_DATE() and ADD_MONTHS()
//!    a DATE, ROUND() and TRUNC() of a DATE a DATE ...

const std = @import("std");
const typing = @import("../../sql/typing.zig");
const types = @import("../../sql/types.zig");
const int = @import("../../sql/sqlite_int.zig");

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
    .store_wrappers = &.{"xq_ora_coerce"},
};

/// The longest VARCHAR2 (MAX_STRING_SIZE = EXTENDED).
const max_varchar2 = 32767;

fn spell(t: Type, buf: *[64]u8) []const u8 {
    return switch (t.logical) {
        .int1, .int2, .int4, .int8 => "NUMBER",
        .numeric => if (t.precision) |p| std.fmt.bufPrint(buf, "NUMBER({d},{d})", .{ p, t.scale orelse 0 }) catch "NUMBER" else "NUMBER",
        .float4 => "BINARY_FLOAT",
        .float8 => "BINARY_DOUBLE",
        .varchar => if (t.length) |n| std.fmt.bufPrint(buf, "VARCHAR2({d})", .{n}) catch "VARCHAR2" else "VARCHAR2",
        .char => if (t.length) |n| std.fmt.bufPrint(buf, "CHAR({d})", .{n}) catch "CHAR" else "CHAR",
        .text => "CLOB",
        .bytes => if (t.length) |n| std.fmt.bufPrint(buf, "RAW({d})", .{n}) catch "BLOB" else "BLOB",
        .boolean => "BOOLEAN",
        .date => "DATE",
        .timestamp => "TIMESTAMP",
        .timestamp_tz => "TIMESTAMP WITH TIME ZONE",
        .interval => "INTERVAL DAY TO SECOND",
        else => typing.plainName(t.logical),
    };
}

fn number(c: *Ctx) Oom!TypeId {
    return c.named("NUMBER");
}

fn literal(c: *Ctx, e: *const int.Expr) Oom!TypeId {
    return switch (e.op) {
        TK.INTEGER, TK.FLOAT => number(c),
        TK.STRING => if (typing.stringLength(e)) |n| (if (n == 0) unknown else c.make(.{ .logical = .char, .length = n })) else unknown,
        TK.BLOB => c.make(.{ .logical = .bytes }),
        else => unknown,
    };
}

/// Whether `l` is a number, or converts to one (a string).
fn numeric(l: Logical) bool {
    return typing.isNumber(l) or typing.isString(l);
}

/// Oracle's DATE (with a time of day) and TIMESTAMP.
fn isDate(l: Logical) bool {
    return l == .timestamp or l == .date;
}

fn operator(c: *Ctx, op: u8, a_arg: Operand, b_arg: ?Operand) Oom!TypeId {
    const a = c.throughCast(a_arg);
    const b = b_arg orelse {
        if (typing.isFloat(a.logical())) return a.id;
        return if (numeric(a.logical())) number(c) else unknown;
    };
    if (op == TK.CONCAT) return concat(c, &.{ a, b });
    const la = a.logical();
    const lb = b.logical();
    if (op == TK.PLUS or op == TK.MINUS) {
        if (isDate(la) and numeric(lb)) return a.id;
        if (op == TK.PLUS and numeric(la) and isDate(lb)) return b.id;
        if (op == TK.MINUS and isDate(la) and isDate(lb)) return number(c);
    }
    if (!numeric(la) or !numeric(lb)) return unknown;
    if (typing.isFloat(la) or typing.isFloat(lb)) {
        return c.make(.{ .logical = if (la == .float8 or lb == .float8) .float8 else .float4 });
    }
    return number(c);
}

/// || (and concat(), which the frontend makes of a || that may meet a
/// NULL): a VARCHAR2 of the sum of the lengths.
fn concat(c: *Ctx, args: []const Operand) Oom!TypeId {
    var n: u32 = 0;
    for (args) |a| n += lengthOf(a) orelse return c.named("VARCHAR2");
    if (n == 0 or n > max_varchar2) return c.named("VARCHAR2");
    return c.make(.{ .logical = .varchar, .length = n });
}

/// The length of a string operand; 0 for NULL (or ''), which
/// concatenates as the empty string.
fn lengthOf(o: Operand) ?u32 {
    if (o.e.op == TK.NULL) return 0;
    if (o.e.op == TK.STRING) return typing.stringLength(o.e);
    return switch (o.logical()) {
        .varchar, .char => o.type.length,
        else => null,
    };
}

fn function(name: []const u8) ?Ret {
    return functions.get(name);
}

const functions = std.StaticStringMap(Ret).initComptime(.{
    // Aggregates and window functions.
    .{ "count", Ret{ .named = "NUMBER" } },
    .{ "sum", Ret{ .rule = numberOrFloat } },
    .{ "avg", Ret{ .rule = numberOrFloat } },
    .{ "xq_stddev_samp", Ret{ .rule = numberOrFloat } },
    .{ "xq_stddev_pop", Ret{ .rule = numberOrFloat } },
    .{ "xq_var_samp", Ret{ .rule = numberOrFloat } },
    .{ "xq_var_pop", Ret{ .rule = numberOrFloat } },
    .{ "group_concat", Ret{ .named = "VARCHAR2" } },
    .{ "row_number", Ret{ .named = "NUMBER" } },
    .{ "rank", Ret{ .named = "NUMBER" } },
    .{ "dense_rank", Ret{ .named = "NUMBER" } },
    .{ "ntile", Ret{ .named = "NUMBER" } },
    .{ "lag", Ret{ .arg = 0 } },
    .{ "lead", Ret{ .arg = 0 } },
    .{ "first_value", Ret{ .arg = 0 } },
    .{ "last_value", Ret{ .arg = 0 } },
    // Strings.
    .{ "length", Ret{ .named = "NUMBER" } },
    .{ "lengthb", Ret{ .named = "NUMBER" } },
    .{ "lengthc", Ret{ .named = "NUMBER" } },
    .{ "octet_length", Ret{ .named = "NUMBER" } },
    .{ "instr", Ret{ .named = "NUMBER" } },
    .{ "concat", Ret{ .rule = concat } },
    .{ "upper", Ret{ .named = "VARCHAR2" } },
    .{ "lower", Ret{ .named = "VARCHAR2" } },
    .{ "initcap", Ret{ .named = "VARCHAR2" } },
    .{ "substr", Ret{ .named = "VARCHAR2" } },
    .{ "lpad", Ret{ .named = "VARCHAR2" } },
    .{ "rpad", Ret{ .named = "VARCHAR2" } },
    .{ "ltrim", Ret{ .named = "VARCHAR2" } },
    .{ "rtrim", Ret{ .named = "VARCHAR2" } },
    .{ "trim", Ret{ .named = "VARCHAR2" } },
    .{ "replace", Ret{ .named = "VARCHAR2" } },
    .{ "translate", Ret{ .named = "VARCHAR2" } },
    .{ "to_char", Ret{ .named = "VARCHAR2" } },
    .{ "sys_context", Ret{ .named = "VARCHAR2" } },
    // Numbers.
    .{ "abs", Ret{ .rule = numberOrFloat } },
    .{ "ceil", Ret{ .rule = numberOrFloat } },
    .{ "floor", Ret{ .rule = numberOrFloat } },
    .{ "sign", Ret{ .rule = numberOrFloat } },
    .{ "mod", Ret{ .rule = numberOrFloat } },
    .{ "power", Ret{ .rule = numberOrFloat } },
    .{ "sqrt", Ret{ .rule = numberOrFloat } },
    .{ "exp", Ret{ .rule = numberOrFloat } },
    .{ "ln", Ret{ .rule = numberOrFloat } },
    .{ "log", Ret{ .rule = numberOrFloat } },
    .{ "round", Ret{ .rule = roundRule } },
    .{ "trunc", Ret{ .rule = roundRule } },
    .{ "to_number", Ret{ .named = "NUMBER" } },
    .{ "greatest", Ret{ .common = 0 } },
    .{ "least", Ret{ .common = 0 } },
    // Dates (SYSDATE: the frontend's Func.result_type).
    .{ "to_date", Ret{ .named = "DATE" } },
    .{ "to_timestamp", Ret{ .named = "TIMESTAMP" } },
    .{ "add_months", Ret{ .named = "DATE" } },
    .{ "last_day", Ret{ .named = "DATE" } },
    .{ "next_day", Ret{ .named = "DATE" } },
    .{ "months_between", Ret{ .named = "NUMBER" } },
    .{ "extract", Ret{ .named = "NUMBER" } },
    // A value stored into a column: of the column's type.
    .{ "xq_ora_coerce", Ret{ .rule = coerce } },
});

/// A NUMBER, or the float type of a float argument.
fn numberOrFloat(c: *Ctx, args: []const Operand) Oom!TypeId {
    for (args) |a| if (typing.isFloat(a.logical())) return a.id;
    return number(c);
}

/// ROUND() and TRUNC(): of a DATE a DATE, else as numberOrFloat().
fn roundRule(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len > 0 and isDate(args[0].logical())) return args[0].id;
    return numberOrFloat(c, args);
}

/// xq_ora_coerce(v, 'TYPE', ...): of the type named.
fn coerce(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len < 2) return unknown;
    return c.named(typing.stringArg(args[1]) orelse return unknown);
}
