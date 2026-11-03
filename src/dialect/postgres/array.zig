//! PostgreSQL's arrays. An array value is TEXT, PostgreSQL's own text of
//! it (array_out()): `{1,2,NULL}`, `{"a b",c}`, `{{1,2},{3,4}}`, with
//! its bounds before it when a lower bound is not 1 (`[0:1]={1,2}`). The
//! catalog's int2vector and oidvector are their text too (`1 2`, lower
//! bound 0). The type of the elements is the core's (Expr.xq_type, a
//! types.Type of logical `array` and its `element`): the input of an
//! array of a type (a cast, a store into a column) reads each element as
//! the element type reads it and writes it as the type writes it, so
//! that the text of a value is canonical: `'{ 1 , 01}'::int[]` is
//! `{1,1}`, `'{yes}'::bool[]` is `{t}`, and two arrays of one type are
//! equal when their texts are. Where the element type is not known (a
//! view's text, a parameter of no type) the elements are taken as they
//! are written and compared as their values are (a number with a
//! number, text with text).
//!
//! Engine functions (visible in every dialect: the schema holds them):
//!
//!   xq_pg_array_<elem>(x)          ::elem[] and the store into an elem[]
//!                                  column: the canonical text, checked
//!                                  (xq_pg_array_int4 ...; _any for
//!                                  elements of no known type)
//!   xq_pg_array_valid(x)           the CHECK of an array column
//!   xq_pg_array(v, ...)            ARRAY[v, ...] (overload.zig wraps a
//!                                  value of a type in xq_pg_elem())
//!   xq_pg_array_nested(a, ...)     ARRAY[ARRAY[...], ...]: a dimension more
//!   xq_pg_elem(x, code)            x as the text of an element of `code`
//!   xq_pg_any(x, a, op, all [, code])  x op ANY/ALL (a)
//!   xq_pg_subscript(a, i, ...)     a[i][j] (its element as text, or an
//!   xq_pg_subscript_k(a, i, ..., code)  integer if it reads as one; _k:
//!                                  as the element type's value)
//!   xq_pg_slice(a, lo, hi, ...)    a[lo:hi] (NULL: the array's own bound)
//!   xq_pg_array_cat2(a, b)         a || b of two arrays
//!   xq_pg_array_contains(a, b)     a @> b (b <@ a)
//!   xq_pg_array_overlap(a, b)      a && b
//!   xq_pg_array_agg(x) / _arrays   array_agg() of elements / of arrays
//!   xq_pg_rows_unnest(a [, code])  the rows of unnest(a), as
//!                                  json_each() reads them (parser.zig)
//!   xq_pg_rows_subscripts(a, d, r) the rows of generate_subscripts()
//!   xq_pg_rows_expand(a)           of information_schema._pg_expandarray()
//!   xq_pg_record_field(r, name)    (r).x of a record of _pg_expandarray()
//!   collations xq_pg_array, xq_pg_array_num: arrays in PostgreSQL's order
//!                                  (of text, of number elements)
//!
//! The dialect's functions (array_length() ...) are at the end.

const std = @import("std");
const simd = @import("xqlite_base").simd;
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const types = @import("../../sql/types.zig");
const json = @import("json.zig");
const jsonb_bin = @import("../jsonb.zig");
const datetime = @import("datetime.zig");
const like = @import("../like.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Allocator = std.mem.Allocator;
const FuncDef = int.FuncDef;
const Logical = types.Logical;
const isNull = dfunc.isNull;

// ============================================================ elements

/// The type of the elements of an array, as the engine functions are
/// told it (Code).
pub const Elem = enum(u8) {
    /// Not known: elements as written, compared as their values are.
    unknown,
    boolean,
    int2,
    int4,
    int8,
    float4,
    float8,
    numeric,
    text,
    bytea,
    date,
    time,
    timetz,
    timestamp,
    timestamptz,
    interval,
    uuid,
    json,
    jsonb,

    pub fn of(l: Logical) Elem {
        return switch (l) {
            .unknown, .array => .unknown,
            .boolean => .boolean,
            .int1, .int2 => .int2,
            .int4 => .int4,
            .int8 => .int8,
            .float4 => .float4,
            .float8 => .float8,
            .numeric => .numeric,
            .text, .varchar, .char => .text,
            .bytes => .bytea,
            .date => .date,
            .time => .time,
            .time_tz => .timetz,
            .timestamp => .timestamp,
            .timestamp_tz => .timestamptz,
            .interval => .interval,
            .uuid => .uuid,
            .json => .json,
            .jsonb => .jsonb,
        };
    }

    /// PostgreSQL's name of the type, as its messages say.
    pub fn typeName(e: Elem) []const u8 {
        return switch (e) {
            .unknown, .text => "text",
            .boolean => "boolean",
            .int2 => "smallint",
            .int4 => "integer",
            .int8 => "bigint",
            .float4 => "real",
            .float8 => "double precision",
            .numeric => "numeric",
            .bytea => "bytea",
            .date => "date",
            .time => "time without time zone",
            .timetz => "time with time zone",
            .timestamp => "timestamp without time zone",
            .timestamptz => "timestamp with time zone",
            .interval => "interval",
            .uuid => "uuid",
            .json => "json",
            .jsonb => "jsonb",
        };
    }

    /// The suffix of its xq_pg_array_<suffix>() (PostgreSQL's internal
    /// name of the type).
    pub fn suffix(e: Elem) []const u8 {
        return switch (e) {
            .unknown => "any",
            .boolean => "bool",
            else => @tagName(e),
        };
    }

    pub fn isNumber(e: Elem) bool {
        return switch (e) {
            .int2, .int4, .int8, .float4, .float8, .numeric => true,
            else => false,
        };
    }
};

const n_elems = std.enums.values(Elem).len;

/// What an engine function is told of the elements, as an integer
/// argument: the element type, the scale of a numeric (+1, 0 for none)
/// << 8, and 1 << 16 if the values are arrays themselves (an array of
/// arrays: a dimension more).
pub const Code = struct {
    elem: Elem = .unknown,
    scale: ?u8 = null,
    nested: bool = false,

    pub fn encode(c: Code) i64 {
        const s: i64 = if (c.scale) |x| @as(i64, x) + 1 else 0;
        return @as(i64, @backingInt(c.elem)) | s << 8 | @as(i64, @intFromBool(c.nested)) << 16;
    }

    pub fn decode(v: i64) Code {
        const e: u8 = @intCast(v & 0xff);
        const s: i64 = (v >> 8) & 0xff;
        return .{
            .elem = if (e < n_elems) @fromBackingInt(@intCast(e)) else .unknown,
            .scale = if (s > 0) @intCast(s - 1) else null,
            .nested = (v >> 16) & 1 != 0,
        };
    }

    /// The code of the elements of an array of type `t`.
    pub fn ofArray(t: types.Type) Code {
        if (t.logical != .array) return .{};
        return .{ .elem = .of(t.element), .scale = if (t.element == .numeric) t.scale else null };
    }

    /// The code of values of type `t` made elements.
    pub fn ofValue(t: types.Type) Code {
        if (t.logical == .array) {
            var c = ofArray(t);
            c.nested = true;
            return c;
        }
        return .{ .elem = .of(t.logical), .scale = if (t.logical == .numeric) t.scale else null };
    }
};

// ======================================================== parse, write

pub const max_dims = 6;

/// An array: its dimensions (none if empty) and its elements, the last
/// dimension's fastest; an element is its text (null for NULL).
pub const Array = struct {
    ndim: u8 = 0,
    dims: [max_dims]u32 = @splat(0),
    lower: [max_dims]i32 = @splat(1),
    elems: []?[]const u8 = &.{},

    pub fn count(x: *const Array) usize {
        if (x.ndim == 0) return 0;
        var n: usize = 1;
        for (x.dims[0..x.ndim]) |d| n *= d;
        return n;
    }

    /// A one-dimensional array of `elems` (from 1).
    pub fn list(elems: []?[]const u8) Array {
        var x: Array = .{ .elems = elems };
        if (elems.len > 0) {
            x.ndim = 1;
            x.dims[0] = @intCast(elems.len);
        }
        return x;
    }

    fn upper(x: *const Array, d: usize) i64 {
        return @as(i64, x.lower[d]) + x.dims[d] - 1;
    }
};

pub const ParseError = error{ Malformed, OutOfMemory };

const Parse = struct {
    a: Allocator,
    z: []const u8,
    i: usize = 0,
    out: std.ArrayList(?[]const u8) = .empty,
    x: Array = .{},
    seen: [max_dims]bool = @splat(false),
    /// PostgreSQL's DETAIL of the error, if known (parseWith()).
    detail: ?[]const u8 = null,
    /// The text gave the dimensions ([1:2]=...).
    dims_given: bool = false,

    /// Malformed, with PostgreSQL's DETAIL.
    fn bad(p: *Parse, detail: []const u8) error{Malformed} {
        p.detail = detail;
        return error.Malformed;
    }

    /// Malformed: the sub-arrays do not match (dimension_error).
    fn dimensionError(p: *Parse) error{Malformed} {
        return p.bad(if (p.dims_given) "Specified array dimensions do not match array contents." else "Multidimensional arrays must have sub-arrays with matching dimensions.");
    }

    const end_of_input = "Unexpected end of input.";

    fn ws(p: *Parse) void {
        while (p.i < p.z.len and isSpace(p.z[p.i])) p.i += 1;
    }

    fn peek(p: *const Parse) ?u8 {
        return if (p.i < p.z.len) p.z[p.i] else null;
    }

    fn int(p: *Parse) ?i64 {
        const start = p.i;
        if (p.i < p.z.len and (p.z[p.i] == '-' or p.z[p.i] == '+')) p.i += 1;
        while (p.i < p.z.len and std.ascii.isDigit(p.z[p.i])) p.i += 1;
        return std.fmt.parseInt(i64, p.z[start..p.i], 10) catch null;
    }

    fn level(p: *Parse, depth: usize) ParseError!void {
        if (depth >= max_dims) return error.Malformed;
        p.i += 1; // {
        p.ws();
        var n: u32 = 0;
        if (p.peek() == '}') {
            p.i += 1;
            // {} only as the whole array.
            if (depth != 0) return error.Malformed;
            return;
        }
        while (true) {
            p.ws();
            const c = p.peek() orelse return p.bad(end_of_input);
            const quoted = c == '"';
            if (c == '{') {
                if (p.x.ndim != 0 and depth + 1 >= p.x.ndim) return p.dimensionError();
                try p.level(depth + 1);
                if (p.x.ndim == 0) return error.Malformed;
            } else {
                if (p.x.ndim == 0) p.x.ndim = @intCast(depth + 1) else if (p.x.ndim != depth + 1) return p.dimensionError();
                try p.element();
            }
            n += 1;
            p.ws();
            const d = p.peek() orelse return p.bad(end_of_input);
            p.i += 1;
            if (d == ',') continue;
            if (d == '}') break;
            // ReadArrayToken(): what may not follow an element.
            if (d == '{') return p.bad("Unexpected \"{\" character.");
            return p.bad(if (quoted) "Incorrectly quoted array element." else "Unexpected array element.");
        }
        if (!p.seen[depth]) {
            p.seen[depth] = true;
            p.x.dims[depth] = n;
        } else if (p.x.dims[depth] != n) return p.dimensionError();
    }

    fn element(p: *Parse) ParseError!void {
        var buf: std.ArrayList(u8) = .empty;
        if (p.peek() == '"') {
            p.i += 1;
            while (true) {
                const c = p.peek() orelse return p.bad(end_of_input);
                p.i += 1;
                if (c == '"') break;
                if (c == '\\') {
                    const e = p.peek() orelse return p.bad(end_of_input);
                    p.i += 1;
                    try buf.append(p.a, e);
                } else try buf.append(p.a, c);
            }
            return p.out.append(p.a, buf.items);
        }
        var keep: usize = 0; // the length without trailing blanks
        var escaped = false;
        while (true) {
            const c = p.peek() orelse return p.bad(end_of_input);
            if (c == ',' or c == '}') break;
            if (c == '{') return p.bad("Unexpected \"{\" character.");
            if (c == '"') return p.bad("Incorrectly quoted array element.");
            p.i += 1;
            if (c == '\\') {
                const e = p.peek() orelse return p.bad(end_of_input);
                p.i += 1;
                try buf.append(p.a, e);
                keep = buf.items.len;
                escaped = true;
            } else {
                try buf.append(p.a, c);
                if (!isSpace(c)) keep = buf.items.len;
            }
        }
        buf.items.len = keep;
        // A delimiter or a brace where an element is expected.
        if (buf.items.len == 0) return p.bad(if (p.z[p.i] == ',') "Unexpected \",\" character." else "Unexpected \"}\" character.");
        if (!escaped and std.ascii.eqlIgnoreCase(buf.items, "null")) return p.out.append(p.a, null);
        try p.out.append(p.a, buf.items);
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// Array `z` (array_in()'s syntax). `vector`: also the space-separated
/// integers of an int2vector or oidvector (`1 2`, from 0).
pub fn parse(a: Allocator, z: []const u8, vector: bool) ParseError!Array {
    var detail: ?[]const u8 = null;
    return parseWith(a, z, vector, &detail);
}

/// parse(), leaving PostgreSQL's DETAIL of a malformed array in
/// `detail` where it is known (static text; malformedError()).
pub fn parseWith(a: Allocator, z: []const u8, vector: bool, detail: *?[]const u8) ParseError!Array {
    var p: Parse = .{ .a = a, .z = z };
    defer detail.* = p.detail;
    p.ws();
    // [lo:hi][lo:hi]=
    var bounds: [max_dims][2]i64 = undefined;
    var nb: usize = 0;
    while (p.peek() == '[') {
        if (nb == max_dims) return error.Malformed;
        p.i += 1;
        p.ws();
        p.dims_given = true;
        const lo = p.int() orelse return p.bad("\"[\" must introduce explicitly-specified array dimensions.");
        p.ws();
        var hi = lo;
        var l = lo;
        if (p.peek() == ':') {
            p.i += 1;
            p.ws();
            hi = p.int() orelse return p.bad("Missing array dimension value.");
            p.ws();
        } else l = 1;
        if (p.peek() != ']') return p.bad("Missing \"]\" after array dimensions.");
        p.i += 1;
        if (hi < l - 1) return error.Malformed;
        bounds[nb] = .{ l, hi };
        nb += 1;
        p.ws();
    }
    if (nb > 0) {
        if (p.peek() != '=') return p.bad("Missing \"=\" after array dimensions.");
        p.i += 1;
        p.ws();
    }
    if (p.peek() != '{') {
        const must = "Array value must start with \"{\" or dimension information.";
        if (nb == 0 and vector) return parseVector(a, z) catch |err| if (err == error.Malformed) p.bad(must) else err;
        return p.bad(must);
    }
    try p.level(0);
    p.ws();
    if (p.i != p.z.len) return p.bad("Junk after closing right brace.");
    p.x.elems = p.out.items;
    if (nb > 0) {
        if (nb != p.x.ndim) return p.dimensionError();
        for (bounds[0..nb], 0..) |b, d| {
            if (b[1] - b[0] + 1 != p.x.dims[d]) return p.dimensionError();
            p.x.lower[d] = std.math.cast(i32, b[0]) orelse return error.Malformed;
        }
    }
    return p.x;
}

/// Make PostgreSQL's error of malformed array `z` the result of `ctx`,
/// with its DETAIL `detail` where it is known (parseWith()'s).
pub fn malformedError(ctx: *Context, a: Allocator, z: []const u8, detail: ?[]const u8) void {
    const msg = std.fmt.allocPrint(a, "malformed array literal: \"{s}\"", .{z}) catch return api.resultErrorNomem(ctx);
    api.resultErrorFields(ctx, .of("22P02"), .{ .message = msg, .detail = detail });
}

fn parseVector(a: Allocator, z: []const u8) ParseError!Array {
    var out: std.ArrayList(?[]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, z, " \t\r\n");
    while (it.next()) |w| {
        _ = std.fmt.parseInt(i64, w, 10) catch return error.Malformed;
        try out.append(a, w);
    }
    var x = Array.list(out.items);
    x.lower[0] = 0;
    return x;
}

/// The text of `x`, as array_out() writes it.
pub fn write(a: Allocator, x: *const Array) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeTo(a, &out, x);
    return out.items;
}

pub fn writeTo(a: Allocator, out: *std.ArrayList(u8), x: *const Array) error{OutOfMemory}!void {
    if (x.ndim == 0 or x.count() == 0) return out.appendSlice(a, "{}");
    var decorate = false;
    for (x.lower[0..x.ndim]) |l| {
        if (l != 1) decorate = true;
    }
    if (decorate) {
        for (0..x.ndim) |d| try out.print(a, "[{d}:{d}]", .{ x.lower[d], x.upper(d) });
        try out.append(a, '=');
    }
    var i: usize = 0;
    try writeLevel(a, out, x, 0, &i);
}

fn writeLevel(a: Allocator, out: *std.ArrayList(u8), x: *const Array, d: usize, i: *usize) error{OutOfMemory}!void {
    try out.append(a, '{');
    for (0..x.dims[d]) |k| {
        if (k > 0) try out.append(a, ',');
        if (d + 1 < x.ndim) {
            try writeLevel(a, out, x, d + 1, i);
        } else {
            json.writeArrayElem(a, out, x.elems[i.*]) catch return error.OutOfMemory;
            i.* += 1;
        }
    }
    try out.append(a, '}');
}

// ======================================================= element values

/// An error of an element's input: its SQLSTATE and message.
pub const Fail = struct { state: *const [5]u8, msg: []const u8 };

pub const ElemError = error{ Invalid, OutOfMemory };

/// The text of element `z` of type `e` as the type's output writes what
/// its input reads (`01` of an integer is `1`, `yes` of a boolean `t`);
/// error.Invalid with `fail` set if the type does not read it.
pub fn elemIn(a: Allocator, e: Elem, z: []const u8, fail: *Fail) ElemError![]const u8 {
    const t = std.mem.trim(u8, z, " \t\r\n\x0b\x0c");
    switch (e) {
        .unknown, .text, .bytea, .timetz => return z,
        .boolean => {
            const b = @import("funcs.zig").parseBool(t) orelse return invalid(a, e, z, fail);
            return if (b) "t" else "f";
        },
        .int2, .int4, .int8 => {
            const v = std.fmt.parseInt(i64, t, 10) catch |err| switch (err) {
                error.Overflow => return outOfRange(a, e, z, fail),
                else => return invalid(a, e, z, fail),
            };
            const ok = switch (e) {
                .int2 => std.math.cast(i16, v) != null,
                .int4 => std.math.cast(i32, v) != null,
                else => true,
            };
            if (!ok) return outOfRange(a, e, z, fail);
            return std.fmt.allocPrint(a, "{d}", .{v});
        },
        .float4, .float8 => {
            const v = parseFloat(t) orelse return invalid(a, e, z, fail);
            var buf: [64]u8 = undefined;
            return a.dupe(u8, floatText(&buf, v, e == .float4));
        },
        .numeric => return numericIn(a, t) orelse return invalid(a, e, z, fail),
        .uuid => {
            var hex: [32]u8 = undefined;
            var n: usize = 0;
            var s = t;
            if (s.len >= 2 and s[0] == '{' and s[s.len - 1] == '}') s = s[1 .. s.len - 1];
            for (s, 0..) |c, k| {
                if (c == '-' and k > 0 and k + 1 < s.len and n % 4 == 0 and s[k - 1] != '-') continue;
                if (!std.ascii.isHex(c) or n == 32) return invalid(a, e, z, fail);
                hex[n] = std.ascii.toLower(c);
                n += 1;
            }
            if (n != 32) return invalid(a, e, z, fail);
            return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
        },
        .json => {
            _ = json.parse(a, z, false) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(a, e, z, fail),
            };
            return z;
        },
        .jsonb => {
            const v = json.parseJsonb(a, z) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(a, e, z, fail),
            };
            return json.toText(a, v, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(a, e, z, fail),
            };
        },
        .date, .time, .timestamp, .timestamptz, .interval => {
            var buf: datetime.Buf = undefined;
            const out = dateIn(e, t, &buf) catch |err| {
                fail.state = if (err == error.Syntax) "22007" else "22008";
                fail.msg = if (err == error.Syntax)
                    try std.fmt.allocPrint(a, "invalid input syntax for type {s}: \"{s}\"", .{ e.typeName(), z })
                else
                    try std.fmt.allocPrint(a, "date/time field value out of range: \"{s}\"", .{z});
                return error.Invalid;
            };
            return a.dupe(u8, out);
        },
    }
}

fn dateIn(e: Elem, t: []const u8, buf: *datetime.Buf) datetime.Error![]const u8 {
    return switch (e) {
        .date => datetime.formatDate(try datetime.parseDate(t), buf),
        .time => datetime.formatTime(try datetime.parseTime(t), buf),
        .timestamp => datetime.formatTimestamp(try datetime.parseTimestamp(t, false), buf),
        .timestamptz => datetime.formatTimestamp(try datetime.parseTimestamp(t, true), buf),
        .interval => datetime.formatInterval(try datetime.parseInterval(t), buf),
        else => unreachable,
    };
}

fn invalid(a: Allocator, e: Elem, z: []const u8, fail: *Fail) ElemError {
    fail.* = .{ .state = "22P02", .msg = try std.fmt.allocPrint(a, "invalid input syntax for type {s}: \"{s}\"", .{ e.typeName(), z }) };
    return error.Invalid;
}

fn outOfRange(a: Allocator, e: Elem, z: []const u8, fail: *Fail) ElemError {
    fail.* = .{ .state = "22003", .msg = try std.fmt.allocPrint(a, "value \"{s}\" is out of range for type {s}", .{ z, e.typeName() }) };
    return error.Invalid;
}

pub fn parseFloat(z: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(z, "nan")) return std.math.nan(f64);
    if (std.ascii.eqlIgnoreCase(z, "infinity") or std.ascii.eqlIgnoreCase(z, "inf") or std.ascii.eqlIgnoreCase(z, "+infinity")) return std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(z, "-infinity") or std.ascii.eqlIgnoreCase(z, "-inf")) return -std.math.inf(f64);
    if (z.len == 0) return null;
    for (z) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '-' or c == '+')) return null;
    return std.fmt.parseFloat(f64, z) catch null;
}

/// PostgreSQL's text of a double (of a real if `real`): float8out()'s.
pub fn floatText(buf: *[64]u8, v: f64, real: bool) []const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isInf(v)) return if (v > 0) "Infinity" else "-Infinity";
    if (v == 0) return if (std.math.signbit(v)) "-0" else "0";
    return @import("jfuncs.zig").floatText(buf[0..48], v, real);
}

/// numeric_in()'s value of `t` as numeric_out() writes it: the scale as
/// written once the exponent moved the point (`1.50`, `1e2` is `100`,
/// `.5` is `0.5`), without leading zeros; null if it is no number.
pub fn numericIn(a: Allocator, t: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(t, "nan")) return "NaN";
    var i: usize = 0;
    var neg = false;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) {
        neg = t[i] == '-';
        i += 1;
    }
    var digits: std.ArrayList(u8) = .empty;
    var point: ?usize = null;
    var n: usize = 0;
    while (i < t.len and (std.ascii.isDigit(t[i]) or (t[i] == '.' and point == null))) : (i += 1) {
        if (t[i] == '.') {
            point = digits.items.len;
            continue;
        }
        digits.append(a, t[i]) catch return null;
        n += 1;
    }
    if (n == 0) return null;
    var exp: i64 = 0;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        const start = i;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        exp = std.fmt.parseInt(i64, t[start..i], 10) catch return null;
        if (@abs(exp) > 1000) return null;
    }
    if (i != t.len) return null;
    // The digits and where the point goes.
    const d = digits.items;
    const int_len: i64 = @as(i64, @intCast(point orelse d.len)) + exp;
    var frac: i64 = @as(i64, @intCast(d.len)) - int_len;
    if (frac < 0) frac = 0;
    var out: std.ArrayList(u8) = .empty;
    if (neg) out.append(a, '-') catch return null;
    if (int_len <= 0) {
        out.append(a, '0') catch return null;
    } else {
        var k: usize = 0;
        // Leading zeros.
        while (k + 1 < @as(usize, @intCast(int_len)) and k < d.len and d[k] == '0') k += 1;
        while (k < @as(usize, @intCast(int_len))) : (k += 1) out.append(a, if (k < d.len) d[k] else '0') catch return null;
    }
    if (frac > 0) {
        out.append(a, '.') catch return null;
        var k: i64 = int_len;
        while (k < @as(i64, @intCast(d.len))) : (k += 1) out.append(a, if (k < 0) '0' else d[@intCast(k)]) catch return null;
    }
    // -0 is 0.
    var zero = true;
    for (out.items) |c| if (c != '-' and c != '0' and c != '.') {
        zero = false;
    };
    if (zero and neg) return out.items[1..];
    return out.items;
}

/// A value of SQLite of an element.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    text: []const u8,
};

/// The SQLite value of element `z` (not NULL) of type `e`: a boolean 1
/// or 0, an integer, a double, a numeric's number; else the text. Of a
/// type not known, an integer if the text is one as an integer writes
/// it, else the text.
pub fn elemValue(e: Elem, z: []const u8) Value {
    switch (e) {
        .boolean => if (@import("funcs.zig").parseBool(std.mem.trim(u8, z, " "))) |b| return .{ .int = @intFromBool(b) },
        .int2, .int4, .int8 => if (std.fmt.parseInt(i64, std.mem.trim(u8, z, " "), 10)) |v| return .{ .int = v } else |_| {},
        .float4, .float8 => if (parseFloat(std.mem.trim(u8, z, " "))) |v| return .{ .float = v },
        .numeric => {
            const t = std.mem.trim(u8, z, " ");
            if (std.mem.indexOfAny(u8, t, ".eE") == null) {
                if (std.fmt.parseInt(i64, t, 10)) |v| return .{ .int = v } else |_| {}
            }
            if (parseFloat(t)) |v| return .{ .float = v };
        },
        .unknown => if (canonicalInt(z)) |v| return .{ .int = v },
        else => {},
    }
    return .{ .text = z };
}

/// The integer `z` is if it is written as an integer is written.
fn canonicalInt(z: []const u8) ?i64 {
    if (z.len == 0 or z.len > 19) return null;
    const digits = if (z[0] == '-') z[1..] else z;
    if (digits.len == 0 or (digits[0] == '0' and digits.len > 1)) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, z, 10) catch null;
}

fn resultElem(ctx: *Context, e: Elem, z: ?[]const u8) void {
    const t = z orelse return api.resultNull(ctx);
    switch (elemValue(e, t)) {
        .null => api.resultNull(ctx),
        .int => |v| api.resultInt64(ctx, v),
        .float => |v| api.resultDouble(ctx, v),
        .text => |s| api.resultText(ctx, s, .transient),
    }
}

/// The text of SQLite value `m` as an element of `c`; null for NULL;
/// error.Invalid with `fail` set if the type does not read it.
pub fn valueElem(a: Allocator, c: Code, m: *Mem, fail: *Fail) ElemError!?[]const u8 {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return null,
        vi.SQLITE_INTEGER => {
            const v = api.valueInt64(m);
            switch (c.elem) {
                .boolean => return if (v != 0) "t" else "f",
                .float4, .float8 => {
                    var buf: [64]u8 = undefined;
                    return try a.dupe(u8, floatText(&buf, @floatFromInt(v), c.elem == .float4));
                },
                .numeric => if (c.scale) |s| if (s > 0) {
                    return try std.fmt.allocPrint(a, "{d}.{s}", .{ v, zeros(s) });
                },
                else => {},
            }
            return try std.fmt.allocPrint(a, "{d}", .{v});
        },
        vi.SQLITE_FLOAT => {
            const v = api.valueDouble(m);
            switch (c.elem) {
                .int2, .int4, .int8 => return try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@round(std.math.clamp(v, -9.2e18, 9.2e18))))}),
                .boolean => return if (v != 0) "t" else "f",
                .numeric => {
                    if (c.scale) |s| return try std.fmt.allocPrint(a, "{d:.[1]}", .{ v, s });
                    var buf: [64]u8 = undefined;
                    const z = floatText(&buf, v, false);
                    if (std.mem.indexOfScalar(u8, z, 'e') == null) return try a.dupe(u8, z);
                    return try std.fmt.allocPrint(a, "{d}", .{v});
                },
                else => {
                    var buf: [64]u8 = undefined;
                    return try a.dupe(u8, floatText(&buf, v, c.elem == .float4));
                },
            }
        },
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse "";
            // A jsonb value stored as JSONB: its text.
            if (c.elem == .jsonb and jsonb_bin.valid(b)) return json.blobText(a, b) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(a, c.elem, "", fail),
            };
            return try std.fmt.allocPrint(a, "\\x{x}", .{b});
        },
        else => {
            const z = api.valueText(m) orelse return error.OutOfMemory;
            return try elemIn(a, c.elem, z, fail);
        },
    }
}

fn zeros(n: u8) []const u8 {
    const z: [256]u8 = @splat('0');
    return z[0..n];
}

/// The order of elements `x` and `y` (not NULL) of type `e`: numbers by
/// value, intervals as interval's order, the others by their text.
pub fn compareElems(e: Elem, x: []const u8, y: []const u8) std.math.Order {
    switch (e) {
        .int2, .int4, .int8, .float4, .float8, .numeric => if (compareNumbers(x, y)) |o| return o,
        .interval => return datetime.collateInterval(null, x, y),
        .unknown => if (compareNumbers(x, y)) |o| return o,
        else => {},
    }
    return simd.order(x, y);
}

fn compareNumbers(x: []const u8, y: []const u8) ?std.math.Order {
    const tx = std.mem.trim(u8, x, " ");
    const ty = std.mem.trim(u8, y, " ");
    if (std.fmt.parseInt(i64, tx, 10)) |a| {
        if (std.fmt.parseInt(i64, ty, 10)) |b| return std.math.order(a, b) else |_| {}
    } else |_| {}
    const a = parseFloat(tx) orelse return null;
    const b = parseFloat(ty) orelse return null;
    // NaN is above every number, as in PostgreSQL.
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.order(@intFromBool(std.math.isNan(a)), @intFromBool(std.math.isNan(b)));
    return std.math.order(a, b);
}

/// The order of value `m` (not NULL) and element `z` of type `e` (`c`),
/// or error.Invalid if the element type does not read `m`. Of a type not
/// known: a number with the number the element reads as (a boolean's
/// t/f as 1/0), numbers before text; text with the element's text.
fn compareValue(a: Allocator, c: Code, m: *Mem, z: []const u8, fail: *Fail) ElemError!std.math.Order {
    if (c.elem == .unknown) {
        switch (api.valueType(m)) {
            vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => {
                const v = api.valueDouble(m);
                const t = std.mem.trim(u8, z, " ");
                if (std.fmt.parseInt(i64, t, 10)) |w| {
                    if (api.valueType(m) == vi.SQLITE_INTEGER) return std.math.order(api.valueInt64(m), w);
                    return std.math.order(v, @as(f64, @floatFromInt(w)));
                } else |_| {}
                if (parseFloat(t)) |w| return std.math.order(v, w);
                if (std.mem.eql(u8, t, "t")) return std.math.order(v, 1);
                if (std.mem.eql(u8, t, "f")) return std.math.order(v, 0);
                return .lt;
            },
            else => {},
        }
        const x = api.valueText(m) orelse return error.OutOfMemory;
        return simd.order(x, z);
    }
    const x = (try valueElem(a, c, m, fail)).?;
    return compareElems(c.elem, x, z);
}

// ================================================================ calls

/// The arena of a call.
const Call = struct {
    arena: std.heap.ArenaAllocator,
    ctx: *Context,

    pub fn init(ctx: *Context) Call {
        return .{ .arena = .init(dfunc.gpa(ctx)), .ctx = ctx };
    }

    pub fn deinit(c: *Call) void {
        c.arena.deinit();
    }

    fn a(c: *Call) Allocator {
        return c.arena.allocator();
    }

    fn text(c: *Call, m: *Mem) ?[]const u8 {
        return dfunc.text(c.ctx, m);
    }

    fn oom(c: *Call) void {
        api.resultErrorNomem(c.ctx);
    }

    /// Array argument `m` (not NULL); null after making the error the
    /// result.
    fn array(c: *Call, m: *Mem) ?Array {
        const z = c.text(m) orelse return null;
        var detail: ?[]const u8 = null;
        return parseWith(c.a(), z, true, &detail) catch |err| {
            if (err == error.OutOfMemory) c.oom() else c.malformed(z, detail);
            return null;
        };
    }

    fn malformed(c: *Call, z: []const u8, detail: ?[]const u8) void {
        malformedError(c.ctx, c.a(), z, detail);
    }

    fn errFmt(c: *Call, comptime st: *const [5]u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(c.a(), fmt, args) catch return c.oom();
        api.resultErrorState(c.ctx, .of(st), msg);
    }

    fn failed(c: *Call, err: ElemError, fail: Fail) void {
        switch (err) {
            error.OutOfMemory => c.oom(),
            error.Invalid => api.resultErrorState(c.ctx, .{ .sqlstate = fail.state.* }, fail.msg),
        }
    }

    fn result(c: *Call, x: *const Array) void {
        const z = write(c.a(), x) catch return c.oom();
        api.resultText(c.ctx, z, .transient);
    }
};

fn inArena(comptime f: fn (*Call, []*Mem) void) dfunc.StepFn {
    return dfunc.withArena(Call, f);
}

const det: dfunc.Options = .{ .deterministic = true };

fn sf(name: [:0]const u8, n: i16, f: dfunc.StepFn) FuncDef {
    return dfunc.scalar(name, n, det, f);
}

fn codeArg(m: *Mem) Code {
    return Code.decode(api.valueInt64(m));
}

/// The input of an array of `e` (a cast, the store into a column): text
/// read as array_in() reads it, each element by `e`'s input, written
/// back canonical. Another value is no array literal.
fn arrayIn(c: *Call, argv: []*Mem, comptime e: Elem) void {
    const m = argv[0];
    if (isNull(m)) return api.resultNull(c.ctx);
    const z = c.text(m) orelse return;
    var detail: ?[]const u8 = null;
    if (api.valueType(m) != vi.SQLITE_TEXT) {
        _ = parseWith(c.a(), z, false, &detail) catch {};
        return c.malformed(z, detail);
    }
    var x = parseWith(c.a(), z, false, &detail) catch |err| return if (err == error.OutOfMemory) c.oom() else c.malformed(z, detail);
    if (e != .unknown) {
        var fail: Fail = undefined;
        for (x.elems) |*el| if (el.*) |t| {
            el.* = elemIn(c.a(), e, t, &fail) catch |err| return c.failed(err, fail);
        };
    }
    _ = &x;
    c.result(&x);
}

/// xq_pg_array_<elem>(x) for each element type, by Elem.
pub const input_functions = blk: {
    var defs: [n_elems]FuncDef = undefined;
    for (std.enums.values(Elem), 0..) |e, i| {
        defs[i] = sf("xq_pg_array_" ++ e.suffix(), 1, dfunc.withArena(Call, struct {
            fn f(c: *Call, argv: []*Mem) void {
                arrayIn(c, argv, e);
            }
        }.f));
    }
    break :blk defs;
};

/// The input function of arrays of `l` (Rules.store, casts).
pub fn inputFunction(l: Logical) *const FuncDef {
    return &input_functions[@backingInt(Elem.of(l))];
}

/// The name of the input function of arrays of `l`.
pub fn inputName(l: Logical) [:0]const u8 {
    return inputFunction(l).name;
}

/// The element type of input function `name` (xq_pg_array_int4), null
/// for another name.
pub fn inputElem(name: []const u8) ?Elem {
    for (std.enums.values(Elem)) |e| {
        if (std.mem.eql(u8, name, input_functions[@backingInt(e)].name)) return e;
    }
    return null;
}

/// The CHECK of an array column: NULL or a text array_in() reads.
fn validFunc(c: *Call, argv: []*Mem) void {
    const m = argv[0];
    if (isNull(m)) return api.resultInt64(c.ctx, 1);
    if (api.valueType(m) != vi.SQLITE_TEXT) return api.resultInt64(c.ctx, 0);
    const z = c.text(m) orelse return;
    _ = parse(c.a(), z, false) catch |err| return if (err == error.OutOfMemory) c.oom() else api.resultInt64(c.ctx, 0);
    api.resultInt64(c.ctx, 1);
}

/// xq_pg_elem(x, code): x as the text of an element.
fn elemFunc(c: *Call, argv: []*Mem) void {
    var fail: Fail = undefined;
    const z = valueElem(c.a(), codeArg(argv[1]), argv[0], &fail) catch |err| return c.failed(err, fail);
    if (z) |t| api.resultText(c.ctx, t, .transient) else api.resultNull(c.ctx);
}

/// ARRAY[v, ...]: of NULL, numbers and text, as elements of no known
/// type (overload.zig wraps a value of a type in xq_pg_elem()).
fn makeFunc(c: *Call, argv: []*Mem) void {
    const elems = c.a().alloc(?[]const u8, argv.len) catch return c.oom();
    var fail: Fail = undefined;
    for (argv, elems) |m, *e| e.* = valueElem(c.a(), .{}, m, &fail) catch |err| return c.failed(err, fail);
    c.result(&Array.list(elems));
}

/// ARRAY[a, b ...] of arrays: an array of a dimension more; NULLs and
/// empty arrays are left out (the others must be of one shape).
fn nestedFunc(c: *Call, argv: []*Mem) void {
    var out: std.ArrayList(?[]const u8) = .empty;
    var shape: ?Array = null;
    var n: u32 = 0;
    for (argv) |m| {
        if (isNull(m)) continue;
        const x = c.array(m) orelse return;
        if (x.count() == 0) continue;
        if (shape) |sh| {
            if (sh.ndim != x.ndim or !std.mem.eql(u32, sh.dims[0..sh.ndim], x.dims[0..x.ndim])) {
                return api.resultErrorState(c.ctx, .of("2202E"), "multidimensional arrays must have array expressions with matching dimensions");
            }
        } else shape = x;
        out.appendSlice(c.a(), x.elems) catch return c.oom();
        n += 1;
    }
    const sh = shape orelse return api.resultText(c.ctx, "{}", .static);
    if (sh.ndim == max_dims) return api.resultErrorState(c.ctx, .of("54000"), "number of array dimensions (7) exceeds the maximum allowed (6)");
    var x: Array = .{ .ndim = sh.ndim + 1, .elems = out.items };
    x.dims[0] = n;
    for (0..sh.ndim) |d| {
        x.dims[d + 1] = sh.dims[d];
        x.lower[d + 1] = sh.lower[d];
    }
    c.result(&x);
}

/// The operators of xq_pg_any()'s `op`.
pub const AnyOp = enum(u8) {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    like,
    not_like,
    ilike,
    not_ilike,
};

/// xq_pg_any(x, a, op, all [, code]): `x op ANY (a)` (or ALL): true if
/// the comparison is true for one element (false for all), else NULL if
/// one was NULL, else false (true). NULL if `a` is.
fn anyFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[1])) return api.resultNull(c.ctx);
    const x = c.array(argv[1]) orelse return;
    const op: AnyOp = std.enums.fromInt(AnyOp, api.valueInt64(argv[2])) orelse .eq;
    const all = api.valueInt64(argv[3]) != 0;
    const code: Code = if (argv.len > 4) codeArg(argv[4]) else .{};
    var nulls = false;
    var fail: Fail = undefined;
    const m = argv[0];
    for (x.elems) |e| {
        const t = e orelse {
            nulls = true;
            continue;
        };
        if (isNull(m)) {
            nulls = true;
            continue;
        }
        const r: bool = switch (op) {
            .like, .not_like, .ilike, .not_ilike => blk: {
                const v = c.text(m) orelse return;
                const hit = like.likeMatch(t, v, '\\', op == .ilike or op == .not_ilike) catch
                    return api.resultErrorState(c.ctx, .of("22025"), "LIKE pattern must not end with escape character");
                break :blk hit != (op == .not_like or op == .not_ilike);
            },
            else => blk: {
                const o = compareValue(c.a(), code, m, t, &fail) catch |err| return c.failed(err, fail);
                break :blk switch (op) {
                    .eq => o == .eq,
                    .ne => o != .eq,
                    .lt => o == .lt,
                    .le => o != .gt,
                    .gt => o == .gt,
                    .ge => o != .lt,
                    else => unreachable,
                };
            },
        };
        if (r and !all) return api.resultInt64(c.ctx, 1);
        if (!r and all) return api.resultInt64(c.ctx, 0);
    }
    if (nulls) return api.resultNull(c.ctx);
    api.resultInt64(c.ctx, @intFromBool(all));
}

/// The offset in `x.elems` of the element at subscripts `subs` (one per
/// dimension), null if out of range.
fn offsetOf(x: *const Array, subs: []const i64) ?usize {
    if (subs.len != x.ndim or x.ndim == 0) return null;
    var off: usize = 0;
    for (subs, 0..) |i, d| {
        const k = std.math.sub(i64, i, x.lower[d]) catch return null;
        if (k < 0 or k >= x.dims[d]) return null;
        off = off * x.dims[d] + @as(usize, @intCast(k));
    }
    return off;
}

/// xq_pg_subscript(a, i, ...) and xq_pg_subscript_k(a, i, ..., code):
/// a[i][j]; NULL out of range or with fewer subscripts than dimensions.
fn subscriptFunc(c: *Call, argv: []*Mem, comptime typed: bool) void {
    const n = if (typed) argv.len - 1 else argv.len;
    const e: Elem = if (typed) codeArg(argv[argv.len - 1]).elem else .unknown;
    for (argv[0..n]) |m| if (isNull(m)) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    var subs: [max_dims]i64 = undefined;
    if (n - 1 > max_dims) return api.resultErrorState(c.ctx, .of("54000"), "number of array dimensions exceeds the maximum allowed (6)");
    for (argv[1..n], 0..) |m, i| subs[i] = api.valueInt64(m);
    const off = offsetOf(&x, subs[0 .. n - 1]) orelse return api.resultNull(c.ctx);
    resultElem(c.ctx, e, x.elems[off]);
}

/// xq_pg_slice(a, lo, hi, ...): a[lo:hi][lo:hi], each NULL bound the
/// array's own; the part of each dimension in range, from 1; empty if
/// none is.
fn sliceFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    const nb = (argv.len - 1) / 2;
    if (x.ndim == 0 or nb > x.ndim) return api.resultText(c.ctx, "{}", .static);
    var lo: [max_dims]i64 = undefined;
    var hi: [max_dims]i64 = undefined;
    for (0..x.ndim) |d| {
        lo[d] = x.lower[d];
        hi[d] = x.upper(d);
        if (d < nb) {
            const ml = argv[1 + 2 * d];
            const mh = argv[2 + 2 * d];
            if (!isNull(ml)) lo[d] = @max(lo[d], api.valueInt64(ml));
            if (!isNull(mh)) hi[d] = @min(hi[d], api.valueInt64(mh));
        }
        if (lo[d] > hi[d]) return api.resultText(c.ctx, "{}", .static);
    }
    var out: std.ArrayList(?[]const u8) = .empty;
    var r: Array = .{ .ndim = x.ndim };
    for (0..x.ndim) |d| r.dims[d] = @intCast(hi[d] - lo[d] + 1);
    // Every subscript of the slice, in order.
    var idx: [max_dims]i64 = undefined;
    for (0..x.ndim) |d| idx[d] = lo[d];
    while (true) {
        out.append(c.a(), x.elems[offsetOf(&x, idx[0..x.ndim]).?]) catch return c.oom();
        var d: usize = x.ndim;
        while (d > 0) {
            d -= 1;
            idx[d] += 1;
            if (idx[d] <= hi[d]) break;
            idx[d] = lo[d];
            if (d == 0) {
                r.elems = out.items;
                return c.result(&r);
            }
        }
    }
}

/// xq_pg_array_set(a, v, i, ...): `a[i][j] = v` of UPDATE: `a` with that
/// element `v`. A one-dimensional array (or NULL, or empty) grows to
/// take it, NULLs between; another must have the element.
fn setFunc(c: *Call, argv: []*Mem) void {
    for (argv[2..]) |m| if (isNull(m)) return api.resultErrorState(c.ctx, .of("22004"), "array subscript in assignment must not be null");
    const n = argv.len - 2;
    var fail: Fail = undefined;
    const v = valueElem(c.a(), .{}, argv[1], &fail) catch |err| return c.failed(err, fail);
    var x: Array = if (isNull(argv[0])) .{} else c.array(argv[0]) orelse return;
    if (x.count() == 0) {
        var subs: [max_dims]i64 = undefined;
        if (n > max_dims) return api.resultErrorState(c.ctx, .of("54000"), "number of array dimensions exceeds the maximum allowed (6)");
        for (argv[2..], 0..) |m, i| subs[i] = api.valueInt64(m);
        var r: Array = .{ .ndim = @intCast(n) };
        for (0..n) |d| {
            r.dims[d] = 1;
            r.lower[d] = std.math.cast(i32, subs[d]) orelse return api.resultErrorState(c.ctx, .of("2202E"), "array subscript out of range");
        }
        const one = c.a().alloc(?[]const u8, 1) catch return c.oom();
        one[0] = v;
        r.elems = one;
        return c.result(&r);
    }
    if (n != x.ndim) return api.resultErrorState(c.ctx, .of("2202E"), "wrong number of array subscripts");
    var subs: [max_dims]i64 = undefined;
    for (argv[2..], 0..) |m, i| subs[i] = api.valueInt64(m);
    if (offsetOf(&x, subs[0..n])) |off| {
        const elems = c.a().dupe(?[]const u8, x.elems) catch return c.oom();
        elems[off] = v;
        x.elems = elems;
        return c.result(&x);
    }
    if (x.ndim != 1) return api.resultErrorState(c.ctx, .of("2202E"), "array subscript out of range");
    const i = subs[0];
    const lo: i64 = @min(i, x.lower[0]);
    const hi: i64 = @max(i, x.upper(0));
    // PostgreSQL's MaxArraySize.
    const span: i128 = @as(i128, hi) - lo + 1;
    if (span > 134217727) return api.resultErrorState(c.ctx, .of("54000"), "array size exceeds the maximum allowed (134217727)");
    const len: usize = @intCast(span);
    const elems = c.a().alloc(?[]const u8, len) catch return c.oom();
    @memset(elems, null);
    const start: usize = @intCast(x.lower[0] - lo);
    @memcpy(elems[start..][0..x.elems.len], x.elems);
    elems[@intCast(i - lo)] = v;
    x.elems = elems;
    x.dims[0] = @intCast(len);
    x.lower[0] = std.math.cast(i32, lo) orelse return api.resultErrorState(c.ctx, .of("2202E"), "array subscript out of range");
    c.result(&x);
}

/// a || b of two arrays (array_cat()): of the same dimensions, or one of
/// a dimension less (an element of the other's first dimension).
fn catArrays(c: *Call, x: *const Array, y: *const Array) ?Array {
    if (x.count() == 0) return y.*;
    if (y.count() == 0) return x.*;
    const elems = std.mem.concat(c.a(), ?[]const u8, &.{ x.elems, y.elems }) catch {
        c.oom();
        return null;
    };
    var r = x.*;
    r.elems = elems;
    if (x.ndim == y.ndim) {
        if (!std.mem.eql(u32, x.dims[1..x.ndim], y.dims[1..y.ndim])) {
            c.errFmt("2202E", "cannot concatenate incompatible arrays", .{});
            return null;
        }
        r.dims[0] = x.dims[0] + y.dims[0];
    } else if (x.ndim == y.ndim + 1 and std.mem.eql(u32, x.dims[1..x.ndim], y.dims[0..y.ndim])) {
        r.dims[0] = x.dims[0] + 1;
    } else if (y.ndim == x.ndim + 1 and std.mem.eql(u32, y.dims[1..y.ndim], x.dims[0..x.ndim])) {
        r = y.*;
        r.elems = elems;
        r.dims[0] = y.dims[0] + 1;
    } else {
        c.errFmt("2202E", "cannot concatenate incompatible arrays", .{});
        return null;
    }
    return r;
}

fn catFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) and isNull(argv[1])) return api.resultNull(c.ctx);
    if (isNull(argv[0])) return api.resultValue(c.ctx, argv[1]);
    if (isNull(argv[1])) return api.resultValue(c.ctx, argv[0]);
    const x = c.array(argv[0]) orelse return;
    const y = c.array(argv[1]) orelse return;
    const r = catArrays(c, &x, &y) orelse return;
    c.result(&r);
}

/// array_append(a, x) (`prepend`: array_prepend(x, a)) of a
/// one-dimensional array.
fn appendFunc(c: *Call, argv: []*Mem, comptime prepend: bool) void {
    const am = if (prepend) argv[1] else argv[0];
    const vm = if (prepend) argv[0] else argv[1];
    var x: Array = if (isNull(am)) .{} else c.array(am) orelse return;
    if (x.ndim > 1) return api.resultErrorState(c.ctx, .of("2202E"), "argument must be empty or one-dimensional array");
    var fail: Fail = undefined;
    const v = valueElem(c.a(), .{}, vm, &fail) catch |err| return c.failed(err, fail);
    const one = [_]?[]const u8{v};
    const elems = std.mem.concat(c.a(), ?[]const u8, if (prepend) &.{ &one, x.elems } else &.{ x.elems, &one }) catch return c.oom();
    if (x.ndim == 0) {
        x = Array.list(elems);
    } else {
        x.elems = elems;
        x.dims[0] += 1;
    }
    c.result(&x);
}

/// Whether element `e` equals value `m` (both not NULL), as `=` of a
/// type not known compares them.
fn elemEquals(c: *Call, e: []const u8, m: *Mem) ?bool {
    var fail: Fail = undefined;
    const o = compareValue(c.a(), .{}, m, e, &fail) catch |err| {
        c.failed(err, fail);
        return null;
    };
    return o == .eq;
}

/// array_remove(a, x): without the elements equal to x (IS NOT
/// DISTINCT FROM).
fn removeFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    if (x.ndim > 1) return api.resultErrorState(c.ctx, .of("0A000"), "removing elements from multidimensional arrays is not supported");
    var out: std.ArrayList(?[]const u8) = .empty;
    for (x.elems) |e| {
        const same = if (e) |t| (if (isNull(argv[1])) false else elemEquals(c, t, argv[1]) orelse return) else isNull(argv[1]);
        if (!same) out.append(c.a(), e) catch return c.oom();
    }
    var r = Array.list(out.items);
    if (x.ndim == 1 and out.items.len > 0) r.lower[0] = x.lower[0];
    c.result(&r);
}

/// array_replace(a, x, y): each element equal to x (IS NOT DISTINCT
/// FROM) replaced by y.
fn replaceFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    var x = c.array(argv[0]) orelse return;
    var fail: Fail = undefined;
    const y = valueElem(c.a(), .{}, argv[2], &fail) catch |err| return c.failed(err, fail);
    for (x.elems) |*e| {
        const same = if (e.*) |t| (if (isNull(argv[1])) false else elemEquals(c, t, argv[1]) orelse return) else isNull(argv[1]);
        if (same) e.* = y;
    }
    c.result(&x);
}

/// array_position(a, x [, start]) and array_positions(a, x).
fn positionFunc(c: *Call, argv: []*Mem, comptime all: bool) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    if (x.ndim > 1) return api.resultErrorState(c.ctx, .of("0A000"), "searching for elements in multidimensional arrays is not supported");
    var start: i64 = if (x.ndim == 1) x.lower[0] else 1;
    if (!all and argv.len > 2) {
        if (isNull(argv[2])) return api.resultErrorState(c.ctx, .of("22004"), "initial position must not be null");
        start = api.valueInt64(argv[2]);
    }
    var out: std.ArrayList(?[]const u8) = .empty;
    for (x.elems, 0..) |e, k| {
        const pos = @as(i64, if (x.ndim == 1) x.lower[0] else 1) + @as(i64, @intCast(k));
        if (pos < start) continue;
        const same = if (e) |t| (if (isNull(argv[1])) false else elemEquals(c, t, argv[1]) orelse return) else isNull(argv[1]);
        if (!same) continue;
        if (!all) return api.resultInt64(c.ctx, pos);
        out.append(c.a(), std.fmt.allocPrint(c.a(), "{d}", .{pos}) catch return c.oom()) catch return c.oom();
    }
    if (!all) return api.resultNull(c.ctx);
    c.result(&Array.list(out.items));
}

/// a @> b: every element of b (not NULL) equals one of a.
fn containsFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    const y = c.array(argv[1]) orelse return;
    api.resultInt64(c.ctx, @intFromBool(containsAll(&x, &y)));
}

fn containsAll(x: *const Array, y: *const Array) bool {
    outer: for (y.elems) |e| {
        const t = e orelse return false;
        for (x.elems) |f| if (f) |u| if (compareElems(.unknown, t, u) == .eq) continue :outer;
        return false;
    }
    return true;
}

/// a && b: an element (not NULL) in both.
fn overlapFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    const y = c.array(argv[1]) orelse return;
    for (y.elems) |e| if (e) |t| for (x.elems) |f| if (f) |u| if (compareElems(.unknown, t, u) == .eq) return api.resultInt64(c.ctx, 1);
    api.resultInt64(c.ctx, 0);
}

/// array_length(a, d), array_lower(), array_upper(): NULL for a
/// dimension it does not have.
fn dimFunc(c: *Call, argv: []*Mem, comptime what: enum { length, lower, upper }) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    const d = api.valueInt64(argv[1]);
    if (d < 1 or d > x.ndim) return api.resultNull(c.ctx);
    const k: usize = @intCast(d - 1);
    api.resultInt64(c.ctx, switch (what) {
        .length => x.dims[k],
        .lower => x.lower[k],
        .upper => x.upper(k),
    });
}

fn ndimsFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    if (x.ndim == 0) return api.resultNull(c.ctx);
    api.resultInt64(c.ctx, x.ndim);
}

fn cardinalityFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    api.resultInt64(c.ctx, @intCast(x.count()));
}

/// array_dims(a): `[1:2][1:3]`, NULL if empty.
fn dimsFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    if (x.ndim == 0) return api.resultNull(c.ctx);
    var out: std.ArrayList(u8) = .empty;
    for (0..x.ndim) |d| out.print(c.a(), "[{d}:{d}]", .{ x.lower[d], x.upper(d) }) catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

/// array_to_string(a, sep [, null]): the elements (of every dimension)
/// with `sep` between; NULLs left out, or `null`'s text.
fn toStringFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(c.ctx);
    const x = c.array(argv[0]) orelse return;
    const sep = c.text(argv[1]) orelse return;
    const null_text: ?[]const u8 = if (argv.len > 2 and !isNull(argv[2])) c.text(argv[2]) orelse return else null;
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (x.elems) |e| {
        const v = e orelse null_text orelse continue;
        if (!first) out.appendSlice(c.a(), sep) catch return c.oom();
        first = false;
        out.appendSlice(c.a(), v) catch return c.oom();
    }
    api.resultText(c.ctx, out.items, .transient);
}

/// string_to_array(s, sep [, null]): a text[]; a NULL separator splits
/// into characters, an empty one gives the whole string.
fn stringToArrayFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const z = c.text(argv[0]) orelse return;
    const null_text: ?[]const u8 = if (argv.len > 2 and !isNull(argv[2])) c.text(argv[2]) orelse return else null;
    var out: std.ArrayList(?[]const u8) = .empty;
    if (z.len > 0) {
        if (isNull(argv[1])) {
            var i: usize = 0;
            while (i < z.len) {
                const j = dfunc.nextChar(z, i);
                out.append(c.a(), z[i..j]) catch return c.oom();
                i = j;
            }
        } else {
            const sep = c.text(argv[1]) orelse return;
            if (sep.len == 0) {
                out.append(c.a(), z) catch return c.oom();
            } else {
                var it = std.mem.splitSequence(u8, z, sep);
                while (it.next()) |part| out.append(c.a(), part) catch return c.oom();
            }
        }
    }
    if (null_text) |n| for (out.items) |*e| if (e.*) |t| if (std.mem.eql(u8, t, n)) {
        e.* = null;
    };
    c.result(&Array.list(out.items));
}

// ============================================================ aggregates

/// The state of array_agg(): the elements' texts (in a buffer of the
/// connection's allocator, each preceded by its length, -1 for NULL),
/// their number and, of arrays, the shape of the first.
const Agg = struct {
    buf: ?*std.ArrayList(u8),
    n: u64,
    ndim: usize,
    dims: [max_dims]u32,
    lower: [max_dims]i32,
};

fn aggBuf(ctx: *Context, st: *Agg) ?*std.ArrayList(u8) {
    if (st.buf) |b| return b;
    const b = dfunc.gpa(ctx).create(std.ArrayList(u8)) catch {
        api.resultErrorNomem(ctx);
        return null;
    };
    b.* = .empty;
    st.buf = b;
    return b;
}

fn aggPush(ctx: *Context, st: *Agg, e: ?[]const u8) bool {
    const g = dfunc.gpa(ctx);
    const b = aggBuf(ctx, st) orelse return false;
    var len: [4]u8 = undefined;
    std.mem.writeInt(i32, &len, if (e) |t| @intCast(t.len) else -1, .little);
    b.appendSlice(g, &len) catch {
        api.resultErrorNomem(ctx);
        return false;
    };
    if (e) |t| b.appendSlice(g, t) catch {
        api.resultErrorNomem(ctx);
        return false;
    };
    return true;
}

fn aggStep(ctx: *Context, argv: []*Mem) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    var c: Call = .init(ctx);
    defer c.deinit();
    var fail: Fail = undefined;
    const e = valueElem(c.a(), .{}, argv[0], &fail) catch |err| return c.failed(err, fail);
    if (aggPush(ctx, st, e)) st.n += 1;
}

/// array_agg() of arrays: of one shape, not NULL.
fn aggArraysStep(ctx: *Context, argv: []*Mem) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    if (isNull(argv[0])) return api.resultErrorState(ctx, .of("22004"), "cannot accumulate null arrays");
    var c: Call = .init(ctx);
    defer c.deinit();
    const x = c.array(argv[0]) orelse return;
    if (x.count() == 0) return api.resultErrorState(ctx, .of("2202E"), "cannot accumulate empty arrays");
    if (st.n == 0) {
        st.ndim = x.ndim;
        st.dims = x.dims;
        st.lower = x.lower;
    } else if (st.ndim != x.ndim or !std.mem.eql(u32, st.dims[0..x.ndim], x.dims[0..x.ndim])) {
        return api.resultErrorState(ctx, .of("2202E"), "cannot accumulate arrays of different dimensionality");
    }
    if (x.ndim == max_dims) return api.resultErrorState(ctx, .of("54000"), "number of array dimensions (7) exceeds the maximum allowed (6)");
    for (x.elems) |e| if (!aggPush(ctx, st, e)) return;
    st.n += 1;
}

fn aggElems(a: Allocator, b: []const u8) error{OutOfMemory}![]?[]const u8 {
    var out: std.ArrayList(?[]const u8) = .empty;
    var i: usize = 0;
    while (i + 4 <= b.len) {
        const len = std.mem.readInt(i32, b[i..][0..4], .little);
        i += 4;
        if (len < 0) {
            try out.append(a, null);
        } else {
            const n: usize = @intCast(len);
            try out.append(a, b[i .. i + n]);
            i += n;
        }
    }
    return out.items;
}

fn aggFinalImpl(ctx: *Context, comptime arrays: bool) void {
    const st = dfunc.aggState(Agg, ctx, false) orelse return api.resultNull(ctx);
    const b = st.buf orelse return api.resultNull(ctx);
    st.buf = null;
    defer {
        b.deinit(dfunc.gpa(ctx));
        dfunc.gpa(ctx).destroy(b);
    }
    if (st.n == 0) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const elems = aggElems(c.a(), b.items) catch return c.oom();
    var x = Array.list(elems);
    if (arrays) {
        x.ndim = @intCast(st.ndim + 1);
        x.dims[0] = @intCast(st.n);
        for (0..st.ndim) |d| {
            x.dims[d + 1] = st.dims[d];
            x.lower[d + 1] = st.lower[d];
        }
    }
    c.result(&x);
}

fn aggFinal(ctx: *Context) void {
    aggFinalImpl(ctx, false);
}

/// The value of array_agg() as a window function: the elements so far,
/// kept.
fn aggValueImpl(ctx: *Context, comptime arrays: bool) void {
    const st = dfunc.aggState(Agg, ctx, false) orelse return api.resultNull(ctx);
    const b = st.buf orelse return api.resultNull(ctx);
    if (st.n == 0) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const elems = aggElems(c.a(), b.items) catch return c.oom();
    var x = Array.list(elems);
    if (arrays) {
        x.ndim = @intCast(st.ndim + 1);
        x.dims[0] = @intCast(st.n);
        for (0..st.ndim) |d| {
            x.dims[d + 1] = st.dims[d];
            x.lower[d + 1] = st.lower[d];
        }
    }
    c.result(&x);
}

fn aggValue(ctx: *Context) void {
    aggValueImpl(ctx, false);
}

fn aggArraysValue(ctx: *Context) void {
    aggValueImpl(ctx, true);
}

/// The first row of the window frame leaves: its element (of arrays, its
/// elements) off the front.
fn aggInverseImpl(ctx: *Context, comptime arrays: bool) void {
    const st = dfunc.aggState(Agg, ctx, false) orelse return;
    const b = st.buf orelse return;
    if (st.n == 0) return;
    var per: usize = 1;
    if (arrays) for (st.dims[0..st.ndim]) |d| {
        per *= d;
    };
    var i: usize = 0;
    for (0..per) |_| {
        if (i + 4 > b.items.len) break;
        const len = std.mem.readInt(i32, b.items[i..][0..4], .little);
        i += 4 + if (len > 0) @as(usize, @intCast(len)) else 0;
    }
    std.mem.copyForwards(u8, b.items[0 .. b.items.len - i], b.items[i..]);
    b.items.len -= i;
    st.n -= 1;
}

fn aggInverse(ctx: *Context, _: []*Mem) void {
    aggInverseImpl(ctx, false);
}

fn aggArraysInverse(ctx: *Context, _: []*Mem) void {
    aggInverseImpl(ctx, true);
}

fn aggArraysFinal(ctx: *Context) void {
    aggFinalImpl(ctx, true);
}

// ================================================= set-returning rows

/// Write the JSON of element `e` (of `el`) as json_each() gives it back:
/// a number, a boolean as 1/0, a string, null.
fn jsonElem(a: Allocator, out: *std.ArrayList(u8), el: Elem, e: ?[]const u8) error{OutOfMemory}!void {
    const t = e orelse return out.appendSlice(a, "null");
    switch (elemValue(el, t)) {
        .null => try out.appendSlice(a, "null"),
        .int => |v| try out.print(a, "{d}", .{v}),
        .float => |v| {
            if (!std.math.isFinite(v)) return json.writeString(a, out, t) catch error.OutOfMemory;
            var buf: [64]u8 = undefined;
            const z = floatText(&buf, v, false);
            // JSON wants a digit around the point and no "e+".
            if (std.mem.indexOfScalar(u8, z, 'e') != null) try out.print(a, "{e}", .{v}) else try out.appendSlice(a, z);
        },
        .text => |z| json.writeString(a, out, z) catch return error.OutOfMemory,
    }
}

/// xq_pg_rows_unnest(a [, code]): the elements of `a` (of every
/// dimension, in order) as a JSON array.
fn rowsUnnest(c: *Call, argv: []*Mem) void {
    const el: Elem = if (argv.len > 1) codeArg(argv[1]).elem else .unknown;
    if (isNull(argv[0])) return api.resultText(c.ctx, "[]", .static);
    const x = c.array(argv[0]) orelse return;
    var out: std.ArrayList(u8) = .empty;
    out.append(c.a(), '[') catch return c.oom();
    for (x.elems, 0..) |e, i| {
        if (i > 0) out.append(c.a(), ',') catch return c.oom();
        jsonElem(c.a(), &out, el, e) catch return c.oom();
    }
    out.append(c.a(), ']') catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

/// xq_pg_rows_subscripts(a, d, reverse): the subscripts of dimension d.
fn rowsSubscripts(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultText(c.ctx, "[]", .static);
    const x = c.array(argv[0]) orelse return;
    const d = api.valueInt64(argv[1]);
    if (d < 1 or d > x.ndim) return api.resultText(c.ctx, "[]", .static);
    const k: usize = @intCast(d - 1);
    const rev = !isNull(argv[2]) and api.valueInt64(argv[2]) != 0;
    var out: std.ArrayList(u8) = .empty;
    out.append(c.a(), '[') catch return c.oom();
    var i: u32 = 0;
    while (i < x.dims[k]) : (i += 1) {
        if (i > 0) out.append(c.a(), ',') catch return c.oom();
        const v = if (rev) x.upper(k) - i else @as(i64, x.lower[k]) + i;
        out.print(c.a(), "{d}", .{v}) catch return c.oom();
    }
    out.append(c.a(), ']') catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

/// xq_pg_rows_expand(a, record): _pg_expandarray(a)'s rows (x, n) as
/// [[x, n], ...], n from 1; of a record, each row its text `(x,n)`
/// (xq_pg_record_field() reads it).
fn rowsExpand(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultText(c.ctx, "[]", .static);
    const x = c.array(argv[0]) orelse return;
    const record = api.valueInt64(argv[1]) != 0;
    var out: std.ArrayList(u8) = .empty;
    out.append(c.a(), '[') catch return c.oom();
    for (x.elems, 0..) |e, i| {
        if (i > 0) out.append(c.a(), ',') catch return c.oom();
        if (record) {
            const t = std.fmt.allocPrint(c.a(), "({s},{d})", .{ e orelse "", i + 1 }) catch return c.oom();
            json.writeString(c.a(), &out, t) catch return c.oom();
            continue;
        }
        out.append(c.a(), '[') catch return c.oom();
        jsonElem(c.a(), &out, .unknown, e) catch return c.oom();
        out.print(c.a(), ",{d}]", .{i + 1}) catch return c.oom();
    }
    out.append(c.a(), ']') catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

/// xq_pg_record_field(r, name): field `name` of a record of
/// _pg_expandarray() (`(x,n)`, its text: x then n).
fn recordFieldFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const z = c.text(argv[0]) orelse return;
    const name = c.text(argv[1]) orelse return;
    const inner = std.mem.trim(u8, z, "()");
    const comma = std.mem.lastIndexOfScalar(u8, inner, ',') orelse return api.resultNull(c.ctx);
    const part = if (std.mem.eql(u8, name, "n")) inner[comma + 1 ..] else inner[0..comma];
    if (part.len == 0) return api.resultNull(c.ctx);
    resultElem(c.ctx, .unknown, part);
}

/// xq_pg_record(v, ...): a record's text, `(1,a)` (quoted as
/// record_out() quotes).
fn recordFunc(c: *Call, argv: []*Mem) void {
    var out: std.ArrayList(u8) = .empty;
    out.append(c.a(), '(') catch return c.oom();
    var fail: Fail = undefined;
    for (argv, 0..) |m, i| {
        if (i > 0) out.append(c.a(), ',') catch return c.oom();
        const t = (valueElem(c.a(), .{}, m, &fail) catch |err| return c.failed(err, fail)) orelse continue;
        var quote = t.len == 0;
        for (t) |ch| if (ch == '"' or ch == '\\' or ch == '(' or ch == ')' or ch == ',' or isSpace(ch)) {
            quote = true;
        };
        if (!quote) {
            out.appendSlice(c.a(), t) catch return c.oom();
            continue;
        }
        out.append(c.a(), '"') catch return c.oom();
        for (t) |ch| {
            if (ch == '"' or ch == '\\') out.append(c.a(), ch) catch return c.oom();
            out.append(c.a(), ch) catch return c.oom();
        }
        out.append(c.a(), '"') catch return c.oom();
    }
    out.append(c.a(), ')') catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

// ============================================================ collations

/// Arrays in PostgreSQL's order: element by element (NULL after every
/// value), then the shorter first; of numbers by value (`_num`), else by
/// text.
fn collateImpl(x: []const u8, y: []const u8, el: Elem) std.math.Order {
    // Small arrays in a buffer on the stack, others (or when it is too
    // small) in pages.
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    if (collateIn(fba.allocator(), x, y, el)) |o| return o else |_| {}
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    return collateIn(arena.allocator(), x, y, el) catch simd.order(x, y);
}

fn collateIn(a: Allocator, x: []const u8, y: []const u8, el: Elem) error{OutOfMemory}!std.math.Order {
    const ax = parse(a, x, true) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else simd.order(x, y);
    const ay = parse(a, y, true) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else simd.order(x, y);
    const n = @min(ax.elems.len, ay.elems.len);
    for (ax.elems[0..n], ay.elems[0..n]) |ex, ey| {
        const o: std.math.Order = if (ex == null and ey == null) .eq else if (ex == null) .gt else if (ey == null) .lt else compareElems(el, ex.?, ey.?);
        if (o != .eq) return o;
    }
    if (ax.elems.len != ay.elems.len) return std.math.order(ax.elems.len, ay.elems.len);
    if (ax.ndim != ay.ndim) return std.math.order(ax.ndim, ay.ndim);
    for (0..ax.ndim) |d| {
        if (ax.dims[d] != ay.dims[d]) return std.math.order(ax.dims[d], ay.dims[d]);
        if (ax.lower[d] != ay.lower[d]) return std.math.order(ax.lower[d], ay.lower[d]);
    }
    return .eq;
}

pub fn collateText(_: ?*anyopaque, x: []const u8, y: []const u8) std.math.Order {
    return collateImpl(x, y, .text);
}

pub fn collateNumber(_: ?*anyopaque, x: []const u8, y: []const u8) std.math.Order {
    return collateImpl(x, y, .numeric);
}

pub const collation_text = "xq_pg_array";
pub const collation_number = "xq_pg_array_num";

// ============================================================== tables

/// An aggregate that is a window function too.
fn agg(name: [:0]const u8, step: dfunc.StepFn, final: dfunc.FinalFn, value: dfunc.FinalFn, inverse: dfunc.StepFn) FuncDef {
    var d = dfunc.aggregate(name, 1, det, step, final);
    d.x_value = value;
    d.x_inverse = inverse;
    return d;
}

pub const engine_functions = input_functions ++ [_]FuncDef{
    sf("xq_pg_array_valid", 1, inArena(validFunc)),
    // ::text[] before element types (in the text of older schemas).
    sf("xq_pg_text_array", 1, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            arrayIn(c, argv, .text);
        }
    }.f)),
    sf("xq_pg_elem", 2, inArena(elemFunc)),
    sf("xq_pg_array", -1, inArena(makeFunc)),
    sf("xq_pg_array_nested", -1, inArena(nestedFunc)),
    sf("xq_pg_any", 4, inArena(anyFunc)),
    sf("xq_pg_any", 5, inArena(anyFunc)),
    sf("xq_pg_subscript", -1, dfunc.atLeast(1, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            subscriptFunc(c, argv, false);
        }
    }.f))),
    sf("xq_pg_subscript_k", -1, dfunc.atLeast(2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            subscriptFunc(c, argv, true);
        }
    }.f))),
    sf("xq_pg_slice", -1, dfunc.atLeast(1, inArena(sliceFunc))),
    sf("xq_pg_array_set", -1, dfunc.atLeast(3, inArena(setFunc))),
    sf("xq_pg_array_cat2", 2, inArena(catFunc)),
    sf("xq_pg_array_append", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            appendFunc(c, argv, false);
        }
    }.f)),
    sf("xq_pg_array_prepend", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            appendFunc(c, argv, true);
        }
    }.f)),
    sf("xq_pg_array_contains", 2, inArena(containsFunc)),
    sf("xq_pg_array_overlap", 2, inArena(overlapFunc)),
    agg("xq_pg_array_agg", aggStep, aggFinal, aggValue, aggInverse),
    agg("xq_pg_array_agg_arrays", aggArraysStep, aggArraysFinal, aggArraysValue, aggArraysInverse),
    sf("xq_pg_rows_unnest", 1, inArena(rowsUnnest)),
    sf("xq_pg_rows_unnest", 2, inArena(rowsUnnest)),
    sf("xq_pg_rows_subscripts", 3, inArena(rowsSubscripts)),
    sf("xq_pg_rows_expand", 2, inArena(rowsExpand)),
    sf("xq_pg_record_field", 2, inArena(recordFieldFunc)),
    sf("xq_pg_record", -1, inArena(recordFunc)),
};

/// The dialect's functions (PostgreSQL's names).
pub const functions = [_]FuncDef{
    sf("array_length", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            dimFunc(c, argv, .length);
        }
    }.f)),
    sf("array_lower", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            dimFunc(c, argv, .lower);
        }
    }.f)),
    sf("array_upper", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            dimFunc(c, argv, .upper);
        }
    }.f)),
    sf("array_ndims", 1, inArena(ndimsFunc)),
    sf("cardinality", 1, inArena(cardinalityFunc)),
    sf("array_dims", 1, inArena(dimsFunc)),
    sf("array_append", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            appendFunc(c, argv, false);
        }
    }.f)),
    sf("array_prepend", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            appendFunc(c, argv, true);
        }
    }.f)),
    sf("array_cat", 2, inArena(catFunc)),
    sf("array_remove", 2, inArena(removeFunc)),
    sf("array_replace", 3, inArena(replaceFunc)),
} ++ dfunc.overloads("array_position", &.{ 2, 3 }, det, dfunc.withArena(Call, struct {
    fn f(c: *Call, argv: []*Mem) void {
        positionFunc(c, argv, false);
    }
}.f)) ++ [_]FuncDef{
    sf("array_positions", 2, dfunc.withArena(Call, struct {
        fn f(c: *Call, argv: []*Mem) void {
            positionFunc(c, argv, true);
        }
    }.f)),
} ++ dfunc.overloads("array_to_string", &.{ 2, 3 }, det, inArena(toStringFunc)) ++
    dfunc.overloads("string_to_array", &.{ 2, 3 }, det, inArena(stringToArrayFunc)) ++
    [_]FuncDef{agg("array_agg", aggStep, aggFinal, aggValue, aggInverse)};

// ================================================================= tests

fn expectRound(in: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const x = try parse(arena.allocator(), in, false);
    try std.testing.expectEqualStrings(want, try write(arena.allocator(), &x));
}

test "array literals" {
    try expectRound("{1,2,NULL}", "{1,2,NULL}");
    try expectRound(" { 1 , 2 } ", "{1,2}");
    try expectRound("{\"a b\",c,\"\",\"NULL\",d\\,e}", "{\"a b\",c,\"\",\"NULL\",\"d,e\"}");
    try expectRound("{{1,2},{3,4}}", "{{1,2},{3,4}}");
    try expectRound("[0:1]={1,2}", "[0:1]={1,2}");
    try expectRound("[1:2]={1,2}", "{1,2}");
    try expectRound("{}", "{}");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "x", "{1,2", "{{1},{2,3}}", "{1,{2}}", "{{1},2}", "{,}", "[1:3]={1,2}", "{a\"b}", "{{}}" }) |bad| {
        try std.testing.expectError(error.Malformed, parse(a, bad, false));
    }
    const v = try parse(a, "1 2 3", true);
    try std.testing.expectEqual(@as(i32, 0), v.lower[0]);
    try std.testing.expectEqual(@as(usize, 3), v.count());
}

test "element input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: Fail = undefined;
    try std.testing.expectEqualStrings("1", try elemIn(a, .int4, " 01 ", &fail));
    try std.testing.expectError(error.Invalid, elemIn(a, .int4, "a", &fail));
    try std.testing.expectEqualStrings("invalid input syntax for type integer: \"a\"", fail.msg);
    try std.testing.expectError(error.Invalid, elemIn(a, .int2, "70000", &fail));
    try std.testing.expectEqualStrings("t", try elemIn(a, .boolean, "yes", &fail));
    try std.testing.expectEqualStrings("1e+20", try elemIn(a, .float8, "1e20", &fail));
    try std.testing.expectEqualStrings("1", try elemIn(a, .float8, "1.0", &fail));
    for ([_][2][]const u8{ .{ "1.50", "1.50" }, .{ "1e2", "100" }, .{ "1.5e1", "15" }, .{ ".5", "0.5" }, .{ "-0", "0" }, .{ "007", "7" }, .{ "1.25e-1", "0.125" }, .{ "+3.", "3" } }) |p| {
        try std.testing.expectEqualStrings(p[1], numericIn(a, p[0]).?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), numericIn(a, "1x"));
    try std.testing.expectEqual(Code{ .elem = .numeric, .scale = 2, .nested = true }, Code.decode((Code{ .elem = .numeric, .scale = 2, .nested = true }).encode()));
}
