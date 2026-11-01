//! SQL Server's types of expressions (dialect.Hooks.typing, the rules of
//! sql/typing.zig), by its data type precedence:
//!  - an integer literal is an int if it fits 32 bits, else a
//!    numeric(p,0) of its digits; a literal with a point a numeric(p,s)
//!    of its digits (1.50: numeric(3,2)), with an exponent a float; a
//!    string literal a varchar(n) of its length;
//!  - integers compute in the wider of their types (int / int is an
//!    int); a float makes a float (real only with real); exact numbers
//!    (an integer is a numeric(10,0) and the like) follow SQL Server's
//!    precision and scale rules: + and - give scale max(s1, s2) and
//!    precision max(s1, s2) + max(p1 - s1, p2 - s2) + 1, * scale s1 + s2
//!    and precision p1 + p2 + 1, / scale max(6, s1 + p2 + 1) and
//!    precision p1 - s1 + s2 + that scale, % scale max(s1, s2); beyond a
//!    precision of 38 the precision is 38 and the scale shrinks to what
//!    the integral digits leave (not below 6 for * and /) - simplified:
//!    SQL Server keeps at least min(s, 6) for every operator;
//!  - a string with a number is of the number's type (the string is
//!    converted); `+` of strings (the frontend's concatenation) a
//!    varchar of the lengths' sum (varchar(max) beyond 8000 or if one is
//!    unknown); xq_tsql_add(), the `+` the frontend leaves to the values,
//!    the same by the operands' types;
//!  - functions: COUNT() an int (COUNT_BIG(), lowered to count(), too),
//!    SUM() of an int an int, of a decimal(p,s) a decimal(38,s), AVG() of
//!    an int an int and of a decimal(p,s) a decimal(38,max(s,6)), LEN()
//!    an int, UPPER() the type of its argument ...

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
    .store_wrappers = &.{"xq_tsql_store"},
};

/// The longest varchar(n) before varchar(max).
const max_varchar = 8000;

fn spell(t: Type, buf: *[64]u8) []const u8 {
    return switch (t.logical) {
        .int1 => "tinyint",
        .int2 => "smallint",
        .int4 => "int",
        .int8 => "bigint",
        .float4 => "real",
        .float8 => "float",
        .boolean => "bit",
        .numeric => if (t.precision) |p| std.fmt.bufPrint(buf, "numeric({d},{d})", .{ p, t.scale orelse 0 }) catch "numeric" else "numeric",
        .varchar => if (t.length) |n| std.fmt.bufPrint(buf, "varchar({d})", .{n}) catch "varchar(max)" else "varchar(max)",
        .char => if (t.length) |n| std.fmt.bufPrint(buf, "char({d})", .{n}) catch "char" else "char",
        .text => "varchar(max)",
        .bytes => if (t.length) |n| std.fmt.bufPrint(buf, "varbinary({d})", .{n}) catch "varbinary(max)" else "varbinary(max)",
        .timestamp => "datetime2",
        .timestamp_tz => "datetimeoffset",
        .uuid => "uniqueidentifier",
        .json => "nvarchar(max)",
        else => typing.plainName(t.logical),
    };
}

fn literal(c: *Ctx, e: *const int.Expr) Oom!TypeId {
    switch (e.op) {
        TK.INTEGER => {
            if (typing.intLiteral(e)) |v| if (std.math.cast(i32, v) != null) return c.named("int");
            const d = typing.decimalLiteral(e) orelse return c.named("bigint");
            return numeric(c, d.precision(), 0);
        },
        TK.FLOAT => {
            const d = typing.decimalLiteral(e) orelse return c.named("float");
            if (d.exponent != null) return c.named("float");
            return numeric(c, @max(d.int_digits + d.frac_digits, 1), d.frac_digits);
        },
        TK.STRING => return varchar(c, @max(typing.stringLength(e) orelse 1, 1)),
        TK.BLOB => return c.make(.{ .logical = .bytes }),
        else => return unknown,
    }
}

fn numeric(c: *Ctx, p: u32, s: u32) Oom!TypeId {
    // Beyond 38 digits: 38, the scale kept as the integral digits allow.
    var pp = p;
    var ss = s;
    if (pp > 38) {
        const integral = pp - ss;
        ss = if (integral < 32) @min(ss, 38 - integral) else @min(ss, 6);
        pp = 38;
    }
    return c.make(.{ .logical = .numeric, .precision = typing.clampU8(@max(pp, 1)), .scale = typing.clampU8(ss) });
}

fn varchar(c: *Ctx, n: ?u32) Oom!TypeId {
    const len: ?u32 = if (n) |x| (if (x <= max_varchar) x else null) else null;
    return c.make(.{ .logical = .varchar, .length = len });
}

fn operator(c: *Ctx, op: u8, a_arg: Operand, b_arg: ?Operand) Oom!TypeId {
    var a = a_arg;
    var b = b_arg orelse {
        if (op == TK.BITNOT) return if (typing.intWidth(a.logical()) != null) a.id else unknown;
        return if (typing.isNumber(a.logical())) a.id else unknown;
    };
    if (op == TK.CONCAT) return concat(c, a, b);
    // A string is converted to the number it meets.
    if (typing.isString(a.logical()) and typing.isNumber(b.logical())) a = b;
    if (typing.isString(b.logical()) and typing.isNumber(a.logical())) b = a;
    const la = numberOf(a.logical()) orelse return unknown;
    const lb = numberOf(b.logical()) orelse return unknown;
    if (typing.intWidth(la)) |wa| if (typing.intWidth(lb)) |wb| {
        return c.make(.{ .logical = if (wa >= wb) la else lb });
    };
    switch (op) {
        TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => return unknown,
        else => {},
    }
    if (typing.isFloat(la) or typing.isFloat(lb)) {
        return c.make(.{ .logical = if (la == .float4 and lb == .float4) .float4 else .float8 });
    }
    const x = typing.exact(withLogical(a.type, la)) orelse return c.make(.{ .logical = .numeric });
    const y = typing.exact(withLogical(b.type, lb)) orelse return c.make(.{ .logical = .numeric });
    const ix = x.p -| x.s;
    const iy = y.p -| y.s;
    return switch (op) {
        TK.PLUS, TK.MINUS => numeric(c, @max(x.s, y.s) + @max(ix, iy) + 1, @max(x.s, y.s)),
        TK.STAR => numeric(c, x.p + y.p + 1, x.s + y.s),
        TK.SLASH => blk: {
            const s = @max(6, x.s + y.p + 1);
            break :blk numeric(c, ix + y.s + s, s);
        },
        TK.REM => numeric(c, @min(ix, iy) + @max(x.s, y.s), @max(x.s, y.s)),
        else => unknown,
    };
}

/// The numeric type of `l`: a bit computes as an int.
fn numberOf(l: Logical) ?Logical {
    if (l == .boolean) return .int4;
    return if (typing.isNumber(l)) l else null;
}

fn withLogical(t: Type, l: Logical) Type {
    if (t.logical == l) return t;
    return .{ .logical = l };
}

/// A concatenation: a varchar of the sum of the lengths.
fn concat(c: *Ctx, a: Operand, b: Operand) Oom!TypeId {
    const la = lengthOf(a) orelse return varchar(c, null);
    const lb = lengthOf(b) orelse return varchar(c, null);
    return varchar(c, la + lb);
}

fn lengthOf(o: Operand) ?u32 {
    if (o.e.op == TK.NULL) return 0;
    return switch (o.logical()) {
        .varchar, .char => o.type.length,
        else => null,
    };
}

fn function(name: []const u8) ?Ret {
    return functions.get(name);
}

const functions = std.StaticStringMap(Ret).initComptime(.{
    // Aggregates and window functions (COUNT_BIG() is lowered to count()).
    .{ "count", Ret{ .named = "int" } },
    .{ "sum", Ret{ .rule = sum } },
    .{ "avg", Ret{ .rule = avg } },
    .{ "xq_tsql_avg", Ret{ .rule = avg } },
    .{ "xq_stddev_samp", Ret{ .named = "float" } },
    .{ "xq_stddev_pop", Ret{ .named = "float" } },
    .{ "xq_var_samp", Ret{ .named = "float" } },
    .{ "xq_var_pop", Ret{ .named = "float" } },
    .{ "group_concat", Ret{ .named = "varchar(max)" } },
    .{ "row_number", Ret{ .named = "bigint" } },
    .{ "rank", Ret{ .named = "bigint" } },
    .{ "dense_rank", Ret{ .named = "bigint" } },
    .{ "ntile", Ret{ .named = "bigint" } },
    .{ "lag", Ret{ .arg = 0 } },
    .{ "lead", Ret{ .arg = 0 } },
    .{ "first_value", Ret{ .arg = 0 } },
    .{ "last_value", Ret{ .arg = 0 } },
    // Strings (LEN() is length(rtrim()), DATALENGTH() octet_length()).
    .{ "length", Ret{ .named = "int" } },
    .{ "octet_length", Ret{ .named = "int" } },
    .{ "charindex", Ret{ .named = "int" } },
    .{ "instr", Ret{ .named = "int" } },
    .{ "ascii", Ret{ .named = "int" } },
    .{ "unicode", Ret{ .named = "int" } },
    .{ "upper", Ret{ .rule = stringArg } },
    .{ "lower", Ret{ .rule = stringArg } },
    .{ "ltrim", Ret{ .rule = stringArg } },
    .{ "rtrim", Ret{ .rule = stringArg } },
    .{ "trim", Ret{ .rule = stringArg } },
    .{ "reverse", Ret{ .rule = stringArg } },
    .{ "replace", Ret{ .named = "varchar(max)" } },
    .{ "substr", Ret{ .rule = stringArg } },
    .{ "left", Ret{ .rule = stringArg } },
    .{ "right", Ret{ .rule = stringArg } },
    .{ "replicate", Ret{ .named = "varchar(max)" } },
    .{ "stuff", Ret{ .named = "varchar(max)" } },
    .{ "space", Ret{ .named = "varchar(max)" } },
    .{ "char", Ret{ .named = "char(1)" } },
    .{ "concat", Ret{ .named = "varchar(max)" } },
    // ISNULL() (lowered to ifnull()) is of its first argument's type,
    // COALESCE() of the arguments' common type.
    .{ "ifnull", Ret{ .arg = 0 } },
    // Numbers: of their argument's type, but the transcendental ones.
    .{ "abs", Ret{ .arg = 0 } },
    .{ "round", Ret{ .arg = 0 } },
    .{ "truncate", Ret{ .arg = 0 } },
    .{ "sign", Ret{ .arg = 0 } },
    .{ "power", Ret{ .arg = 0 } },
    .{ "ceiling", Ret{ .rule = ceiling } },
    .{ "floor", Ret{ .rule = ceiling } },
    .{ "sqrt", Ret{ .named = "float" } },
    .{ "exp", Ret{ .named = "float" } },
    .{ "ln", Ret{ .named = "float" } },
    .{ "log", Ret{ .named = "float" } },
    .{ "log10", Ret{ .named = "float" } },
    .{ "sin", Ret{ .named = "float" } },
    .{ "cos", Ret{ .named = "float" } },
    .{ "tan", Ret{ .named = "float" } },
    .{ "asin", Ret{ .named = "float" } },
    .{ "acos", Ret{ .named = "float" } },
    .{ "atan", Ret{ .named = "float" } },
    .{ "degrees", Ret{ .arg = 0 } },
    .{ "radians", Ret{ .arg = 0 } },
    .{ "pi", Ret{ .named = "float" } },
    .{ "xq_rand", Ret{ .named = "float" } },
    .{ "isnumeric", Ret{ .named = "int" } },
    // Dates (GETDATE(): the frontend's Func.result_type).
    .{ "datediff", Ret{ .named = "int" } },
    .{ "datepart", Ret{ .named = "int" } },
    .{ "datename", Ret{ .named = "nvarchar(30)" } },
    .{ "dateadd", Ret{ .arg = 2 } },
    .{ "eomonth", Ret{ .named = "date" } },
    .{ "datefromparts", Ret{ .named = "date" } },
    .{ "date", Ret{ .named = "date" } },
    .{ "isdate", Ret{ .named = "int" } },
    // The session.
    .{ "xq_tsql_newid", Ret{ .named = "uniqueidentifier" } },
    .{ "scope_identity", Ret{ .named = "numeric(38,0)" } },
    .{ "ident_current", Ret{ .named = "numeric(38,0)" } },
    .{ "changes", Ret{ .named = "int" } },
    .{ "xq_tsql_trancount", Ret{ .named = "int" } },
    // `+` whose operands the frontend did not know.
    .{ "xq_tsql_add", Ret{ .rule = add } },
});

fn sum(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const a = args[0];
    return switch (numberOf(a.logical()) orelse return unknown) {
        .int1, .int2, .int4 => c.named("int"),
        .int8 => c.named("bigint"),
        .numeric => if (a.type.precision != null) numeric(c, 38, a.type.scale orelse 0) else c.make(.{ .logical = .numeric }),
        else => c.named("float"),
    };
}

fn avg(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const a = args[0];
    return switch (numberOf(a.logical()) orelse return unknown) {
        .int1, .int2, .int4 => c.named("int"),
        .int8 => c.named("bigint"),
        .numeric => if (a.type.precision != null) numeric(c, 38, @max(a.type.scale orelse 0, 6)) else c.make(.{ .logical = .numeric }),
        else => c.named("float"),
    };
}

/// UPPER() and the like: of the type of their string argument.
fn stringArg(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len > 0 and typing.isString(args[0].logical())) return args[0].id;
    return varchar(c, null);
}

/// CEILING(), FLOOR(): a decimal(p,s) gives a decimal(p,0), another
/// number its type.
fn ceiling(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 1) return unknown;
    const a = args[0];
    if (a.logical() == .numeric) {
        const p = a.type.precision orelse return c.make(.{ .logical = .numeric });
        return numeric(c, p, 0);
    }
    return if (typing.isNumber(a.logical())) a.id else unknown;
}

fn add(c: *Ctx, args: []const Operand) Oom!TypeId {
    if (args.len != 2) return unknown;
    if (typing.isString(args[0].logical()) and typing.isString(args[1].logical())) return concat(c, args[0], args[1]);
    return operator(c, TK.PLUS, args[0], args[1]);
}
