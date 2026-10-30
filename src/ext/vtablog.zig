//! The vtablog virtual table (port of ext/misc/vtablog.c): a virtual table
//! that prints each call of its methods, for testing and analysing the
//! virtual table interface.
//!
//!     CREATE VIRTUAL TABLE temp.log USING vtablog(
//!        schema='CREATE TABLE x(a,b,c)',
//!        rows=25
//!     );
//!
//! Arguments: schema=TEXT (the CREATE TABLE statement of the table,
//! default "CREATE TABLE x(a,b);"), rows=N (the table has N rows, default
//! 10), consume_order_by=N (set orderByConsumed when the left-most ORDER
//! BY term is column N ascending, or -N descending; columns count from 1).
//! Column i of row r is the letter i ('a'...) followed by r. xUpdate only
//! prints its arguments.
//!
//! The output goes to `out`; the xqlite shell sets it to its own output
//! when the XQ_VTABLOG environment variable is set (the sqlite3 shell
//! prints to the same stdout), so that `xqt planner` can compare
//! the calls with those of an sqlite3 built with vtablog.c.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const vtab = @import("../sql/vtab.zig");
const api = @import("../vdbe/api.zig");
const printf = @import("../sql/printf.zig");

const Sqlite3 = int.Sqlite3;
const Mem = vi.Mem;
const RC = int.RC;
const IC = vtab.INDEX_CONSTRAINT;

/// Where the calls are printed (stdout in C): the pAux of the module.
const Out = *std.Io.Writer;

fn printTo(out: Out, comptime fmt: []const u8, args: anytype) void {
    out.print(fmt, args) catch {};
}

/// vtablog_vtab.
const LogVtab = struct {
    base: vtab.Vtab = .{},
    gpa: std.mem.Allocator,
    out: Out,
    /// Schema name: argv[1] of xConnect/xCreate.
    z_db: [:0]u8,
    /// Table name: argv[2] of xConnect/xCreate.
    z_name: [:0]u8,
    /// Rows of the table.
    n_row: i32 = 10,
    /// Cursors made.
    n_cursor: i32 = 0,
    /// Consume the ORDER BY if on the N-th column, or -N with DESC.
    i_consume_ob: i32 = 0,

    fn of(p: *vtab.Vtab) *LogVtab {
        return @fieldParentPtr("base", p);
    }

    fn print(t: *const LogVtab, comptime fmt: []const u8, args: anytype) void {
        printTo(t.out, fmt, args);
    }
};

/// vtablog_cursor.
const LogCursor = struct {
    base: vtab.VtabCursor = .{},
    i_cursor: i32,
    i_rowid: i64 = 0,

    fn of(cur: *vtab.VtabCursor) *LogCursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }
};

/// Port of vtablog_skip_whitespace().
fn skipWhitespace(z: []const u8) []const u8 {
    var i: usize = 0;
    while (i < z.len and std.ascii.isWhitespace(z[i])) i += 1;
    return z[i..];
}

/// Port of vtablog_dequote().
fn dequote(z: []u8) []u8 {
    const q: u8 = if (z.len > 0) z[0] else 0;
    if (q != '\'' and q != '"') return z;
    const n = z.len;
    if (n < 2 or z[n - 1] != z[0]) return z;
    var i: usize = 1;
    var j: usize = 0;
    while (i < n - 1) : (i += 1) {
        if (z[i] == q and z[i + 1] == q) i += 1;
        z[j] = z[i];
        j += 1;
    }
    return z[0..j];
}

/// Port of vtablog_parameter(): the value of "TAG = VALUE" in `z`, or null.
fn parameter(tag: []const u8, z_arg: []const u8) ?[]const u8 {
    var z = skipWhitespace(z_arg);
    if (!std.mem.startsWith(u8, z, tag)) return null;
    z = skipWhitespace(z[tag.len..]);
    if (z.len == 0 or z[0] != '=') return null;
    return skipWhitespace(z[1..]);
}

/// Port of vtablog_string_parameter(): true on an error (left in `err`).
/// The value is NUL-terminated within its allocation, which `val` holds
/// whole. (vtablog_trim_whitespace() starts at the terminator, so it never
/// trims anything.)
fn stringParameter(gpa: std.mem.Allocator, err: *?[:0]u8, param: []const u8, arg: []const u8, val: *?[:0]u8) bool {
    const value = parameter(param, arg) orelse return false;
    if (val.* != null) {
        err.* = std.fmt.allocPrintSentinel(gpa, "more than one '{s}' parameter", .{param}, 0) catch null;
        return true;
    }
    const copy = gpa.dupeSentinel(u8, value, 0) catch {
        err.* = gpa.dupeSentinel(u8, "out of memory", 0) catch null;
        return true;
    };
    const n = dequote(copy).len;
    copy[n] = 0;
    val.* = copy;
    return false;
}

fn freeParam(gpa: std.mem.Allocator, z: ?[:0]u8) void {
    if (z) |s| gpa.free(s);
}

/// The text of a parameter (up to its terminator).
fn paramText(z: [:0]u8) [:0]const u8 {
    return std.mem.sliceTo(z, 0);
}

/// Port of atoi().
fn atoi(z: []const u8) i32 {
    var s = skipWhitespace(z);
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var v: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(i32)) break;
    }
    return @truncate(if (neg) -v else v);
}

/// Port of vtablogConnectCreate().
fn connectCreate(db: *Sqlite3, out: Out, argv: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, err: *?[:0]u8, is_create: bool) i32 {
    const gpa = db.gpa;
    var rc: i32 = RC.OK;
    var z_schema: ?[:0]u8 = null;
    var z_nrow: ?[:0]u8 = null;
    var z_consume_ob: ?[:0]u8 = null;
    defer {
        freeParam(gpa, z_schema);
        freeParam(gpa, z_nrow);
        freeParam(gpa, z_consume_ob);
    }

    printTo(out, "{s}.{s}.{s}():\n", .{ argv[1], argv[2], if (is_create) "xCreate" else "xConnect" });
    printTo(out, "  argc={d}\n", .{argv.len});
    for (argv, 0..) |a, i| printTo(out, "  argv[{d}] = [{s}]\n", .{ i, a });

    for (argv[3..]) |z| {
        if (stringParameter(gpa, err, "schema", z, &z_schema)) return RC.ERROR;
        if (stringParameter(gpa, err, "rows", z, &z_nrow)) return RC.ERROR;
        if (stringParameter(gpa, err, "consume_order_by", z, &z_consume_ob)) return RC.ERROR;
    }
    if (z_schema == null) {
        z_schema = gpa.dupeSentinel(u8, "CREATE TABLE x(a,b);", 0) catch return RC.NOMEM;
    }
    printTo(out, "  schema = '{s}'\n", .{paramText(z_schema.?)});
    rc = vtab.declareVtab(db, paramText(z_schema.?));
    if (rc == RC.OK) {
        const new = gpa.create(LogVtab) catch return RC.NOMEM;
        new.* = .{
            .gpa = gpa,
            .out = out,
            .z_db = gpa.dupeSentinel(u8, argv[1], 0) catch {
                gpa.destroy(new);
                return RC.NOMEM;
            },
            .z_name = gpa.dupeSentinel(u8, argv[2], 0) catch {
                gpa.destroy(new);
                return RC.NOMEM;
            },
        };
        pp_vtab.* = &new.base;
        if (z_nrow) |z| new.n_row = atoi(paramText(z));
        printTo(out, "  nrow = {d}\n", .{new.n_row});
        if (z_consume_ob) |z| new.i_consume_ob = atoi(paramText(z));
        if (new.i_consume_ob != 0) printTo(out, "  consume_order_by = {d}\n", .{new.i_consume_ob});
    }
    return rc;
}

fn logCreate(db: *Sqlite3, out: Out, argv: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, err: *?[:0]u8) i32 {
    return connectCreate(db, out, argv, pp_vtab, err, true);
}

fn logConnect(db: *Sqlite3, out: Out, argv: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, err: *?[:0]u8) i32 {
    return connectCreate(db, out, argv, pp_vtab, err, false);
}

fn freeVtab(t: *LogVtab) void {
    const gpa = t.gpa;
    gpa.free(t.z_db);
    gpa.free(t.z_name);
    gpa.destroy(t);
}

/// Port of vtablogDisconnect().
fn logDisconnect(p: *vtab.Vtab) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xDisconnect()\n", .{ t.z_db, t.z_name });
    freeVtab(t);
    return RC.OK;
}

/// Port of vtablogDestroy().
fn logDestroy(p: *vtab.Vtab) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xDestroy()\n", .{ t.z_db, t.z_name });
    freeVtab(t);
    return RC.OK;
}

/// Port of vtablogOpen().
fn logOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t = LogVtab.of(p);
    t.n_cursor += 1;
    t.print("{s}.{s}.xOpen(cursor={d})\n", .{ t.z_db, t.z_name, t.n_cursor });
    const cur = t.gpa.create(LogCursor) catch return RC.NOMEM;
    cur.* = .{ .i_cursor = t.n_cursor };
    pp_cursor.* = &cur.base;
    return RC.OK;
}

/// Port of vtablogClose().
fn logClose(cur: *vtab.VtabCursor) i32 {
    const c = LogCursor.of(cur);
    const t = LogVtab.of(cur.vtab);
    t.print("{s}.{s}.xClose(cursor={d})\n", .{ t.z_db, t.z_name, c.i_cursor });
    t.gpa.destroy(c);
    return RC.OK;
}

/// Port of vtablogNext().
fn logNext(cur: *vtab.VtabCursor) i32 {
    const c = LogCursor.of(cur);
    const t = LogVtab.of(cur.vtab);
    const r: i32 = @truncate(c.i_rowid);
    t.print("{s}.{s}.xNext(cursor={d})  rowid {d} -> {d}\n", .{ t.z_db, t.z_name, c.i_cursor, r, r +% 1 });
    c.i_rowid += 1;
    return RC.OK;
}

/// Port of vtablogColumn().
fn logColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = LogCursor.of(cur);
    const t = LogVtab.of(cur.vtab);
    var buf: [50]u8 = undefined;
    const r: i32 = @truncate(c.i_rowid);
    const val = if (i < 26)
        std.fmt.bufPrint(&buf, "{c}{d}", .{ "abcdefghijklmnopqrstuvwxyz"[@intCast(i)], r }) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{{{d}}}{d}", .{ i, r }) catch unreachable;
    t.print("{s}.{s}.xColumn(cursor={d}, i={d}): [{s}]\n", .{ t.z_db, t.z_name, c.i_cursor, i, val });
    api.resultText(ctx, val, .transient);
    return RC.OK;
}

/// Port of vtablogRowid().
fn logRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    const c = LogCursor.of(cur);
    const t = LogVtab.of(cur.vtab);
    t.print("{s}.{s}.xRowid(cursor={d}): {d}\n", .{ t.z_db, t.z_name, c.i_cursor, @as(i32, @truncate(c.i_rowid)) });
    rowid.* = c.i_rowid;
    return RC.OK;
}

/// Port of vtablogEof().
fn logEof(cur: *vtab.VtabCursor) bool {
    const c = LogCursor.of(cur);
    const t = LogVtab.of(cur.vtab);
    const rc = c.i_rowid >= t.n_row;
    t.print("{s}.{s}.xEof(cursor={d}): {d}\n", .{ t.z_db, t.z_name, c.i_cursor, @intFromBool(rc) });
    return rc;
}

/// Port of vtablogQuote(): print a value as an SQL literal.
fn quote(out: Out, gpa: std.mem.Allocator, p: *Mem) void {
    switch (api.valueType(p)) {
        vi.SQLITE_NULL => printTo(out, "NULL", .{}),
        vi.SQLITE_INTEGER => printTo(out, "{d}", .{api.valueInt64(p)}),
        vi.SQLITE_FLOAT => {
            const z = printf.mprintf(gpa, "%!.20g", &.{.{ .double = api.valueDouble(p) }}) catch return;
            defer gpa.free(z);
            printTo(out, "{s}", .{z});
        },
        vi.SQLITE_BLOB => {
            const z = api.valueBlob(p) orelse {
                printTo(out, "/*OOM-fault*/", .{});
                return;
            };
            printTo(out, "x'", .{});
            for (z) |b| printTo(out, "{x:0>2}", .{b});
            printTo(out, "'", .{});
        },
        vi.SQLITE_TEXT => {
            const z: []const u8 = api.valueText(p) orelse "";
            // A single quote is doubled... as the C code does it: each
            // quote is printed once more after the text up to it.
            if (std.mem.indexOfScalar(u8, z, '\'') == null) {
                printTo(out, "'{s}'", .{z});
            } else {
                printTo(out, "'", .{});
                var rest = z;
                while (rest.len > 0) {
                    var i: usize = 0;
                    while (i < rest.len and rest[i] != '\'') i += 1;
                    const c: u8 = if (i < rest.len) rest[i] else 0;
                    if (c == '\'') i += 1;
                    if (i > 0) {
                        printTo(out, "{s}", .{rest[0..i]});
                        rest = rest[i..];
                    }
                    if (c == '\'') {
                        printTo(out, "'", .{});
                        continue;
                    }
                    if (c == 0) break;
                    rest = rest[1..];
                }
                printTo(out, "'", .{});
            }
        },
        else => {},
    }
}

/// Port of vtablogFilter().
fn logFilter(cur: *vtab.VtabCursor, _: i32, _: ?[:0]const u8, _: []*Mem) i32 {
    const c = LogCursor.of(cur);
    const t = LogVtab.of(cur.vtab);
    t.print("{s}.{s}.xFilter(cursor={d}):\n", .{ t.z_db, t.z_name, c.i_cursor });
    c.i_rowid = 0;
    return RC.OK;
}

/// Port of vtablogOpName().
fn opName(buf: *[30]u8, op: u8) []const u8 {
    return switch (op) {
        IC.EQ => "EQ",
        IC.GT => "GT",
        IC.LE => "LE",
        IC.LT => "LT",
        IC.GE => "GE",
        IC.MATCH => "MATCH",
        IC.LIKE => "LIKE",
        IC.GLOB => "GLOB",
        IC.REGEXP => "REGEXP",
        IC.NE => "NE",
        IC.ISNOT => "ISNOT",
        IC.ISNOTNULL => "ISNOTNULL",
        IC.ISNULL => "ISNULL",
        IC.IS => "IS",
        IC.LIMIT => "LIMIT",
        IC.OFFSET => "OFFSET",
        IC.FUNCTION => "FUNCTION",
        else => std.fmt.bufPrint(buf, "{d}", .{op}) catch unreachable,
    };
}

/// Port of vtablogBestIndex().
fn logBestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xBestIndex():\n", .{ t.z_db, t.z_name });
    t.print("  colUsed: 0x{x:0>16}\n", .{info.col_used});
    t.print("  nConstraint: {d}\n", .{info.constraints.len});
    for (info.constraints, 0..) |cons, i| {
        var val: ?*Mem = null;
        const rc = vtab.rhsValue(info, @intCast(i), &val);
        var buf: [30]u8 = undefined;
        t.print("  constraint[{d}]: col={d} termid={d} op={s} usabled={d} coll={s} rhs=", .{
            i,
            cons.i_column,
            cons.i_term_offset,
            opName(&buf, cons.op),
            @intFromBool(cons.usable),
            vtab.collation(info, @intCast(i)) orelse "(null)",
        });
        if (rc == RC.OK) {
            quote(t.out, t.gpa, val.?);
            t.print("\n", .{});
        } else {
            t.print("N/A\n", .{});
        }
    }
    t.print("  nOrderBy: {d}\n", .{info.order_by.len});
    if (info.order_by.len > 0) {
        for (info.order_by, 0..) |ob, i| {
            t.print("  orderby[{d}]: col={d} desc={d}\n", .{ i, ob.i_column, @intFromBool(ob.desc) });
        }
        if (t.i_consume_ob != 0) {
            const n = info.order_by[0].i_column + 1;
            if ((info.order_by[0].desc and n == -t.i_consume_ob) or
                (!info.order_by[0].desc and n == t.i_consume_ob))
            {
                info.order_by_consumed = true;
            }
        }
    }
    info.estimated_cost = 500;
    info.estimated_rows = 500;
    t.print("  idxNum={d}\n", .{info.idx_num});
    t.print("  idxStr=NULL\n", .{});
    t.print("  sqlite3_vtab_distinct()={d}\n", .{vtab.distinct(info)});
    t.print("  orderByConsumed={d}\n", .{@intFromBool(info.order_by_consumed)});
    const cost = printf.mprintf(t.gpa, "%g", &.{.{ .double = info.estimated_cost }}) catch return RC.NOMEM;
    defer t.gpa.free(cost);
    t.print("  estimatedCost={s}\n", .{cost});
    t.print("  estimatedRows={d}\n", .{info.estimated_rows});
    return RC.OK;
}

/// Port of vtablogUpdate(): print the arguments; nothing changes.
fn logUpdate(p: *vtab.Vtab, argv: []*Mem, _: *i64) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xUpdate():\n", .{ t.z_db, t.z_name });
    t.print("  argc={d}\n", .{argv.len});
    for (argv, 0..) |a, i| {
        t.print("  argv[{d}]=", .{i});
        quote(t.out, t.gpa, a);
        t.print("\n", .{});
    }
    return RC.OK;
}

fn logBegin(p: *vtab.Vtab) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xBegin()\n", .{ t.z_db, t.z_name });
    return RC.OK;
}

fn logSync(p: *vtab.Vtab) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xSync()\n", .{ t.z_db, t.z_name });
    return RC.OK;
}

fn logCommit(p: *vtab.Vtab) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xCommit()\n", .{ t.z_db, t.z_name });
    return RC.OK;
}

fn logRollback(p: *vtab.Vtab) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xRollback()\n", .{ t.z_db, t.z_name });
    return RC.OK;
}

fn logSavepoint(p: *vtab.Vtab, n: i32) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xSavepoint({d})\n", .{ t.z_db, t.z_name, n });
    return RC.OK;
}

fn logRelease(p: *vtab.Vtab, n: i32) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xRelease({d})\n", .{ t.z_db, t.z_name, n });
    return RC.OK;
}

fn logRollbackTo(p: *vtab.Vtab, n: i32) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xRollbackTo({d})\n", .{ t.z_db, t.z_name, n });
    return RC.OK;
}

/// Port of vtablogFindMethod(): prints; overloads nothing.
fn logFindMethod(p: *vtab.Vtab, n_arg: i32, name: [:0]const u8, _: *?int.FuncDef.StepFn, _: *?*anyopaque) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xFindMethod(nArg={d}, zName={s})\n", .{ t.z_db, t.z_name, n_arg, name });
    return RC.OK;
}

/// Port of vtablogRename().
fn logRename(p: *vtab.Vtab, new_name: [:0]const u8) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xRename('{s}')\n", .{ t.z_db, t.z_name, new_name });
    const copy = t.gpa.dupeSentinel(u8, new_name, 0) catch return RC.NOMEM;
    t.gpa.free(t.z_name);
    t.z_name = copy;
    return RC.OK;
}

/// Port of vtablogShadowName(): a name containing "shadow" is a shadow
/// table name.
fn logShadowName(out: Out, name: []const u8) bool {
    printTo(out, "vtablog.xShadowName('{s}')\n", .{name});
    return std.mem.indexOf(u8, name, "shadow") != null;
}

/// Port of vtablogIntegrity().
fn logIntegrity(p: *vtab.Vtab, _: [:0]const u8, _: [:0]const u8, flags: i32, _: *?[:0]u8) i32 {
    const t = LogVtab.of(p);
    t.print("{s}.{s}.xIntegrity(mFlags=0x{x})\n", .{ t.z_db, t.z_name, flags });
    return 0;
}

/// The vtablog module (vtablogModule).
pub const module: vtab.Module = .{
    .i_version = 4,
    .x_create = vtab.Module.constructor(logCreate),
    .x_connect = vtab.Module.constructor(logConnect),
    .x_best_index = logBestIndex,
    .x_disconnect = logDisconnect,
    .x_destroy = logDestroy,
    .x_open = logOpen,
    .x_close = logClose,
    .x_filter = logFilter,
    .x_next = logNext,
    .x_eof = logEof,
    .x_column = logColumn,
    .x_rowid = logRowid,
    .x_update = logUpdate,
    .x_begin = logBegin,
    .x_sync = logSync,
    .x_commit = logCommit,
    .x_rollback = logRollback,
    .x_find_function = logFindMethod,
    .x_rename = logRename,
    .x_savepoint = logSavepoint,
    .x_release = logRelease,
    .x_rollback_to = logRollbackTo,
    .x_shadow_name = vtab.Module.shadowName(logShadowName),
    .x_integrity = logIntegrity,
};

/// Port of sqlite3_vtablog_init(): register vtablog on `db`, printing
/// the calls to `out`.
pub fn init(db: *Sqlite3, out: Out) i32 {
    return vtab.createModule(db, "vtablog", &module, vtab.Module.auxFor(logCreate, out));
}
