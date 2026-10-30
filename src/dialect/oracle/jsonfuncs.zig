//! Oracle's SQL/JSON functions as engine functions (xq_ora_json_*,
//! visible in every dialect, so that CHECKs, virtual columns and views
//! that use them read the same from any connection), over the JSON model
//! of json.zig. The parser (jsonsql.zig) turns Oracle's syntax into calls
//! whose options are string literals:
//!
//!   xq_ora_is_json(x, flags)                 x IS JSON [STRICT] [WITH UNIQUE KEYS]
//!   xq_ora_json(x)                           x FORMAT JSON, JSON(x)
//!   xq_ora_json_scalar(x)                    JSON_SCALAR(x)
//!   xq_ora_json_value(doc, path, opts, empty_default, error_default, [name, value]...)
//!   xq_ora_json_query(doc, path, opts, [name, value]...)
//!   xq_ora_json_exists(doc, path, opts, [name, value]...)
//!   xq_ora_json_dot(doc, path, flags)        t.col.a.b (dot notation)
//!   xq_ora_json_object(opts, key, value, ...)
//!   xq_ora_json_array(opts, value, ...)
//!   xq_ora_json_objectagg(opts, key, value)  (aggregate)
//!   xq_ora_json_arrayagg(opts, value)        (aggregate)
//!   xq_ora_json_mergepatch(target, patch, opts)
//!   xq_ora_json_serialize(x, opts)
//!   xq_ora_json_transform(doc, opts, op, path, value, ...)
//!   xq_ora_json_table(doc, spec)             JSON_TABLE (eponymous virtual table)
//!
//! `opts` is fields separated by '|' (optsField()): the RETURNING type
//! (types.format() spelling), then the function's handlers and flags. A
//! JSON result carries SQLite's JSON subtype ('J'), so that a JSON value
//! given to a JSON constructor (JSON_OBJECT('a' VALUE JSON_QUERY(...)))
//! is JSON, not a string, as in Oracle.
//!
//! Numbers: JSON_VALUE and JSON type columns give a number as Oracle's
//! NUMBER writes it in JSON (1.50 is 1.5, 1e2 is 100: canonNumber());
//! JSON_QUERY and the other functions keep the number as written in a
//! textual document (with the exponent letter in upper case).

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const vtab = @import("../../sql/vtab.zig");
const FUNC = @import("../../sql/callback.zig").FUNC;
const J = @import("json.zig");
const types = @import("types.zig");
const funcs = @import("funcs.zig");
const dt = @import("datetime.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Allocator = std.mem.Allocator;
const Value = J.Value;
const RC = int.RC;

/// SQLite's JSON subtype (JSON_SUBTYPE in json.c).
pub const subtype_json: u32 = 'J';

fn flags(agg: bool) FUNC {
    _ = agg;
    return .{ .enc = vi.ENC.UTF8, .BUILTIN = true, .CONSTANT = true, .SUBTYPE = true, .RESULT_SUBTYPE = true };
}

fn jscalar(name: [:0]const u8, n_arg: i16, x: dfunc.StepFn) int.FuncDef {
    return .{ .n_arg = n_arg, .func_flags = flags(false), .x_sfunc = x, .name = name };
}

fn jagg(name: [:0]const u8, n_arg: i16, step: dfunc.StepFn, final: dfunc.FinalFn) int.FuncDef {
    return .{ .n_arg = n_arg, .func_flags = flags(true), .x_sfunc = step, .x_finalize = final, .name = name };
}

pub const engine_functions = [_]int.FuncDef{
    jscalar("xq_ora_is_json", 2, isJsonFunc),
    jscalar("xq_ora_json", 1, jsonFunc),
    jscalar("xq_ora_json_scalar", 1, jsonScalarFunc),
    jscalar("xq_ora_json_value", -1, jsonValueFunc),
    jscalar("xq_ora_json_query", -1, jsonQueryFunc),
    jscalar("xq_ora_json_exists", -1, jsonExistsFunc),
    jscalar("xq_ora_json_dot", 3, jsonDotFunc),
    jscalar("xq_ora_json_object", -1, jsonObjectFunc),
    jscalar("xq_ora_json_array", -1, jsonArrayFunc),
    jagg("xq_ora_json_objectagg", 3, objectAggStep, objectAggFinal),
    jagg("xq_ora_json_arrayagg", 2, arrayAggStep, arrayAggFinal),
    jscalar("xq_ora_json_mergepatch", 3, mergePatchFunc),
    jscalar("xq_ora_json_serialize", 2, serializeFunc),
    jscalar("xq_ora_json_transform", -1, transformFunc),
};

// ============================================================ helpers

/// A failure: the message is the call's error unless a handler maps it.
const Fail = error{ Ora, OutOfMemory };

const Call = struct {
    /// Undefined in JSON_TABLE's scan, which sets `now`.
    ctx: *Context,
    arena: std.heap.ArenaAllocator,
    msg: []const u8 = "",
    now: ?dt.DateTime = null,

    fn init(ctx: *Context) Call {
        return .{ .ctx = ctx, .arena = .init(dfunc.gpa(ctx)) };
    }

    fn deinit(c: *Call) void {
        c.arena.deinit();
    }

    fn a(c: *Call) Allocator {
        return c.arena.allocator();
    }

    fn fail(c: *Call, comptime fmt: []const u8, args: anytype) Fail {
        c.msg = try std.fmt.allocPrint(c.a(), fmt, args);
        return error.Ora;
    }

    /// Report `err` as the result of the call.
    fn report(c: *Call, err: Fail) void {
        switch (err) {
            error.OutOfMemory => api.resultErrorNomem(c.ctx),
            error.Ora => api.resultError(c.ctx, c.msg),
        }
    }
};

/// Field `i` of an options string (fields separated by '|'), "" past the
/// end.
pub fn optsField(opts: []const u8, i: usize) []const u8 {
    var it = std.mem.splitScalar(u8, opts, '|');
    var k: usize = 0;
    while (it.next()) |f| : (k += 1) if (k == i) return f;
    return "";
}

fn optsText(m: *Mem) []const u8 {
    return api.valueText(m) orelse "";
}

/// The text of a document argument: null for NULL and '' (Oracle's empty
/// string), numbers as Oracle writes them.
fn docText(m: *Mem, buf: []u8) ?[]const u8 {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return null,
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return funcs.numberText(buf, m),
        else => {
            const z = api.valueText(m) orelse return null;
            if (z.len == 0) return null;
            return z;
        },
    }
}

fn parseDoc(c: *Call, text: []const u8) Fail!Value {
    return J.parse(c.a(), text, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Syntax => c.fail("ORA-40441: JSON syntax error", .{}),
    };
}

fn parsePath(c: *Call, text: []const u8) Fail!J.Path {
    return J.parsePath(c.a(), text) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.BadPath => c.fail("ORA-40442: JSON path expression syntax error ('{s}')", .{text}),
    };
}

/// The JSON number text of an SQL number (0.5, not Oracle's .5).
fn sqlNumberJson(a: Allocator, m: *Mem) Fail![]const u8 {
    var buf: [64]u8 = undefined;
    const t = funcs.numberText(&buf, m);
    if (t.len > 0 and t[0] == '.') return std.fmt.allocPrint(a, "0{s}", .{t});
    if (t.len > 1 and t[0] == '-' and t[1] == '.') return std.fmt.allocPrint(a, "-0{s}", .{t[1..]});
    return a.dupe(u8, t);
}

/// An SQL value as a JSON value: text with the JSON subtype is JSON,
/// other text a string, numbers numbers, NULL null.
fn sqlToJson(c: *Call, m: *Mem) Fail!Value {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return .null,
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => {
            const t = try sqlNumberJson(c.a(), m);
            if (std.mem.eql(u8, t, "Nan") or std.mem.endsWith(u8, t, "Inf")) return .{ .string = t };
            return .{ .number = t };
        },
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse &.{};
            const hex = try c.a().alloc(u8, b.len * 2);
            const digits = "0123456789ABCDEF";
            for (b, 0..) |x, i| {
                hex[2 * i] = digits[x >> 4];
                hex[2 * i + 1] = digits[x & 15];
            }
            return .{ .string = hex };
        },
        else => {
            const z = api.valueText(m) orelse return error.OutOfMemory;
            if (api.valueSubtype(m) == subtype_json) return parseDoc(c, z);
            if (z.len == 0) return .null;
            return .{ .string = try c.a().dupe(u8, z) };
        },
    }
}

fn isJsonArg(m: *Mem) bool {
    return api.valueType(m) == vi.SQLITE_TEXT and api.valueSubtype(m) == subtype_json;
}

/// PASSING variables: name, value pairs from argv[from..].
fn passing(c: *Call, argv: []*Mem) Fail![]J.Var {
    var vars: std.ArrayList(J.Var) = .empty;
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 2) {
        try vars.append(c.a(), .{ .name = try c.a().dupe(u8, optsText(argv[i])), .value = try sqlToJson(c, argv[i + 1]) });
    }
    return vars.items;
}

fn resultJson(c: *Call, text: []const u8) void {
    api.resultText(c.ctx, text, .transient);
    api.resultSubtype(c.ctx, subtype_json);
}

/// The RETURNING type of `opts` field 0 (VARCHAR2(4000) by default).
fn returningType(spelling: []const u8) types.TypeName {
    if (spelling.len == 0) return .{ .name = "VARCHAR2", .precision = 4000 };
    return types.parse(spelling) orelse .{ .name = "VARCHAR2", .precision = 4000 };
}

/// The length limit of a textual RETURNING type, null for none.
fn maxLength(ty: types.TypeName) ?usize {
    const f = types.family(ty.name) orelse return null;
    if (f != .varchar and f != .char) return null;
    return @intCast(ty.precision orelse return null);
}

// ============================================================ numbers

/// A JSON number as Oracle's NUMBER writes it: no exponent, no trailing
/// zeros of the fraction, 0 before the point (1.50 -> 1.5, 1e2 -> 100,
/// 1e-2 -> 0.01, -0 -> 0).
pub fn canonNumber(a: Allocator, lex: []const u8) Allocator.Error![]const u8 {
    var s = lex;
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var exp: i64 = 0;
    if (std.mem.indexOfAny(u8, s, "eE")) |e| {
        exp = std.fmt.parseInt(i64, s[e + 1 ..], 10) catch 0;
        s = s[0..e];
    }
    var digits: std.ArrayList(u8) = .empty;
    var point: i64 = 0; // digits before the decimal point
    var seen_point = false;
    for (s) |ch| {
        if (ch == '.') {
            seen_point = true;
            continue;
        }
        if (!std.ascii.isDigit(ch)) return a.dupe(u8, lex);
        try digits.append(a, ch);
        if (!seen_point) point += 1;
    }
    point += exp;
    // Strip leading zeros (moving the point) and trailing zeros.
    var d = digits.items;
    while (d.len > 0 and d[0] == '0') {
        d = d[1..];
        point -= 1;
    }
    while (d.len > 0 and d[d.len - 1] == '0') d = d[0 .. d.len - 1];
    if (d.len == 0) return "0";
    if (point > 130 or point < -130) return a.dupe(u8, lex);
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(a, '-');
    if (point <= 0) {
        try out.appendSlice(a, "0.");
        try out.appendNTimes(a, '0', @intCast(-point));
        try out.appendSlice(a, d);
    } else {
        const p: usize = @intCast(point);
        if (p >= d.len) {
            try out.appendSlice(a, d);
            try out.appendNTimes(a, '0', p - d.len);
        } else {
            try out.appendSlice(a, d[0..p]);
            try out.append(a, '.');
            try out.appendSlice(a, d[p..]);
        }
    }
    return out.items;
}

/// `v` with its numbers canonical (JSON type storage).
pub fn canonValue(a: Allocator, v: Value) Allocator.Error!Value {
    switch (v) {
        .number => |t| return .{ .number = try canonNumber(a, t) },
        .array => |items| {
            const out = try a.alloc(Value, items.len);
            for (items, out) |x, *o| o.* = try canonValue(a, x);
            return .{ .array = out };
        },
        .object => |ms| {
            const out = try a.alloc(J.Member, ms.len);
            for (ms, out) |m, *o| o.* = .{ .key = m.key, .value = try canonValue(a, m.value) };
            return .{ .object = out };
        },
        else => return v,
    }
}

/// The JSON text a JSON type column stores for `text` (lax syntax read,
/// numbers canonical, compact), or the Oracle error.
pub fn storageText(a: Allocator, text: []const u8) error{ Syntax, Duplicate, OutOfMemory }![]const u8 {
    const v = J.parse(a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Syntax => return error.Syntax,
    };
    if (J.hasDuplicateKeys(v)) return error.Duplicate;
    return J.toText(a, try canonValue(a, v), .{});
}

// ============================================================ cells

/// An SQL value a function computes: a JSON result is text with the JSON
/// subtype.
pub const Cell = union(enum) {
    null,
    int: i64,
    real: f64,
    text: []const u8,
    json: []const u8,
    /// An SQL argument (a DEFAULT), as it is.
    mem: *Mem,
};

fn resultCell(ctx: *Context, cell: Cell) void {
    switch (cell) {
        .null => api.resultNull(ctx),
        .int => |v| api.resultInt64(ctx, v),
        .real => |v| api.resultDouble(ctx, v),
        .text => |t| if (t.len == 0) api.resultNull(ctx) else api.resultText(ctx, t, .transient),
        .json => |t| {
            api.resultText(ctx, t, .transient);
            api.resultSubtype(ctx, subtype_json);
        },
        .mem => |m| api.resultValue(ctx, m),
    }
}

/// A number text as a cell: an integer when it is one, else a real.
fn numberCell(t: []const u8) Cell {
    if (std.fmt.parseInt(i64, t, 10)) |v| return .{ .int = v } else |_| {}
    const x = std.fmt.parseFloat(f64, t) catch return .null;
    if (x == @trunc(x) and @abs(x) < 9.007199254740992e15) return .{ .int = @intFromFloat(x) };
    return .{ .real = x };
}

/// A JSON scalar as an SQL value of type `ty` (JSON_VALUE's RETURNING):
/// error.Ora with the message on a value that does not convert.
fn scalarAs(c: *Call, v: Value, ty: types.TypeName, truncate: bool, path: []const u8) Fail!Cell {
    if (v == .null) return .null;
    const fam = types.family(ty.name) orelse .varchar;
    switch (fam) {
        .varchar, .char, .clob, .rowid, .interval => {
            const s: []const u8 = switch (v) {
                .string => |s| s,
                .number => |t| try canonNumber(c.a(), t),
                .bool => |b| if (b) "true" else "false",
                else => unreachable,
            };
            if (maxLength(ty)) |max| {
                const len = if (ty.char_semantics) dfunc.charCount(s) else s.len;
                if (len > max) {
                    if (truncate) return .{ .text = s[0..dfunc.charOffset(s, max)] };
                    return c.fail("ORA-61723: Value selected by JSON path '{s}' exceeds maximum ({d}).", .{ path, max });
                }
            }
            return .{ .text = s };
        },
        .number, .binary_float => {
            const t: []const u8 = switch (v) {
                .number => |t| t,
                .string => |s| std.mem.trim(u8, s, " "),
                else => return c.fail("ORA-01722: invalid number", .{}),
            };
            const n = (funcs.parseNum(t) catch return c.fail("ORA-01722: unable to convert string value containing '{s}' to a number", .{t})) orelse return .null;
            var x: f64 = switch (n) {
                .int => |i| @floatFromInt(i),
                .real => |r| r,
            };
            if (fam == .binary_float) return .{ .real = x };
            const scale = ty.scale orelse (if (ty.precision != null) @as(i64, 0) else null);
            if (scale) |s| x = funcs.roundTo(x, s, false);
            if (types.precisionBound(ty)) |bound| if (@abs(x) >= bound) return c.fail("ORA-01438: value larger than specified precision allowed for this column", .{});
            if (n == .int and (scale == null or scale.? >= 0)) return .{ .int = n.int };
            if (x == @trunc(x) and @abs(x) < 9.007199254740992e15) return .{ .int = @intFromFloat(x) };
            return .{ .real = x };
        },
        .date, .timestamp => {
            if (v != .string) return c.fail("ORA-01861: literal does not match format string", .{});
            const d = dt.parseDefault(v.string, c.now orelse funcs.now(c.ctx)) orelse return c.fail("ORA-01861: literal does not match format string", .{});
            var buf: [48]u8 = undefined;
            const t = if (fam == .date) dt.writeDate(&buf, d) else dt.writeTimestamp(&buf, d, 6);
            return .{ .text = try c.a().dupe(u8, t) };
        },
        .boolean => switch (v) {
            .bool => |b| return .{ .int = @intFromBool(b) },
            .string => |s| {
                if (std.ascii.eqlIgnoreCase(s, "true")) return .{ .int = 1 };
                if (std.ascii.eqlIgnoreCase(s, "false")) return .{ .int = 0 };
                return c.fail("ORA-61800: invalid boolean value", .{});
            },
            else => return c.fail("ORA-61800: invalid boolean value", .{}),
        },
        .json => return .{ .json = try J.toText(c.a(), v, .{}) },
        .blob, .raw => return c.fail("ORA-40449: invalid data type for return value", .{}),
    }
}

// ======================================================== IS JSON, JSON()

/// xq_ora_is_json(x, flags): flags 1 STRICT, 2 WITH UNIQUE KEYS, 4
/// DISALLOW SCALARS.
fn isJsonFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    const fl = api.valueInt64(argv[1]);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = J.parse(c.a(), text, .{ .lax = fl & 1 == 0 }) catch |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Syntax => return api.resultInt64(ctx, 0),
    };
    if (fl & 2 != 0 and J.hasDuplicateKeys(v)) return api.resultInt64(ctx, 0);
    // DISALLOW SCALARS
    if (fl & 4 != 0 and v.isScalar()) return api.resultInt64(ctx, 0);
    api.resultInt64(ctx, 1);
}

/// xq_ora_json(x): x as JSON (FORMAT JSON, JSON()).
fn jsonFunc(ctx: *Context, argv: []*Mem) void {
    if (isJsonArg(argv[0])) return api.resultValue(ctx, argv[0]);
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = parseDoc(&c, text) catch |err| return c.report(err);
    const out = J.toText(c.a(), v, .{}) catch return api.resultErrorNomem(ctx);
    resultJson(&c, out);
}

/// xq_ora_json_scalar(x): a number or a string as a JSON scalar.
fn jsonScalarFunc(ctx: *Context, argv: []*Mem) void {
    var c: Call = .init(ctx);
    defer c.deinit();
    if (api.valueType(argv[0]) == vi.SQLITE_NULL) return api.resultNull(ctx);
    var v = sqlToJson(&c, argv[0]) catch |err| return c.report(err);
    if (v == .number) v = .{ .number = canonNumber(c.a(), v.number) catch return api.resultErrorNomem(ctx) };
    if (v == .null) return api.resultNull(ctx);
    const out = J.toText(c.a(), v, .{}) catch return api.resultErrorNomem(ctx);
    resultJson(&c, out);
}

// ============================================================ JSON_VALUE

/// A handler: N (NULL), E (ERROR), D (DEFAULT), A (EMPTY ARRAY), O
/// (EMPTY OBJECT); `inherit` when the clause is absent.
const Handler = enum { null, err, default, empty_array, empty_object, inherit };

fn handler(code: []const u8) Handler {
    if (code.len == 0) return .inherit;
    return switch (code[0]) {
        'E' => .err,
        'D' => .default,
        'A' => .empty_array,
        'O' => .empty_object,
        'I' => .inherit,
        else => .null,
    };
}

pub const ValueSpec = struct {
    ty: types.TypeName,
    on_empty: Handler,
    on_error: Handler,
    truncate: bool,
};

pub fn valueSpec(opts: []const u8) ValueSpec {
    return .{
        .ty = returningType(optsField(opts, 0)),
        .on_empty = handler(optsField(opts, 1)),
        .on_error = handler(optsField(opts, 2)),
        .truncate = std.mem.eql(u8, optsField(opts, 3), "T"),
    };
}

/// JSON_VALUE of the parsed document `doc` (null for an invalid one):
/// the cell; error.Empty when the path selects nothing (the ON EMPTY
/// handler's case), error.Ora for an error (the ON ERROR handler's), the
/// message in `c`.
fn valueCore(c: *Call, doc_opt: ?Value, path_text: []const u8, path: J.Path, spec: ValueSpec, vars: []const J.Var) (Fail || error{Empty})!Cell {
    const doc = doc_opt orelse return c.fail("ORA-40441: JSON syntax error", .{});
    var e: J.Eval = .{ .a = c.a(), .strict = path.strict, .root = doc, .vars = vars };
    const items = e.run(path, doc) catch |err| switch (err) {
        error.OutOfMemory => |x| return x,
        error.Eval => return c.fail("ORA-40462: JSON path '{s}' evaluated to no value.", .{path_text}),
    };
    if (items.len == 0) {
        c.msg = try std.fmt.allocPrint(c.a(), "ORA-40462: JSON path '{s}' evaluated to no value.", .{path_text});
        return error.Empty;
    }
    if (items.len > 1) return c.fail("ORA-40470: JSON path '{s}' evaluated to multiple values.", .{path_text});
    if (!items[0].isScalar()) {
        if (types.family(spec.ty.name) == .json) return .{ .json = try J.toText(c.a(), items[0], .{}) };
        return c.fail("ORA-40456: JSON path '{s}' evaluated to non-scalar value.", .{path_text});
    }
    return scalarAs(c, items[0], spec.ty, spec.truncate, path_text);
}

/// What a handler gives: `def` for DEFAULT (null: NULL).
fn handle(h: Handler, def: ?Cell) Fail!Cell {
    return switch (h) {
        .err => error.Ora,
        .default => def orelse .null,
        else => .null,
    };
}

/// JSON_VALUE with its handlers applied.
fn valueOf(c: *Call, doc: ?Value, path_text: []const u8, path: J.Path, spec: ValueSpec, def_empty: ?Cell, def_error: ?Cell, vars: []const J.Var) Fail!Cell {
    return valueCore(c, doc, path_text, path, spec, vars) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Empty => {
            if (spec.on_empty == .inherit) return handle(spec.on_error, def_error);
            return handle(spec.on_empty, def_empty);
        },
        error.Ora => return handle(spec.on_error, def_error),
    };
}

/// xq_ora_json_value(doc, path, opts, empty_default, error_default,
/// [name, value]...): opts "TYPE|empty|error|T(runcate)".
fn jsonValueFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 5) return api.resultError(ctx, "xq_ora_json_value: wrong number of arguments");
    var c: Call = .init(ctx);
    defer c.deinit();
    const path_text = optsText(argv[1]);
    const path = parsePath(&c, path_text) catch |err| return c.report(err);
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    const spec = valueSpec(optsText(argv[2]));
    const vars = passing(&c, argv[5..]) catch |err| return c.report(err);
    const doc: ?Value = J.parse(c.a(), text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Syntax => null,
    };
    const cell = valueOf(&c, doc, path_text, path, spec, .{ .mem = argv[3] }, .{ .mem = argv[4] }, vars) catch |err| return c.report(err);
    resultCell(ctx, cell);
}

// ============================================================ JSON_QUERY

pub const QuerySpec = struct {
    ty: types.TypeName,
    on_empty: Handler,
    on_error: Handler,
    /// N(one), U(nconditional), C(onditional).
    wrapper: u8,
    pretty: bool,
    ascii: bool,
};

pub fn querySpec(opts: []const u8) QuerySpec {
    const w = optsField(opts, 3);
    return .{
        .ty = returningType(optsField(opts, 0)),
        .on_empty = handler(optsField(opts, 1)),
        .on_error = handler(optsField(opts, 2)),
        .wrapper = if (w.len > 0) w[0] else 'N',
        .pretty = std.mem.eql(u8, optsField(opts, 4), "P"),
        .ascii = std.mem.eql(u8, optsField(opts, 5), "A"),
    };
}

fn handled(h: Handler) ?[]const u8 {
    return switch (h) {
        .empty_array => "[]",
        .empty_object => "{}",
        else => null,
    };
}

/// JSON_QUERY: the JSON text, null for NULL.
fn queryOf(c: *Call, doc_opt: ?Value, path_text: []const u8, path: J.Path, spec: QuerySpec, vars: []const J.Var) Fail!?[]const u8 {
    const r = queryCore(c, doc_opt, path_text, path, spec, vars);
    if (r) |x| return x else |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Ora => {},
    }
    return switch (spec.on_error) {
        .err => error.Ora,
        else => handled(spec.on_error),
    };
}

fn queryCore(c: *Call, doc_opt: ?Value, path_text: []const u8, path: J.Path, spec: QuerySpec, vars: []const J.Var) Fail!?[]const u8 {
    const doc = doc_opt orelse return c.fail("ORA-40441: JSON syntax error", .{});
    var e: J.Eval = .{ .a = c.a(), .strict = path.strict, .root = doc, .vars = vars };
    const items = e.run(path, doc) catch |err| switch (err) {
        error.OutOfMemory => |x| return x,
        error.Eval => return c.fail("ORA-40462: JSON path '{s}' evaluated to no value.", .{path_text}),
    };
    if (items.len == 0) {
        const h = if (spec.on_empty == .inherit) spec.on_error else spec.on_empty;
        return switch (h) {
            .err => c.fail("ORA-40462: JSON path '{s}' evaluated to no value.", .{path_text}),
            else => handled(h),
        };
    }
    const v: Value = switch (spec.wrapper) {
        'U' => .{ .array = items },
        // Conditional: a single value (a scalar too, as 23ai allows
        // scalars) is not wrapped.
        'C' => if (items.len == 1) items[0] else .{ .array = items },
        else => blk: {
            if (items.len > 1) return c.fail("ORA-40480: JSON array wrapper needed for result of JSON query '{s}'", .{path_text});
            break :blk items[0];
        },
    };
    const text = try J.toText(c.a(), v, .{ .pretty = spec.pretty, .ascii = spec.ascii });
    if (maxLength(spec.ty)) |max| if (text.len > max) return c.fail("ORA-40478: output value too large (maximum: {d})", .{max});
    return text;
}

/// xq_ora_json_query(doc, path, opts, [name, value]...): opts
/// "TYPE|empty|error|wrapper|P(retty)|A(scii)".
fn jsonQueryFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 3) return api.resultError(ctx, "xq_ora_json_query: wrong number of arguments");
    var c: Call = .init(ctx);
    defer c.deinit();
    const path_text = optsText(argv[1]);
    const path = parsePath(&c, path_text) catch |err| return c.report(err);
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    const spec = querySpec(optsText(argv[2]));
    const vars = passing(&c, argv[3..]) catch |err| return c.report(err);
    const doc: ?Value = J.parse(c.a(), text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Syntax => null,
    };
    const out = queryOf(&c, doc, path_text, path, spec, vars) catch |err| return c.report(err);
    if (out) |t| resultJson(&c, t) else api.resultNull(ctx);
}

// =========================================================== JSON_EXISTS

/// xq_ora_json_exists(doc, path, opts, [name, value]...): opts the ON
/// ERROR handler, F(ALSE), T(RUE) or E(RROR).
fn jsonExistsFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 3) return api.resultError(ctx, "xq_ora_json_exists: wrong number of arguments");
    var c: Call = .init(ctx);
    defer c.deinit();
    const path_text = optsText(argv[1]);
    const path = parsePath(&c, path_text) catch |err| return c.report(err);
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultInt64(ctx, 0);
    const on_error = optsField(optsText(argv[2]), 0);
    const vars = passing(&c, argv[3..]) catch |err| return c.report(err);
    const r = existsOf(&c, text, path, vars);
    if (r) |b| return api.resultInt64(ctx, @intFromBool(b)) else |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Ora => {
            if (std.mem.eql(u8, on_error, "E")) return c.report(err);
            return api.resultInt64(ctx, @intFromBool(std.mem.eql(u8, on_error, "T")));
        },
    }
}

fn existsOf(c: *Call, text: []const u8, path: J.Path, vars: []const J.Var) Fail!bool {
    const doc = try parseDoc(c, text);
    var e: J.Eval = .{ .a = c.a(), .strict = path.strict, .root = doc, .vars = vars };
    const items = e.run(path, doc) catch |err| switch (err) {
        error.OutOfMemory => |x| return x,
        error.Eval => return false,
    };
    return items.len > 0;
}

// ========================================================== dot notation

/// xq_ora_json_dot(doc, path, flags): t.col.a.b; flags 1: the column is
/// of type JSON (scalars are JSON: "str"), 2: the path ends with an item
/// method (the SQL value). Several values are an array.
fn jsonDotFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const path = parsePath(&c, optsText(argv[1])) catch |err| return c.report(err);
    const fl = api.valueInt64(argv[2]);
    const doc = J.parse(c.a(), text, .{}) catch return api.resultNull(ctx);
    var e: J.Eval = .{ .a = c.a(), .strict = false, .root = doc };
    const items = e.run(path, doc) catch return api.resultNull(ctx);
    if (items.len == 0) return api.resultNull(ctx);
    const v: Value = if (items.len == 1) items[0] else .{ .array = items };
    if (fl & 2 != 0 or (fl & 1 == 0 and v.isScalar())) {
        switch (v) {
            .null => return api.resultNull(ctx),
            .string => |s| return if (s.len == 0) api.resultNull(ctx) else api.resultText(ctx, s, .transient),
            .bool => |b| return api.resultText(ctx, if (b) "true" else "false", .static),
            .number => |t| {
                const canon = canonNumber(c.a(), t) catch return api.resultErrorNomem(ctx);
                if (fl & 2 != 0) return resultCell(ctx, numberCell(canon));
                return api.resultText(ctx, canon, .transient);
            },
            else => {},
        }
    }
    const out = J.toText(c.a(), v, .{}) catch return api.resultErrorNomem(ctx);
    resultJson(&c, out);
}

// ===================================================== constructors

/// Flags of the constructors' options (field 1): 1 ABSENT ON NULL, 2
/// NULL ON NULL, 4 WITH UNIQUE KEYS. Field 0 is the RETURNING type.
fn ctorFlags(opts: []const u8) i64 {
    return std.fmt.parseInt(i64, optsField(opts, 1), 10) catch 0;
}

fn finishCtor(c: *Call, v: Value, opts: []const u8) void {
    const out = J.toText(c.a(), v, .{}) catch return api.resultErrorNomem(c.ctx);
    const ty = returningType(optsField(opts, 0));
    if (optsField(opts, 0).len > 0) if (maxLength(ty)) |max| if (out.len > max) {
        return c.report(c.fail("ORA-40478: output value too large (maximum: {d})", .{max}));
    };
    resultJson(c, out);
}

fn keyText(c: *Call, m: *Mem) Fail![]const u8 {
    var buf: [64]u8 = undefined;
    const k = docText(m, &buf) orelse return c.fail("ORA-40417: JSON path expression has an invalid key name", .{});
    return c.a().dupe(u8, k);
}

/// xq_ora_json_object(opts, key, value, ...).
fn jsonObjectFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 1 or argv.len % 2 != 1) return api.resultError(ctx, "xq_ora_json_object: wrong number of arguments");
    var c: Call = .init(ctx);
    defer c.deinit();
    const opts = optsText(argv[0]);
    const fl = ctorFlags(opts);
    var ms: std.ArrayList(J.Member) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const k = keyText(&c, argv[i]) catch |err| return c.report(err);
        const v = sqlToJson(&c, argv[i + 1]) catch |err| return c.report(err);
        if (v == .null and fl & 1 != 0) continue;
        if (fl & 4 != 0) for (ms.items) |m| if (std.mem.eql(u8, m.key, k)) {
            return c.report(c.fail("ORA-40473: duplicate key names '{s}' in JSON object", .{k}));
        };
        ms.append(c.a(), .{ .key = k, .value = v }) catch return api.resultErrorNomem(ctx);
    }
    finishCtor(&c, .{ .object = ms.items }, opts);
}

/// xq_ora_json_array(opts, value, ...).
fn jsonArrayFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 1) return api.resultError(ctx, "xq_ora_json_array: wrong number of arguments");
    var c: Call = .init(ctx);
    defer c.deinit();
    const opts = optsText(argv[0]);
    const fl = ctorFlags(opts);
    var items: std.ArrayList(Value) = .empty;
    for (argv[1..]) |m| {
        const v = sqlToJson(&c, m) catch |err| return c.report(err);
        if (v == .null and fl & 2 == 0) continue;
        items.append(c.a(), v) catch return api.resultErrorNomem(ctx);
    }
    finishCtor(&c, .{ .array = items.items }, opts);
}

// ============================================================ aggregates

/// The state of JSON_ARRAYAGG / JSON_OBJECTAGG: the members written so
/// far, comma separated.
const AggState = struct {
    text: std.ArrayList(u8) = .empty,
    n: usize = 0,
};

fn aggState(ctx: *Context, create: bool) ?*AggState {
    const bytes = api.aggregateContext(ctx, if (create) @sizeOf(*AggState) else 0) orelse return null;
    const slot: **AggState = @ptrCast(@alignCast(bytes.ptr));
    if (@intFromPtr(slot.*) == 0) {
        if (!create) return null;
        const st = dfunc.gpa(ctx).create(AggState) catch return null;
        st.* = .{};
        slot.* = st;
    }
    return slot.*;
}

fn aggAppend(ctx: *Context, key: ?[]const u8, v: Value) void {
    const st = aggState(ctx, true) orelse return api.resultErrorNomem(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const g = dfunc.gpa(ctx);
    var tmp: std.ArrayList(u8) = .empty;
    if (key) |k| {
        J.writeString(c.a(), &tmp, k, false) catch return api.resultErrorNomem(ctx);
        tmp.append(c.a(), ':') catch return api.resultErrorNomem(ctx);
    }
    J.write(c.a(), &tmp, v, .{}) catch return api.resultErrorNomem(ctx);
    if (st.n > 0) st.text.append(g, ',') catch return api.resultErrorNomem(ctx);
    st.text.appendSlice(g, tmp.items) catch return api.resultErrorNomem(ctx);
    st.n += 1;
}

fn aggFinal(ctx: *Context, open: u8, close: u8) void {
    const st = aggState(ctx, false) orelse return api.resultNull(ctx);
    const g = dfunc.gpa(ctx);
    defer {
        st.text.deinit(g);
        g.destroy(st);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g);
    out.append(g, open) catch return api.resultErrorNomem(ctx);
    out.appendSlice(g, st.text.items) catch return api.resultErrorNomem(ctx);
    out.append(g, close) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
    api.resultSubtype(ctx, subtype_json);
}

/// xq_ora_json_arrayagg(opts, value): flags as JSON_ARRAY's.
fn arrayAggStep(ctx: *Context, argv: []*Mem) void {
    const fl = ctorFlags(optsText(argv[0]));
    var c: Call = .init(ctx);
    defer c.deinit();
    // The state exists from the first row (an empty array, not NULL).
    _ = aggState(ctx, true) orelse return api.resultErrorNomem(ctx);
    const v = sqlToJson(&c, argv[1]) catch |err| return c.report(err);
    if (v == .null and fl & 2 == 0) return;
    aggAppend(ctx, null, v);
}

fn arrayAggFinal(ctx: *Context) void {
    aggFinal(ctx, '[', ']');
}

/// xq_ora_json_objectagg(opts, key, value).
fn objectAggStep(ctx: *Context, argv: []*Mem) void {
    const fl = ctorFlags(optsText(argv[0]));
    var c: Call = .init(ctx);
    defer c.deinit();
    _ = aggState(ctx, true) orelse return api.resultErrorNomem(ctx);
    const k = keyText(&c, argv[1]) catch |err| return c.report(err);
    const v = sqlToJson(&c, argv[2]) catch |err| return c.report(err);
    if (v == .null and fl & 1 != 0) return;
    aggAppend(ctx, k, v);
}

fn objectAggFinal(ctx: *Context) void {
    aggFinal(ctx, '{', '}');
}

// ======================================================= JSON_MERGEPATCH

fn mergePatch(a: Allocator, target: Value, patch: Value) Allocator.Error!Value {
    if (patch != .object) return patch;
    const base: []const J.Member = if (target == .object) target.object else &.{};
    var out: std.ArrayList(J.Member) = .empty;
    try out.appendSlice(a, base);
    for (patch.object) |pm| {
        var found: ?usize = null;
        for (out.items, 0..) |m, i| if (std.mem.eql(u8, m.key, pm.key)) {
            found = i;
            break;
        };
        if (pm.value == .null) {
            if (found) |i| _ = out.orderedRemove(i);
            continue;
        }
        if (found) |i| {
            out.items[i].value = try mergePatch(a, out.items[i].value, pm.value);
        } else {
            try out.append(a, .{ .key = pm.key, .value = try mergePatch(a, .null, pm.value) });
        }
    }
    return .{ .object = out.items };
}

/// Field 0 the type, 1 P(retty), 2 A(scii), 3 T(runcate), 4 the ON ERROR
/// handler (N or E), 5 O(rdered).
fn outputOpts(opts: []const u8) J.WriteOptions {
    return .{
        .pretty = std.mem.eql(u8, optsField(opts, 1), "P"),
        .ascii = std.mem.eql(u8, optsField(opts, 2), "A"),
        .ordered = std.mem.eql(u8, optsField(opts, 5), "O"),
    };
}

fn finishOutput(c: *Call, v: Value, opts: []const u8) void {
    var out = J.toText(c.a(), v, outputOpts(opts)) catch return api.resultErrorNomem(c.ctx);
    if (optsField(opts, 0).len > 0) if (maxLength(returningType(optsField(opts, 0)))) |max| if (out.len > max) {
        if (std.mem.eql(u8, optsField(opts, 3), "T")) {
            out = out[0..max];
        } else if (std.mem.eql(u8, optsField(opts, 4), "N")) {
            return api.resultNull(c.ctx);
        } else return c.report(c.fail("ORA-40478: output value too large (maximum: {d})", .{max}));
    };
    resultJson(c, out);
}

/// xq_ora_json_mergepatch(target, patch, opts).
fn mergePatchFunc(ctx: *Context, argv: []*Mem) void {
    var c: Call = .init(ctx);
    defer c.deinit();
    const opts = optsText(argv[2]);
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const t = docText(argv[0], &b1) orelse return api.resultNull(ctx);
    const p = docText(argv[1], &b2) orelse return api.resultNull(ctx);
    const patch = J.parse(c.a(), p, .{}) catch return api.resultError(ctx, "ORA-40629: Patch specification is not valid JSON");
    const target = J.parse(c.a(), t, .{}) catch {
        if (std.mem.eql(u8, optsField(opts, 4), "E")) return api.resultError(ctx, "ORA-40441: JSON syntax error");
        return api.resultNull(ctx);
    };
    const v = mergePatch(c.a(), target, patch) catch return api.resultErrorNomem(ctx);
    finishOutput(&c, v, opts);
}

/// xq_ora_json_serialize(x, opts).
fn serializeFunc(ctx: *Context, argv: []*Mem) void {
    var c: Call = .init(ctx);
    defer c.deinit();
    const opts = optsText(argv[1]);
    var buf: [64]u8 = undefined;
    const t = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    const v = J.parse(c.a(), t, .{}) catch {
        if (std.mem.eql(u8, optsField(opts, 4), "N")) return api.resultNull(ctx);
        return api.resultError(ctx, "ORA-40441: JSON syntax error");
    };
    finishOutput(&c, v, opts);
}

// ========================================================= JSON_TRANSFORM

/// The places a path of member and index steps (with wildcards and
/// filters) names in `root`, as pointers into the tree, for the parent
/// steps of a JSON_TRANSFORM operation.
fn places(c: *Call, root: *Value, steps: []const J.Step, out: *std.ArrayList(*Value)) Fail!void {
    if (steps.len == 0) return out.append(c.a(), root);
    switch (steps[0]) {
        .member => |k| switch (root.*) {
            .object => |ms| for (ms) |*m| if (std.mem.eql(u8, m.key, k)) return places(c, &m.value, steps[1..], out),
            .array => |items| for (items) |*x| if (x.* == .object) try places(c, x, steps, out),
            else => {},
        },
        .any_member => if (root.* == .object) for (root.object) |*m| try places(c, &m.value, steps[1..], out),
        .array => |ranges| {
            if (root.* != .array) return;
            const items = root.array;
            if (ranges) |rs| {
                for (rs) |r| {
                    const from = rangeIndex(r.from, items.len);
                    const to = if (r.to) |x| rangeIndex(x, items.len) else from;
                    var k = @max(from, 0);
                    while (k <= to and k < items.len) : (k += 1) try places(c, &items[@intCast(k)], steps[1..], out);
                }
            } else for (items) |*x| try places(c, x, steps[1..], out);
        },
        .filter => {
            var e: J.Eval = .{ .a = c.a(), .strict = false, .root = root.* };
            const one = [_]J.Step{steps[0]};
            const r = e.run(.{ .base = .current, .steps = @constCast(&one) }, root.*) catch |err| switch (err) {
                error.OutOfMemory => |x| return x,
                error.Eval => return,
            };
            if (r.len > 0) try places(c, root, steps[1..], out);
        },
        else => return c.fail("ORA-40442: JSON path expression syntax error", .{}),
    }
}

fn rangeIndex(x: J.Index, len: usize) i64 {
    return if (x.last) @as(i64, @intCast(len)) - 1 - x.n else x.n;
}

const Op = enum { set, insert, replace, append, remove, rename, keep };

fn opOf(s: []const u8) ?Op {
    const names = [_]struct { []const u8, Op }{
        .{ "SET", .set },       .{ "INSERT", .insert }, .{ "REPLACE", .replace }, .{ "APPEND", .append },
        .{ "REMOVE", .remove }, .{ "RENAME", .rename }, .{ "KEEP", .keep },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], s)) return n[1];
    return null;
}

fn applyOp(c: *Call, root: *Value, op: Op, path: J.Path, value: Value, new_name: []const u8) Fail!void {
    if (path.steps.len == 0) {
        switch (op) {
            .set, .replace => root.* = value,
            .remove => root.* = .{ .object = &.{} },
            else => {},
        }
        return;
    }
    const last = path.steps[path.steps.len - 1];
    var parents: std.ArrayList(*Value) = .empty;
    try places(c, root, path.steps[0 .. path.steps.len - 1], &parents);
    if (parents.items.len == 0 and (op == .insert or op == .append)) return c.fail("ORA-40762: missing value in JSON_TRANSFORM", .{});
    for (parents.items) |parent| switch (last) {
        .member => |k| {
            if (parent.* != .object) continue;
            const ms = parent.object;
            var found: ?usize = null;
            for (ms, 0..) |m, i| if (std.mem.eql(u8, m.key, k)) {
                found = i;
                break;
            };
            switch (op) {
                .set, .insert, .replace => {
                    if (found) |i| {
                        if (op == .insert) return c.fail("ORA-40763: value already exists in JSON_TRANSFORM", .{});
                        ms[i].value = value;
                    } else if (op != .replace) {
                        const out = try c.a().alloc(J.Member, ms.len + 1);
                        @memcpy(out[0..ms.len], ms);
                        out[ms.len] = .{ .key = k, .value = value };
                        parent.* = .{ .object = out };
                    }
                },
                .remove => if (found) |i| {
                    var list: std.ArrayList(J.Member) = .empty;
                    try list.appendSlice(c.a(), ms);
                    _ = list.orderedRemove(i);
                    parent.* = .{ .object = list.items };
                },
                .rename => if (found) |i| {
                    // Oracle moves the member to the end.
                    var list: std.ArrayList(J.Member) = .empty;
                    try list.appendSlice(c.a(), ms);
                    const m = list.orderedRemove(i);
                    try list.append(c.a(), .{ .key = new_name, .value = m.value });
                    parent.* = .{ .object = list.items };
                },
                .append => {
                    const i = found orelse return c.fail("ORA-40762: missing value in JSON_TRANSFORM", .{});
                    const target = ms[i].value;
                    const old: []const Value = if (target == .array) target.array else &.{target};
                    const out = try c.a().alloc(Value, old.len + 1);
                    @memcpy(out[0..old.len], old);
                    out[old.len] = value;
                    ms[i].value = .{ .array = out };
                },
                .keep => {},
            }
        },
        .array => |ranges_opt| {
            if (parent.* != .array) continue;
            const items = parent.array;
            const rs = ranges_opt orelse {
                if (op == .remove) parent.* = .{ .array = &.{} };
                if (op == .set or op == .replace) for (items) |*x| {
                    x.* = value;
                };
                continue;
            };
            if (rs.len != 1 or rs[0].to != null) return c.fail("ORA-40442: JSON path expression syntax error", .{});
            const idx = rangeIndex(rs[0].from, items.len);
            if (idx < 0) continue;
            const ui: usize = @intCast(idx);
            switch (op) {
                .set, .replace => {
                    if (ui < items.len) {
                        items[ui] = value;
                    } else if (op == .set) {
                        const out = try c.a().alloc(Value, items.len + 1);
                        @memcpy(out[0..items.len], items);
                        out[items.len] = value;
                        parent.* = .{ .array = out };
                    }
                },
                .insert => {
                    const at = @min(ui, items.len);
                    var list: std.ArrayList(Value) = .empty;
                    try list.appendSlice(c.a(), items);
                    try list.insert(c.a(), at, value);
                    parent.* = .{ .array = list.items };
                },
                .remove => if (ui < items.len) {
                    var list: std.ArrayList(Value) = .empty;
                    try list.appendSlice(c.a(), items);
                    _ = list.orderedRemove(ui);
                    parent.* = .{ .array = list.items };
                },
                .append => if (ui < items.len) {
                    const target = items[ui];
                    const old: []const Value = if (target == .array) target.array else &.{target};
                    const out = try c.a().alloc(Value, old.len + 1);
                    @memcpy(out[0..old.len], old);
                    out[old.len] = value;
                    items[ui] = .{ .array = out };
                },
                else => {},
            }
        },
        else => return c.fail("ORA-40442: JSON path expression syntax error", .{}),
    };
}

/// KEEP: only the values the paths name (and what leads to them) stay.
fn keep(c: *Call, root: *Value, paths: []const J.Path) Fail!void {
    var kept: std.AutoHashMapUnmanaged(*const Value, void) = .empty;
    for (paths) |path| {
        var ps: std.ArrayList(*Value) = .empty;
        try places(c, root, path.steps, &ps);
        for (ps.items) |x| try kept.put(c.a(), x, {});
    }
    // Nothing named: the document stays as it is.
    if (kept.count() == 0) return;
    _ = try prune(c, root, &kept);
}

/// Whether `v` stays: it is kept, or something under it is (then its
/// other members go).
fn prune(c: *Call, v: *Value, kept: *std.AutoHashMapUnmanaged(*const Value, void)) Fail!bool {
    if (kept.contains(v)) return true;
    switch (v.*) {
        .object => |ms| {
            var out: std.ArrayList(J.Member) = .empty;
            for (ms) |*m| if (try prune(c, &m.value, kept)) try out.append(c.a(), m.*);
            v.* = .{ .object = out.items };
            return out.items.len > 0;
        },
        .array => |items| {
            var out: std.ArrayList(Value) = .empty;
            for (items) |*x| if (try prune(c, x, kept)) try out.append(c.a(), x.*);
            v.* = .{ .array = out.items };
            return out.items.len > 0;
        },
        else => return false,
    }
}

/// xq_ora_json_transform(doc, opts, op, path, value, ...): op SET,
/// INSERT, REPLACE, APPEND, REMOVE, RENAME (value the new name) or KEEP.
fn transformFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 2 or (argv.len - 2) % 3 != 0) return api.resultError(ctx, "xq_ora_json_transform: wrong number of arguments");
    var c: Call = .init(ctx);
    defer c.deinit();
    const opts = optsText(argv[1]);
    var buf: [64]u8 = undefined;
    const text = docText(argv[0], &buf) orelse return api.resultNull(ctx);
    var doc = parseDoc(&c, text) catch |err| return c.report(err);
    var i: usize = 2;
    var keeps: std.ArrayList(J.Path) = .empty;
    while (i < argv.len) : (i += 3) {
        const op = opOf(optsText(argv[i])) orelse return api.resultError(ctx, "xq_ora_json_transform: bad operation");
        const path = parsePath(&c, optsText(argv[i + 1])) catch |err| return c.report(err);
        if (op == .keep) {
            keeps.append(c.a(), path) catch return api.resultErrorNomem(ctx);
            continue;
        }
        if (keeps.items.len > 0) {
            keep(&c, &doc, keeps.items) catch |err| return c.report(err);
            keeps.clearRetainingCapacity();
        }
        var value: Value = .null;
        var new_name: []const u8 = "";
        if (op == .rename) {
            new_name = c.a().dupe(u8, optsText(argv[i + 2])) catch return api.resultErrorNomem(ctx);
        } else if (op != .remove) {
            value = sqlToJson(&c, argv[i + 2]) catch |err| return c.report(err);
            if (value == .number) value = .{ .number = canonNumber(c.a(), value.number) catch return api.resultErrorNomem(ctx) };
        }
        applyOp(&c, &doc, op, path, value, new_name) catch |err| return c.report(err);
    }
    if (keeps.items.len > 0) keep(&c, &doc, keeps.items) catch |err| return c.report(err);
    finishOutput(&c, doc, opts);
}

// ============================================================ JSON_TABLE

/// JSON_TABLE as the eponymous virtual table xq_ora_json_table(doc, spec):
///
///   CREATE TABLE x(c0, ..., c99, doc HIDDEN, spec HIDDEN)
///
/// `spec` is JSON the parser writes (jsonsql.zig):
///
///   {"p": row path, "e": "N"|"E", "c": [column ...]}
///   column: {"k":"o"}                            FOR ORDINALITY
///           {"k":"v","t":TYPE,"p":path,"e":h,"m":h,"de":v,"dm":v,"tr":1}
///           {"k":"x","t":TYPE,"p":path,"e":h}    EXISTS PATH
///           {"k":"q","t":TYPE,"p":path,"w":"N|U|C","e":h,"m":h}  FORMAT JSON
///           {"k":"n","p":path,"c":[column ...]}  NESTED PATH
///
/// The columns are numbered depth first (c0, c1 ...), as the parser
/// refers to them. A row of the outer path with nested paths gives the
/// rows of each nested path in turn (the others' columns NULL), or one
/// row with them all NULL when none has a row: Oracle's outer join and
/// union of sibling NESTED paths.
pub const max_columns = 100;

const doc_column = max_columns;
const spec_column = max_columns + 1;

const Col = struct {
    kind: u8,
    ty: types.TypeName = .{ .name = "VARCHAR2", .precision = 4000 },
    path_text: []const u8 = "$",
    path: J.Path = .{},
    on_error: Handler = .null,
    on_empty: Handler = .inherit,
    def_error: ?Value = null,
    def_empty: ?Value = null,
    truncate: bool = false,
    wrapper: u8 = 'N',
    /// Its column number (not for 'n').
    index: usize = 0,
    nested: []Col = &.{},
};

const Spec = struct {
    path_text: []const u8,
    path: J.Path,
    error_on_error: bool,
    cols: []Col,
    n_cols: usize,
};

fn str(v: ?Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

fn readCols(c: *Call, list: ?Value, n: *usize) Fail![]Col {
    const items = if (list) |l| (if (l == .array) l.array else &.{}) else &.{};
    var out: std.ArrayList(Col) = .empty;
    for (items) |it| {
        const k = str(it.get("k"));
        var col: Col = .{ .kind = if (k.len > 0) k[0] else 'v' };
        if (col.kind == 'n') {
            col.path_text = str(it.get("p"));
            col.path = try parsePath(c, col.path_text);
            col.nested = try readCols(c, it.get("c"), n);
            try out.append(c.a(), col);
            continue;
        }
        col.index = n.*;
        n.* += 1;
        if (col.kind != 'o') {
            if (str(it.get("t")).len > 0) col.ty = returningType(str(it.get("t")));
            col.path_text = str(it.get("p"));
            col.path = try parsePath(c, col.path_text);
            col.on_error = handler(str(it.get("e")));
            col.on_empty = handler(str(it.get("m")));
            col.def_error = it.get("de");
            col.def_empty = it.get("dm");
            col.truncate = it.get("tr") != null;
            const w = str(it.get("w"));
            if (w.len > 0) col.wrapper = w[0];
        }
        try out.append(c.a(), col);
    }
    return out.items;
}

fn readSpec(c: *Call, text: []const u8) Fail!Spec {
    const v = J.parse(c.a(), text, .{ .lax = false }) catch return c.fail("xq_ora_json_table: bad specification", .{});
    var n: usize = 0;
    const p = str(v.get("p"));
    return .{
        .path_text = p,
        .path = try parsePath(c, p),
        .error_on_error = std.mem.eql(u8, str(v.get("e")), "E"),
        .cols = try readCols(c, v.get("c"), &n),
        .n_cols = n,
    };
}

/// The value of column `col` for the row item `item`.
fn columnCell(c: *Call, col: Col, item: Value, ordinal: usize) Fail!Cell {
    switch (col.kind) {
        'o' => return .{ .int = @intCast(ordinal) },
        'x' => {
            var e: J.Eval = .{ .a = c.a(), .strict = false, .root = item };
            const r = e.run(col.path, item) catch |err| switch (err) {
                error.OutOfMemory => |x| return x,
                error.Eval => &.{},
            };
            const fam = types.family(col.ty.name) orelse .varchar;
            if (fam == .varchar or fam == .char or fam == .clob) return .{ .text = if (r.len > 0) "true" else "false" };
            return .{ .int = @intFromBool(r.len > 0) };
        },
        'q' => {
            const spec: QuerySpec = .{ .ty = col.ty, .on_empty = col.on_empty, .on_error = col.on_error, .wrapper = col.wrapper, .pretty = false, .ascii = false };
            const t = try queryOf(c, item, col.path_text, col.path, spec, &.{});
            return if (t) |x| .{ .json = x } else .null;
        },
        else => {
            const spec: ValueSpec = .{ .ty = col.ty, .on_empty = col.on_empty, .on_error = col.on_error, .truncate = col.truncate };
            const de: ?Cell = if (col.def_empty) |d| try defaultCell(c, d, col) else null;
            const dr: ?Cell = if (col.def_error) |d| try defaultCell(c, d, col) else null;
            return valueOf(c, item, col.path_text, col.path, spec, de, dr, &.{});
        },
    }
}

fn defaultCell(c: *Call, d: Value, col: Col) Fail!Cell {
    return scalarAs(c, d, col.ty, true, col.path_text) catch |err| switch (err) {
        error.OutOfMemory => |x| return x,
        error.Ora => .null,
    };
}

const Row = []Cell;

/// The rows of `cols` for the item `item` (ordinal `ordinal`), appended
/// to `out`, `base` the row so far.
fn levelRows(c: *Call, cols: []const Col, item: Value, ordinal: usize, base: Row, out: *std.ArrayList(Row)) Fail!void {
    const row = try c.a().dupe(Cell, base);
    var n_nested: usize = 0;
    for (cols) |col| {
        if (col.kind == 'n') {
            n_nested += 1;
            continue;
        }
        row[col.index] = try columnCell(c, col, item, ordinal);
    }
    if (n_nested == 0) return out.append(c.a(), row);
    const before = out.items.len;
    for (cols) |col| {
        if (col.kind != 'n') continue;
        var e: J.Eval = .{ .a = c.a(), .strict = false, .root = item };
        const items = e.run(col.path, item) catch |err| switch (err) {
            error.OutOfMemory => |x| return x,
            error.Eval => &.{},
        };
        for (items, 1..) |x, k| try levelRows(c, col.nested, x, k, row, out);
    }
    if (out.items.len == before) try out.append(c.a(), row);
}

const JtVtab = struct {
    base: vtab.Vtab = .{},
    db: *int.Sqlite3,
};

const JtCursor = struct {
    base: vtab.VtabCursor = .{},
    db: *int.Sqlite3,
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    i: usize = 0,
    doc: ?[]const u8 = null,
    spec: ?[]const u8 = null,

    fn of(cur: *vtab.VtabCursor) *JtCursor {
        return @fieldParentPtr("base", cur);
    }
};

const schema_sql: [:0]const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var s: []const u8 = "CREATE TABLE x(";
    for (0..max_columns) |i| s = s ++ std.fmt.comptimePrint("c{d},", .{i});
    break :blk (s ++ "doc HIDDEN,spec HIDDEN)") ++ "";
};

fn jtConnect(db: *int.Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    @setEvalBranchQuota(10_000);
    const rc = vtab.declareVtab(db, schema_sql);
    if (rc == RC.OK) {
        const t = db.gpa.create(JtVtab) catch return RC.NOMEM;
        t.* = .{ .db = db };
        pp_vtab.* = &t.base;
        _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
    }
    return rc;
}

fn jtDisconnect(p: *vtab.Vtab) i32 {
    const t: *JtVtab = @fieldParentPtr("base", p);
    t.db.gpa.destroy(t);
    return RC.OK;
}

fn jtOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t: *JtVtab = @fieldParentPtr("base", p);
    const cur = t.db.gpa.create(JtCursor) catch return RC.NOMEM;
    cur.* = .{ .db = t.db, .arena = .init(t.db.gpa) };
    pp_cursor.* = &cur.base;
    return RC.OK;
}

fn jtClose(cur: *vtab.VtabCursor) i32 {
    const c = JtCursor.of(cur);
    c.arena.deinit();
    c.db.gpa.destroy(c);
    return RC.OK;
}

/// Both hidden arguments must be given (equality constraints).
fn jtBestIndex(_: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    var idx: [2]i32 = .{ -1, -1 };
    for (info.constraints, 0..) |cons, i| {
        if (cons.i_column != doc_column and cons.i_column != spec_column) continue;
        if (cons.op != vtab.INDEX_CONSTRAINT.EQ) continue;
        if (!cons.usable) return RC.CONSTRAINT;
        idx[@intCast(cons.i_column - doc_column)] = @intCast(i);
    }
    if (idx[0] < 0 or idx[1] < 0) {
        info.estimated_cost = 1e30;
        info.idx_num = 0;
        return RC.OK;
    }
    for (idx, 1..) |k, n| {
        info.usage[@intCast(k)].argv_index = @intCast(n);
        info.usage[@intCast(k)].omit = true;
    }
    info.estimated_cost = 1;
    info.estimated_rows = 100;
    info.idx_num = 1;
    return RC.OK;
}

fn jtFilter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const jc = JtCursor.of(cur);
    _ = jc.arena.reset(.retain_capacity);
    jc.rows = &.{};
    jc.i = 0;
    if (idx_num != 1 or argv.len != 2) {
        vtab.setErrMsg(jc.db, cur.vtab, "JSON_TABLE: missing arguments", .{});
        return RC.ERROR;
    }
    const a = jc.arena.allocator();
    var buf: [64]u8 = undefined;
    const doc_text = docText(argv[0], &buf) orelse return RC.OK;
    const doc_copy = a.dupe(u8, doc_text) catch return RC.NOMEM;
    const spec_text = a.dupe(u8, api.valueText(argv[1]) orelse "") catch return RC.NOMEM;
    // A Call without a context: errors become the table's message.
    var c: Call = .{ .ctx = undefined, .arena = .init(jc.db.gpa), .now = dt.DateTime.fromEpochSeconds(0) };
    defer c.deinit();
    const rows = tableRows(&c, doc_copy, spec_text) catch |err| switch (err) {
        error.OutOfMemory => return RC.NOMEM,
        error.Ora => {
            vtab.setErrMsg(jc.db, cur.vtab, "{s}", .{c.msg});
            return RC.ERROR;
        },
    };
    // Copy the rows into the cursor's arena.
    const out = a.alloc(Row, rows.len) catch return RC.NOMEM;
    for (rows, out) |r, *o| {
        o.* = a.alloc(Cell, r.len) catch return RC.NOMEM;
        for (r, o.*) |cell, *oc| oc.* = switch (cell) {
            .text => |t| .{ .text = a.dupe(u8, t) catch return RC.NOMEM },
            .json => |t| .{ .json = a.dupe(u8, t) catch return RC.NOMEM },
            .mem => .null,
            else => cell,
        };
    }
    jc.rows = out;
    jc.doc = doc_copy;
    jc.spec = spec_text;
    return RC.OK;
}

fn tableRows(c: *Call, doc_text: []const u8, spec_text: []const u8) Fail![]Row {
    const spec = try readSpec(c, spec_text);
    const doc = J.parse(c.a(), doc_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => |x| return x,
        error.Syntax => {
            if (spec.error_on_error) return c.fail("ORA-40441: JSON syntax error", .{});
            return &.{};
        },
    };
    var e: J.Eval = .{ .a = c.a(), .strict = false, .root = doc };
    const items = e.run(spec.path, doc) catch |err| switch (err) {
        error.OutOfMemory => |x| return x,
        error.Eval => &.{},
    };
    const base = try c.a().alloc(Cell, spec.n_cols);
    @memset(base, .null);
    var out: std.ArrayList(Row) = .empty;
    for (items, 1..) |x, k| try levelRows(c, spec.cols, x, k, base, &out);
    return out.items;
}

fn jtNext(cur: *vtab.VtabCursor) i32 {
    JtCursor.of(cur).i += 1;
    return RC.OK;
}

fn jtEof(cur: *vtab.VtabCursor) bool {
    const c = JtCursor.of(cur);
    return c.i >= c.rows.len;
}

fn jtColumn(cur: *vtab.VtabCursor, ctx: *Context, i: i32) i32 {
    const c = JtCursor.of(cur);
    const n: usize = @intCast(i);
    if (n == doc_column) {
        if (c.doc) |d| api.resultText(ctx, d, .transient) else api.resultNull(ctx);
        return RC.OK;
    }
    if (n == spec_column) {
        if (c.spec) |s| api.resultText(ctx, s, .transient) else api.resultNull(ctx);
        return RC.OK;
    }
    const row = c.rows[c.i];
    if (n >= row.len) {
        api.resultNull(ctx);
        return RC.OK;
    }
    resultCell(ctx, row[n]);
    return RC.OK;
}

fn jtRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = @intCast(JtCursor.of(cur).i + 1);
    return RC.OK;
}

pub const json_table_module: vtab.Module = .{
    .i_version = 0,
    .x_connect = jtConnect,
    .x_best_index = jtBestIndex,
    .x_disconnect = jtDisconnect,
    .x_open = jtOpen,
    .x_close = jtClose,
    .x_filter = jtFilter,
    .x_next = jtNext,
    .x_eof = jtEof,
    .x_column = jtColumn,
    .x_rowid = jtRowid,
};

pub const json_table_name = "xq_ora_json_table";

test "oracle json: canonical numbers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "1.50", "1.5" },  .{ "1e2", "100" },          .{ "1E-2", "0.01" }, .{ "-0", "0" },
        .{ "0.5", "0.5" },   .{ "123.456e1", "1234.56" }, .{ "-0.50", "-0.5" }, .{ "1e30", "1000000000000000000000000000000" },
        .{ "1.23e-10", "0.000000000123" }, .{ "10", "10" },
    };
    for (cases) |cs| try std.testing.expectEqualStrings(cs[1], try canonNumber(a, cs[0]));
}
