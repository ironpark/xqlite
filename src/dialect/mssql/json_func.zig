//! The JSON functions of the T-SQL dialect, engine functions (xq_tsql_*,
//! visible in every dialect, so that views and computed columns may keep
//! them): JSON_VALUE, JSON_QUERY, JSON_MODIFY, ISJSON(x, type),
//! JSON_PATH_EXISTS, JSON_OBJECT, JSON_ARRAY, STRING_ESCAPE(x, 'json')
//! and the aggregate of FOR JSON. The text, paths and escaping are
//! json.zig's; OPENJSON is openjson.zig.
//!
//! Where SQL Server's output depends on the SQL type of a value (FOR
//! JSON, JSON_MODIFY, JSON_OBJECT: bit is true/false, float is
//! 1.500000000000000e+000, datetime has a T, binary is base64, the
//! result of JSON_QUERY, FOR JSON and the JSON functions is JSON and not
//! a string), the parser passes the type as a value kind (Kind), one
//! character per value.

const std = @import("std");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const json = @import("json.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const isNull = dfunc.isNull;
const Allocator = std.mem.Allocator;

/// How a value is written as JSON (the type SQL Server sees).
pub const Kind = enum(u8) {
    /// JSON text (JSON_QUERY, FOR JSON, JSON_MODIFY ...): as it is.
    json = 'j',
    /// A character string (or a uniqueidentifier).
    string = 's',
    /// bit: true or false.
    bit = 'b',
    /// float: 1.500000000000000e+000.
    float = 'f',
    /// real: 1.5000000e+000.
    real = 'r',
    /// A date or time: the space between date and time a T, none
    /// before the offset.
    temporal = 'd',
    /// binary/varbinary: base64.
    binary = 'x',
    /// By the storage class: integers and reals are numbers, text is a
    /// string, blobs base64.
    auto = 'a',

    pub fn of(c: u8) Kind {
        return std.enums.fromInt(Kind, c) orelse .auto;
    }
};

fn fail(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [400]u8 = undefined;
    api.resultError(ctx, std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

fn textError(ctx: *Context, z: []const u8, pos: usize) void {
    var buf: [200]u8 = undefined;
    api.resultError(ctx, json.textMessage(&buf, z, pos));
}

fn pathError(ctx: *Context, z: []const u8, pos: usize) void {
    var buf: [200]u8 = undefined;
    api.resultError(ctx, json.pathMessage(&buf, z, pos));
}

pub const not_found = "Property cannot be found on the specified JSON path.";
pub const no_container = "Object or array cannot be found in the specified JSON path.";
pub const no_scalar = "Scalar value cannot be found in the specified JSON path.";

/// The text of argument `m` (its bytes for a blob); null on OOM, after
/// making it the error.
fn argText(ctx: *Context, m: *Mem) ?[]const u8 {
    if (api.valueType(m) == vi.SQLITE_BLOB) return api.valueBlob(m) orelse "";
    return dfunc.text(ctx, m);
}

/// The path argument: an error for NULL (`func` names the function).
fn pathArg(ctx: *Context, a: Allocator, m: *Mem, func: []const u8, allow_append: bool) ?json.Path {
    if (isNull(m)) {
        fail(ctx, "Argument data type NULL is invalid for argument 2 of {s} function.", .{func});
        return null;
    }
    const z = argText(ctx, m) orelse return null;
    var perr: json.PathError = .{};
    return json.parsePath(a, z, allow_append, &perr) catch |err| switch (err) {
        error.OutOfMemory => {
            api.resultErrorNomem(ctx);
            return null;
        },
        error.BadPath => {
            pathError(ctx, z, perr.pos);
            return null;
        },
    };
}

fn arena(ctx: *Context) std.heap.ArenaAllocator {
    return .init(dfunc.gpa(ctx));
}

// ============================================================ functions

/// xq_tsql_json_value(json, path): the scalar at path as text (4000
/// characters at most), NULL for a container or nothing (lax), else an
/// error (strict).
pub fn jsonValueFunc(ctx: *Context, argv: []*Mem) void {
    var ar = arena(ctx);
    defer ar.deinit();
    const a = ar.allocator();
    const path = pathArg(ctx, a, argv[1], "JSON_VALUE", false) orelse return;
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = argText(ctx, argv[0]) orelse return;
    var err: json.SyntaxError = .{};
    const found = json.find(z, path.steps, &err) catch return textError(ctx, z, err.pos);
    const it = switch (found) {
        .missing => return if (path.strict) api.resultError(ctx, not_found) else api.resultNull(ctx),
        .item => |x| x,
    };
    if (it.isContainer()) return if (path.strict) api.resultError(ctx, no_scalar) else api.resultNull(ctx);
    const t = (json.scalarText(a, z, it) catch return api.resultErrorNomem(ctx)) orelse return api.resultNull(ctx);
    if (dfunc.charCount(t) > 4000) {
        if (path.strict) return api.resultError(ctx, "String value in the specified JSON path would be truncated.");
        return api.resultNull(ctx);
    }
    api.resultText(ctx, t, .transient);
}

/// xq_tsql_json_query(json [, path]): the object or array at path as
/// written, NULL for a scalar or nothing (lax), else an error (strict).
pub fn jsonQueryFunc(ctx: *Context, argv: []*Mem) void {
    var ar = arena(ctx);
    defer ar.deinit();
    const a = ar.allocator();
    const path: json.Path = if (argv.len > 1) pathArg(ctx, a, argv[1], "JSON_QUERY", false) orelse return else .{};
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = argText(ctx, argv[0]) orelse return;
    var err: json.SyntaxError = .{};
    const found = json.find(z, path.steps, &err) catch return textError(ctx, z, err.pos);
    const it = switch (found) {
        .missing => return if (path.strict) api.resultError(ctx, not_found) else api.resultNull(ctx),
        .item => |x| x,
    };
    if (!it.isContainer()) return if (path.strict) api.resultError(ctx, no_container) else api.resultNull(ctx);
    api.resultText(ctx, it.text(z), .transient);
}

/// xq_tsql_json_path_exists(json, path): 1 if the path has a value
/// (SQL Server 2022).
pub fn jsonPathExistsFunc(ctx: *Context, argv: []*Mem) void {
    var ar = arena(ctx);
    defer ar.deinit();
    const path = pathArg(ctx, ar.allocator(), argv[1], "JSON_PATH_EXISTS", false) orelse return;
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = argText(ctx, argv[0]) orelse return;
    var err: json.SyntaxError = .{};
    const found = json.find(z, path.steps, &err) catch return textError(ctx, z, err.pos);
    api.resultInt64(ctx, @intFromBool(found == .item));
}

/// xq_tsql_isjson(x, type): ISJSON with a type (SQL Server 2022): VALUE
/// (any JSON value), ARRAY, OBJECT or SCALAR (a string or a number).
/// ISJSON(x) without one is SQLite's json_valid() (the parser's CASE).
pub fn isjsonFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = argText(ctx, argv[0]) orelse return;
    const ty = dfunc.text(ctx, argv[1]) orelse return;
    const v = json.parseValue(z) orelse return api.resultInt64(ctx, 0);
    const ok = if (std.ascii.eqlIgnoreCase(ty, "array"))
        v.kind == .array
    else if (std.ascii.eqlIgnoreCase(ty, "object"))
        v.kind == .object
    else if (std.ascii.eqlIgnoreCase(ty, "scalar"))
        v.kind == .string or v.kind == .number
    else
        true;
    api.resultInt64(ctx, @intFromBool(ok));
}

/// xq_tsql_json_escape(s): STRING_ESCAPE(s, 'json').
pub fn jsonEscapeFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = argText(ctx, argv[0]) orelse return;
    var ar = arena(ctx);
    defer ar.deinit();
    var out: std.ArrayList(u8) = .empty;
    json.writeEscaped(ar.allocator(), &out, z) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
}

// ================================================================ values

/// Append value `m` of kind `kind` as JSON (a value that is not NULL).
pub fn writeValue(a: Allocator, out: *std.ArrayList(u8), m: *Mem, kind: Kind) error{OutOfMemory}!void {
    const ty = api.valueType(m);
    switch (kind) {
        .json => if (ty == vi.SQLITE_TEXT) return out.appendSlice(a, api.valueText(m) orelse ""),
        .bit => return out.appendSlice(a, if (api.valueDouble(m) != 0) "true" else "false"),
        .float, .real => if (ty == vi.SQLITE_INTEGER or ty == vi.SQLITE_FLOAT) {
            return writeFloat(a, out, api.valueDouble(m), if (kind == .float) 15 else 7);
        },
        .temporal => if (ty == vi.SQLITE_TEXT) {
            const t = api.valueText(m) orelse "";
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(a);
            var date_seen = false;
            for (t, 0..) |c, i| {
                if (c == ' ') {
                    // 2024-01-02 03:04 -> 2024-01-02T03:04; 05 +02:00 -> 05+02:00
                    if (!date_seen and i > 0 and std.ascii.isDigit(t[i - 1]) and std.mem.indexOfScalar(u8, t[0..i], '-') != null) {
                        try tmp.append(a, 'T');
                        date_seen = true;
                        continue;
                    }
                    if (i + 1 < t.len and (t[i + 1] == '+' or t[i + 1] == '-')) continue;
                }
                try tmp.append(a, c);
            }
            return json.writeString(a, out, tmp.items);
        },
        .string => if (ty != vi.SQLITE_BLOB) return json.writeString(a, out, api.valueText(m) orelse ""),
        else => {},
    }
    switch (ty) {
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => {
            const t = api.valueText(m) orelse "";
            // SQLite's text of a real is JSON but for "Inf".
            if (std.mem.indexOfAny(u8, t, "In") != null) return json.writeString(a, out, t);
            try out.appendSlice(a, t);
        },
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse "";
            const enc = std.base64.standard.Encoder;
            const buf = try a.alloc(u8, enc.calcSize(b.len));
            defer a.free(buf);
            // Base64 needs no escapes (SQL Server leaves its / alone).
            try out.append(a, '"');
            try out.appendSlice(a, enc.encode(buf, b));
            try out.append(a, '"');
        },
        else => try json.writeString(a, out, api.valueText(m) orelse ""),
    }
}

/// SQL Server's text of a float (digits 15) or real (7):
/// d.ddd...e+XXX.
fn writeFloat(a: Allocator, out: *std.ArrayList(u8), x: f64, digits: u8) error{OutOfMemory}!void {
    var buf: [64]u8 = undefined;
    const t = (if (digits == 15)
        std.fmt.bufPrint(&buf, "{e:.15}", .{x})
    else
        std.fmt.bufPrint(&buf, "{e:.7}", .{@as(f64, @as(f32, @floatCast(x)))})) catch return;
    const e = std.mem.indexOfScalar(u8, t, 'e') orelse return out.appendSlice(a, t);
    const exp = std.fmt.parseInt(i32, t[e + 1 ..], 10) catch 0;
    try out.appendSlice(a, t[0..e]);
    var eb: [16]u8 = undefined;
    try out.appendSlice(a, std.fmt.bufPrint(&eb, "e{c}{d:0>3}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch "");
}

// ============================================================ JSON_MODIFY

/// xq_tsql_json_modify(json, path, value, kind): the document with the
/// value at path set (replaced or added), deleted (NULL in lax mode) or
/// appended to (append).
pub fn jsonModifyFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var ar = arena(ctx);
    defer ar.deinit();
    const a = ar.allocator();
    const z = argText(ctx, argv[0]) orelse return;
    var err: json.SyntaxError = .{};
    const doc = json.parse(z, &err) catch return textError(ctx, z, err.pos);
    const path = pathArg(ctx, a, argv[1], "JSON_MODIFY", true) orelse return;
    if (path.steps.len == 0 and !path.append) return api.resultError(ctx, "Unsupported JSON path found in argument 2 of JSON_MODIFY.");
    const vkind = kindArg(ctx, argv) orelse return;
    const out = modify(a, z, doc, path, argv[2], vkind) catch |e| switch (e) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.NotFound => return api.resultError(ctx, not_found),
        error.NotArray => return api.resultError(ctx, "Array cannot be found in the specified JSON path."),
    };
    api.resultText(ctx, out, .transient);
}

fn kindArg(ctx: *Context, argv: []*Mem) ?Kind {
    if (argv.len < 4) return .auto;
    const t = dfunc.text(ctx, argv[3]) orelse return null;
    return if (t.len > 0) Kind.of(t[0]) else .auto;
}

const ModifyError = error{ OutOfMemory, NotFound, NotArray };

fn modify(a: Allocator, z: []const u8, doc: json.Item, path: json.Path, value: *Mem, kind: Kind) ModifyError![]const u8 {
    const steps = path.steps;
    var val: std.ArrayList(u8) = .empty;
    const is_null = isNull(value);
    if (is_null) try val.appendSlice(a, "null") else try writeValue(a, &val, value, kind);

    if (path.append) {
        const target = json.lookup(z, doc, steps);
        if (target) |t| {
            if (t.kind != .array) return if (path.strict) error.NotArray else z;
            return insertInto(a, z, t, null, val.items);
        }
        if (path.strict) return error.NotFound;
        // A new array of the value, where a property can be added.
        if (steps.len == 0 or steps[steps.len - 1] != .key) return z;
        const parent = json.lookup(z, doc, steps[0 .. steps.len - 1]) orelse return z;
        if (parent.kind != .object) return z;
        var arr: std.ArrayList(u8) = .empty;
        try arr.append(a, '[');
        try arr.appendSlice(a, val.items);
        try arr.append(a, ']');
        return insertInto(a, z, parent, steps[steps.len - 1].key, arr.items);
    }

    const parent = json.lookup(z, doc, steps[0 .. steps.len - 1]) orelse return if (path.strict) error.NotFound else z;
    const last = steps[steps.len - 1];
    const want: json.Kind = if (last == .key) .object else .array;
    if (parent.kind != want) return if (path.strict) error.NotFound else z;
    var m: json.Members = .open(z, parent.start);
    var err: json.SyntaxError = .{};
    var prev_comma: ?usize = null;
    while (m.next(0, &err) catch unreachable) |e| {
        const hit = switch (last) {
            .key => |k| json.keyEquals(e.key.?.text(z), k),
            .index => |n| e.index == n,
        };
        // m.i: the comma after the member, or the closing bracket.
        const comma_after: ?usize = if (z[m.i] == ',') m.i else null;
        if (!hit) {
            prev_comma = comma_after;
            continue;
        }
        if (is_null and !path.strict and last == .key) {
            // Delete the member with the comma after it, or (the last)
            // with the comma before it.
            if (comma_after) |c| return splice(a, z, e.start, c + 1, "");
            if (prev_comma) |c| return splice(a, z, c, e.value.end, "");
            return splice(a, z, e.start, e.value.end, "");
        }
        return splice(a, z, e.value.start, e.value.end, val.items);
    }
    if (path.strict) return error.NotFound;
    if (last == .index or is_null) return z;
    return insertInto(a, z, parent, last.key, val.items);
}

/// `z` with z[from..to] replaced by `with`.
fn splice(a: Allocator, z: []const u8, from: usize, to: usize, with: []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.concat(a, u8, &.{ z[0..from], with, z[to..] });
}

/// `z` with a member (`key`: `v`, or the element `v`) added at the end
/// of container `c`, just before its closing bracket.
fn insertInto(a: Allocator, z: []const u8, c: json.Item, key: ?[]const u8, v: []const u8) error{OutOfMemory}![]const u8 {
    var piece: std.ArrayList(u8) = .empty;
    const empty = json.skipWs(z, c.start + 1) == c.end - 1;
    if (!empty) try piece.append(a, ',');
    if (key) |k| {
        try json.writeString(a, &piece, k);
        try piece.append(a, ':');
    }
    try piece.appendSlice(a, v);
    return splice(a, z, c.end - 1, c.end - 1, piece.items);
}

// ======================================================= JSON_OBJECT/ARRAY

/// xq_tsql_json_object(options, kinds, key, value, ...): SQL Server
/// 2022's JSON_OBJECT; options 'absent' leaves out NULL values.
pub const jsonObjectFunc = dfunc.bind(build, .{true});

/// xq_tsql_json_array(options, kinds, value, ...): JSON_ARRAY; options
/// 'null' writes NULLs (ABSENT ON NULL is the default).
pub const jsonArrayFunc = dfunc.bind(build, .{false});

fn build(ctx: *Context, argv: []*Mem, object: bool) void {
    var ar = arena(ctx);
    defer ar.deinit();
    const a = ar.allocator();
    const opts = dfunc.text(ctx, argv[0]) orelse return;
    const kinds = dfunc.text(ctx, argv[1]) orelse return;
    const absent = std.mem.eql(u8, opts, "absent");
    var out: std.ArrayList(u8) = .empty;
    out.append(a, if (object) '{' else '[') catch return api.resultErrorNomem(ctx);
    const step: usize = if (object) 2 else 1;
    var i: usize = 2;
    var n: usize = 0;
    var first = true;
    while (i + step - 1 < argv.len) : ({
        i += step;
        n += 1;
    }) {
        const v = argv[i + step - 1];
        if (isNull(v) and absent) continue;
        if (!first) out.append(a, ',') catch return api.resultErrorNomem(ctx);
        first = false;
        if (object) {
            if (isNull(argv[i])) return api.resultError(ctx, "JSON_OBJECT key cannot be NULL.");
            json.writeString(a, &out, argText(ctx, argv[i]) orelse return) catch return api.resultErrorNomem(ctx);
            out.append(a, ':') catch return api.resultErrorNomem(ctx);
        }
        if (isNull(v)) {
            out.appendSlice(a, "null") catch return api.resultErrorNomem(ctx);
        } else {
            const k: Kind = if (n < kinds.len) Kind.of(kinds[n]) else .auto;
            writeValue(a, &out, v, k) catch return api.resultErrorNomem(ctx);
        }
    }
    out.append(a, if (object) '}' else ']') catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
}

// ============================================================== FOR JSON

/// The state of xq_tsql_for_json(): the spec (read at the first row)
/// and the text so far.
///
/// The spec is a JSON array the parser writes:
///
///     [auto, include_null_values, without_array_wrapper, root|null,
///      [[name, kind, level], ...], [level name, ...]]
///
/// In PATH mode (auto 0) a dotted name is a property of nested objects
/// (`a.b`: {"a":{"b":..}}, the objects of adjacent columns merged, an
/// object without values left out); there is one level. In AUTO mode
/// level 0 is the first table of the select list, and each next table's
/// columns are an array of objects named after the table in the object
/// of the level before; consecutive rows with the same values of a
/// level share its object.
const ForJson = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    out: std.ArrayList(u8) = .empty,
    auto: bool = false,
    nulls: bool = false,
    wrap: bool = true,
    root: ?[]u8 = null,
    cols: []Col = &.{},
    levels: [][]const u8 = &.{},
    /// The values of each level in the last row (their JSON).
    prev: []?[]u8 = &.{},
    rows: u64 = 0,

    const Col = struct { segs: []const []const u8, kind: Kind, level: u32 };

    fn deinit(st: *ForJson) void {
        st.out.deinit(st.gpa);
        for (st.prev) |p| if (p) |x| st.gpa.free(x);
        st.arena.deinit();
        st.gpa.destroy(st);
    }
};

/// The elements of the array at `it` (a valid spec).
fn specItems(a: Allocator, spec: []const u8, it: json.Item) error{ OutOfMemory, BadSpec }![]json.Item {
    if (it.kind != .array) return error.BadSpec;
    var err: json.SyntaxError = .{};
    var out: std.ArrayList(json.Item) = .empty;
    var m: json.Members = .open(spec, it.start);
    while (m.next(0, &err) catch return error.BadSpec) |e| try out.append(a, e.value);
    return out.items;
}

fn specString(a: Allocator, spec: []const u8, it: json.Item) error{ OutOfMemory, BadSpec }![]u8 {
    if (it.kind != .string) return error.BadSpec;
    return json.decodeString(a, it.text(spec));
}

/// Read the spec (a constant the parser wrote).
fn readSpec(st: *ForJson, spec: []const u8) error{ OutOfMemory, BadSpec }!void {
    const a = st.arena.allocator();
    var err: json.SyntaxError = .{};
    const doc = json.parse(spec, &err) catch return error.BadSpec;
    const parts = try specItems(a, spec, doc);
    if (parts.len != 6) return error.BadSpec;
    st.auto = std.mem.eql(u8, parts[0].text(spec), "1");
    st.nulls = std.mem.eql(u8, parts[1].text(spec), "1");
    st.wrap = !std.mem.eql(u8, parts[2].text(spec), "1");
    if (parts[3].kind == .string) st.root = try specString(a, spec, parts[3]);
    var cols: std.ArrayList(ForJson.Col) = .empty;
    for (try specItems(a, spec, parts[4])) |c| {
        const f = try specItems(a, spec, c);
        if (f.len != 3) return error.BadSpec;
        const name = try specString(a, spec, f[0]);
        const kind = try specString(a, spec, f[1]);
        var segs: std.ArrayList([]const u8) = .empty;
        if (st.auto) {
            try segs.append(a, name);
        } else {
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |sg| try segs.append(a, sg);
        }
        try cols.append(a, .{
            .segs = segs.items,
            .kind = if (kind.len > 0) Kind.of(kind[0]) else .auto,
            .level = std.fmt.parseInt(u32, f[2].text(spec), 10) catch 0,
        });
    }
    st.cols = cols.items;
    var levels: std.ArrayList([]const u8) = .empty;
    for (try specItems(a, spec, parts[5])) |l| try levels.append(a, try specString(a, spec, l));
    if (levels.items.len == 0) try levels.append(a, "");
    st.levels = levels.items;
    st.prev = try a.alloc(?[]u8, levels.items.len);
    @memset(st.prev, null);
}

/// xq_tsql_for_json(spec, v1, ..., vn): a row of FOR JSON.
pub fn forJsonStep(ctx: *Context, argv: []*Mem) void {
    const slot = dfunc.aggState(?*ForJson, ctx, true) orelse return;
    const st = slot.* orelse blk: {
        const gpa = dfunc.gpa(ctx);
        const st = gpa.create(ForJson) catch return api.resultErrorNomem(ctx);
        st.* = .{ .gpa = gpa, .arena = .init(gpa) };
        slot.* = st;
        const spec = dfunc.text(ctx, argv[0]) orelse return;
        readSpec(st, spec) catch |err| switch (err) {
            error.OutOfMemory => return api.resultErrorNomem(ctx),
            error.BadSpec => return api.resultError(ctx, "xqlite: bad FOR JSON spec"),
        };
        break :blk st;
    };
    forJsonRow(st, argv[1..]) catch return api.resultErrorNomem(ctx);
}

fn forJsonRow(st: *ForJson, vals: []*Mem) error{OutOfMemory}!void {
    const a = st.gpa;
    const k = st.levels.len;
    // The values of each level, to compare with the last row's.
    const keys = try a.alloc(?[]u8, k);
    @memset(keys, null);
    defer {
        for (keys) |x| if (x) |y| a.free(y);
        a.free(keys);
    }
    if (k > 1) for (0..k) |j| {
        var t: std.ArrayList(u8) = .empty;
        errdefer t.deinit(a);
        for (st.cols, 0..) |c, i| {
            if (c.level != j or i >= vals.len) continue;
            if (isNull(vals[i])) try t.appendSlice(a, "null") else try writeValue(a, &t, vals[i], c.kind);
            try t.append(a, ',');
        }
        keys[j] = try t.toOwnedSlice(a);
    };
    var d: usize = 0;
    if (st.rows > 0) {
        d = k - 1;
        for (0..k - 1) |j| {
            const same = if (st.prev[j]) |p| (keys[j] != null and std.mem.eql(u8, p, keys[j].?)) else false;
            if (!same) {
                d = j;
                break;
            }
        }
        var j = k;
        while (j > d) {
            j -= 1;
            try closeLevel(st, j);
        }
        try st.out.append(a, ',');
    }
    for (d..k) |j| try openLevel(st, j, vals);
    for (0..k) |j| {
        if (st.prev[j]) |p| a.free(p);
        st.prev[j] = keys[j];
        keys[j] = null;
    }
    st.rows += 1;
}

fn closeLevel(st: *ForJson, j: usize) error{OutOfMemory}!void {
    if (j + 1 < st.levels.len) try st.out.append(st.gpa, ']');
    try st.out.append(st.gpa, '}');
}

/// Open the object of level `j` for the row: its members, and the array
/// of the next level.
fn openLevel(st: *ForJson, j: usize, vals: []*Mem) error{OutOfMemory}!void {
    const a = st.gpa;
    const out = &st.out;
    try out.append(a, '{');
    // The objects of dotted names open (PATH), and whether each object
    // (the row's first) has a member yet.
    var open: std.ArrayList([]const u8) = .empty;
    defer open.deinit(a);
    var has: std.ArrayList(bool) = .empty;
    defer has.deinit(a);
    try has.append(a, false);
    for (st.cols, 0..) |c, i| {
        if (c.level != j or i >= vals.len) continue;
        const v = vals[i];
        if (isNull(v) and !st.nulls) continue;
        const obj = c.segs[0 .. c.segs.len - 1];
        var common: usize = 0;
        while (common < open.items.len and common < obj.len and std.mem.eql(u8, open.items[common], obj[common])) common += 1;
        while (open.items.len > common) {
            _ = open.pop();
            _ = has.pop();
            try out.append(a, '}');
        }
        for (obj[open.items.len..]) |seg| {
            if (has.items[has.items.len - 1]) try out.append(a, ',');
            has.items[has.items.len - 1] = true;
            try json.writeString(a, out, seg);
            try out.appendSlice(a, ":{");
            try open.append(a, seg);
            try has.append(a, false);
        }
        if (has.items[has.items.len - 1]) try out.append(a, ',');
        has.items[has.items.len - 1] = true;
        try json.writeString(a, out, c.segs[c.segs.len - 1]);
        try out.append(a, ':');
        if (isNull(v)) try out.appendSlice(a, "null") else try writeValue(a, out, v, c.kind);
    }
    while (open.items.len > 0) {
        _ = open.pop();
        try out.append(a, '}');
    }
    if (j + 1 < st.levels.len) {
        if (has.items[0]) try out.append(a, ',');
        try json.writeString(a, out, st.levels[j + 1]);
        try out.appendSlice(a, ":[");
    }
}

pub fn forJsonFinal(ctx: *Context) void {
    const slot = dfunc.aggState(?*ForJson, ctx, false) orelse return api.resultNull(ctx);
    const st = slot.* orelse return api.resultNull(ctx);
    slot.* = null;
    defer st.deinit();
    if (st.rows == 0) return api.resultNull(ctx);
    finish(st) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, st.out.items, .transient);
}

/// Close the open objects and wrap the rows ([...], ROOT).
fn finish(st: *ForJson) error{OutOfMemory}!void {
    const a = st.gpa;
    var j = st.levels.len;
    while (j > 0) {
        j -= 1;
        try closeLevel(st, j);
    }
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(a);
    if (st.root) |name| {
        try head.append(a, '{');
        try json.writeString(a, &head, name);
        try head.append(a, ':');
    }
    if (st.wrap) try head.append(a, '[');
    try st.out.insertSlice(a, 0, head.items);
    if (st.wrap) try st.out.append(a, ']');
    if (st.root != null) try st.out.append(a, '}');
}
