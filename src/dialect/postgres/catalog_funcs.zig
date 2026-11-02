//! The functions of PostgreSQL's system catalogs, over the snapshot of
//! pgcatalog.zig:
//!
//!  - dialect functions: pg_get_userbyid(), pg_table_is_visible() and
//!    the other *_is_visible(), pg_get_expr(), pg_get_indexdef(),
//!    pg_get_constraintdef(), pg_get_viewdef(), pg_get_serial_sequence(),
//!    obj_description(), col_description(), shobj_description(), the
//!    privilege functions (has_table_privilege() ...: the one role is a
//!    superuser), to_regclass() and its kin, pg_typeof() (by the value's
//!    storage class), pg_encoding_to_char(), the size functions,
//!    array_to_string() of an array literal, and the ones psql calls on
//!    relations xqlite has none of (pg_get_triggerdef(),
//!    pg_partition_ancestors() ...);
//!  - engine functions, as the parser writes casts into the schema:
//!    xq_pg_regclass(x), xq_pg_regtype(x), xq_pg_regnamespace(x),
//!    xq_pg_regrole(x) read a name (or a number) into an OID, as
//!    PostgreSQL's input functions do along search_path, and
//!    xq_pg_regclass_out(oid) ... write it back (the text of a reg*
//!    value, schema-qualified when the name alone would not find it);
//!    xq_pg_regproc(x) is a function's name (regproc stays text: only
//!    pg_type's I/O columns hold one); xq_pg_array_position(arr, v),
//!    xq_pg_dt_precision() for information_schema.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const pgc = @import("pgcatalog.zig");
const state = @import("state.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Allocator = std.mem.Allocator;
const Snapshot = pgc.Snapshot;
const isNull = dfunc.isNull;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const det: dfunc.Options = .{ .deterministic = true };
const none: dfunc.Options = .{};

pub const functions = [_]int.FuncDef{
    dfunc.scalar("pg_get_userbyid", 1, det, userByIdFunc),
    dfunc.scalar("pg_table_is_visible", 1, none, tableVisibleFunc),
    dfunc.scalar("pg_type_is_visible", 1, none, typeVisibleFunc),
    dfunc.scalar("pg_function_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_collation_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_opclass_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_operator_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_conversion_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_statistics_obj_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_ts_config_is_visible", 1, det, trueFunc),
    dfunc.scalar("pg_get_expr", 2, det, getExprFunc),
    dfunc.scalar("pg_get_expr", 3, det, getExprFunc),
    dfunc.scalar("pg_get_indexdef", 1, none, indexDefFunc),
    dfunc.scalar("pg_get_indexdef", 3, none, indexDefFunc),
    dfunc.scalar("pg_get_constraintdef", 1, none, constraintDefFunc),
    dfunc.scalar("pg_get_constraintdef", 2, none, constraintDefFunc),
    dfunc.scalar("pg_get_viewdef", 1, none, viewDefFunc),
    dfunc.scalar("pg_get_viewdef", 2, none, viewDefFunc),
    dfunc.scalar("pg_get_serial_sequence", 2, none, serialSequenceFunc),
    dfunc.scalar("obj_description", 1, none, objDescriptionFunc),
    dfunc.scalar("obj_description", 2, none, objDescriptionFunc),
    dfunc.scalar("col_description", 2, none, colDescriptionFunc),
    dfunc.scalar("shobj_description", 2, det, nullFunc),
    dfunc.scalar("pg_get_triggerdef", 1, det, nullFunc),
    dfunc.scalar("pg_get_triggerdef", 2, det, nullFunc),
    dfunc.scalar("pg_get_ruledef", 1, det, nullFunc),
    dfunc.scalar("pg_get_ruledef", 2, det, nullFunc),
    dfunc.scalar("pg_get_partkeydef", 1, det, nullFunc),
    dfunc.scalar("pg_get_partition_constraintdef", 1, det, nullFunc),
    dfunc.scalar("pg_get_statisticsobjdef_columns", 1, det, nullFunc),
    dfunc.scalar("pg_get_function_result", 1, det, nullFunc),
    dfunc.scalar("pg_get_function_arguments", 1, det, nullFunc),
    dfunc.scalar("pg_get_function_identity_arguments", 1, det, nullFunc),
    dfunc.scalar("pg_partition_ancestors", 1, det, firstArgFunc),
    dfunc.scalar("pg_partition_root", 1, det, firstArgFunc),
    dfunc.scalar("pg_relation_is_publishable", 1, det, falseFunc),
    dfunc.scalar("pg_is_in_recovery", 0, det, falseFunc),
    dfunc.scalar("pg_backend_pid", 0, det, backendPidFunc),
    dfunc.scalar("pg_encoding_to_char", 1, det, encodingFunc),
    dfunc.scalar("pg_char_to_encoding", 1, det, charToEncodingFunc),
    dfunc.scalar("pg_size_pretty", 1, det, sizePrettyFunc),
    dfunc.scalar("pg_table_size", 1, det, zeroFunc),
    dfunc.scalar("pg_relation_size", 1, det, zeroFunc),
    dfunc.scalar("pg_relation_size", 2, det, zeroFunc),
    dfunc.scalar("pg_total_relation_size", 1, det, zeroFunc),
    dfunc.scalar("pg_indexes_size", 1, det, zeroFunc),
    dfunc.scalar("pg_database_size", 1, det, zeroFunc),
    dfunc.scalar("pg_typeof", 1, det, typeofFunc),
    dfunc.scalar("to_regclass", 1, none, dfunc.bind(regIn, .{ Reg.class, true })),
    dfunc.scalar("to_regtype", 1, none, dfunc.bind(regIn, .{ Reg.type, true })),
    dfunc.scalar("to_regnamespace", 1, none, dfunc.bind(regIn, .{ Reg.namespace, true })),
    dfunc.scalar("to_regrole", 1, none, dfunc.bind(regIn, .{ Reg.role, true })),
    dfunc.scalar("quote_ident", 1, det, quoteIdentFunc),
    dfunc.scalar("quote_literal", 1, det, dfunc.bind(quoteLiteralFunc, .{false})),
    dfunc.scalar("quote_nullable", 1, det, dfunc.bind(quoteLiteralFunc, .{true})),
    dfunc.scalar("array_to_string", 2, det, arrayToStringFunc),
    dfunc.scalar("array_to_string", 3, det, arrayToStringFunc),
} ++ privileges;

/// has_table_privilege() and its kin, with and without the role.
const privileges = blk: {
    const names = [_]struct { [:0]const u8, []const i16 }{
        .{ "has_table_privilege", &.{ 2, 3 } },                .{ "has_schema_privilege", &.{ 2, 3 } },
        .{ "has_database_privilege", &.{ 2, 3 } },             .{ "has_column_privilege", &.{ 3, 4 } },
        .{ "has_any_column_privilege", &.{ 2, 3 } },           .{ "has_sequence_privilege", &.{ 2, 3 } },
        .{ "has_function_privilege", &.{ 2, 3 } },             .{ "has_type_privilege", &.{ 2, 3 } },
        .{ "has_tablespace_privilege", &.{ 2, 3 } },           .{ "has_language_privilege", &.{ 2, 3 } },
        .{ "has_foreign_data_wrapper_privilege", &.{ 2, 3 } }, .{ "has_server_privilege", &.{ 2, 3 } },
        .{ "pg_has_role", &.{ 2, 3 } },
    };
    var n = 0;
    for (names) |x| n += x[1].len;
    var out: [n]int.FuncDef = undefined;
    var i = 0;
    for (names) |x| for (x[1]) |k| {
        out[i] = dfunc.scalar(x[0], k, det, trueFunc);
        i += 1;
    };
    const final = out;
    break :blk final;
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_regclass", 1, none, dfunc.bind(regIn, .{ Reg.class, false })),
    dfunc.scalar("xq_pg_regtype", 1, none, dfunc.bind(regIn, .{ Reg.type, false })),
    dfunc.scalar("xq_pg_regnamespace", 1, none, dfunc.bind(regIn, .{ Reg.namespace, false })),
    dfunc.scalar("xq_pg_regrole", 1, none, dfunc.bind(regIn, .{ Reg.role, false })),
    dfunc.scalar("xq_pg_regproc", 1, none, regprocFunc),
    dfunc.scalar("xq_pg_regclass_out", 1, none, dfunc.bind(regOut, .{Reg.class})),
    dfunc.scalar("xq_pg_regtype_out", 1, none, dfunc.bind(regOut, .{Reg.type})),
    dfunc.scalar("xq_pg_regnamespace_out", 1, none, dfunc.bind(regOut, .{Reg.namespace})),
    dfunc.scalar("xq_pg_regrole_out", 1, none, dfunc.bind(regOut, .{Reg.role})),
    dfunc.scalar("xq_pg_array_position", 2, det, arrayPositionFunc),
    dfunc.scalar("xq_pg_dt_precision", 2, det, dtPrecisionFunc),
};

// ============================================================ helpers

/// A call's snapshot and arena.
const Call = struct {
    ctx: *Context,
    db: *int.Sqlite3,
    arena: std.heap.ArenaAllocator,
    snap: ?*Snapshot = null,

    fn init(ctx: *Context) Call {
        const db = api.contextDbHandle(ctx);
        return .{ .ctx = ctx, .db = db, .arena = .init(db.gpa) };
    }

    fn deinit(c: *Call) void {
        if (c.snap) |s| pgc.release(c.db, s);
        c.arena.deinit();
    }

    fn a(c: *Call) Allocator {
        return c.arena.allocator();
    }

    /// The snapshot; null after setting the error.
    fn get(c: *Call) ?*Snapshot {
        if (c.snap) |s| return s;
        c.snap = pgc.acquire(c.db) catch |err| {
            if (err == error.OutOfMemory) api.resultErrorNomem(c.ctx) else api.resultError(c.ctx, "xqlite: cannot read the catalog");
            return null;
        };
        return c.snap;
    }

    fn path(c: *Call, s: *const Snapshot) ?[]u32 {
        return pgc.path(c.db, s, c.a()) catch {
            api.resultErrorNomem(c.ctx);
            return null;
        };
    }

    fn text(c: *Call, z: []const u8) void {
        api.resultText(c.ctx, z, .transient);
    }

    fn oom(c: *Call) void {
        api.resultErrorNomem(c.ctx);
    }
};

fn oidArg(m: *Mem) ?u32 {
    if (isNull(m)) return null;
    const v = api.valueInt64(m);
    if (v < 0 or v > std.math.maxInt(u32)) return 0;
    return @intCast(v);
}

/// The text of relation `r`: its name, with its schema's if the name
/// alone does not find it (PostgreSQL's regclassout()).
pub fn relText(a: Allocator, s: *const Snapshot, p: []const u32, r: *const pgc.Rel) error{OutOfMemory}![]const u8 {
    const n = try pgc.quoteIdent(a, r.name);
    if (pgc.visible(s, p, r)) return n;
    const ns = if (s.nsp(r.nsp)) |x| x.name else "?";
    return std.fmt.allocPrint(a, "{s}.{s}", .{ try pgc.quoteIdent(a, ns), n });
}

/// The relation `r` qualified always (pg_get_indexdef()'s table).
fn relQualified(a: Allocator, s: *const Snapshot, r: *const pgc.Rel) error{OutOfMemory}![]const u8 {
    const ns = if (s.nsp(r.nsp)) |x| x.name else "?";
    return std.fmt.allocPrint(a, "{s}.{s}", .{ try pgc.quoteIdent(a, ns), try pgc.quoteIdent(a, r.name) });
}

// ===================================================== the simple ones

fn trueFunc(ctx: *Context, _: []*Mem) void {
    api.resultInt64(ctx, 1);
}

fn falseFunc(ctx: *Context, _: []*Mem) void {
    api.resultInt64(ctx, 0);
}

fn nullFunc(ctx: *Context, _: []*Mem) void {
    api.resultNull(ctx);
}

fn zeroFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    api.resultInt64(ctx, 0);
}

fn firstArgFunc(ctx: *Context, argv: []*Mem) void {
    api.resultValue(ctx, argv[0]);
}

fn backendPidFunc(ctx: *Context, _: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    // A number of the connection's own, stable while it lives.
    api.resultInt64(ctx, @intCast(1000 + (@intFromPtr(db) >> 4) % 30000));
}

fn userByIdFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    if (oid == pgc.oid_superuser) return api.resultText(ctx, state.user, .static);
    var buf: [48]u8 = undefined;
    api.resultText(ctx, std.fmt.bufPrint(&buf, "unknown (OID={d})", .{oid}) catch "unknown", .transient);
}

fn encodingFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    api.resultText(ctx, if (api.valueInt64(argv[0]) == 6) "UTF8" else "", .static);
}

fn charToEncodingFunc(ctx: *Context, argv: []*Mem) void {
    const z = dfunc.text(ctx, argv[0]) orelse return;
    api.resultInt64(ctx, if (std.ascii.eqlIgnoreCase(z, "UTF8") or std.ascii.eqlIgnoreCase(z, "UTF-8")) 6 else -1);
}

/// pg_size_pretty(bigint): bytes, kB, MB ... as PostgreSQL rounds them.
fn sizePrettyFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var buf: [48]u8 = undefined;
    const units = [_][]const u8{ "bytes", "kB", "MB", "GB", "TB", "PB" };
    // The next unit from 10240 of one, rounded half away from zero.
    var v: i64 = api.valueInt64(argv[0]);
    var k: usize = 0;
    while (k + 1 < units.len and @abs(v) >= 10240) : (k += 1) v = @divTrunc(v + (if (v < 0) @as(i64, -512) else @as(i64, 512)), 1024);
    api.resultText(ctx, std.fmt.bufPrint(&buf, "{d} {s}", .{ v, units[k] }) catch "?", .transient);
}

/// pg_typeof(x): the type of the value as stored (the expression's
/// type is not known to a function).
fn typeofFunc(ctx: *Context, argv: []*Mem) void {
    const z: []const u8 = switch (api.valueType(argv[0])) {
        vi.SQLITE_INTEGER => blk: {
            const v = api.valueInt64(argv[0]);
            break :blk if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) "integer" else "bigint";
        },
        vi.SQLITE_FLOAT => "numeric",
        vi.SQLITE_BLOB => "bytea",
        vi.SQLITE_NULL => "unknown",
        else => "text",
    };
    api.resultText(ctx, z, .static);
}

fn quoteIdentFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    c.text(pgc.quoteIdent(c.a(), dfunc.text(ctx, argv[0]) orelse return) catch return c.oom());
}

/// quote_literal(x), quote_nullable(x) (NULL is 'NULL'): E'...' when
/// there is a backslash, as PostgreSQL writes it.
fn quoteLiteralFunc(ctx: *Context, argv: []*Mem, nullable: bool) void {
    if (isNull(argv[0])) return if (nullable) api.resultText(ctx, "NULL", .static) else api.resultNull(ctx);
    const z = dfunc.text(ctx, argv[0]) orelse return;
    var c: Call = .init(ctx);
    defer c.deinit();
    var out: std.ArrayList(u8) = .empty;
    const a = c.a();
    if (std.mem.indexOfScalar(u8, z, '\\') != null) out.append(a, 'E') catch return c.oom();
    out.append(a, '\'') catch return c.oom();
    for (z) |ch| {
        if (ch == '\'' or ch == '\\') out.append(a, ch) catch return c.oom();
        out.append(a, ch) catch return c.oom();
    }
    out.append(a, '\'') catch return c.oom();
    c.text(out.items);
}

/// array_to_string(array, sep [, null_string]) of an array literal
/// ('{a,b}', as the dialect's arrays are text).
fn arrayToStringFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(ctx);
    const z = dfunc.text(ctx, argv[0]) orelse return;
    const sep = dfunc.text(ctx, argv[1]) orelse return;
    const null_text: ?[]const u8 = if (argv.len > 2 and !isNull(argv[2])) dfunc.text(ctx, argv[2]) orelse return else null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(dfunc.gpa(ctx));
    var it = Elements{ .z = z };
    var first = true;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(dfunc.gpa(ctx));
    while (it.next(dfunc.gpa(ctx), &buf) catch return api.resultErrorNomem(ctx)) |e| {
        const v: []const u8 = if (e) |x| x else null_text orelse continue;
        if (!first) out.appendSlice(dfunc.gpa(ctx), sep) catch return api.resultErrorNomem(ctx);
        first = false;
        out.appendSlice(dfunc.gpa(ctx), v) catch return api.resultErrorNomem(ctx);
    }
    dfunc.resultOwned(ctx, &out);
}

/// The elements of a one-dimensional array literal: each its text, null
/// for NULL.
const Elements = struct {
    z: []const u8,
    i: usize = 0,

    fn next(it: *Elements, gpa: Allocator, buf: *std.ArrayList(u8)) !??[]const u8 {
        const z = it.z;
        if (it.i == 0) {
            while (it.i < z.len and z[it.i] != '{') it.i += 1;
            if (it.i >= z.len) return null;
            it.i += 1;
        }
        while (it.i < z.len and (z[it.i] == ' ' or z[it.i] == ',')) it.i += 1;
        if (it.i >= z.len or z[it.i] == '}') return null;
        buf.clearRetainingCapacity();
        if (z[it.i] == '"') {
            it.i += 1;
            while (it.i < z.len and z[it.i] != '"') : (it.i += 1) {
                if (z[it.i] == '\\' and it.i + 1 < z.len) it.i += 1;
                try buf.append(gpa, z[it.i]);
            }
            it.i += 1;
            return @as(?[]const u8, buf.items);
        }
        const start = it.i;
        while (it.i < z.len and z[it.i] != ',' and z[it.i] != '}') it.i += 1;
        const e = std.mem.trim(u8, z[start..it.i], " ");
        if (std.ascii.eqlIgnoreCase(e, "NULL")) return @as(?[]const u8, null);
        return @as(?[]const u8, e);
    }
};

/// xq_pg_array_position(array, v): the 1-based place of `v` in the array
/// literal (numbers compared as numbers), NULL if it is not there.
fn arrayPositionFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(ctx);
    const z = dfunc.text(ctx, argv[0]) orelse return;
    const v = dfunc.text(ctx, argv[1]) orelse return;
    var it = Elements{ .z = z };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(dfunc.gpa(ctx));
    var n: i64 = 1;
    while (it.next(dfunc.gpa(ctx), &buf) catch return api.resultErrorNomem(ctx)) |e| : (n += 1) {
        if (e) |x| if (eql(x, v)) return api.resultInt64(ctx, n);
    }
    api.resultNull(ctx);
}

/// xq_pg_dt_precision(pg_type, sqlite_type): the fractional digits of a
/// time or timestamp type, NULL if not given.
fn dtPrecisionFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = dfunc.text(ctx, argv[0]) orelse return;
    const lp = std.mem.indexOfScalar(u8, z, '(') orelse return api.resultNull(ctx);
    const rp = std.mem.indexOfScalarPos(u8, z, lp, ')') orelse return api.resultNull(ctx);
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, z[lp + 1 .. rp], " "), 10) catch return api.resultNull(ctx);
    api.resultInt64(ctx, n);
}

// ==================================================== catalog lookups

fn tableVisibleFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    const r = s.rel(oid) orelse {
        for (pgc.builtin_relations) |b| if (b[0] == oid) return api.resultInt64(ctx, 1);
        return api.resultNull(ctx);
    };
    const p = c.path(s) orelse return;
    api.resultInt64(ctx, @intFromBool(pgc.visible(s, p, r)));
}

fn typeVisibleFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    if (pgc.builtinType(oid) != null) return api.resultInt64(ctx, 1);
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    const p = c.path(s) orelse return;
    for (s.rels) |*r| if (r.rowtype == oid) return api.resultInt64(ctx, @intFromBool(pgc.visible(s, p, r)));
    api.resultNull(ctx);
}

fn getExprFunc(ctx: *Context, argv: []*Mem) void {
    api.resultValue(ctx, argv[0]);
}

fn indexDefFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    const col: i64 = if (argv.len > 1 and !isNull(argv[1])) api.valueInt64(argv[1]) else 0;
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    const x = s.index(oid) orelse return api.resultNull(ctx);
    if (col > 0) {
        if (col > x.coldefs.len) return c.text("");
        const d = x.coldefs[@intCast(col - 1)];
        return c.text(if (std.mem.endsWith(u8, d, " DESC")) d[0 .. d.len - 5] else d);
    }
    const z = indexDef(c.a(), s, x, prettyArg(argv, 2)) catch return c.oom();
    c.text(z);
}

/// The `pretty` argument at `i`, false without one.
fn prettyArg(argv: []*Mem, i: usize) bool {
    return argv.len > i and !isNull(argv[i]) and api.valueInt64(argv[i]) != 0;
}

/// `z` without one pair of parentheses around all of it, if it has one
/// (strings and quoted names skipped).
fn unwrap(z: []const u8) ?[]const u8 {
    if (z.len < 2 or z[0] != '(' or z[z.len - 1] != ')') return null;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < z.len) : (i += 1) {
        switch (z[i]) {
            '\'', '"' => {
                const q = z[i];
                i += 1;
                while (i < z.len and z[i] != q) i += 1;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0 and i != z.len - 1) return null;
            },
            else => {},
        }
    }
    return z[1 .. z.len - 1];
}

/// The places of the AND and OR outside parentheses of `z`.
fn topLevelOps(a: Allocator, z: []const u8) error{OutOfMemory}![]const struct { usize, usize } {
    var out: std.ArrayList(struct { usize, usize }) = .empty;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < z.len) : (i += 1) {
        switch (z[i]) {
            '\'', '"' => {
                const q = z[i];
                i += 1;
                while (i < z.len and z[i] != q) i += 1;
            },
            '(' => depth += 1,
            ')' => depth -|= 1,
            ' ' => if (depth == 0) {
                for ([_][]const u8{ " AND ", " OR " }) |w| {
                    if (i + w.len <= z.len and std.ascii.eqlIgnoreCase(z[i .. i + w.len], w)) {
                        try out.append(a, .{ i, i + w.len });
                        break;
                    }
                }
            },
            else => {},
        }
    }
    return out.items;
}

/// An expression as PostgreSQL's pretty mode prints it: without the
/// parentheses around all of it, nor around an AND's or OR's operand that
/// is no AND or OR itself (`a > 0 AND c IS NOT NULL`).
fn pretty(a: Allocator, z0: []const u8) error{OutOfMemory}![]const u8 {
    var z = std.mem.trim(u8, z0, " ");
    while (unwrap(z)) |x| z = std.mem.trim(u8, x, " ");
    const ops = try topLevelOps(a, z);
    if (ops.len == 0) return z;
    var out: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    for (0..ops.len + 1) |k| {
        const end = if (k < ops.len) ops[k][0] else z.len;
        const operand = std.mem.trim(u8, z[start..end], " ");
        const inner = unwrap(operand);
        const keep = inner == null or (try topLevelOps(a, inner.?)).len > 0;
        try out.appendSlice(a, if (keep) operand else std.mem.trim(u8, inner.?, " "));
        if (k < ops.len) {
            try out.appendSlice(a, z[ops[k][0]..ops[k][1]]);
            start = ops[k][1];
        }
    }
    return out.items;
}

pub fn indexDef(a: Allocator, s: *const Snapshot, x: *const pgc.IndexRow, pretty_mode: bool) error{OutOfMemory}![]const u8 {
    const ir = s.rel(x.rel) orelse return "";
    const tr = s.rel(x.table) orelse return "";
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "CREATE {s}INDEX {s} ON {s} USING btree (", .{ if (x.unique) "UNIQUE " else "", try pgc.quoteIdent(a, ir.name), try relQualified(a, s, tr) });
    for (x.coldefs, 0..) |d, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, d);
    }
    try out.append(a, ')');
    if (x.pred) |p| {
        if (pretty_mode) {
            try out.print(a, " WHERE {s}", .{try pretty(a, p)});
        } else if (unwrap(p) != null) try out.print(a, " WHERE {s}", .{p}) else try out.print(a, " WHERE ({s})", .{p});
    }
    return out.items;
}

fn constraintDefFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    const k = s.con(oid) orelse return api.resultNull(ctx);
    const p = c.path(s) orelse return;
    const z = constraintDef(c.a(), s, p, k, prettyArg(argv, 1)) catch return c.oom();
    c.text(z);
}

fn columnList(a: Allocator, out: *std.ArrayList(u8), s: *const Snapshot, rel: u32, keys: []const i16) error{OutOfMemory}!void {
    try out.append(a, '(');
    for (keys, 0..) |k, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, if (s.attr(rel, k)) |at| try pgc.quoteIdent(a, at.name) else "?");
    }
    try out.append(a, ')');
}

pub fn constraintDef(a: Allocator, s: *const Snapshot, p: []const u32, k: *const pgc.Con, pretty_mode: bool) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (k.type) {
        'p', 'u' => {
            try out.appendSlice(a, if (k.type == 'p') "PRIMARY KEY " else "UNIQUE ");
            try columnList(a, &out, s, k.rel, k.keys);
        },
        'f' => {
            try out.appendSlice(a, "FOREIGN KEY ");
            try columnList(a, &out, s, k.rel, k.keys);
            try out.appendSlice(a, " REFERENCES ");
            if (s.rel(k.frel)) |fr| try out.appendSlice(a, try relText(a, s, p, fr)) else try out.appendSlice(a, "?");
            try columnList(a, &out, s, k.frel, k.fkeys);
            const actions = [_]struct { u8, []const u8 }{ .{ 'r', "RESTRICT" }, .{ 'c', "CASCADE" }, .{ 'n', "SET NULL" }, .{ 'd', "SET DEFAULT" } };
            for (actions) |x| if (x[0] == k.upd) try out.print(a, " ON UPDATE {s}", .{x[1]});
            for (actions) |x| if (x[0] == k.del) try out.print(a, " ON DELETE {s}", .{x[1]});
            if (k.deferrable) try out.appendSlice(a, " DEFERRABLE");
            if (k.deferred) try out.appendSlice(a, " INITIALLY DEFERRED");
        },
        'c' => {
            const b = k.bin orelse "";
            if (pretty_mode) {
                try out.print(a, "CHECK ({s})", .{try pretty(a, b)});
            } else if (unwrap(b) != null) try out.print(a, "CHECK ({s})", .{b}) else try out.print(a, "CHECK (({s}))", .{b});
        },
        else => {},
    }
    return out.items;
}

fn viewDefFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    const r: *const pgc.Rel = if (api.valueType(argv[0]) == vi.SQLITE_INTEGER)
        s.rel(oidArg(argv[0]).?) orelse return api.resultNull(ctx)
    else blk: {
        const name = dfunc.text(ctx, argv[0]) orelse return;
        const p = c.path(s) orelse return;
        const oid = resolveClass(c.a(), s, p, name) catch return c.oom();
        break :blk s.rel(oid orelse return api.resultNull(ctx)) orelse return api.resultNull(ctx);
    };
    const sql = r.sql orelse return api.resultNull(ctx);
    const z = viewQuery(c.a(), s, sql) catch return c.oom();
    c.text(z);
}

/// The query of a view's CREATE VIEW text, as pg_get_viewdef() writes it
/// (after a space, before a semicolon).
fn viewQuery(a: Allocator, s: *const Snapshot, sql: []const u8) error{OutOfMemory}![]const u8 {
    // After the first AS outside a column list.
    var depth: usize = 0;
    var i: usize = 0;
    var start: usize = 0;
    while (i + 3 < sql.len) : (i += 1) {
        switch (sql[i]) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            '"', '\'' => {
                const q = sql[i];
                i += 1;
                while (i < sql.len and sql[i] != q) i += 1;
            },
            else => {},
        }
        if (depth == 0 and std.ascii.eqlIgnoreCase(sql[i .. i + 4], " AS ")) {
            start = i + 4;
            break;
        }
    }
    const reg = registered(a, s) catch return error.OutOfMemory;
    const q = try pgc.pgText(a, std.mem.trim(u8, sql[start..], " ;"), reg);
    return std.fmt.allocPrint(a, " {s};", .{q});
}

fn registered(a: Allocator, s: *const Snapshot) error{OutOfMemory}![]const @import("../../catalog/schema.zig").Info {
    var out: std.ArrayList(@import("../../catalog/schema.zig").Info) = .empty;
    for (s.nsps) |n| if (n.mangled) try out.append(a, .{ .name = n.name, .owner = state.user });
    return out.items;
}

fn objDescriptionFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    if (argv.len > 1) {
        const cat = dfunc.text(ctx, argv[1]) orelse return;
        if (!eql(cat, "pg_class") and !eql(cat, "pg_catalog.pg_class")) return api.resultNull(ctx);
    }
    describe(ctx, oid, 0);
}

fn colDescriptionFunc(ctx: *Context, argv: []*Mem) void {
    const oid = oidArg(argv[0]) orelse return api.resultNull(ctx);
    if (isNull(argv[1])) return api.resultNull(ctx);
    describe(ctx, oid, @intCast(std.math.clamp(api.valueInt64(argv[1]), -1, std.math.maxInt(i32))));
}

fn describe(ctx: *Context, oid: u32, subid: i32) void {
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    for (s.descs) |d| if (d.obj == oid and d.subid == subid) return c.text(d.text);
    api.resultNull(ctx);
}

/// pg_get_serial_sequence(table, column): the sequence of an identity or
/// serial column, schema-qualified.
fn serialSequenceFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(ctx);
    const tname = dfunc.text(ctx, argv[0]) orelse return;
    const col = dfunc.text(ctx, argv[1]) orelse return;
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    const p = c.path(s) orelse return;
    const oid = (resolveClass(c.a(), s, p, tname) catch return c.oom()) orelse {
        return relationError(ctx, tname);
    };
    const cname = (parseName(c.a(), col) catch return c.oom())[0];
    var num: i16 = 0;
    for (s.attrs) |at| if (at.rel == oid and eql(at.name, cname)) {
        num = at.num;
    };
    if (num == 0) {
        var buf: [256]u8 = undefined;
        return api.resultErrorState(ctx, .of("42703"), std.fmt.bufPrint(&buf, "column \"{s}\" of relation \"{s}\" does not exist", .{ cname[0..@min(cname.len, 100)], tname[0..@min(tname.len, 100)] }) catch "column does not exist");
    }
    for (s.deps) |d| if (d.rel == oid and d.num == num) {
        const r = s.rel(d.seq) orelse break;
        return c.text(relQualified(c.a(), s, r) catch return c.oom());
    };
    api.resultNull(ctx);
}

// ============================================================ reg* types

const Reg = enum { class, type, namespace, role };

/// The parts of a possibly qualified name: unquoted parts folded to lower
/// case, "x" kept (PostgreSQL's stringToQualifiedNameList()).
fn parseName(a: Allocator, z: []const u8) error{OutOfMemory}![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const t = std.mem.trim(u8, z, " ");
    while (i <= t.len) : (i += 1) {
        if (i == t.len or t[i] == '.') {
            try parts.append(a, cur.items);
            cur = .empty;
            continue;
        }
        if (t[i] == '"') {
            i += 1;
            while (i < t.len) : (i += 1) {
                if (t[i] == '"') {
                    if (i + 1 < t.len and t[i + 1] == '"') {
                        i += 1;
                    } else break;
                }
                try cur.append(a, t[i]);
            }
            continue;
        }
        try cur.append(a, std.ascii.toLower(t[i]));
    }
    // The name last.
    std.mem.reverse([]const u8, parts.items);
    return parts.items;
}

fn allDigits(z: []const u8) bool {
    if (z.len == 0) return false;
    for (z) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The OID of relation name `z` along search path `p`; null if none.
pub fn resolveClass(a: Allocator, s: *const Snapshot, p: []const u32, z: []const u8) error{OutOfMemory}!?u32 {
    const parts = try parseName(a, z);
    const name = parts[0];
    if (parts.len > 1) {
        const ns = parts[1];
        if (eql(ns, "pg_catalog")) {
            for (pgc.builtin_relations) |b| if (eql(b[1], name)) return b[0];
            return null;
        }
        const n = s.nspByName(ns) orelse return null;
        return if (s.relByName(n.oid, name)) |r| r.oid else null;
    }
    for (p) |n| {
        if (n == pgc.oid_pg_catalog) {
            for (pgc.builtin_relations) |b| if (eql(b[1], name)) return b[0];
            continue;
        }
        if (s.relByName(n, name)) |r| return r.oid;
    }
    return null;
}

/// The OID of type name `z` (format_type()'s spelling, the internal name
/// or a common alias, `[]` for its array); a relation's row type.
fn resolveType(a: Allocator, s: *const Snapshot, p: []const u32, z0: []const u8) error{OutOfMemory}!?u32 {
    var z = std.mem.trim(u8, z0, " ");
    var array = false;
    if (std.mem.endsWith(u8, z, "[]")) {
        array = true;
        z = std.mem.trim(u8, z[0 .. z.len - 2], " ");
    }
    // Without the modifiers ("character varying(20)").
    var buf: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (z) |c| {
        if (c == '(') depth += 1;
        if (depth == 0) try buf.append(a, std.ascii.toLower(c));
        if (c == ')') depth -|= 1;
    }
    var words: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, buf.items, ' ');
    while (it.next()) |w| {
        if (words.items.len > 0) try words.append(a, ' ');
        try words.appendSlice(a, w);
    }
    var n: []const u8 = words.items;
    if (std.mem.startsWith(u8, n, "pg_catalog.")) n = n["pg_catalog.".len..];
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "int", "int4" },                    .{ "integer", "int4" },               .{ "smallint", "int2" },                         .{ "bigint", "int8" },
        .{ "boolean", "bool" },                .{ "real", "float4" },                .{ "float", "float8" },                          .{ "double precision", "float8" },
        .{ "decimal", "numeric" },             .{ "character varying", "varchar" },  .{ "char varying", "varchar" },                  .{ "character", "bpchar" },
        .{ "char", "bpchar" },                 .{ "\"char\"", "char" },              .{ "timestamp without time zone", "timestamp" }, .{ "timestamp with time zone", "timestamptz" },
        .{ "time without time zone", "time" }, .{ "time with time zone", "timetz" }, .{ "bit varying", "varbit" },
    };
    for (aliases) |x| if (eql(x[0], n)) {
        n = x[1];
        break;
    };
    for (pgc.builtin_types) |t| if (t.cat != 'A' or t.elem == 0 or t.oid == 22 or t.oid == 30) if (eql(t.name, n)) {
        return if (array) t.array else t.oid;
    };
    if (array) return null;
    const oid = (try resolveClass(a, s, p, z)) orelse return null;
    const r = s.rel(oid) orelse return null;
    return if (r.rowtype != 0) r.rowtype else null;
}

fn relationError(ctx: *Context, z: []const u8) void {
    var buf: [256]u8 = undefined;
    api.resultErrorState(ctx, .of("42P01"), std.fmt.bufPrint(&buf, "relation \"{s}\" does not exist", .{z[0..@min(z.len, 200)]}) catch "relation does not exist");
}

/// The input of a reg* type: an OID as a number, else the object's name.
/// `soft`: NULL for an unknown name (to_regclass()), else an error.
fn regIn(ctx: *Context, argv: []*Mem, comptime reg: Reg, comptime soft: bool) void {
    const m = argv[0];
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return api.resultNull(ctx),
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return api.resultInt64(ctx, api.valueInt64(m)),
        else => {},
    }
    const z = std.mem.trim(u8, dfunc.text(ctx, m) orelse return, " ");
    if (allDigits(z)) return api.resultInt64(ctx, std.fmt.parseInt(i64, z, 10) catch 0);
    if (eql(z, "-")) return api.resultInt64(ctx, 0);
    var c: Call = .init(ctx);
    defer c.deinit();
    var buf: [256]u8 = undefined;
    switch (reg) {
        .role => {
            const n = (parseName(c.a(), z) catch return c.oom())[0];
            if (eql(n, state.user)) return api.resultInt64(ctx, pgc.oid_superuser);
            if (soft) return api.resultNull(ctx);
            return api.resultErrorState(ctx, .of("42704"), std.fmt.bufPrint(&buf, "role \"{s}\" does not exist", .{n[0..@min(n.len, 100)]}) catch "role does not exist");
        },
        else => {},
    }
    const s = c.get() orelse return;
    const p = c.path(s) orelse return;
    switch (reg) {
        .class => {
            if (resolveClass(c.a(), s, p, z) catch return c.oom()) |o| return api.resultInt64(ctx, o);
            if (soft) return api.resultNull(ctx);
            relationError(ctx, z);
        },
        .type => {
            if (resolveType(c.a(), s, p, z) catch return c.oom()) |o| return api.resultInt64(ctx, o);
            if (soft) return api.resultNull(ctx);
            api.resultErrorState(ctx, .of("42704"), std.fmt.bufPrint(&buf, "type \"{s}\" does not exist", .{z[0..@min(z.len, 100)]}) catch "type does not exist");
        },
        .namespace => {
            const n = (parseName(c.a(), z) catch return c.oom())[0];
            if (s.nspByName(n)) |x| return api.resultInt64(ctx, x.oid);
            if (soft) return api.resultNull(ctx);
            api.resultErrorState(ctx, .of("3F000"), std.fmt.bufPrint(&buf, "schema \"{s}\" does not exist", .{n[0..@min(n.len, 100)]}) catch "schema does not exist");
        },
        .role => unreachable,
    }
}

/// The text of a reg* value.
fn regOut(ctx: *Context, argv: []*Mem, comptime reg: Reg) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_TEXT and !allDigits(api.valueText(argv[0]) orelse "")) return api.resultValue(ctx, argv[0]);
    const oid = oidArg(argv[0]).?;
    var nbuf: [16]u8 = undefined;
    const number = std.fmt.bufPrint(&nbuf, "{d}", .{oid}) catch "0";
    if (oid == 0) return api.resultText(ctx, "-", .static);
    switch (reg) {
        .role => return api.resultText(ctx, if (oid == pgc.oid_superuser) state.user else number, .transient),
        .type => if (pgc.builtinType(oid)) |t| return api.resultText(ctx, t.fmt, .static),
        .class => for (pgc.builtin_relations) |b| if (b[0] == oid) return api.resultText(ctx, b[1], .static),
        .namespace => {},
    }
    var c: Call = .init(ctx);
    defer c.deinit();
    const s = c.get() orelse return;
    switch (reg) {
        .namespace => if (s.nsp(oid)) |n| return c.text(pgc.quoteIdent(c.a(), n.name) catch return c.oom()),
        .class => if (s.rel(oid)) |r| {
            const p = c.path(s) orelse return;
            return c.text(relText(c.a(), s, p, r) catch return c.oom());
        },
        .type => for (s.rels) |*r| if (r.rowtype == oid) {
            const p = c.path(s) orelse return;
            return c.text(relText(c.a(), s, p, r) catch return c.oom());
        },
        .role => unreachable,
    }
    api.resultText(ctx, number, .transient);
}

/// xq_pg_regproc(x): a function's name ('pg_catalog.array_in' is
/// array_in), its OID's name if known.
fn regprocFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (isNull(m)) return api.resultNull(ctx);
    var c: Call = .init(ctx);
    defer c.deinit();
    if (api.valueType(m) == vi.SQLITE_INTEGER) {
        const oid = oidArg(m).?;
        if (oid == 0) return api.resultText(ctx, "-", .static);
        if (pgc.procName(c.a(), oid) catch return c.oom()) |n| return c.text(n);
        return api.resultValue(ctx, m);
    }
    const z = dfunc.text(ctx, m) orelse return;
    const parts = parseName(c.a(), z) catch return c.oom();
    c.text(parts[0]);
}

test "pretty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a > 0 AND c IS NOT NULL", try pretty(a, "((a > 0) AND (c IS NOT NULL))"));
    try std.testing.expectEqualStrings("length(b) > 1", try pretty(a, "(length(b) > 1)"));
    try std.testing.expectEqualStrings("(a OR b) AND c = ')'", try pretty(a, "((a OR b) AND (c = ')'))"));
    try std.testing.expectEqualStrings("(a) + (b)", try pretty(a, "(a) + (b)"));
}

test "parseName" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseName(arena.allocator(), "Sales.\"My T\"");
    try std.testing.expectEqualStrings("My T", p[0]);
    try std.testing.expectEqualStrings("sales", p[1]);
}
