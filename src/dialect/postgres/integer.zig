//! PostgreSQL's integers (smallint, integer, bigint) as values come in:
//!  - their input (int2in(), int4in(), int8in(), whose
//!    pg_strtoint16_safe() ... read PostgreSQL 16's forms): parse(),
//!    for every place that reads a string as an integer (the casts, what
//!    a column stores, pg_input_is_valid());
//!  - the casts to them, engine functions: xq_pg_cast_int2(x),
//!    xq_pg_cast_int4(x), xq_pg_cast_int8(x). A string is read by
//!    parse(), a real rounds half to even (rint(), as float8 -> int
//!    does), an integer is checked against the range. (The casts of
//!    before, xq_pg_int2() ... of funcs.zig, stay as they were for the
//!    schemas that call them.)
//!  - what a value stored into a column of one goes through
//!    (typing.zig's storeColumn(), storeColumn() here): a string by
//!    parse(), a real (a numeric's literal) rounded half away from zero
//!    and a BLOB (a numeric's key) by decimal_sql.zig's xq_dec_int2() ...,
//!    as numeric -> int does; a double precision or real by the cast
//!    instead (Store.typed);
//!  - `a # b` of integers: xq_pg_int_xor(a, b), an engine function, as
//!    there is no opcode for it (the parser makes the call, overload.zig
//!    checks its operands by operators.zig's table).

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const typing = @import("../../sql/typing.zig");
const types = @import("../../sql/types.zig");
const decimal_sql = @import("../decimal_sql.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

/// An integer type.
pub const Width = enum {
    int2,
    int4,
    int8,

    /// The type PostgreSQL names `n` (format_type()'s name), null for
    /// another.
    pub fn named(n: []const u8) ?Width {
        for (std.enums.values(Width)) |w| if (std.mem.eql(u8, n, w.name())) return w;
        return null;
    }

    /// PostgreSQL's name of the type, as its errors say.
    pub fn name(w: Width) []const u8 {
        return switch (w) {
            .int2 => "smallint",
            .int4 => "integer",
            .int8 => "bigint",
        };
    }

    fn bits(w: Width) u7 {
        return switch (w) {
            .int2 => 16,
            .int4 => 32,
            .int8 => 64,
        };
    }

    pub fn min(w: Width) i64 {
        return switch (w) {
            .int2 => std.math.minInt(i16),
            .int4 => std.math.minInt(i32),
            .int8 => std.math.minInt(i64),
        };
    }

    pub fn max(w: Width) i64 {
        return switch (w) {
            .int2 => std.math.maxInt(i16),
            .int4 => std.math.maxInt(i32),
            .int8 => std.math.maxInt(i64),
        };
    }

    pub fn holds(w: Width, v: i64) bool {
        return v >= w.min() and v <= w.max();
    }

    /// The integer type of `l`, null for another.
    pub fn of(l: types.Logical) ?Width {
        return switch (l) {
            .int1, .int2 => .int2,
            .int4 => .int4,
            .int8 => .int8,
            else => null,
        };
    }
};

pub const InputError = error{
    /// `invalid input syntax for type smallint: "x"` (22P02).
    InvalidSyntax,
    /// `value "x" is out of range for type smallint` (22003).
    OutOfRange,
};

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// PostgreSQL's input of an integer of type `w` (pg_strtoint16_safe(),
/// pg_strtoint32_safe(), pg_strtoint64_safe()): spaces around, a sign,
/// decimal digits or 0x/0o/0b and hexadecimal, octal or binary digits,
/// an underscore between two digits (or after the prefix: 0x_FF). A
/// value too large is out of range as soon as its digits make it so,
/// even if what follows them is not an integer ('100000x' of a
/// smallint).
pub fn parse(s: []const u8, w: Width) InputError!i64 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base: u64 = 10;
    if (i + 1 < s.len and s[i] == '0') switch (s[i + 1]) {
        'x', 'X' => base = 16,
        'o', 'O' => base = 8,
        'b', 'B' => base = 2,
        else => {},
    };
    if (base != 10) i += 2;
    // The magnitude of the smallest value; PostgreSQL's check before
    // each digit (tmp > -(PG_INT16_MIN / base)).
    const limit: u64 = @as(u64, 1) << @intCast(w.bits() - 1);
    const first = i;
    var tmp: u64 = 0;
    while (i < s.len) {
        const d = digitOf(s[i]);
        if (d < base) {
            if (tmp > limit / base) return error.OutOfRange;
            tmp = tmp * base + d;
            i += 1;
        } else if (s[i] == '_' and (base != 10 or i > first)) {
            // An underscore is followed by a digit.
            i += 1;
            if (i >= s.len or digitOf(s[i]) >= base) return error.InvalidSyntax;
        } else break;
    }
    if (i == first) return error.InvalidSyntax;
    while (i < s.len and isSpace(s[i])) i += 1;
    if (i != s.len) return error.InvalidSyntax;
    if (neg) {
        if (tmp > limit) return error.OutOfRange;
        return @intCast(-@as(i128, tmp));
    }
    if (tmp > limit - 1) return error.OutOfRange;
    return @intCast(tmp);
}

/// The value of hexadecimal digit `c`, 99 for another character.
pub fn digitOf(c: u8) u64 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 99,
    };
}

/// The message and SQLSTATE of input error `err` of string `raw` read as
/// an integer of type `w` (pg_input_error_info()), in `buf`.
pub fn inputError(err: InputError, w: Width, raw: []const u8, buf: []u8) struct { msg: []const u8, state: int.ErrorState } {
    const shown = raw[0..@min(raw.len, 900)];
    return switch (err) {
        error.InvalidSyntax => .{
            .msg = std.fmt.bufPrint(buf, "invalid input syntax for type {s}: \"{s}\"", .{ w.name(), shown }) catch "invalid input syntax",
            .state = .of("22P02"),
        },
        error.OutOfRange => .{
            .msg = std.fmt.bufPrint(buf, "value \"{s}\" is out of range for type {s}", .{ shown, w.name() }) catch "value out of range",
            .state = .of("22003"),
        },
    };
}

/// The result of reading string `raw` as an integer of type `w`: the
/// integer or PostgreSQL's error.
pub fn input(ctx: *Context, raw: []const u8, w: Width) void {
    const v = parse(raw, w) catch |err| {
        var buf: [1024]u8 = undefined;
        const e = inputError(err, w, raw, &buf);
        return api.resultErrorState(ctx, e.state, e.msg);
    };
    api.resultInt64(ctx, v);
}

fn outOfRange(ctx: *Context, w: Width) void {
    api.resultErrorState(ctx, .of("22003"), switch (w) {
        .int2 => "smallint out of range",
        .int4 => "integer out of range",
        .int8 => "bigint out of range",
    });
}

/// A real made an integer of type `w`: rounded half to even (rint(), a
/// double precision's cast) or half away from zero (a numeric's).
fn fromReal(ctx: *Context, x: f64, w: Width, comptime even: bool) void {
    const v = if (even and @abs(x - @trunc(x)) == 0.5) 2.0 * @round(x / 2.0) else @round(x);
    if (!(v >= -0x1p63 and v < 0x1p63)) return outOfRange(ctx, w);
    const i: i64 = @intFromFloat(v);
    if (!w.holds(i)) return outOfRange(ctx, w);
    api.resultInt64(ctx, i);
}

fn convert(ctx: *Context, argv: []*Mem, w: Width, comptime store: bool) void {
    const m = argv[0];
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => api.resultNull(ctx),
        vi.SQLITE_INTEGER => {
            const v = api.valueInt64(m);
            if (!w.holds(v)) return outOfRange(ctx, w);
            api.resultInt64(ctx, v);
        },
        vi.SQLITE_FLOAT => fromReal(ctx, api.valueDouble(m), w, !store),
        // A numeric's key.
        vi.SQLITE_BLOB => if (store) decimalInt(w).x_sfunc.?(ctx, argv) else {
            var buf: [64]u8 = undefined;
            api.resultErrorState(ctx, .of("42846"), std.fmt.bufPrint(&buf, "cannot cast type bytea to {s}", .{w.name()}) catch "cannot cast type bytea");
        },
        else => {
            const raw = dfunc.text(ctx, m) orelse return;
            input(ctx, raw, w);
        },
    }
}

/// numeric -> int (decimal_sql.zig): half away from zero.
pub fn decimalInt(w: Width) *const int.FuncDef {
    const d = decimal_sql.def;
    return switch (w) {
        .int2 => d("xq_dec_int2", 1),
        .int4 => d("xq_dec_int4", 1),
        .int8 => d("xq_dec_int8", 1),
    };
}

fn castFunc(ctx: *Context, argv: []*Mem, w: Width) void {
    convert(ctx, argv, w, false);
}

fn storeFunc(ctx: *Context, argv: []*Mem, w: Width) void {
    convert(ctx, argv, w, true);
}

const det: dfunc.Options = .{ .deterministic = true };

/// The engine functions, by name: what calls one (castDef(),
/// storeColumn(), overload.zig) takes it from here, not by its place in
/// engine_functions.
pub const defs = struct {
    pub const cast_int2 = dfunc.scalar("xq_pg_cast_int2", 1, det, dfunc.bind(castFunc, .{Width.int2}));
    pub const cast_int4 = dfunc.scalar("xq_pg_cast_int4", 1, det, dfunc.bind(castFunc, .{Width.int4}));
    pub const cast_int8 = dfunc.scalar("xq_pg_cast_int8", 1, det, dfunc.bind(castFunc, .{Width.int8}));
    pub const int_xor = dfunc.scalar("xq_pg_int_xor", 2, det, xorFunc);
    const store_int2 = dfunc.scalar("xq_pg_store_int2", 1, det, dfunc.bind(storeFunc, .{Width.int2}));
    const store_int4 = dfunc.scalar("xq_pg_store_int4", 1, det, dfunc.bind(storeFunc, .{Width.int4}));
    const store_int8 = dfunc.scalar("xq_pg_store_int8", 1, det, dfunc.bind(storeFunc, .{Width.int8}));
};

pub const engine_functions = [_]int.FuncDef{ defs.cast_int2, defs.cast_int4, defs.cast_int8, defs.int_xor };

/// `a # b` of integers (int2xor() ...): NULL if either is.
fn xorFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    api.resultInt64(ctx, api.valueInt64(argv[0]) ^ api.valueInt64(argv[1]));
}

/// The cast that reads a value as an integer of type `w`.
pub fn castDef(w: Width) *const int.FuncDef {
    return switch (w) {
        .int2 => &defs.cast_int2,
        .int4 => &defs.cast_int4,
        .int8 => &defs.cast_int8,
    };
}

/// The name of castDef(w): xq_pg_cast_int4 ...
pub fn castName(w: Width) [:0]const u8 {
    return castDef(w).name;
}

/// The integer type castName() names `name` (lower case), null for
/// another name.
pub fn castOf(name: []const u8) ?Width {
    for (std.enums.values(Width)) |w| if (std.mem.eql(u8, name, castName(w))) return w;
    return null;
}

/// What a value stored into a column of integer type `t` goes through
/// (typing.Rules.store_column), null for a type of no integer: a string
/// or a parameter read as the type's input, a numeric (its key, or a
/// real: a numeric's literal) rounded half away from zero as numeric ->
/// int does; a double precision or real by the cast (rounded to even).
/// An integer is stored as it is (the column's check says "smallint out
/// of range"), by the code SQLite's INSERT has.
pub fn storeColumn(t: types.Type) ?typing.Store {
    const w = Width.of(t.logical) orelse return null;
    return .{
        .typed = .{ .types = .initMany(&.{ .float4, .float8 }), .conv = .{ .def = castDef(w) } },
        .needed = .{ .def = switch (w) {
            .int2 => &defs.store_int2,
            .int4 => &defs.store_int4,
            .int8 => &defs.store_int8,
        } },
    };
}

test "pg integer input" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 123), try parse("  123  ", .int2));
    try t.expectEqual(@as(i64, -32768), try parse("-32768", .int2));
    try t.expectError(error.OutOfRange, parse("32768", .int2));
    try t.expectError(error.OutOfRange, parse("100000x", .int2));
    try t.expectError(error.InvalidSyntax, parse("32769x", .int2));
    try t.expectEqual(@as(i64, 1071), try parse("0x42F", .int4));
    try t.expectEqual(@as(i64, 187), try parse("0o273", .int4));
    try t.expectEqual(@as(i64, 37), try parse("0b100101", .int4));
    try t.expectEqual(@as(i64, 37), try parse("0b_10_0101", .int4));
    try t.expectEqual(@as(i64, 1000000), try parse("1_000_000", .int4));
    try t.expectEqual(@as(i64, std.math.minInt(i64)), try parse("-0x8000000000000000", .int8));
    try t.expectError(error.OutOfRange, parse("0x8000000000000000", .int8));
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), try parse("9223372036854775807", .int8));
    for ([_][]const u8{ "", "    ", "- 1234", "4 444", "34.5", "0x", "0b", "0o", "_100", "100_", "10__000", "1e3", "+", "0x_", "abc" }) |z|
        try t.expectError(error.InvalidSyntax, parse(z, .int2));
}
