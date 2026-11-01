//! The parser's side of the T-SQL dialect's JSON support: the JSON
//! functions' special syntax, FOR JSON, OPENJSON in FROM, and the value
//! kinds (json_func.Kind) that tell the runtime how SQL Server would
//! write a value of a SQL type as JSON.
//!
//! FOR JSON is an aggregate over the query, which stays as it is but for
//! the names of its columns:
//!
//!     SELECT a, b AS [x.y] FROM t ORDER BY a FOR JSON PATH
//!     ->
//!     SELECT xq_tsql_for_json('<spec>', xq_fj.xq_j0, xq_fj.xq_j1)
//!       AS "JSON_F52E2B61-18A1-11d1-B105-00805F49916B"
//!     FROM (SELECT a AS xq_j0, b AS xq_j1 FROM t ORDER BY xq_j0 LIMIT -1)
//!       AS xq_fj HAVING count(*) > 0
//!
//! The spec (json_func.zig) has the options and each column's JSON name,
//! value kind and AUTO level; the LIMIT keeps the query's order for the
//! aggregate, and HAVING makes no rows no row (SQL Server returns none;
//! as a subquery, NULL).
//!
//! A value is JSON (written as it is, not as a string) if SQL Server
//! types it so: JSON_QUERY, JSON_MODIFY, JSON_OBJECT, JSON_ARRAY and a
//! FOR JSON subquery without WITHOUT_ARRAY_WRAPPER (isJson()).

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const build = @import("../../sql/build.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const json = @import("json.zig");
const functions = @import("functions.zig");
const openjson = @import("openjson.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub const json_column_name = "JSON_F52E2B61-18A1-11d1-B105-00805F49916B";

// ================================================================ kinds

/// The engine functions whose results SQL Server types as JSON.
const json_funcs = [_][]const u8{ "xq_tsql_json_query", "xq_tsql_json_modify", "xq_tsql_json_object", "xq_tsql_json_array" };

/// Whether SQL Server would take `e` as JSON text (not escape it).
pub fn isJson(e: *const Expr) bool {
    switch (e.kind) {
        .func => |f| {
            for (json_funcs) |n| if (std.mem.eql(u8, f.name.text, n)) return true;
            return false;
        },
        .subquery => |sel| return isForJson(sel),
        .collate => |c| return isJson(c.e),
        else => return false,
    }
}

/// A query FOR JSON (with the array wrapper, which makes it JSON).
fn isForJson(sel: *const tree.Select) bool {
    if (sel.body.* != .core) return false;
    const core = sel.body.core;
    if (core.cols.len != 1 or core.cols[0] != .expr) return false;
    const e = core.cols[0].expr.e;
    if (e.kind != .func or !std.mem.eql(u8, e.kind.func.name.text, "xq_tsql_for_json")) return false;
    const args = e.kind.func.args;
    if (args.len == 0 or args[0].kind != .string) return false;
    const spec = args[0].kind.string;
    // [A,N,W,...: W is WITHOUT_ARRAY_WRAPPER.
    return spec.len > 5 and spec[5] == '0';
}

/// The kind of a value of SQL type `t`.
pub fn typeKind(t: types.Type) u8 {
    return switch (t.base) {
        .bit => 'b',
        .float => 'f',
        .real => 'r',
        .date, .time, .datetime, .datetime2, .smalldatetime, .datetimeoffset => 'd',
        .binary, .varbinary, .image => 'x',
        .char, .varchar, .nchar, .nvarchar, .text, .ntext, .uniqueidentifier, .xml => 's',
        else => 'a',
    };
}

/// A column of a FROM item and its kind.
pub const Col = struct { name: []const u8, kind: u8 };
/// A FROM item: its label (alias or name) and columns (null if unknown).
pub const Source = struct { label: []const u8, cols: ?[]const Col, index: usize };

/// The kind of `e` with the columns of `scope` known (null: none).
pub fn valueKind(s: *Parser, e: *const Expr, scope: ?[]const Source) u8 {
    if (isJson(e)) return 'j';
    switch (e.kind) {
        .string, .concat => return 's',
        .float => |t| return if (std.mem.indexOfAny(u8, t, "eE") != null) 'f' else 'a',
        .cast => |c| {
            const ty: ?types.Type = switch (c.mode) {
                .typed => |t| types.parseText(t.type_arg),
                else => types.parseText(c.target_type),
            };
            if (ty) |t| return typeKind(t);
        },
        .collate => |c| return valueKind(s, c.e, scope),
        .column => |names| if (scope) |sc| {
            if (findColumn(sc, names)) |r| return r.col.kind;
        },
        else => {},
    }
    return if (s.classOf(e) == .string) 's' else 'a';
}

const Found = struct { src: usize, col: Col };

/// The column `names` (a column reference) stands for in `scope`.
fn findColumn(scope: []const Source, names: []const Name) ?Found {
    const col = names[names.len - 1].text;
    const label: ?[]const u8 = if (names.len >= 2) names[names.len - 2].text else null;
    for (scope, 0..) |src, i| {
        if (label) |l| if (!eq(l, src.label)) continue;
        const cols = src.cols orelse {
            if (label != null) return .{ .src = i, .col = .{ .name = col, .kind = 'a' } };
            continue;
        };
        for (cols) |c| if (eq(c.name, col)) return .{ .src = i, .col = c };
    }
    return null;
}

/// The FROM items of `items` (nested joins flattened) and their
/// columns.
pub fn scopeOf(s: *Parser, items: []const tree.FromItem) Error![]Source {
    var out: std.ArrayList(Source) = .empty;
    try collect(s, items, &out);
    return out.items;
}

fn collect(s: *Parser, items: []const tree.FromItem, out: *std.ArrayList(Source)) Error!void {
    for (items) |it| {
        const label: []const u8 = if (it.alias) |a| a.name.text else switch (it.source) {
            .table => |q| q.name.text,
            .func => |f| f.name.text,
            else => "",
        };
        switch (it.source) {
            .table => |q| {
                const t = try s.target(q);
                var cols: ?[]Col = null;
                if (t.tab != null) {
                    var l: std.ArrayList(Col) = .empty;
                    for (t.cols) |c| {
                        if (c.hidden) continue;
                        const k: u8 = if (c.decl_type) |d| (if (types.parseText(d)) |ty| typeKind(ty) else 'a') else 'a';
                        try l.append(s.a, .{ .name = c.name, .kind = k });
                    }
                    cols = l.items;
                }
                try out.append(s.a, .{ .label = label, .cols = cols, .index = out.items.len });
            },
            .func => |f| try out.append(s.a, .{ .label = label, .cols = s.openjson_cols.get(f), .index = out.items.len }),
            .subquery => |sel| {
                var cols: ?[]Col = null;
                if (leftCore(sel.body)) |core| {
                    var l: std.ArrayList(Col) = .empty;
                    var ok = true;
                    for (core.cols, 0..) |rc, i| switch (rc) {
                        .expr => |x| {
                            const n: []const u8 = if (it.alias != null and i < it.alias.?.cols.len) it.alias.?.cols[i].text else if (x.alias) |a| a.text else if (x.e.kind == .column) x.e.kind.column[x.e.kind.column.len - 1].text else "";
                            try l.append(s.a, .{ .name = n, .kind = valueKind(s, x.e, null) });
                        },
                        else => ok = false,
                    };
                    if (ok) cols = l.items;
                }
                try out.append(s.a, .{ .label = label, .cols = cols, .index = out.items.len });
            },
            .nested => |inner| try collect(s, inner, out),
        }
    }
}

/// A kind not known until the FROM clause is: the character `index` of
/// the string node `node` is the kind of `value`.
pub const Fix = struct { node: *Expr, index: usize, value: *Expr };

/// The kind argument of a value (a string node): known now, or 'a'
/// until resolveKinds() fills it in.
pub fn kindArg(s: *Parser, pos: u32, values: []const *Expr) Error!*Expr {
    const buf = try s.a.alloc(u8, values.len);
    const node = try s.str(pos, buf);
    for (values, 0..) |v, i| {
        buf[i] = valueKind(s, v, null);
        if (buf[i] == 'a' and (v.kind == .column or v.kind == .func or v.kind == .case)) {
            try s.json_fixes.append(s.a, .{ .node = node, .index = i, .value = v });
        }
    }
    return node;
}

/// Fill in the kinds of the values parsed since `mark` with the columns
/// of FROM items `items`.
pub fn resolveKinds(s: *Parser, mark: usize, items: []const tree.FromItem) Error!void {
    if (s.json_fixes.items.len <= mark) return;
    defer s.json_fixes.shrinkRetainingCapacity(mark);
    const scope = try scopeOf(s, items);
    for (s.json_fixes.items[mark..]) |f| {
        const buf: []u8 = @constCast(f.node.kind.string);
        buf[f.index] = valueKind(s, f.value, scope);
    }
}

// ============================================================ functions

/// ISJSON(x [, type]), JSON_VALUE, JSON_QUERY, JSON_MODIFY,
/// JSON_PATH_EXISTS, JSON_OBJECT, JSON_ARRAY and STRING_ESCAPE after
/// their `(`; null if `n` is none of them.
pub fn call(s: *Parser, n: []const u8, pos: u32) Error!?*Expr {
    if (eq(n, "JSON_OBJECT")) return try jsonObject(s, pos);
    if (eq(n, "JSON_ARRAY")) return try jsonArray(s, pos);
    if (eq(n, "ISJSON")) {
        const x = try s.expr();
        try badArg(s, x, 1, "isjson");
        if (s.eatOp(",")) {
            const t = s.tok;
            if (t.kind != .ident or !t.isAnyKw(&.{ "VALUE", "ARRAY", "OBJECT", "SCALAR" })) return s.syntaxError();
            s.advance();
            try s.expectOp(")");
            return try s.func(pos, "xq_tsql_isjson", &.{ x, try s.str(pos, try std.ascii.allocLowerString(s.a, t.text)) });
        }
        try s.expectOp(")");
        // json_valid() and an object or array: SQLite's own functions,
        // so that a CHECK (ISJSON(c) = 1) works in sqlite3 too.
        const valid = try s.func(pos, "json_valid", &.{x});
        const jt = try s.func(pos, "json_type", &.{x});
        const container = try s.mk(pos, .{ .in_list = .{ .e = jt, .not = false, .items = try s.a.dupe(*Expr, &.{ try s.str(pos, "object"), try s.str(pos, "array") }) } });
        const is_null = try s.mk(pos, .{ .is_null = .{ .e = x, .not = false } });
        return try s.mk(pos, .{ .case = .{ .operand = null, .whens = try s.a.dupe(*Expr, &.{ is_null, try s.mk(pos, .null), valid, container }), .@"else" = try s.int_(pos, 0) } });
    }
    const names = [_][]const u8{ "JSON_VALUE", "JSON_QUERY", "JSON_MODIFY", "JSON_PATH_EXISTS", "STRING_ESCAPE" };
    for (names) |x| {
        if (eq(n, x)) break;
    } else return null;
    var args: []*Expr = &.{};
    if (!s.isOp(")")) args = try s.exprList();
    try s.expectOp(")");
    const k = args.len;
    if (eq(n, "JSON_VALUE") or eq(n, "JSON_PATH_EXISTS")) {
        if (k != 2) return argCount(s, n);
        try badArg(s, args[0], 1, if (eq(n, "JSON_VALUE")) "json_value" else "json_path_exists");
        if (args[1].kind == .null and eq(n, "JSON_VALUE")) return s.failState(.numbered("42804", 8116), "Argument data type NULL is invalid for argument 2 of json_value function.", .{});
        return try s.func(pos, if (eq(n, "JSON_VALUE")) "xq_tsql_json_value" else "xq_tsql_json_path_exists", args);
    }
    if (eq(n, "JSON_QUERY")) {
        if (k < 1 or k > 2) return argCount(s, n);
        try badArg(s, args[0], 1, "json_query");
        return try s.func(pos, "xq_tsql_json_query", args);
    }
    if (eq(n, "JSON_MODIFY")) {
        if (k != 3) return argCount(s, n);
        try badArg(s, args[0], 1, "json_modify");
        try badValue(s, args[2], 3, "json_modify");
        // JSON_MODIFY takes a real as a float.
        const kind = try kindArg(s, pos, args[2..3]);
        if (std.mem.eql(u8, kind.kind.string, "r")) kind.kind.string = "f";
        return try s.func(pos, "xq_tsql_json_modify", &.{ args[0], args[1], args[2], kind });
    }
    // STRING_ESCAPE(x, 'json')
    if (k != 2) return argCount(s, n);
    if (args[1].kind != .string or !eq(args[1].kind.string, "json")) return s.failState(.of("22023"), "An invalid value was specified for argument 2.", .{});
    return try s.func(pos, "xq_tsql_json_escape", args[0..1]);
}

fn argCount(s: *Parser, n: []const u8) Error {
    return s.failState(.numbered("42883", 174), "The {s} function requires a different number of arguments.", .{n});
}

/// A number constant where text is required: SQL Server's compile error.
fn badArg(s: *Parser, e: *const Expr, i: u32, func: []const u8) Error!void {
    const t: ?[]const u8 = switch (e.kind) {
        .integer => "int",
        .float => |f| if (std.mem.indexOfAny(u8, f, "eE") != null) "float" else "numeric",
        else => null,
    };
    if (t) |tn| return s.failState(.numbered("42804", 8116), "Argument data type {s} is invalid for argument {d} of {s} function.", .{ tn, i, func });
}

/// A value of a type JSON has no form for (dates, money, binary,
/// uniqueidentifier): SQL Server's compile error.
fn badValue(s: *Parser, e: *const Expr, i: u32, func: []const u8) Error!void {
    // CAST(x AS varbinary(n)): substr(CAST(x AS BLOB), 1, n).
    const blob = switch (e.kind) {
        .func => |f| std.mem.eql(u8, f.name.text, "substr") and f.args.len > 0 and f.args[0].kind == .cast and f.args[0].kind.cast.mode == .affinity and std.mem.eql(u8, f.args[0].kind.cast.mode.affinity, "BLOB"),
        .cast => |c| c.mode == .affinity and std.mem.eql(u8, c.mode.affinity, "BLOB"),
        else => false,
    };
    if (blob) return s.failState(.numbered("42804", 8116), "Argument data type varbinary is invalid for argument {d} of {s} function.", .{ i, func });
    if (e.kind != .cast) return;
    const c = e.kind.cast;
    const ty = (switch (c.mode) {
        .typed => |t| types.parseText(t.type_arg),
        else => types.parseText(c.target_type),
    }) orelse return;
    switch (ty.base) {
        .money, .smallmoney, .date, .time, .datetime, .datetime2, .smalldatetime, .datetimeoffset, .binary, .varbinary, .image, .uniqueidentifier => {
            return s.failState(.numbered("42804", 8116), "Argument data type {s} is invalid for argument {d} of {s} function.", .{ @tagName(ty.base), i, func });
        },
        else => {},
    }
}

/// `[NULL | ABSENT] ON NULL` at the end of JSON_OBJECT/JSON_ARRAY.
fn onNull(s: *Parser) Error!?bool {
    if ((s.isKw("NULL") or s.isKw("ABSENT")) and s.peek().isKw("ON") and s.peek2().isKw("NULL")) {
        const absent = s.isKw("ABSENT");
        s.advance();
        s.advance();
        s.advance();
        return absent;
    }
    return null;
}

/// JSON_OBJECT([key : value, ...] [NULL|ABSENT ON NULL]) (SQL Server
/// 2022): NULL ON NULL by default.
fn jsonObject(s: *Parser, pos: u32) Error!*Expr {
    var keys: std.ArrayList(*Expr) = .empty;
    var vals: std.ArrayList(*Expr) = .empty;
    var absent = false;
    if (try onNull(s)) |x| {
        absent = x;
    } else if (!s.isOp(")")) while (true) {
        try keys.append(s.a, try s.expr());
        try s.expectOp(":");
        try vals.append(s.a, try s.expr());
        if (s.eatOp(",")) continue;
        if (try onNull(s)) |x| absent = x;
        break;
    };
    try s.expectOp(")");
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(s.a, try s.str(pos, if (absent) "absent" else "null"));
    try args.append(s.a, try kindArg(s, pos, vals.items));
    for (keys.items, vals.items) |k, v| {
        try args.append(s.a, k);
        try args.append(s.a, v);
    }
    return s.func(pos, "xq_tsql_json_object", args.items);
}

/// JSON_ARRAY([value, ...] [NULL|ABSENT ON NULL]) (SQL Server 2022):
/// ABSENT ON NULL by default.
fn jsonArray(s: *Parser, pos: u32) Error!*Expr {
    var vals: std.ArrayList(*Expr) = .empty;
    var absent = true;
    if (try onNull(s)) |x| {
        absent = x;
    } else if (!s.isOp(")")) while (true) {
        try vals.append(s.a, try s.expr());
        if (s.eatOp(",")) continue;
        if (try onNull(s)) |x| absent = x;
        break;
    };
    try s.expectOp(")");
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(s.a, try s.str(pos, if (absent) "absent" else "null"));
    try args.append(s.a, try kindArg(s, pos, vals.items));
    try args.appendSlice(s.a, vals.items);
    return s.func(pos, "xq_tsql_json_array", args.items);
}

// ============================================================= OPENJSON

/// `OPENJSON ( json [, path] ) [WITH ( col type ['path'] [AS JSON], ... )]`
/// at the current token (OPENJSON): the call of the engine table-valued
/// function (openjson.zig).
pub fn openJson(s: *Parser) Error!*tree.Func {
    const pos = s.here();
    s.advance();
    try s.expectOp("(");
    const args = try s.exprList();
    try s.expectOp(")");
    if (args.len < 1 or args.len > 2) return s.failState(.numbered("42883", 174), "The openjson function requires 1 to 2 arguments.", .{});
    try badArg(s, args[0], 1, "openjson");
    if (args.len == 2 and args[1].kind == .null) return s.failState(.numbered("42804", 8116), "Argument data type NULL is invalid for argument 2 of openjson function.", .{});
    if (!(s.isKw("WITH") and s.peek().is("("))) {
        const f = try s.new(tree.Func, .{ .name = .{ .text = openjson.default_name, .pos = pos }, .args = args });
        try s.openjson_cols.put(s.a, f, try s.a.dupe(Col, &.{ .{ .name = "key", .kind = 's' }, .{ .name = "value", .kind = 's' }, .{ .name = "type", .kind = 'a' } }));
        return f;
    }
    s.advance();
    try s.expectOp("(");
    var spec: std.ArrayList(u8) = .empty;
    var cols: std.ArrayList(Col) = .empty;
    try spec.append(s.a, '[');
    while (true) {
        const n = try s.nameText(try s.anyName());
        const ty = try functions.typeNameOf(s, true);
        var path: ?[]const u8 = null;
        if (s.tok.kind == .string) path = try s.stringLiteral();
        var as_json = false;
        if (s.isKw("AS") and s.peek().isKw("JSON")) {
            s.advance();
            s.advance();
            if (!(ty.t.base == .nvarchar and ty.t.len == types.max_len)) {
                return s.failState(.of("42601"), "AS JSON option can be specified only for column of nvarchar(max) type in WITH clause.", .{});
            }
            as_json = true;
        }
        if (path) |p| {
            var perr: json.PathError = .{};
            _ = json.parsePath(s.a, p, false, &perr) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.BadPath => {
                    var buf: [200]u8 = undefined;
                    return s.failState(json.path_error, "{s}", .{json.pathMessage(&buf, p, perr.pos)});
                },
            };
        }
        if (cols.items.len > 0) try spec.append(s.a, ',');
        try spec.append(s.a, '[');
        try json.writeString(s.a, &spec, n);
        try spec.append(s.a, ',');
        try json.writeString(s.a, &spec, ty.text);
        try spec.append(s.a, ',');
        if (path) |p| try json.writeString(s.a, &spec, p) else try spec.appendSlice(s.a, "null");
        try spec.appendSlice(s.a, if (as_json) ",1]" else ",0]");
        try cols.append(s.a, .{ .name = n, .kind = if (as_json) 'j' else typeKind(ty.t) });
        if (!s.eatOp(",")) break;
    }
    try s.expectOp(")");
    try spec.append(s.a, ']');
    const name = try openjson.withName(s.a, spec.items);
    const f = try s.new(tree.Func, .{ .name = .{ .text = name, .pos = pos }, .args = args });
    try s.openjson_cols.put(s.a, f, cols.items);
    return f;
}

// ============================================================= FOR JSON

/// The first query of a body (whose columns name the result's).
fn leftCore(b: *tree.Body) ?*tree.Core {
    return switch (b.*) {
        .core => |c| c,
        .compound => |c| leftCore(c.left),
        .nested => |n| leftCore(n.body),
        .values => null,
    };
}

const OutCol = struct { name: []const u8, kind: u8, src: ?usize, e: *Expr };

/// `FOR JSON {PATH | AUTO} [, ROOT[('name')]] [, INCLUDE_NULL_VALUES]
/// [, WITHOUT_ARRAY_WRAPPER]` after query `sel` (the current token is
/// FOR): the query of the JSON text.
pub fn forJson(s: *Parser, sel: *tree.Select) Error!*tree.Select {
    const pos = s.here();
    s.advance();
    s.advance(); // JSON
    var auto = false;
    if (s.eatKw("AUTO")) {
        auto = true;
    } else if (!s.eatKw("PATH")) return s.syntaxError();
    var root: ?[]const u8 = null;
    var nulls = false;
    var nowrap = false;
    while (s.eatOp(",")) {
        if (s.eatKw("ROOT")) {
            root = "root";
            if (s.eatOp("(")) {
                root = try s.stringLiteral();
                try s.expectOp(")");
            }
        } else if (s.eatKw("INCLUDE_NULL_VALUES")) {
            nulls = true;
        } else if (s.eatKw("WITHOUT_ARRAY_WRAPPER")) {
            nowrap = true;
        } else return s.syntaxError();
    }
    if (root != null and nowrap) return s.failState(.of("42601"), "ROOT option and WITHOUT_ARRAY_WRAPPER option cannot be used together in FOR JSON. Remove one of these options.", .{});
    const core = leftCore(sel.body) orelse return s.fail("xqlite: FOR JSON of VALUES is not supported", .{});
    const scope = try scopeOf(s, core.from);

    // The columns, * expanded.
    var cols: std.ArrayList(OutCol) = .empty;
    for (core.cols) |rc| switch (rc) {
        .star => |p| for (scope) |src| try expand(s, &cols, src, p),
        .table_star => |ts| {
            const l = ts.names[ts.names.len - 1].text;
            for (scope) |src| {
                if (eq(src.label, l)) try expand(s, &cols, src, ts.star_pos);
            }
        },
        .expr => |x| {
            const n: ?[]const u8 = if (x.alias) |a| a.text else if (x.e.kind == .column) x.e.kind.column[x.e.kind.column.len - 1].text else null;
            const nm = n orelse return s.failState(.numbered("42601", 1038), "Column expressions and data sources without names or aliases cannot be formatted as JSON text using FOR JSON clause. Add alias to the unnamed column or table.", .{});
            if (nm.len == 0) return s.failState(.numbered("42601", 1038), "Column expressions and data sources without names or aliases cannot be formatted as JSON text using FOR JSON clause. Add alias to the unnamed column or table.", .{});
            const src: ?usize = if (x.e.kind == .column) (if (findColumn(scope, x.e.kind.column)) |f| f.src else null) else null;
            try cols.append(s.a, .{ .name = nm, .kind = valueKind(s, x.e, scope), .src = src, .e = x.e });
        },
    };

    // AUTO: a level per table, in the order the columns name them.
    var levels: std.ArrayList([]const u8) = .empty;
    var level_of = try s.a.alloc(u32, cols.items.len);
    if (auto) {
        if (scope.len == 0) return s.failState(.of("42601"), "FOR JSON AUTO requires at least one table for generating JSON objects. Use FOR JSON PATH or add a FROM clause with a table name.", .{});
        var srcs: std.ArrayList(usize) = .empty;
        var last: u32 = 0;
        for (cols.items, 0..) |c, i| {
            if (c.src) |src| {
                const lv: u32 = for (srcs.items, 0..) |x, j| {
                    if (x == src) break @intCast(j);
                } else blk: {
                    try srcs.append(s.a, src);
                    try levels.append(s.a, scope[src].label);
                    break :blk @intCast(srcs.items.len - 1);
                };
                last = lv;
            }
            level_of[i] = last;
        }
    } else @memset(level_of, 0);
    try checkNames(s, cols.items, level_of, auto);

    // The spec: [auto, nulls, nowrap, root, [[name, kind, level], ...], [levels]].
    var spec: std.ArrayList(u8) = .empty;
    try spec.print(s.a, "[{d},{d},{d},", .{ @intFromBool(auto), @intFromBool(nulls), @intFromBool(nowrap) });
    if (root) |r| try json.writeString(s.a, &spec, r) else try spec.appendSlice(s.a, "null");
    try spec.appendSlice(s.a, ",[");
    for (cols.items, 0..) |c, i| {
        if (i > 0) try spec.append(s.a, ',');
        try spec.append(s.a, '[');
        try json.writeString(s.a, &spec, c.name);
        try spec.print(s.a, ",\"{c}\",{d}]", .{ c.kind, level_of[i] });
    }
    try spec.appendSlice(s.a, "],[");
    for (levels.items, 0..) |l, i| {
        if (i > 0) try spec.append(s.a, ',');
        try json.writeString(s.a, &spec, l);
    }
    try spec.appendSlice(s.a, "]]");

    // The query, its columns renamed xq_jN (ORDER BY by their names too).
    var new_cols: std.ArrayList(tree.ResultCol) = .empty;
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(s.a, try s.str(pos, spec.items));
    const sub: Name = .{ .text = "xq_fj", .pos = pos };
    for (cols.items, 0..) |c, i| {
        const al: Name = .{ .text = try std.fmt.allocPrint(s.a, "xq_j{d}", .{i}), .pos = pos };
        try new_cols.append(s.a, .{ .expr = .{ .e = c.e, .alias = al } });
        try args.append(s.a, try tree.expr(s.a, pos, pos, .{ .column = try s.a.dupe(Name, &.{ sub, al }) }));
    }
    for (sel.order_by) |*it| {
        if (it.expr.kind != .column or it.expr.kind.column.len != 1) continue;
        const n = it.expr.kind.column[0].text;
        for (cols.items, 0..) |c, i| if (eq(c.name, n)) {
            it.expr = try tree.expr(s.a, it.expr.pos, it.expr.end, .{ .column = try s.a.dupe(Name, &.{new_cols.items[i].expr.alias.?}) });
            break;
        };
    }
    core.cols = new_cols.items;
    if (sel.order_by.len > 0 and sel.limit == null) sel.limit = try s.int_(pos, -1);

    const agg = try s.func(pos, "xq_tsql_for_json", args.items);
    const cnt = try s.funcNode(pos, .{ .name = .{ .text = "count", .pos = pos }, .star = true });
    const having = try s.mk(pos, .{ .compare = .{ .op = .gt, .l = cnt, .r = try s.int_(pos, 0) } });
    const outer = try s.new(tree.Core, .{
        .cols = try s.a.dupe(tree.ResultCol, &.{.{ .expr = .{ .e = agg, .alias = .{ .text = json_column_name, .pos = pos } } }}),
        .from = try s.a.dupe(tree.FromItem, &.{.{ .source = .{ .subquery = sel }, .alias = .{ .name = sub } }}),
        .having = having,
        .pos = pos,
    });
    return s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = outer }), .pos = sel.pos });
}

/// The columns of FROM item `src` for `*`.
fn expand(s: *Parser, cols: *std.ArrayList(OutCol), src: Source, pos: u32) Error!void {
    const list = src.cols orelse return s.fail("xqlite: FOR JSON of * over {s} is not supported", .{if (src.label.len > 0) src.label else "a subquery without an alias"});
    for (list) |c| {
        const names = try s.a.dupe(Name, &.{ .{ .text = src.label, .pos = pos }, .{ .text = c.name, .pos = pos } });
        try cols.append(s.a, .{ .name = c.name, .kind = c.kind, .src = src.index, .e = try tree.expr(s.a, pos, pos, .{ .column = names }) });
    }
}

/// SQL Server's error for names that would make the same property: in
/// PATH mode a dotted name is a path of nested objects, and the objects
/// of a path must be next to each other.
fn checkNames(s: *Parser, cols: []const OutCol, level_of: []const u32, auto: bool) Error!void {
    // Every property made so far: its full path (level, segments) and
    // whether it is an object; the objects open (of the last column).
    const Prop = struct { level: u32, path: []const u8, object: bool };
    var props: std.ArrayList(Prop) = .empty;
    var open: []const u8 = "";
    var open_level: u32 = std.math.maxInt(u32);
    for (cols, 0..) |c, i| {
        const lv = level_of[i];
        if (lv != open_level) open = "";
        open_level = lv;
        const name = c.name;
        // The objects of the name's path, then the name itself.
        var it: usize = 0;
        while (true) {
            const dot = if (auto) null else std.mem.indexOfScalarPos(u8, name, it, '.');
            const prefix = if (dot) |d| name[0..d] else name;
            const object = dot != null;
            const is_open = object and open.len >= prefix.len and std.mem.eql(u8, open[0..prefix.len], prefix) and (open.len == prefix.len or open[prefix.len] == '.');
            if (!is_open) {
                for (props.items) |p| {
                    if (p.level == lv and std.mem.eql(u8, p.path, prefix)) {
                        return s.failState(.of("42701"), "Property '{s}' cannot be generated in JSON output due to a conflict with another column name or alias. Use different names and aliases for each column in SELECT list.", .{name});
                    }
                }
                try props.append(s.a, .{ .level = lv, .path = prefix, .object = object });
            }
            const d = dot orelse break;
            it = d + 1;
        }
        open = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| (if (auto) "" else name[0..d]) else "";
    }
}
