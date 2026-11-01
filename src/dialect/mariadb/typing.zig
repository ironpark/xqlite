//! MariaDB's types of expressions (dialect.Hooks.typing, the rules of
//! sql/typing.zig):
//!  - an integer literal is an int if it fits 32 bits, a bigint if 64,
//!    else a decimal(p,0); a literal with a point a decimal(p,s) of its
//!    digits (1.50: decimal(3,2)), with an exponent a double; a string
//!    literal a varchar(n) of its length;
//!  - integer + - * % and the bit operations compute in BIGINT; `/` gives
//!    a DECIMAL of scale s1 + 4 (div_precision_increment: 7 / 2 is
//!    3.5000), DIV a BIGINT; decimals give scale max(s1, s2) for + - %
//!    and s1 + s2 for * (at most 38, precision at most 65); a float or a
//!    double (or a string, converted to one) makes a double;
//!  - functions: COUNT() a BIGINT, SUM() of integers a DECIMAL(p + 22, 0)
//!    and of a DECIMAL(p,s) a DECIMAL(p + 22, s), AVG() of integers a
//!    DECIMAL(p + 4, 4) and of a DECIMAL(p,s) a DECIMAL(p + 4, s + 4)
//!    (AVG(1, 2) is 1.5000), LENGTH() an INT, ROUND(x, 2) a DECIMAL of
//!    scale 2, NOW() a DATETIME ... A string function is of its string
//!    argument's type, else a VARCHAR of no known length.

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
    .store_wrappers = &.{"xq_coerce"},
};

/// div_precision_increment.
const div_increment = 4;

fn spell(t: Type, buf: *[64]u8) []const u8 {
    return switch (t.logical) {
        .int1 => "tinyint",
        .int2 => "smallint",
        .int4 => "int",
        .int8 => "bigint",
        .float4 => "float",
        .float8 => "double",
        .numeric => if (t.precision) |p| std.fmt.bufPrint(buf, "decimal({d},{d})", .{ p, t.scale orelse 0 }) catch "decimal" else "decimal",
        .varchar => if (t.length) |n| std.fmt.bufPrint(buf, "varchar({d})", .{n}) catch "varchar" else "varchar",
        .char => if (t.length) |n| std.fmt.bufPrint(buf, "char({d})", .{n}) catch "char" else "char",
        .text => "longtext",
        .bytes => if (t.length) |n| std.fmt.bufPrint(buf, "varbinary({d})", .{n}) catch "longblob" else "longblob",
        .timestamp => "datetime",
        .timestamp_tz => "timestamp",
        else => typing.plainName(t.logical),
    };
}

fn literal(c: *Ctx, e: *const int.Expr) Oom!TypeId {
    switch (e.op) {
        TK.INTEGER => {
            if (typing.intLiteral(e)) |v| return c.make(.{ .logical = if (std.math.cast(i32, v) != null) .int4 else .int8 });
            const d = typing.decimalLiteral(e) orelse return c.make(.{ .logical = .int8 });
            return decimal(c, d.precision(), 0);
        },
        TK.FLOAT => {
            const d = typing.decimalLiteral(e) orelse return c.make(.{ .logical = .float8 });
            if (d.exponent != null) return c.make(.{ .logical = .float8 });
            return decimal(c, @max(d.int_digits + d.frac_digits, 1), d.frac_digits);
        },
        TK.STRING => return c.make(.{ .logical = .varchar, .length = typing.stringLength(e) }),
        TK.BLOB => return c.make(.{ .logical = .bytes }),
        else => return unknown,
    }
}

fn decimal(c: *Ctx, p: u32, s: u32) Oom!TypeId {
    const ss = @min(s, 38);
    return c.make(.{ .logical = .numeric, .precision = typing.clampU8(@max(@min(p, 65), ss, 1)), .scale = typing.clampU8(ss) });
}

fn operator(c: *Ctx, op: u8, a_arg: Operand, b_arg: ?Operand) Oom!TypeId {
    const a = c.throughCast(a_arg);
    const b = b_arg orelse {
        if (op == TK.BITNOT) return if (typing.intWidth(a.logical()) != null) c.make(.{ .logical = .int8 }) else unknown;
        return if (typing.isNumber(a.logical())) a.id else unknown;
    };
    if (op == TK.CONCAT) return concat(c, a, b);
    const la = a.logical();
    const lb = b.logical();
    if (la == .unknown or lb == .unknown) return unknown;
    switch (op) {
        TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => return c.make(.{ .logical = .int8 }),
        else => {},
    }
    // Strings are converted to doubles.
    if (!isExact(la) or !isExact(lb)) {
        if ((typing.isNumber(la) or typing.isString(la)) and (typing.isNumber(lb) or typing.isString(lb))) return c.make(.{ .logical = .float8 });
        return unknown;
    }
    const x = typing.exact(a.type) orelse return c.make(.{ .logical = .numeric });
    const y = typing.exact(b.type) orelse return c.make(.{ .logical = .numeric });
    const ints = typing.intWidth(la) != null and typing.intWidth(lb) != null;
    const ix = x.p -| x.s;
    const iy = y.p -| y.s;
    if (op == TK.SLASH) return decimal(c, ix + y.s + x.s + div_increment, x.s + div_increment);
    if (ints) return c.make(.{ .logical = .int8 });
    return switch (op) {
        TK.PLUS, TK.MINUS => decimal(c, @max(ix, iy) + @max(x.s, y.s) + 1, @max(x.s, y.s)),
        TK.STAR => decimal(c, x.p + y.p, x.s + y.s),
        TK.REM => decimal(c, @max(ix, iy) + @max(x.s, y.s), @max(x.s, y.s)),
        else => unknown,
    };
}

fn isExact(l: Logical) bool {
    return l == .numeric or typing.intWidth(l) != null;
}

/// CONCAT(): a varchar of the sum of the lengths, else of no known one.
fn concat(c: *Ctx, a: Operand, b: Operand) Oom!TypeId {
    const la = lengthOf(a) orelse return c.make(.{ .logical = .varchar });
    const lb = lengthOf(b) orelse return c.make(.{ .logical = .varchar });
    return c.make(.{ .logical = .varchar, .length = la + lb });
}

fn lengthOf(o: Operand) ?u32 {
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
    .{ "count", Ret{ .named = "bigint" } },
    .{ "sum", Ret{ .rule = sum } },
    .{ "avg", Ret{ .rule = avg } },
    .{ "xq_stddev_samp", Ret{ .named = "double" } },
    .{ "xq_stddev_pop", Ret{ .named = "double" } },
    .{ "xq_var_samp", Ret{ .named = "double" } },
    .{ "xq_var_pop", Ret{ .named = "double" } },
    .{ "group_concat", Ret{ .named = "text" } },
    .{ "row_number", Ret{ .named = "bigint" } },
    .{ "rank", Ret{ .named = "bigint" } },
    .{ "dense_rank", Ret{ .named = "bigint" } },
    .{ "ntile", Ret{ .named = "bigint" } },
    .{ "lag", Ret{ .arg = 0 } },
    .{ "lead", Ret{ .arg = 0 } },
    .{ "first_value", Ret{ .arg = 0 } },
    .{ "last_value", Ret{ .arg = 0 } },
    .{ "nth_value", Ret{ .arg = 0 } },
    // Strings (LENGTH() is lowered to octet_length(), CHAR_LENGTH() to
    // length()).
    .{ "length", Ret{ .named = "int" } },
    .{ "octet_length", Ret{ .named = "int" } },
    .{ "xq_bit_length", Ret{ .named = "int" } },
    .{ "ascii", Ret{ .named = "int" } },
    .{ "locate", Ret{ .named = "int" } },
    .{ "instr", Ret{ .named = "int" } },
    .{ "find_in_set", Ret{ .named = "int" } },
    .{ "field", Ret{ .named = "int" } },
    .{ "upper", Ret{ .rule = stringArg } },
    .{ "lower", Ret{ .rule = stringArg } },
    .{ "trim", Ret{ .rule = stringArg } },
    .{ "ltrim", Ret{ .rule = stringArg } },
    .{ "rtrim", Ret{ .rule = stringArg } },
    .{ "reverse", Ret{ .rule = stringArg } },
    .{ "substr", Ret{ .rule = stringArg } },
    .{ "left", Ret{ .rule = stringArg } },
    .{ "right", Ret{ .rule = stringArg } },
    .{ "replace", Ret{ .named = "varchar" } },
    .{ "lpad", Ret{ .named = "varchar" } },
    .{ "rpad", Ret{ .named = "varchar" } },
    .{ "repeat", Ret{ .named = "varchar" } },
    .{ "insert", Ret{ .named = "varchar" } },
    .{ "concat", Ret{ .named = "varchar" } },
    .{ "elt", Ret{ .named = "varchar" } },
    .{ "hex", Ret{ .named = "varchar" } },
    .{ "space", Ret{ .named = "varchar" } },
    .{ "format", Ret{ .named = "varchar" } },
    .{ "version", Ret{ .named = "varchar" } },
    // Numbers.
    .{ "abs", Ret{ .arg = 0 } },
    .{ "sign", Ret{ .named = "int" } },
    .{ "mod", Ret{ .rule = mod } },
    .{ "round", Ret{ .rule = round } },
    .{ "truncate", Ret{ .rule = round } },
    .{ "ceil", Ret{ .rule = ceil } },
    .{ "ceiling", Ret{ .rule = ceil } },
    .{ "floor", Ret{ .rule = ceil } },
    .{ "xq_div", Ret{ .named = "bigint" } },
    .{ "pow", Ret{ .named = "double" } },
    .{ "power", Ret{ .named = "double" } },
    .{ "sqrt", Ret{ .named = "double" } },
    .{ "exp", Ret{ .named = "double" } },
    .{ "ln", Ret{ .named = "double" } },
    .{ "log", Ret{ .named = "double" } },
    .{ "log2", Ret{ .named = "double" } },
    .{ "log10", Ret{ .named = "double" } },
    .{ "sin", Ret{ .named = "double" } },
    .{ "cos", Ret{ .named = "double" } },
    .{ "tan", Ret{ .named = "double" } },
    .{ "asin", Ret{ .named = "double" } },
    .{ "acos", Ret{ .named = "double" } },
    .{ "atan", Ret{ .named = "double" } },
    .{ "degrees", Ret{ .named = "double" } },
    .{ "radians", Ret{ .named = "double" } },
    .{ "xq_rand", Ret{ .named = "double" } },
    .{ "greatest", Ret{ .common = 0 } },
    .{ "least", Ret{ .common = 0 } },
    // Dates: NOW() is datetime('now'), CURDATE() date('now') ...
    .{ "datetime", Ret{ .named = "datetime" } },
    .{ "date", Ret{ .named = "date" } },
    .{ "time", Ret{ .named = "time" } },
    .{ "unixepoch", Ret{ .named = "bigint" } },
    .{ "last_day", Ret{ .named = "date" } },
    .{ "str_to_date", Ret{ .named = "datetime" } },
    .{ "date_format", Ret{ .named = "varchar" } },
    .{ "datediff", Ret{ .named = "int" } },
    .{ "to_days", Ret{ .named = "bigint" } },
    .{ "year", Ret{ .named = "int" } },
    .{ "month", Ret{ .named = "int" } },
    .{ "day", Ret{ .named = "int" } },
    .{ "dayofmonth", Ret{ .named = "int" } },
    .{ "dayofweek", Ret{ .named = "int" } },
    .{ "dayofyear", Ret{ .named = "int" } },
    .{ "weekday", Ret{ .named = "int" } },
    .{ "quarter", Ret{ .named = "int" } },
    .{ "hour", Ret{ .named = "int" } },
    .{ "minute", Ret{ .named = "int" } },
    .{ "second", Ret{ .named = "int" } },
    .{ "microsecond", Ret{ .named = "int" } },
    .{ "dayname", Ret{ .named = "varchar" } },
    .{ "monthname", Ret{ .named = "varchar" } },
    .{ "xq_timestampdiff", Ret{ .named = "bigint" } },
    .{ "xq_extract", Ret{ .named = "int" } },
    // The session.
    .{ "last_insert_rowid", Ret{ .named = "bigint" } },
    .{ "changes", Ret{ .named = "bigint" } },
    .{ "nextval", Ret{ .named = "bigint" } },
    .{ "lastval", Ret{ .named = "bigint" } },
    .{ "setval", Ret{ .named = "bigint" } },
    .{ "xq_uuid", Ret{ .named = "varchar(36)" } },
    // A value stored into a column: of the column's type.
    .{ "xq_coerce", Ret{ .rule = coerce } },
});

/// The DECIMAL(p,s) of an exact number (an integer's p digits, scale 0).
fn exactOf(o: Operand) ?struct { p: u32, s: u32 } {
    const x = typing.exact(o.type) orelse return null;
    return .{ .p = x.p, .s = x.s };
}

fn sum(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const a = args[0];
    const l = a.logical();
    if (isExact(l)) {
        const x = exactOf(a) orelse return c.make(.{ .logical = .numeric });
        return decimal(c, x.p + 22, x.s);
    }
    if (typing.isNumber(l) or typing.isString(l)) return c.make(.{ .logical = .float8 });
    return unknown;
}

fn avg(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const a = args[0];
    const l = a.logical();
    if (isExact(l)) {
        const x = exactOf(a) orelse return c.make(.{ .logical = .numeric });
        return decimal(c, x.p + div_increment, x.s + div_increment);
    }
    if (typing.isNumber(l) or typing.isString(l)) return c.make(.{ .logical = .float8 });
    return unknown;
}

fn mod(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 2) return unknown;
    return operator(c, TK.REM, args[0], args[1]);
}

/// ROUND(x[, d]) and TRUNCATE(x, d): an integer stays one (d of 0), a
/// DECIMAL gets scale d, a double stays one.
fn round(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len == 0) return unknown;
    const a = args[0];
    const l = a.logical();
    if (!isExact(l)) return if (typing.isNumber(l)) c.make(.{ .logical = .float8 }) else unknown;
    const d: i64 = if (args.len >= 2) typing.intArg(args[1]) orelse return c.make(.{ .logical = .numeric }) else 0;
    if (typing.intWidth(l) != null and d >= 0) return c.make(.{ .logical = .int8 });
    const x = exactOf(a) orelse return c.make(.{ .logical = .numeric });
    const s: u32 = @intCast(std.math.clamp(d, 0, 38));
    return decimal(c, (x.p -| x.s) + s + 1, s);
}

/// CEIL(), FLOOR(): a BIGINT of an exact number, a double of a float.
fn ceil(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const l = args[0].logical();
    if (isExact(l)) return c.make(.{ .logical = .int8 });
    if (typing.isNumber(l)) return c.make(.{ .logical = .float8 });
    return unknown;
}

/// UPPER() and the like: of the type of their string argument.
fn stringArg(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len > 0 and typing.isString(args[0].logical())) return args[0].id;
    return c.make(.{ .logical = .varchar });
}

/// xq_coerce(v, 'type', ...): of the type named.
fn coerce(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len < 2) return unknown;
    return c.named(typing.stringArg(args[1]) orelse return unknown);
}
