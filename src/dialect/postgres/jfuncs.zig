//! PostgreSQL's json/jsonb functions and operators (json.zig values,
//! jsonpath.zig paths).
//!
//! A json or jsonb value is TEXT: json as written, jsonb normalized
//! (json.zig). A function result that is json/jsonb carries SQLite's
//! JSON subtype ('J'), and a function that builds JSON (to_json(),
//! json_build_object(), json_agg() ...) embeds an argument with that
//! subtype as JSON, any other text as a string. The parser (jtype.zig)
//! wraps what it knows to be json/jsonb (a column, a parameter cast ...)
//! in xq_pg_json()/xq_pg_jsonb() and booleans in xq_pg_json_bool() so
//! that the subtype is there.
//!
//! Engine functions (operators, casts and the rewrites of the parser;
//! visible in every dialect, as the schema may hold them):
//!
//!   xq_pg_json(x), xq_pg_jsonb(x)       ::json (checked, as written),
//!                                       ::jsonb (normalized)
//!   xq_pg_json_bool(b)                  a boolean as JSON true/false
//!   xq_pg_json[b]_get[_text](j, k)      -> / ->> (k text: key, integer: index)
//!   xq_pg_json[b]_path[_text](j, p)     #> / #>> (p a text[] literal)
//!   xq_pg_jsonb_contains(a, b)          @> (and <@ swapped)
//!   xq_pg_jsonb_exists[_any|_all](a, k) ? ?| ?&
//!   xq_pg_jsonb_concat(a, b)            ||
//!   xq_pg_jsonb_delete(a, k)            - (text or integer)
//!   xq_pg_jsonb_delete_keys(a, p)       - text[]
//!   xq_pg_jsonb_delete_path(a, p)       #-
//!   xq_pg_jsonb_path_exists_op(a, q)    @?
//!   xq_pg_jsonb_path_match_op(a, q)     @@
//!   xq_pg_text_array(x)                 ::text[] (the literal, checked)
//!   xq_pg_array(...)                    ARRAY[...] as its text '{1,2}'
//!   xq_pg_array_to_json(a, pretty, num) array_to_json() of a text[] literal
//!   xq_pg_is_json(x, kind, unique)      IS JSON [VALUE|ARRAY|OBJECT|SCALAR]
//!   xq_pg_row_json(name, value, ...)    row_to_json() of a row the parser
//!                                       spelled out
//!   xq_pg_json_ctor_object(flags, ...)  JSON_OBJECT(), JSON_ARRAY() (flags:
//!   xq_pg_json_ctor_array(flags, ...)   1 jsonb, 2 ABSENT ON NULL, 4 UNIQUE)
//!   xq_pg_json_arrayagg(x, flags)       JSON_ARRAYAGG(), JSON_OBJECTAGG()
//!   xq_pg_json_objectagg(k, v, flags)
//!   xq_pg_json_agg_rows(x)              json_agg() of rows (", \n " between)
//!   xq_pg_rows_*(...)                   the rows of a set-returning function
//!                                       as a SQLite JSON array that
//!                                       json_each() reads (parser.zig)
//!
//! The functions of the dialect's table (PostgreSQL's names): to_json,
//! to_jsonb, array_to_json, row_to_json, json[b]_build_object/array,
//! json[b]_object, json[b]_agg, json[b]_object_agg, json[b]_typeof,
//! json[b]_array_length, json[b]_extract_path[_text], json[b]_strip_nulls,
//! jsonb_set, jsonb_set_lax, jsonb_insert, jsonb_pretty,
//! jsonb_path_exists/match/query_array/query_first.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const json = @import("json.zig");
const jsonpath = @import("jsonpath.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Value = json.Value;
const Allocator = std.mem.Allocator;
const FuncDef = int.FuncDef;

/// SQLite's subtype of JSON text (JSON_SUBTYPE).
pub const J: u32 = 'J';

/// Deterministic functions that read and set subtypes.
const det: dfunc.Options = .{ .deterministic = true, .subtype = true, .result_subtype = true };

fn s(name: [:0]const u8, n: i16, f: dfunc.StepFn) FuncDef {
    return dfunc.scalar(name, n, det, f);
}

/// s() for each argument count of `arities`.
fn ov(name: [:0]const u8, comptime arities: []const i16, f: dfunc.StepFn) [arities.len]FuncDef {
    return dfunc.overloads(name, arities, det, f);
}

/// The StepFn of `f`, which works in the arena of its call (Call).
fn inArena(comptime f: fn (*Call, []*Mem) void) dfunc.StepFn {
    return dfunc.withArena(Call, f);
}

fn agg(name: [:0]const u8, n: i16, step: dfunc.StepFn, final: dfunc.FinalFn) FuncDef {
    return dfunc.aggregate(name, n, det, step, final);
}

pub const engine_functions = [_]FuncDef{
    s("xq_pg_json", 1, inArena(castJson)),
    s("xq_pg_jsonb", 1, inArena(castJsonb)),
    s("xq_pg_json_bool", 1, jsonBool),
    s("xq_pg_json_get", 2, getJson),
    s("xq_pg_jsonb_get", 2, getJsonb),
    s("xq_pg_json_get_text", 2, getJsonText),
    s("xq_pg_jsonb_get_text", 2, getJsonbText),
    s("xq_pg_json_path", 2, pathJson),
    s("xq_pg_jsonb_path", 2, pathJsonb),
    s("xq_pg_json_path_text", 2, pathJsonText),
    s("xq_pg_jsonb_path_text", 2, pathJsonbText),
    s("xq_pg_jsonb_contains", 2, inArena(containsFunc)),
    s("xq_pg_jsonb_exists", 2, inArena(existsFunc)),
    s("xq_pg_jsonb_exists_any", 2, existsAnyFunc),
    s("xq_pg_jsonb_exists_all", 2, existsAllFunc),
    s("xq_pg_jsonb_concat", 2, inArena(concatFunc)),
    s("xq_pg_jsonb_delete", 2, inArena(deleteFunc)),
    s("xq_pg_jsonb_delete_keys", 2, inArena(deleteKeysFunc)),
    s("xq_pg_jsonb_delete_path", 2, inArena(deletePathFunc)),
    s("xq_pg_jsonb_path_exists_op", 2, pathExistsOp),
    s("xq_pg_jsonb_path_match_op", 2, pathMatchOp),
    s("xq_pg_text_array", 1, inArena(textArrayFunc)),
    s("xq_pg_array", -1, inArena(arrayFunc)),
    s("xq_pg_array_to_json", 3, arrayToJsonFunc),
    s("xq_pg_is_json", 3, inArena(isJsonFunc)),
    s("xq_pg_row_json", -1, inArena(rowJsonFunc)),
    s("xq_pg_json_ctor_object", -1, inArena(ctorObject)),
    s("xq_pg_json_ctor_array", -1, inArena(ctorArray)),
    agg("xq_pg_json_arrayagg", 2, arrayaggStep, arrayaggFinal),
    agg("xq_pg_json_objectagg", 3, objectaggStep, objectaggFinal),
    agg("xq_pg_json_agg_rows", 1, aggRowsStep, aggFinal),
    s("xq_pg_rows_each", 2, inArena(rowsEach)),
    s("xq_pg_rows_elements", 2, inArena(rowsElements)),
    s("xq_pg_rows_keys", 2, inArena(rowsKeys)),
    s("xq_pg_rows_path", 4, inArena(rowsPath)),
    s("xq_pg_rows_records", -1, inArena(rowsRecords)),
    s("xq_pg_rows_zip", -1, inArena(rowsZip)),
};

pub const functions = [_]FuncDef{
    s("to_json", 1, toJson),
    s("to_jsonb", 1, toJsonb),
    s("array_to_json", 1, arrayToJson),
    s("array_to_json", 2, arrayToJson),
    s("row_to_json", 1, inArena(rowToJson)),
    s("row_to_json", 2, inArena(rowToJson)),
    s("json_build_object", -1, inArena(buildObjectJson)),
    s("jsonb_build_object", -1, inArena(buildObjectJsonb)),
    s("json_build_array", -1, inArena(buildArrayJson)),
    s("jsonb_build_array", -1, inArena(buildArrayJsonb)),
    s("json_object", 1, objectJson),
    s("json_object", 2, objectJson),
    s("jsonb_object", 1, objectJsonb),
    s("jsonb_object", 2, objectJsonb),
    agg("json_agg", 1, aggJsonStep, aggFinal),
    agg("jsonb_agg", 1, aggJsonbStep, aggFinal),
    agg("json_object_agg", 2, objectAggJsonStep, objectAggJsonFinal),
    agg("jsonb_object_agg", 2, objectAggJsonbStep, objectAggJsonbFinal),
    s("json_typeof", 1, typeofJson),
    s("jsonb_typeof", 1, typeofJsonb),
    s("json_array_length", 1, arrayLengthJson),
    s("jsonb_array_length", 1, arrayLengthJsonb),
    s("json_extract_path", -1, extractPathJson),
    s("json_extract_path_text", -1, extractPathJsonText),
    s("jsonb_extract_path", -1, extractPathJsonb),
    s("jsonb_extract_path_text", -1, extractPathJsonbText),
    s("json_strip_nulls", 1, stripNullsJson),
    s("jsonb_strip_nulls", 1, stripNullsJsonb),
} ++
    ov("jsonb_set", &.{ 3, 4 }, inArena(setFunc)) ++
    ov("jsonb_set_lax", &.{ 3, 4, 5 }, inArena(setLaxFunc)) ++
    ov("jsonb_insert", &.{ 3, 4 }, inArena(insertFunc)) ++
    .{s("jsonb_pretty", 1, inArena(prettyFunc))} ++
    ov("jsonb_path_exists", &.{ 2, 3, 4 }, pathExistsFunc) ++
    ov("jsonb_path_match", &.{ 2, 3, 4 }, pathMatchFunc) ++
    ov("jsonb_path_query_array", &.{ 2, 3, 4 }, inArena(pathQueryArrayFunc)) ++
    ov("jsonb_path_query_first", &.{ 2, 3, 4 }, inArena(pathQueryFirstFunc));

const isNull = dfunc.isNull;
const anyNull = dfunc.anyNull;

// ================================================================ helpers

/// The arena of one call, on the connection's allocator.
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

    /// Argument `m` parsed as json (or jsonb, normalized); null after
    /// making the error the result.
    fn parse(c: *Call, m: *Mem, jsonb: bool) ?Value {
        const t = c.text(m) orelse return null;
        return c.parseText(t, jsonb);
    }

    fn parseText(c: *Call, t: []const u8, jsonb: bool) ?Value {
        const v = (if (jsonb) json.parseJsonb(c.a(), t) else json.parse(c.a(), t, false)) catch |e| {
            c.fail(e);
            return null;
        };
        return v;
    }

    fn fail(c: *Call, e: anyerror) void {
        switch (e) {
            error.OutOfMemory => api.resultErrorNomem(c.ctx),
            error.UnicodeEscape => api.resultErrorState(c.ctx, .of("22P05"), "unsupported Unicode escape sequence"),
            else => api.resultErrorState(c.ctx, .of("22P02"), "invalid input syntax for type json"),
        }
    }

    fn errFmt(c: *Call, comptime st: *const [5]u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(c.a(), fmt, args) catch return api.resultErrorNomem(c.ctx);
        api.resultErrorState(c.ctx, .of(st), msg);
    }

    /// Make `v` the result: json's text or jsonb's, with the subtype.
    fn result(c: *Call, v: Value, jsonb: bool) void {
        const t = json.toText(c.a(), v, jsonb) catch return api.resultErrorNomem(c.ctx);
        c.resultJsonText(t);
    }

    fn resultJsonText(c: *Call, t: []const u8) void {
        api.resultText(c.ctx, t, .transient);
        api.resultSubtype(c.ctx, J);
    }

    /// `->>`'s result of `v`.
    fn resultText(c: *Call, v: Value, jsonb: bool) void {
        const t = (json.toSqlText(c.a(), v, jsonb) catch return api.resultErrorNomem(c.ctx)) orelse return api.resultNull(c.ctx);
        api.resultText(c.ctx, t, .transient);
    }

    /// A text[] argument; null after making the error the result.
    fn textArray(c: *Call, m: *Mem) ?[]?[]const u8 {
        const t = c.text(m) orelse return null;
        return json.parseTextArray(c.a(), t) catch |e| {
            if (e == error.OutOfMemory) {
                api.resultErrorNomem(c.ctx);
            } else c.errFmt("22P02", "malformed array literal: \"{s}\"", .{t});
            return null;
        };
    }

    /// The JSON value an SQL value means: a number, a string, null, or
    /// the json of a value with the JSON subtype (normalized for jsonb).
    fn valueOf(c: *Call, m: *Mem, jsonb: bool) ?Value {
        return toValue(c.a(), m, jsonb) catch |e| {
            c.fail(e);
            return null;
        };
    }
};

pub fn toValue(a: Allocator, m: *Mem, jsonb: bool) json.Error!Value {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return json.null_value,
        vi.SQLITE_INTEGER => return .{ .v = .{ .number = try std.fmt.allocPrint(a, "{d}", .{api.valueInt64(m)}) } },
        vi.SQLITE_FLOAT => {
            const f = api.valueDouble(m);
            if (std.math.isNan(f)) return .{ .v = .{ .string = "NaN" } };
            if (std.math.isInf(f)) return .{ .v = .{ .string = if (f > 0) "Infinity" else "-Infinity" } };
            const t = try a.dupe(u8, api.valueText(m) orelse return error.OutOfMemory);
            const n: []const u8 = if (jsonb) (json.numericOut(a, t) catch t) else t;
            return .{ .v = .{ .number = n } };
        },
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse "";
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, "\\x");
            for (b) |byte| try out.print(a, "{x:0>2}", .{byte});
            return .{ .v = .{ .string = out.items } };
        },
        else => {
            const t = try a.dupe(u8, api.valueText(m) orelse return error.OutOfMemory);
            if (api.valueSubtype(m) == J) {
                return if (jsonb) json.parseJsonb(a, t) else json.parse(a, t, false);
            }
            return .{ .v = .{ .string = t } };
        },
    }
}

// ================================================================== casts

fn castJson(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const t = c.text(argv[0]) orelse return;
    _ = c.parseText(t, false) orelse return;
    c.resultJsonText(t);
}

fn castJsonb(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const v = c.parse(argv[0], true) orelse return;
    c.result(v, true);
}

fn jsonBool(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    api.resultText(ctx, if (api.valueInt64(argv[0]) != 0) "true" else "false", .static);
    api.resultSubtype(ctx, J);
}

fn textArrayFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const elems = c.textArray(argv[0]) orelse return;
    writeArray(c, elems);
}

fn writeArray(c: *Call, elems: []const ?[]const u8) void {
    var out: std.ArrayList(u8) = .empty;
    out.append(c.a(), '{') catch return api.resultErrorNomem(c.ctx);
    for (elems, 0..) |e, i| {
        if (i > 0) out.append(c.a(), ',') catch return api.resultErrorNomem(c.ctx);
        json.writeArrayElem(c.a(), &out, e) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(c.a(), '}') catch return api.resultErrorNomem(c.ctx);
    api.resultText(c.ctx, out.items, .transient);
}

fn arrayFunc(c: *Call, argv: []*Mem) void {
    const elems = c.a().alloc(?[]const u8, argv.len) catch return api.resultErrorNomem(c.ctx);
    for (argv, elems) |m, *e| {
        e.* = if (isNull(m)) null else (c.a().dupe(u8, c.text(m) orelse return) catch return api.resultErrorNomem(c.ctx));
    }
    writeArray(c, elems);
}

// ============================================================== operators

/// `->`: `k` an integer is an index (negative from the end), else a key.
fn get(ctx: *Context, argv: []*Mem, jsonb: bool, as_text: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.parse(argv[0], jsonb) orelse return;
    const r = switch (api.valueType(argv[1])) {
        vi.SQLITE_INTEGER => v.at(api.valueInt64(argv[1])),
        else => v.get(c.text(argv[1]) orelse return),
    } orelse return api.resultNull(ctx);
    if (as_text) c.resultText(r, jsonb) else c.result(r, jsonb);
}

const getJson = dfunc.bind(get, .{ false, false });
const getJsonb = dfunc.bind(get, .{ true, false });
const getJsonText = dfunc.bind(get, .{ false, true });
const getJsonbText = dfunc.bind(get, .{ true, true });

/// The value at `path` (keys of objects, indexes of arrays); null if
/// there is none.
fn walk(v: Value, path: []const ?[]const u8) ?Value {
    var cur = v;
    for (path) |step_opt| {
        const step = step_opt orelse return null;
        switch (cur.v) {
            .object => cur = cur.get(step) orelse return null,
            .array => {
                const i = std.fmt.parseInt(i64, std.mem.trim(u8, step, " "), 10) catch return null;
                cur = cur.at(i) orelse return null;
            },
            else => return null,
        }
    }
    return cur;
}

fn pathGet(ctx: *Context, argv: []*Mem, jsonb: bool, as_text: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.parse(argv[0], jsonb) orelse return;
    const path = c.textArray(argv[1]) orelse return;
    const r = walk(v, path) orelse return api.resultNull(ctx);
    if (as_text) c.resultText(r, jsonb) else c.result(r, jsonb);
}

const pathJson = dfunc.bind(pathGet, .{ false, false });
const pathJsonb = dfunc.bind(pathGet, .{ true, false });
const pathJsonText = dfunc.bind(pathGet, .{ false, true });
const pathJsonbText = dfunc.bind(pathGet, .{ true, true });

/// json_extract_path(j, VARIADIC path).
fn extractPath(ctx: *Context, argv: []*Mem, jsonb: bool, as_text: bool) void {
    if (argv.len == 0) return api.resultErrorState(ctx, .of("42883"), "function json_extract_path() does not exist");
    if (anyNull(argv)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.parse(argv[0], jsonb) orelse return;
    const path = c.a().alloc(?[]const u8, argv.len - 1) catch return api.resultErrorNomem(ctx);
    for (argv[1..], path) |m, *p| p.* = c.text(m) orelse return;
    const r = walk(v, path) orelse return api.resultNull(ctx);
    if (as_text) c.resultText(r, jsonb) else c.result(r, jsonb);
}

const extractPathJson = dfunc.bind(extractPath, .{ false, false });
const extractPathJsonText = dfunc.bind(extractPath, .{ false, true });
const extractPathJsonb = dfunc.bind(extractPath, .{ true, false });
const extractPathJsonbText = dfunc.bind(extractPath, .{ true, true });

fn containsFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    const y = c.parse(argv[1], true) orelse return;
    api.resultInt64(c.ctx, @intFromBool(json.contains(x, y)));
}

fn existsFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    api.resultInt64(c.ctx, @intFromBool(json.exists(x, c.text(argv[1]) orelse return)));
}

fn existsSet(ctx: *Context, argv: []*Mem, all: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const x = c.parse(argv[0], true) orelse return;
    const keys = c.textArray(argv[1]) orelse return;
    var r = all;
    for (keys) |k_opt| {
        const k = k_opt orelse continue;
        const e = json.exists(x, k);
        if (all and !e) r = false;
        if (!all and e) r = true;
    }
    api.resultInt64(ctx, @intFromBool(r));
}

const existsAnyFunc = dfunc.bind(existsSet, .{false});
const existsAllFunc = dfunc.bind(existsSet, .{true});

/// `||`: objects merge (the right one's values win), arrays append, a
/// scalar is an array of itself.
fn concatFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    const y = c.parse(argv[1], true) orelse return;
    var r = concat(c.a(), x, y) catch return api.resultErrorNomem(c.ctx);
    json.normalize(c.a(), &r) catch return api.resultErrorNomem(c.ctx);
    c.result(r, true);
}

pub fn concat(a: Allocator, x: Value, y: Value) json.Error!Value {
    if (x.v == .object and y.v == .object) {
        return .{ .v = .{ .object = try std.mem.concat(a, json.Pair, &.{ x.v.object, y.v.object }) } };
    }
    const xs: []const Value = if (x.v == .array) x.v.array else &.{x};
    const ys: []const Value = if (y.v == .array) y.v.array else &.{y};
    return .{ .v = .{ .array = try std.mem.concat(a, Value, &.{ xs, ys }) } };
}

/// `-`: a key (or the string elements equal to it), or an element by
/// index.
fn deleteFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    if (api.valueType(argv[1]) == vi.SQLITE_INTEGER) {
        switch (x.v) {
            .object => return api.resultErrorState(c.ctx, .of("22023"), "cannot delete from object using integer index"),
            .array => |items| {
                const n: i64 = @intCast(items.len);
                var i = api.valueInt64(argv[1]);
                if (i < 0) i += n;
                if (i < 0 or i >= n) return c.result(x, true);
                const k: usize = @intCast(i);
                const out = std.mem.concat(c.a(), Value, &.{ items[0..k], items[k + 1 ..] }) catch return api.resultErrorNomem(c.ctx);
                return c.result(.{ .v = .{ .array = out } }, true);
            },
            else => return api.resultErrorState(c.ctx, .of("22023"), "cannot delete from scalar"),
        }
    }
    const k = c.text(argv[1]) orelse return;
    const r = deleteKeys(c.a(), x, &.{k}) catch |e| return if (e == error.OutOfMemory) api.resultErrorNomem(c.ctx) else api.resultErrorState(c.ctx, .of("22023"), "cannot delete from scalar");
    c.result(r, true);
}

fn deleteKeys(a: Allocator, x: Value, keys: []const ?[]const u8) (json.Error || error{Scalar})!Value {
    const has = struct {
        fn f(ks: []const ?[]const u8, k: []const u8) bool {
            for (ks) |e| if (e != null and std.mem.eql(u8, e.?, k)) return true;
            return false;
        }
    }.f;
    switch (x.v) {
        .object => |pairs| {
            var out: std.ArrayList(json.Pair) = .empty;
            for (pairs) |pp| if (!has(keys, pp.key)) try out.append(a, pp);
            return .{ .v = .{ .object = out.items } };
        },
        .array => |items| {
            var out: std.ArrayList(Value) = .empty;
            for (items) |e| if (!(e.v == .string and has(keys, e.v.string))) try out.append(a, e);
            return .{ .v = .{ .array = out.items } };
        },
        else => return error.Scalar,
    }
}

fn deleteKeysFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    const keys = c.textArray(argv[1]) orelse return;
    const r = deleteKeys(c.a(), x, keys) catch |e| return if (e == error.OutOfMemory) api.resultErrorNomem(c.ctx) else api.resultErrorState(c.ctx, .of("22023"), "cannot delete from scalar");
    c.result(r, true);
}

// ========================================================= path updates

const SetOp = enum { set, insert_before, insert_after, delete };

const SetError = json.Error || error{Reported};

/// PostgreSQL's setPath(): `v` with the value at `path` set, inserted
/// or deleted. `create`: a missing last key (or index past the end) is
/// added.
fn setPath(c: *Call, v: Value, path: []const ?[]const u8, level: usize, new: Value, op: SetOp, create: bool) SetError!Value {
    if (level >= path.len) return v;
    const step = path[level] orelse {
        c.errFmt("22004", "path element at position {d} is null", .{level + 1});
        return error.Reported;
    };
    const last = level + 1 == path.len;
    switch (v.v) {
        .object => |pairs| {
            var out: std.ArrayList(json.Pair) = .empty;
            var found = false;
            for (pairs) |pp| {
                if (!found and std.mem.eql(u8, pp.key, step)) {
                    found = true;
                    if (last) switch (op) {
                        .delete => continue,
                        .set => {
                            try out.append(c.a(), .{ .key = pp.key, .value = new });
                            continue;
                        },
                        .insert_before, .insert_after => {
                            c.errFmt("22023", "cannot replace existing key", .{});
                            return error.Reported;
                        },
                    };
                    try out.append(c.a(), .{ .key = pp.key, .value = try setPath(c, pp.value, path, level + 1, new, op, create) });
                    continue;
                }
                try out.append(c.a(), pp);
            }
            if (!found and last and (create or op == .insert_before or op == .insert_after) and op != .delete) {
                try out.append(c.a(), .{ .key = step, .value = new });
            }
            var r: Value = .{ .v = .{ .object = out.items } };
            try json.normalize(c.a(), &r);
            return r;
        },
        .array => |items| {
            const idx_raw = std.fmt.parseInt(i64, std.mem.trim(u8, step, " "), 10) catch {
                c.errFmt("22P02", "path element at position {d} is not an integer: \"{s}\"", .{ level + 1, step });
                return error.Reported;
            };
            const n: i64 = @intCast(items.len);
            var idx = idx_raw;
            if (idx < 0) {
                if (-idx > n) {
                    idx = -1; // before the first
                } else idx += n;
            }
            var out: std.ArrayList(Value) = .empty;
            if (idx < 0 or idx >= n) {
                if (last and (create or op == .insert_before or op == .insert_after) and op != .delete) {
                    if (idx < 0) try out.append(c.a(), new);
                    try out.appendSlice(c.a(), items);
                    if (idx >= n) try out.append(c.a(), new);
                    return .{ .v = .{ .array = out.items } };
                }
                return v;
            }
            const k: usize = @intCast(idx);
            for (items, 0..) |e, i| {
                if (i != k) {
                    try out.append(c.a(), e);
                    continue;
                }
                if (!last) {
                    try out.append(c.a(), try setPath(c, e, path, level + 1, new, op, create));
                    continue;
                }
                switch (op) {
                    .delete => {},
                    .set => try out.append(c.a(), new),
                    .insert_before => {
                        try out.append(c.a(), new);
                        try out.append(c.a(), e);
                    },
                    .insert_after => {
                        try out.append(c.a(), e);
                        try out.append(c.a(), new);
                    },
                }
            }
            return .{ .v = .{ .array = out.items } };
        },
        else => {
            // A scalar inside the document: nothing to do.
            if (level > 0) return v;
            c.errFmt("22023", "{s}", .{if (op == .delete) "cannot delete path in scalar" else "cannot set path in scalar"});
            return error.Reported;
        },
    }
}

fn runSet(c: *Call, x: Value, path: []const ?[]const u8, new: Value, op: SetOp, create: bool) void {
    if (path.len == 0) return c.result(x, true);
    const r = setPath(c, x, path, 0, new, op, create) catch |e| switch (e) {
        error.Reported => return,
        else => return c.fail(e),
    };
    c.result(r, true);
}

fn deletePathFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    const path = c.textArray(argv[1]) orelse return;
    runSet(c, x, path, json.null_value, .delete, false);
}

/// jsonb_set(target, path, new [, create_missing]).
fn setFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    const path = c.textArray(argv[1]) orelse return;
    const new = c.parse(argv[2], true) orelse return;
    const create = argv.len < 4 or api.valueInt64(argv[3]) != 0;
    runSet(c, x, path, new, .set, create);
}

/// jsonb_set_lax(target, path, new [, create_missing [, null_value_treatment]]).
fn setLaxFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(c.ctx);
    for (argv[3..]) |m| if (isNull(m)) return api.resultErrorState(c.ctx, .of("22023"), "null_value_treatment must be \"delete_key\", \"return_target\", \"use_json_null\", or \"raise_exception\"");
    const x = c.parse(argv[0], true) orelse return;
    const path = c.textArray(argv[1]) orelse return;
    const create = argv.len < 4 or api.valueInt64(argv[3]) != 0;
    if (isNull(argv[2])) {
        const how = if (argv.len == 5) (c.text(argv[4]) orelse return) else "use_json_null";
        if (std.mem.eql(u8, how, "raise_exception")) return api.resultErrorState(c.ctx, .of("22004"), "JSON value must not be null");
        if (std.mem.eql(u8, how, "return_target")) return c.result(x, true);
        if (std.mem.eql(u8, how, "delete_key")) return runSet(c, x, path, json.null_value, .delete, false);
        if (!std.mem.eql(u8, how, "use_json_null")) return api.resultErrorState(c.ctx, .of("22023"), "null_value_treatment must be \"delete_key\", \"return_target\", \"use_json_null\", or \"raise_exception\"");
        return runSet(c, x, path, json.null_value, .set, create);
    }
    const new = c.parse(argv[2], true) orelse return;
    runSet(c, x, path, new, .set, create);
}

/// jsonb_insert(target, path, new [, insert_after]).
fn insertFunc(c: *Call, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(c.ctx);
    const x = c.parse(argv[0], true) orelse return;
    const path = c.textArray(argv[1]) orelse return;
    const new = c.parse(argv[2], true) orelse return;
    const after = argv.len == 4 and api.valueInt64(argv[3]) != 0;
    runSet(c, x, path, new, if (after) .insert_after else .insert_before, false);
}

// ============================================================== jsonpath

const PathArgs = struct { doc: Value, path: jsonpath.Path, vars: ?Value, silent: bool };

/// (target, path [, vars [, silent]]); null after reporting.
fn pathArgs(c: *Call, argv: []*Mem) ?PathArgs {
    const doc = c.parse(argv[0], true) orelse return null;
    var diag: jsonpath.Diag = .{};
    const ptext = c.text(argv[1]) orelse return null;
    const path = jsonpath.compile(c.a(), ptext, &diag) catch |e| {
        if (e == error.OutOfMemory) {
            api.resultErrorNomem(c.ctx);
        } else api.resultErrorState(c.ctx, diag.state orelse .of("42601"), diag.msg);
        return null;
    };
    var vars: ?Value = null;
    if (argv.len > 2 and !isNull(argv[2])) {
        const v = c.parse(argv[2], true) orelse return null;
        if (v.v != .object) {
            api.resultErrorState(c.ctx, .of("22023"), "\"vars\" argument is not an object");
            return null;
        }
        vars = v;
    }
    const silent = argv.len > 3 and api.valueInt64(argv[3]) != 0;
    return .{ .doc = doc, .path = path, .vars = vars, .silent = silent };
}

/// The items of the path; null after reporting (or, silent, an error
/// that is no result).
fn pathItems(c: *Call, pa: PathArgs, silent_empty: *bool) ?[]Value {
    var diag: jsonpath.Diag = .{};
    var x: jsonpath.Exec = .{ .a = c.a(), .root = pa.doc, .vars = pa.vars, .strict = pa.path.strict, .diag = &diag };
    return x.run(pa.path) catch |e| {
        if (e == error.OutOfMemory) {
            api.resultErrorNomem(c.ctx);
        } else if (pa.silent) {
            silent_empty.* = true;
        } else api.resultErrorState(c.ctx, diag.state.?, diag.msg);
        return null;
    };
}

fn pathExists(ctx: *Context, argv: []*Mem, silent_default: bool) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    var pa = pathArgs(&c, argv) orelse return;
    if (silent_default) pa.silent = true;
    var silent_err = false;
    const items = pathItems(&c, pa, &silent_err) orelse return if (silent_err) api.resultNull(ctx) else {};
    api.resultInt64(ctx, @intFromBool(items.len > 0));
}

const pathExistsFunc = dfunc.bind(pathExists, .{false});
const pathExistsOp = dfunc.bind(pathExists, .{true});

fn pathMatch(ctx: *Context, argv: []*Mem, silent_default: bool) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    var pa = pathArgs(&c, argv) orelse return;
    if (silent_default) pa.silent = true;
    var diag: jsonpath.Diag = .{};
    var x: jsonpath.Exec = .{ .a = c.a(), .root = pa.doc, .vars = pa.vars, .strict = pa.path.strict, .diag = &diag };
    const r = x.match(pa.path) catch |e| {
        if (e == error.OutOfMemory) return api.resultErrorNomem(ctx);
        if (pa.silent) return api.resultNull(ctx);
        return api.resultErrorState(ctx, diag.state.?, diag.msg);
    };
    if (r) |b| api.resultInt64(ctx, @intFromBool(b)) else api.resultNull(ctx);
}

const pathMatchFunc = dfunc.bind(pathMatch, .{false});
const pathMatchOp = dfunc.bind(pathMatch, .{true});

fn pathQueryArrayFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(c.ctx);
    const pa = pathArgs(c, argv) orelse return;
    var silent_err = false;
    const items = pathItems(c, pa, &silent_err) orelse return if (silent_err) c.result(.{ .v = .{ .array = &.{} } }, true) else {};
    c.result(.{ .v = .{ .array = items } }, true);
}

fn pathQueryFirstFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(c.ctx);
    const pa = pathArgs(c, argv) orelse return;
    var silent_err = false;
    const items = pathItems(c, pa, &silent_err) orelse return if (silent_err) api.resultNull(c.ctx) else {};
    if (items.len == 0) return api.resultNull(c.ctx);
    c.result(items[0], true);
}

// ========================================================== constructors

fn toJsonAny(ctx: *Context, argv: []*Mem, jsonb: bool) void {
    var c: Call = .init(ctx);
    defer c.deinit();
    if (isNull(argv[0])) return api.resultNull(ctx);
    const v = c.valueOf(argv[0], jsonb) orelse return;
    c.result(v, jsonb);
}

const toJson = dfunc.bind(toJsonAny, .{false});
const toJsonb = dfunc.bind(toJsonAny, .{true});

/// row_to_json() of a value that is already JSON (the parser spells a
/// row out as xq_pg_row_json()); pretty adds the line breaks.
fn rowToJson(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const v = c.valueOf(argv[0], false) orelse return;
    const pretty = argv.len == 2 and api.valueInt64(argv[1]) != 0;
    if (pretty and v.v == .object) {
        var out: std.ArrayList(u8) = .empty;
        const a = c.a();
        out.append(a, '{') catch return api.resultErrorNomem(c.ctx);
        for (v.v.object, 0..) |pp, i| {
            if (i > 0) out.appendSlice(a, ",\n ") catch return api.resultErrorNomem(c.ctx);
            json.writeString(a, &out, pp.key) catch return api.resultErrorNomem(c.ctx);
            out.append(a, ':') catch return api.resultErrorNomem(c.ctx);
            json.writeJson(a, &out, pp.value) catch return api.resultErrorNomem(c.ctx);
        }
        out.append(a, '}') catch return api.resultErrorNomem(c.ctx);
        return c.resultJsonText(out.items);
    }
    c.result(v, false);
}

/// xq_pg_row_json('a', a, 'b', b ...): row_to_json() of a row,
/// `{"a":1,"b":"x"}`.
fn rowJsonFunc(c: *Call, argv: []*Mem) void {
    const a = c.a();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '{') catch return api.resultErrorNomem(c.ctx);
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 2) {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        json.writeString(a, &out, c.text(argv[i]) orelse return) catch return api.resultErrorNomem(c.ctx);
        out.append(a, ':') catch return api.resultErrorNomem(c.ctx);
        const v = c.valueOf(argv[i + 1], false) orelse return;
        json.writeJson(a, &out, v) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, '}') catch return api.resultErrorNomem(c.ctx);
    c.resultJsonText(out.items);
}

/// array_to_json(text[] literal [, pretty]): elements that read as
/// numbers are numbers (the parser says xq_pg_array_to_json() when it
/// knows the element type).
fn arrayToJson(ctx: *Context, argv: []*Mem) void {
    arrayToJsonImpl(ctx, argv[0], argv.len == 2 and !isNull(argv[1]) and api.valueInt64(argv[1]) != 0, null);
}

fn arrayToJsonFunc(ctx: *Context, argv: []*Mem) void {
    arrayToJsonImpl(ctx, argv[0], !isNull(argv[1]) and api.valueInt64(argv[1]) != 0, api.valueInt64(argv[2]) != 0);
}

fn arrayToJsonImpl(ctx: *Context, arr: *Mem, pretty: bool, numeric: ?bool) void {
    if (isNull(arr)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const a = c.a();
    const elems = c.textArray(arr) orelse return;
    var num = numeric orelse true;
    if (numeric == null) for (elems) |e| if (e) |t| {
        _ = json.parse(a, t, false) catch {
            num = false;
            continue;
        };
        if (t.len == 0 or !(std.ascii.isDigit(t[0]) or t[0] == '-')) num = false;
    };
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(ctx);
    for (elems, 0..) |e, i| {
        if (i > 0) out.appendSlice(a, if (pretty) ",\n " else ",") catch return api.resultErrorNomem(ctx);
        if (e) |t| {
            if (num) {
                const v = json.parse(a, t, false) catch return api.resultErrorState(ctx, .of("22P02"), "invalid input syntax for type numeric");
                json.writeJson(a, &out, v) catch return api.resultErrorNomem(ctx);
            } else json.writeString(a, &out, t) catch return api.resultErrorNomem(ctx);
        } else out.appendSlice(a, "null") catch return api.resultErrorNomem(ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(ctx);
    c.resultJsonText(out.items);
}

const BuildOpts = struct { jsonb: bool, absent_on_null: bool = false, unique: bool = false, ctor: bool = false };

/// json_build_object(k, v, ...): `{"a" : 1, "b" : 2}` (jsonb: normalized).
fn buildObject(c: *Call, argv: []*Mem, o: BuildOpts) void {
    const a = c.a();
    if (argv.len % 2 != 0) return api.resultErrorState(c.ctx, .of("22023"), "argument list must have even number of elements");
    var pairs: std.ArrayList(json.Pair) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (isNull(argv[i])) {
            if (o.jsonb and !o.ctor) return c.errFmt("22004", "argument {d}: key must not be null", .{i + 1});
            return api.resultErrorState(c.ctx, .of("22004"), "null value not allowed for object key");
        }
        const kv = c.valueOf(argv[i], false) orelse return;
        const key = switch (kv.v) {
            .string => |t| t,
            else => json.toText(a, kv, false) catch return api.resultErrorNomem(c.ctx),
        };
        if (o.absent_on_null and isNull(argv[i + 1])) continue;
        const v = c.valueOf(argv[i + 1], o.jsonb) orelse return;
        if (o.unique) for (pairs.items) |pp| if (std.mem.eql(u8, pp.key, key)) {
            return c.errFmt("22030", "duplicate JSON object key value: \"{s}\"", .{key});
        };
        pairs.append(a, .{ .key = key, .value = v }) catch return api.resultErrorNomem(c.ctx);
    }
    var obj: Value = .{ .v = .{ .object = pairs.items } };
    if (o.jsonb) {
        json.normalize(a, &obj) catch return api.resultErrorNomem(c.ctx);
        return c.result(obj, true);
    }
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '{') catch return api.resultErrorNomem(c.ctx);
    for (pairs.items, 0..) |pp, k| {
        if (k > 0) out.appendSlice(a, ", ") catch return api.resultErrorNomem(c.ctx);
        json.writeString(a, &out, pp.key) catch return api.resultErrorNomem(c.ctx);
        out.appendSlice(a, " : ") catch return api.resultErrorNomem(c.ctx);
        json.writeJson(a, &out, pp.value) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, '}') catch return api.resultErrorNomem(c.ctx);
    c.resultJsonText(out.items);
}

/// json_build_array(...): `[1, 2]`.
fn buildArray(c: *Call, argv: []*Mem, o: BuildOpts) void {
    const a = c.a();
    var items: std.ArrayList(Value) = .empty;
    for (argv) |m| {
        if (o.absent_on_null and isNull(m)) continue;
        items.append(a, c.valueOf(m, o.jsonb) orelse return) catch return api.resultErrorNomem(c.ctx);
    }
    const arr: Value = .{ .v = .{ .array = items.items } };
    if (o.jsonb) return c.result(arr, true);
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (items.items, 0..) |v, k| {
        if (k > 0) out.appendSlice(a, ", ") catch return api.resultErrorNomem(c.ctx);
        json.writeJson(a, &out, v) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    c.resultJsonText(out.items);
}

fn buildObjectJson(c: *Call, argv: []*Mem) void {
    buildObject(c, argv, .{ .jsonb = false });
}
fn buildObjectJsonb(c: *Call, argv: []*Mem) void {
    buildObject(c, argv, .{ .jsonb = true });
}
fn buildArrayJson(c: *Call, argv: []*Mem) void {
    buildArray(c, argv, .{ .jsonb = false });
}
fn buildArrayJsonb(c: *Call, argv: []*Mem) void {
    buildArray(c, argv, .{ .jsonb = true });
}

fn ctorFlags(m: *Mem) BuildOpts {
    const f = api.valueInt64(m);
    return .{ .jsonb = f & 1 != 0, .absent_on_null = f & 2 != 0, .unique = f & 4 != 0, .ctor = true };
}

fn ctorObject(c: *Call, argv: []*Mem) void {
    buildObject(c, argv[1..], ctorFlags(argv[0]));
}
fn ctorArray(c: *Call, argv: []*Mem) void {
    buildArray(c, argv[1..], ctorFlags(argv[0]));
}

/// json_object(text[]) and json_object(keys text[], values text[]).
fn objectFromArrays(ctx: *Context, argv: []*Mem, jsonb: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const a = c.a();
    var keys: []?[]const u8 = undefined;
    var vals: []?[]const u8 = undefined;
    const first = c.textArray(argv[0]) orelse return;
    if (argv.len == 1) {
        if (first.len % 2 != 0) return api.resultErrorState(ctx, .of("2202E"), "array must have even number of elements");
        keys = a.alloc(?[]const u8, first.len / 2) catch return api.resultErrorNomem(ctx);
        vals = a.alloc(?[]const u8, first.len / 2) catch return api.resultErrorNomem(ctx);
        for (keys, vals, 0..) |*k, *v, i| {
            k.* = first[2 * i];
            v.* = first[2 * i + 1];
        }
    } else {
        keys = first;
        vals = c.textArray(argv[1]) orelse return;
        if (keys.len != vals.len) return api.resultErrorState(ctx, .of("2202E"), "mismatched array dimensions");
    }
    var pairs: std.ArrayList(json.Pair) = .empty;
    for (keys, vals) |k_opt, v_opt| {
        const k = k_opt orelse return api.resultErrorState(ctx, .of("22004"), "null value not allowed for object key");
        const v: Value = if (v_opt) |t| .{ .v = .{ .string = t } } else json.null_value;
        pairs.append(a, .{ .key = k, .value = v }) catch return api.resultErrorNomem(ctx);
    }
    var obj: Value = .{ .v = .{ .object = pairs.items } };
    if (jsonb) {
        json.normalize(a, &obj) catch return api.resultErrorNomem(ctx);
        return c.result(obj, true);
    }
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '{') catch return api.resultErrorNomem(ctx);
    for (pairs.items, 0..) |pp, i| {
        if (i > 0) out.appendSlice(a, ", ") catch return api.resultErrorNomem(ctx);
        json.writeString(a, &out, pp.key) catch return api.resultErrorNomem(ctx);
        out.appendSlice(a, " : ") catch return api.resultErrorNomem(ctx);
        json.writeJson(a, &out, pp.value) catch return api.resultErrorNomem(ctx);
    }
    out.append(a, '}') catch return api.resultErrorNomem(ctx);
    c.resultJsonText(out.items);
}

const objectJson = dfunc.bind(objectFromArrays, .{false});
const objectJsonb = dfunc.bind(objectFromArrays, .{true});

// ============================================================ aggregates

/// The state of an aggregate: a text buffer of the connection's
/// allocator and the number of items.
const Agg = struct {
    /// A text buffer of gpa(ctx), null before the first item.
    list: ?*std.ArrayList(u8),
    n: u64,
    /// JSON_OBJECTAGG(): 8 unique keys, 16 jsonb.
    kind: u64,
};

fn aggList(ctx: *Context, st: *Agg) ?*std.ArrayList(u8) {
    if (st.list) |l| return l;
    const l = dfunc.gpa(ctx).create(std.ArrayList(u8)) catch {
        api.resultErrorNomem(ctx);
        return null;
    };
    l.* = .empty;
    st.list = l;
    return l;
}

/// Take the buffer of the state (the caller frees it with aggFree()).
fn aggTake(st: *Agg) ?*std.ArrayList(u8) {
    const l = st.list orelse return null;
    st.list = null;
    return l;
}

fn aggFree(ctx: *Context, l: *std.ArrayList(u8)) void {
    l.deinit(dfunc.gpa(ctx));
    dfunc.gpa(ctx).destroy(l);
}

/// Append `sep` (unless first) and the JSON text of `m`.
fn aggAppend(ctx: *Context, st: *Agg, sep: []const u8, m: *Mem, jsonb: bool) void {
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.valueOf(m, jsonb) orelse return;
    const t = json.toText(c.a(), v, jsonb) catch return api.resultErrorNomem(ctx);
    aggAppendText(ctx, st, sep, t);
}

fn aggAppendText(ctx: *Context, st: *Agg, sep: []const u8, t: []const u8) void {
    const g = dfunc.gpa(ctx);
    const l = aggList(ctx, st) orelse return;
    if (st.n > 0) l.appendSlice(g, sep) catch return api.resultErrorNomem(ctx);
    l.appendSlice(g, t) catch return api.resultErrorNomem(ctx);
    st.n += 1;
}

fn aggJsonStep(ctx: *Context, argv: []*Mem) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    aggAppend(ctx, st, ", ", argv[0], false);
}

fn aggJsonbStep(ctx: *Context, argv: []*Mem) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    aggAppend(ctx, st, ", ", argv[0], true);
}

fn aggRowsStep(ctx: *Context, argv: []*Mem) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    // json_agg() puts a line break before each row but the first.
    aggAppend(ctx, st, ", \n ", argv[0], false);
}

/// '[' items ']', NULL for no rows.
fn aggFinal(ctx: *Context) void {
    const st = dfunc.aggState(Agg, ctx, false) orelse return api.resultNull(ctx);
    const l = aggTake(st) orelse return api.resultNull(ctx);
    defer aggFree(ctx, l);
    if (st.n == 0) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const t = std.mem.concat(c.a(), u8, &.{ "[", l.items, "]" }) catch return api.resultErrorNomem(ctx);
    c.resultJsonText(t);
}

/// json_object_agg(k, v): `{ "k" : v, ... }`.
fn objectAggStep(ctx: *Context, argv: []*Mem, jsonb: bool, absent_on_null: bool) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    if (isNull(argv[0])) return api.resultErrorState(ctx, .of("22004"), "null value not allowed for object key");
    if (absent_on_null and isNull(argv[1])) return;
    var c: Call = .init(ctx);
    defer c.deinit();
    const a = c.a();
    const kv = c.valueOf(argv[0], false) orelse return;
    const key = switch (kv.v) {
        .string => |t| t,
        else => json.toText(a, kv, false) catch return api.resultErrorNomem(ctx),
    };
    const v = c.valueOf(argv[1], jsonb) orelse return;
    var out: std.ArrayList(u8) = .empty;
    json.writeString(a, &out, key) catch return api.resultErrorNomem(ctx);
    out.appendSlice(a, if (jsonb) ": " else " : ") catch return api.resultErrorNomem(ctx);
    (if (jsonb) json.writeJsonb(a, &out, v) else json.writeJson(a, &out, v)) catch return api.resultErrorNomem(ctx);
    aggAppendText(ctx, st, ", ", out.items);
}

const objectAggJsonStep = dfunc.bind(objectAggStep, .{ false, false });
const objectAggJsonbStep = dfunc.bind(objectAggStep, .{ true, false });

fn objectFinal(ctx: *Context, jsonb: bool, unique: bool, empty_null: bool) void {
    const st = dfunc.aggState(Agg, ctx, false) orelse return if (empty_null) api.resultNull(ctx) else emptyObject(ctx, jsonb);
    const l = aggTake(st) orelse return if (empty_null) api.resultNull(ctx) else emptyObject(ctx, jsonb);
    defer aggFree(ctx, l);
    if (st.n == 0) return if (empty_null) api.resultNull(ctx) else emptyObject(ctx, jsonb);
    var c: Call = .init(ctx);
    defer c.deinit();
    if (!jsonb and !unique) {
        const t = std.mem.concat(c.a(), u8, &.{ "{ ", l.items, " }" }) catch return api.resultErrorNomem(ctx);
        return c.resultJsonText(t);
    }
    const t = std.mem.concat(c.a(), u8, &.{ "{", l.items, "}" }) catch return api.resultErrorNomem(ctx);
    var v = json.parse(c.a(), t, false) catch |e| return c.fail(e);
    if (unique) {
        const pairs = v.v.object;
        for (pairs, 0..) |pp, i| for (pairs[i + 1 ..]) |q| if (std.mem.eql(u8, pp.key, q.key)) {
            return c.errFmt("22030", "duplicate JSON object key value: \"{s}\"", .{pp.key});
        };
    }
    if (!jsonb) {
        const u = std.mem.concat(c.a(), u8, &.{ "{ ", l.items, " }" }) catch return api.resultErrorNomem(ctx);
        return c.resultJsonText(u);
    }
    json.normalize(c.a(), &v) catch return api.resultErrorNomem(ctx);
    c.result(v, true);
}

fn emptyObject(ctx: *Context, jsonb: bool) void {
    _ = jsonb;
    api.resultNull(ctx);
}

fn objectAggJsonFinal(ctx: *Context) void {
    objectFinal(ctx, false, false, true);
}
fn objectAggJsonbFinal(ctx: *Context) void {
    objectFinal(ctx, true, false, true);
}

/// JSON_ARRAYAGG(x, flags): ABSENT ON NULL (flags & 2) skips NULLs.
fn arrayaggStep(ctx: *Context, argv: []*Mem) void {
    const st = dfunc.aggState(Agg, ctx, true) orelse return;
    const o = ctorFlags(argv[1]);
    if (o.absent_on_null and isNull(argv[0])) return;
    aggAppend(ctx, st, ", ", argv[0], o.jsonb);
}

fn arrayaggFinal(ctx: *Context) void {
    aggFinal(ctx);
}

fn objectaggStep(ctx: *Context, argv: []*Mem) void {
    const o = ctorFlags(argv[2]);
    if (dfunc.aggState(Agg, ctx, true)) |st| st.kind = @as(u64, if (o.jsonb) 16 else 0) | @as(u64, if (o.unique) 8 else 0);
    objectAggStep(ctx, argv[0..2], o.jsonb, o.absent_on_null);
}

fn objectaggFinal(ctx: *Context) void {
    const st = dfunc.aggState(Agg, ctx, false) orelse return api.resultNull(ctx);
    objectFinal(ctx, st.kind & 16 != 0, st.kind & 8 != 0, true);
}

// ============================================================ processing

fn typeofAny(ctx: *Context, argv: []*Mem, jsonb: bool) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.parse(argv[0], jsonb) orelse return;
    api.resultText(ctx, v.typeName(), .static);
}

const typeofJson = dfunc.bind(typeofAny, .{false});
const typeofJsonb = dfunc.bind(typeofAny, .{true});

fn arrayLength(ctx: *Context, argv: []*Mem, jsonb: bool) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.parse(argv[0], jsonb) orelse return;
    switch (v.v) {
        .array => |items| api.resultInt64(ctx, @intCast(items.len)),
        .object => api.resultErrorState(ctx, .of("22023"), "cannot get array length of a non-array"),
        else => api.resultErrorState(ctx, .of("22023"), "cannot get array length of a scalar"),
    }
}

const arrayLengthJson = dfunc.bind(arrayLength, .{false});
const arrayLengthJsonb = dfunc.bind(arrayLength, .{true});

fn stripNulls(a: Allocator, v: Value) json.Error!Value {
    switch (v.v) {
        .object => |pairs| {
            var out: std.ArrayList(json.Pair) = .empty;
            for (pairs) |pp| {
                if (pp.value.v == .null) continue;
                try out.append(a, .{ .key = pp.key, .value = try stripNulls(a, pp.value) });
            }
            return .{ .v = .{ .object = out.items } };
        },
        .array => |items| {
            const out = try a.alloc(Value, items.len);
            for (items, out) |e, *o| o.* = try stripNulls(a, e);
            return .{ .v = .{ .array = out } };
        },
        else => return v,
    }
}

fn stripNullsAny(ctx: *Context, argv: []*Mem, jsonb: bool) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const v = c.parse(argv[0], jsonb) orelse return;
    const r = stripNulls(c.a(), v) catch return api.resultErrorNomem(ctx);
    c.result(r, jsonb);
}

const stripNullsJson = dfunc.bind(stripNullsAny, .{false});
const stripNullsJsonb = dfunc.bind(stripNullsAny, .{true});

fn prettyFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const v = c.parse(argv[0], true) orelse return;
    var out: std.ArrayList(u8) = .empty;
    json.writePretty(c.a(), &out, v, 0) catch return api.resultErrorNomem(c.ctx);
    api.resultText(c.ctx, out.items, .transient);
}

/// IS [NOT] JSON: kind 0 VALUE, 1 ARRAY, 2 OBJECT, 3 SCALAR; unique
/// WITH UNIQUE KEYS.
fn isJsonFunc(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const t = c.text(argv[0]) orelse return;
    const v = json.parse(c.a(), t, false) catch return api.resultInt64(c.ctx, 0);
    const kind = api.valueInt64(argv[1]);
    const ok = switch (kind) {
        1 => v.v == .array,
        2 => v.v == .object,
        3 => v.isScalar(),
        else => true,
    };
    if (ok and api.valueInt64(argv[2]) != 0 and hasDuplicateKeys(v)) return api.resultInt64(c.ctx, 0);
    api.resultInt64(c.ctx, @intFromBool(ok));
}

fn hasDuplicateKeys(v: Value) bool {
    switch (v.v) {
        .object => |pairs| {
            for (pairs, 0..) |pp, i| {
                for (pairs[i + 1 ..]) |q| if (std.mem.eql(u8, pp.key, q.key)) return true;
                if (hasDuplicateKeys(pp.value)) return true;
            }
        },
        .array => |items| for (items) |e| if (hasDuplicateKeys(e)) return true,
        else => {},
    }
    return false;
}

// ================================================= set-returning functions

/// The rows of a set-returning function as a SQLite JSON array (no
/// subtype: json_each() reads it as text), NULL for NULL input.
fn resultRows(c: *Call, rows: []const u8) void {
    api.resultText(c.ctx, rows, .transient);
}

const SrfName = struct { jsonb: bool, as_text: bool, name: []const u8 };

fn srfName(c: *Call, m: *Mem) ?SrfName {
    const n = c.text(m) orelse return null;
    return .{ .jsonb = std.mem.startsWith(u8, n, "jsonb"), .as_text = std.mem.endsWith(u8, n, "_text"), .name = n };
}

/// A row value: the text the function returns, as a JSON string (null
/// for SQL NULL).
fn rowItem(c: *Call, out: *std.ArrayList(u8), v: Value, n: SrfName) json.Error!void {
    const a = c.a();
    if (n.as_text) {
        const t = try json.toSqlText(a, v, n.jsonb) orelse return out.appendSlice(a, "null");
        return json.writeString(a, out, t);
    }
    try json.writeString(a, out, try json.toText(a, v, n.jsonb));
}

/// json_each(j) / jsonb_each_text(j) ...: [[key, value], ...].
fn rowsEach(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const n = srfName(c, argv[1]) orelse return;
    const v = c.parse(argv[0], n.jsonb) orelse return;
    if (v.v != .object) {
        if (n.jsonb) return c.errFmt("22023", "cannot call {s} on a non-object", .{n.name});
        return api.resultErrorState(c.ctx, .of("22023"), if (v.v == .array) "cannot deconstruct an array as an object" else "cannot deconstruct a scalar");
    }
    const a = c.a();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (v.v.object, 0..) |pp, i| {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
        json.writeString(a, &out, pp.key) catch return api.resultErrorNomem(c.ctx);
        out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        rowItem(c, &out, pp.value, n) catch return api.resultErrorNomem(c.ctx);
        out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    resultRows(c, out.items);
}

/// json_array_elements(j) ...: [value, ...].
fn rowsElements(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const n = srfName(c, argv[1]) orelse return;
    const v = c.parse(argv[0], n.jsonb) orelse return;
    switch (v.v) {
        .array => {},
        .object => return if (n.jsonb) api.resultErrorState(c.ctx, .of("22023"), "cannot extract elements from an object") else c.errFmt("22023", "cannot call {s} on a non-array", .{n.name}),
        else => return if (n.jsonb) api.resultErrorState(c.ctx, .of("22023"), "cannot extract elements from a scalar") else c.errFmt("22023", "cannot call {s} on a scalar", .{n.name}),
    }
    const a = c.a();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (v.v.array, 0..) |e, i| {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        rowItem(c, &out, e, n) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    resultRows(c, out.items);
}

/// json_object_keys(j): [key, ...].
fn rowsKeys(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(c.ctx);
    const n = srfName(c, argv[1]) orelse return;
    const v = c.parse(argv[0], n.jsonb) orelse return;
    switch (v.v) {
        .object => {},
        .array => return c.errFmt("22023", "cannot call {s} on an array", .{n.name}),
        else => return c.errFmt("22023", "cannot call {s} on a scalar", .{n.name}),
    }
    const a = c.a();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (v.v.object, 0..) |pp, i| {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        json.writeString(a, &out, pp.key) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    resultRows(c, out.items);
}

/// jsonb_path_query(j, path, vars, silent): [value, ...].
fn rowsPath(c: *Call, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(c.ctx);
    const pa = pathArgs(c, argv) orelse return;
    var silent_err = false;
    const items = pathItems(c, pa, &silent_err) orelse return if (silent_err) api.resultNull(c.ctx) else {};
    const a = c.a();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (items, 0..) |e, i| {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        rowItem(c, &out, e, .{ .jsonb = true, .as_text = false, .name = "" }) catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    resultRows(c, out.items);
}

/// json_to_record[set](j) / json_populate_record[set](base, j):
/// xq_pg_rows_records(j, name, col, ...): [[field text, ...], ...], a
/// field as the record's column reads it (a string unquoted, null NULL,
/// anything else its json text).
fn rowsRecords(c: *Call, argv: []*Mem) void {
    if (argv.len < 2 or isNull(argv[0])) return api.resultNull(c.ctx);
    const n = srfName(c, argv[1]) orelse return;
    const v = c.parse(argv[0], n.jsonb) orelse return;
    const set = std.mem.endsWith(u8, n.name, "set");
    const a = c.a();
    const cols = a.alloc([]const u8, argv.len - 2) catch return api.resultErrorNomem(c.ctx);
    for (argv[2..], cols) |m, *col| col.* = a.dupe(u8, c.text(m) orelse return) catch return api.resultErrorNomem(c.ctx);
    var rows: []const Value = undefined;
    if (set) {
        rows = switch (v.v) {
            .array => |items| items,
            else => return c.errFmt("22023", "cannot call {s} on {s}", .{ n.name, if (v.v == .object) "an object" else "a scalar" }),
        };
        for (rows) |r| if (r.v != .object) return c.errFmt("22023", "argument of {s} must be an array of objects", .{n.name});
    } else {
        if (v.v != .object) return c.errFmt("22023", "cannot call populate_composite on {s}", .{if (v.v == .array) "an array" else "a scalar"});
        rows = &.{v};
    }
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (rows, 0..) |r, i| {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
        for (cols, 0..) |col, k| {
            if (k > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
            const f = r.get(col) orelse json.null_value;
            rowItem(c, &out, f, .{ .jsonb = n.jsonb, .as_text = true, .name = n.name }) catch return api.resultErrorNomem(c.ctx);
        }
        out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    resultRows(c, out.items);
}

/// xq_pg_rows_zip(rows, ...): several select-list set-returning functions
/// in step: [[a0, b0], [a1, null], ...] as long as the longest.
fn rowsZip(c: *Call, argv: []*Mem) void {
    const a = c.a();
    const lists = a.alloc([]const Value, argv.len) catch return api.resultErrorNomem(c.ctx);
    var n: usize = 0;
    for (argv, lists) |m, *l| {
        if (isNull(m)) {
            l.* = &.{};
            continue;
        }
        const v = c.parse(m, false) orelse return;
        l.* = if (v.v == .array) v.v.array else &.{};
        n = @max(n, l.len);
    }
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
    for (0..n) |i| {
        if (i > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
        out.append(a, '[') catch return api.resultErrorNomem(c.ctx);
        for (lists, 0..) |l, k| {
            if (k > 0) out.append(a, ',') catch return api.resultErrorNomem(c.ctx);
            const e = if (i < l.len) l[i] else json.null_value;
            json.writeJson(a, &out, e) catch return api.resultErrorNomem(c.ctx);
        }
        out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    }
    out.append(a, ']') catch return api.resultErrorNomem(c.ctx);
    resultRows(c, out.items);
}

// ============================================================ collation

/// The collation xq_pg_jsonb: jsonb's order (json.compare()) of two
/// jsonb texts; two values of which one is not JSON compare as bytes.
pub fn collate(_: ?*anyopaque, x: []const u8, y: []const u8) std.math.Order {
    if (std.mem.eql(u8, x, y)) return .eq;
    // Small values parse on the stack, others (or when that is not
    // enough) on the heap.
    var buf: [16384]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    if (compareText(fba.allocator(), x, y)) |o| return o else |err| if (err != error.OutOfMemory) return std.mem.order(u8, x, y);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    return compareText(arena.allocator(), x, y) catch std.mem.order(u8, x, y);
}

fn compareText(a: Allocator, x: []const u8, y: []const u8) json.Error!std.math.Order {
    const vx = try json.parseJsonb(a, x);
    const vy = try json.parseJsonb(a, y);
    return json.compare(vx, vy);
}

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&engine_functions);
}
