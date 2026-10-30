//! OPENJSON as engine table-valued functions (eponymous virtual tables,
//! visible in every dialect: Hooks.table_function, registered when a
//! statement names one):
//!
//!   xq_tsql_openjson(json [, path])
//!       OPENJSON without WITH: the members of the object or array at
//!       path, as `key` (BIN2: COLLATE BINARY), `value` (a scalar's text,
//!       a container as written) and `type` (0 null, 1 string, 2 number,
//!       3 true/false, 4 array, 5 object).
//!   "xq_tsql_openjson_<hash>:<spec>"(json [, path])
//!       OPENJSON ... WITH (col type ['path'] [AS JSON], ...): a row per
//!       element of the array at path (one for an object), a column per
//!       column of the spec, its value converted to the column's type as
//!       CAST does (runtime.convert()). The spec, in the name so that a
//!       view keeps it, is the JSON array
//!       [[name, type, path|null, as_json], ...]; <hash> tells apart
//!       specs that differ in case only (module names do not).
//!
//! The json and path arguments are the hidden columns xq_json and
//! xq_path. SQL Server reads the document an element at a time, so does
//! the cursor: a syntax error is found when the row that has it is.
//! A path to a scalar is an empty set in lax mode, an error in strict.
//! In the FROM clause the parser makes OPENJSON(...) one of these calls,
//! and CROSS APPLY / OUTER APPLY of it a join (SQLite lets the arguments
//! of a table-valued function use the tables before it).

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const vtab = @import("../../sql/vtab.zig");
const api = @import("../../vdbe/api.zig");
const memm = @import("../../vdbe/mem.zig");
const ctype = @import("xqlite_base").ctype;
const json = @import("json.zig");
const jf = @import("json_func.zig");
const types = @import("types.zig");
const rt = @import("runtime.zig");

const Sqlite3 = int.Sqlite3;
const Mem = vi.Mem;
const RC = int.RC;

pub const default_name = "xq_tsql_openjson";
const with_prefix = "xq_tsql_openjson_";

/// A column of WITH.
const Col = struct {
    name: []const u8,
    type: types.Type,
    /// The path's steps (lax, strict); null for `$.name`.
    path: ?json.Path,
    as_json: bool,
};

/// The module's spec (its aux data, none for the default schema).
const Spec = struct {
    arena: std.heap.ArenaAllocator,
    cols: []Col,
};

/// The module name of OPENJSON ... WITH: the spec, and a hash of it.
pub fn withName(a: std.mem.Allocator, spec: []const u8) error{OutOfMemory}![]const u8 {
    const h = std.hash.Wyhash.hash(0, spec);
    return std.fmt.allocPrint(a, "{s}{x:0>16}:{s}", .{ with_prefix, h, spec });
}

/// Hooks.table_function: the OPENJSON module called `name`, registered
/// on `db`.
pub fn register(db: *Sqlite3, name: []const u8) ?*int.Module {
    if (ctype.eqlNoCase(name, default_name)) {
        return vtab.createModuleInternal(db, default_name, &module, null, null);
    }
    if (name.len <= with_prefix.len or !ctype.eqlNoCase(name[0..with_prefix.len], with_prefix)) return null;
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
    const h = std.fmt.parseInt(u64, name[with_prefix.len..colon], 16) catch return null;
    const text = name[colon + 1 ..];
    if (std.hash.Wyhash.hash(0, text) != h) return null;
    const spec = db.gpa.create(Spec) catch {
        db.oomFault();
        return null;
    };
    spec.* = .{ .arena = .init(db.gpa), .cols = &.{} };
    spec.cols = readSpec(spec.arena.allocator(), text) catch {
        destroySpec(spec);
        return null;
    };
    return vtab.createModuleInternal(db, name, &module, spec, &destroySpecOpaque);
}

fn destroySpec(spec: *Spec) void {
    const gpa = spec.arena.child_allocator;
    spec.arena.deinit();
    gpa.destroy(spec);
}

fn destroySpecOpaque(p: ?*anyopaque) void {
    destroySpec(@ptrCast(@alignCast(p.?)));
}

fn readSpec(a: std.mem.Allocator, text: []const u8) error{ OutOfMemory, Bad }![]Col {
    var err: json.SyntaxError = .{};
    const doc = json.parse(text, &err) catch return error.Bad;
    var cols: std.ArrayList(Col) = .empty;
    var m: json.Members = .open(text, doc.start);
    while (m.next(0, &err) catch return error.Bad) |e| {
        var f: [4]json.Item = undefined;
        var n: usize = 0;
        var fm: json.Members = .open(text, e.value.start);
        while (fm.next(0, &err) catch return error.Bad) |x| : (n += 1) {
            if (n < 4) f[n] = x.value;
        }
        if (n != 4 or f[0].kind != .string or f[1].kind != .string) return error.Bad;
        const ty = types.parseText(try json.decodeString(a, f[1].text(text))) orelse return error.Bad;
        var path: ?json.Path = null;
        if (f[2].kind == .string) {
            var perr: json.PathError = .{};
            path = json.parsePath(a, try json.decodeString(a, f[2].text(text)), false, &perr) catch return error.Bad;
        }
        try cols.append(a, .{
            .name = try json.decodeString(a, f[0].text(text)),
            .type = ty,
            .path = path,
            .as_json = std.mem.eql(u8, f[3].text(text), "1"),
        });
    }
    return cols.items;
}

// ================================================================= vtab

const Table = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
    /// Null for the default schema.
    spec: ?*const Spec,
    /// The column number of xq_json (xq_path is the next).
    json_col: i32,
};

const Cursor = struct {
    base: vtab.VtabCursor = .{},
    gpa: std.mem.Allocator,
    /// The document (a copy) and the path text.
    doc: []u8 = &.{},
    path_text: []u8 = &.{},
    path: json.Path = .{},
    path_arena: std.heap.ArenaAllocator,
    members: ?json.Members = null,
    /// A single row (WITH over an object).
    single: ?json.Item = null,
    single_done: bool = false,
    cur: ?json.Members.Entry = null,
    eof: bool = true,
    rowid: i64 = 0,

    fn of(c: *vtab.VtabCursor) *Cursor {
        return @alignCast(@fieldParentPtr("base", c));
    }

    fn reset(c: *Cursor) void {
        c.gpa.free(c.doc);
        c.gpa.free(c.path_text);
        c.doc = &.{};
        c.path_text = &.{};
        _ = c.path_arena.reset(.retain_capacity);
        c.path = .{};
        c.members = null;
        c.single = null;
        c.single_done = false;
        c.cur = null;
        c.eof = true;
        c.rowid = 0;
    }
};

fn appendQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) error{OutOfMemory}!void {
    try out.append(a, '"');
    for (name) |c| {
        if (c == '"') try out.append(a, '"');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

fn connect(db: *Sqlite3, aux: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const spec: ?*const Spec = @ptrCast(@alignCast(aux));
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(db.gpa);
    const a = db.gpa;
    var n: i32 = 0;
    (blk: {
        sql.appendSlice(a, "CREATE TABLE x(") catch |e| break :blk e;
        if (spec) |sp| {
            for (sp.cols) |c| {
                appendQuoted(a, &sql, c.name) catch |e| break :blk e;
                sql.print(a, " {s}, ", .{if (c.as_json) "TEXT" else c.type.storage()}) catch |e| break :blk e;
                n += 1;
            }
        } else {
            sql.appendSlice(a, "\"key\" TEXT COLLATE BINARY, \"value\" TEXT, \"type\" INTEGER, ") catch |e| break :blk e;
            n = 3;
        }
        sql.appendSlice(a, "xq_json HIDDEN, xq_path HIDDEN)") catch |e| break :blk e;
        sql.append(a, 0) catch |e| break :blk e;
    }) catch return RC.NOMEM;
    const rc = vtab.declareVtab(db, sql.items[0 .. sql.items.len - 1 :0]);
    if (rc != RC.OK) return rc;
    const t = db.gpa.create(Table) catch return RC.NOMEM;
    t.* = .{ .db = db, .spec = spec, .json_col = n };
    pp_vtab.* = &t.base;
    _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
    return RC.OK;
}

fn disconnect(p: *vtab.Vtab) i32 {
    const t: *Table = @alignCast(@fieldParentPtr("base", p));
    t.db.gpa.destroy(t);
    return RC.OK;
}

/// The json argument (xq_json =) is required, the path optional; as
/// json_each().
fn bestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    const t: *Table = @alignCast(@fieldParentPtr("base", p));
    var idx = [2]i32{ -1, -1 };
    var unusable: u32 = 0;
    var usable: u32 = 0;
    for (info.constraints, 0..) |cons, i| {
        if (cons.i_column < t.json_col) continue;
        const col: u5 = @intCast(cons.i_column - t.json_col);
        const bit = @as(u32, 1) << col;
        if (!cons.usable) {
            unusable |= bit;
        } else if (cons.op == vtab.INDEX_CONSTRAINT.EQ) {
            idx[col] = @intCast(i);
            usable |= bit;
        }
    }
    if (info.order_by.len > 0 and info.order_by[0].i_column < 0 and !info.order_by[0].desc) info.order_by_consumed = true;
    if (unusable & ~usable != 0) return RC.CONSTRAINT;
    if (idx[0] < 0) {
        info.idx_num = 0;
        info.estimated_cost = 1e99;
        return RC.OK;
    }
    info.estimated_cost = 1.0;
    info.usage[@intCast(idx[0])].argv_index = 1;
    info.usage[@intCast(idx[0])].omit = true;
    info.idx_num = 1;
    if (idx[1] >= 0) {
        info.usage[@intCast(idx[1])].argv_index = 2;
        info.usage[@intCast(idx[1])].omit = true;
        info.idx_num = 3;
    }
    return RC.OK;
}

fn open(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t: *Table = @alignCast(@fieldParentPtr("base", p));
    const c = t.db.gpa.create(Cursor) catch return RC.NOMEM;
    c.* = .{ .gpa = t.db.gpa, .path_arena = .init(t.db.gpa) };
    pp_cursor.* = &c.base;
    return RC.OK;
}

fn close(cur: *vtab.VtabCursor) i32 {
    const c = Cursor.of(cur);
    c.reset();
    c.path_arena.deinit();
    c.gpa.destroy(c);
    return RC.OK;
}

fn tableOf(cur: *vtab.VtabCursor) *Table {
    return @alignCast(@fieldParentPtr("base", cur.vtab));
}

fn setError(cur: *vtab.VtabCursor, msg: []const u8) i32 {
    const t = tableOf(cur);
    vtab.setErrMsg(t.db, cur.vtab, "{s}", .{msg});
    return RC.ERROR;
}

fn syntaxError(cur: *vtab.VtabCursor, z: []const u8, pos: usize) i32 {
    var buf: [200]u8 = undefined;
    return setError(cur, json.textMessage(&buf, z, pos));
}

fn filter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c = Cursor.of(cur);
    const t = tableOf(cur);
    c.reset();
    if (idx_num == 0 or argv.len == 0) return RC.OK;
    if (api.valueType(argv[0]) == vi.SQLITE_NULL) return RC.OK;
    const z: []const u8 = if (api.valueType(argv[0]) == vi.SQLITE_BLOB) api.valueBlob(argv[0]) orelse "" else api.valueText(argv[0]) orelse return RC.NOMEM;
    c.doc = c.gpa.dupe(u8, z) catch return RC.NOMEM;
    if (argv.len > 1) {
        if (api.valueType(argv[1]) == vi.SQLITE_NULL) return setError(cur, "Argument data type NULL is invalid for argument 2 of OPENJSON function.");
        const pz = api.valueText(argv[1]) orelse return RC.NOMEM;
        c.path_text = c.gpa.dupe(u8, pz) catch return RC.NOMEM;
        var perr: json.PathError = .{};
        c.path = json.parsePath(c.path_arena.allocator(), c.path_text, false, &perr) catch |err| switch (err) {
            error.OutOfMemory => return RC.NOMEM,
            error.BadPath => {
                var buf: [200]u8 = undefined;
                return setError(cur, json.pathMessage(&buf, c.path_text, perr.pos));
            },
        };
    }
    const doc = c.doc;
    var err: json.SyntaxError = .{};
    const start = json.locate(doc, c.path.steps, &err) catch return syntaxError(cur, doc, err.pos);
    const at = start orelse {
        if (c.path.strict) return setError(cur, jf.not_found);
        return RC.OK;
    };
    if (doc[at] != '{' and doc[at] != '[') {
        if (c.path.strict) return setError(cur, "Value referenced by JSON path is not an array or object and cannot be opened with OPENJSON.");
        // A bad scalar is still an error.
        _ = json.scan(doc, at, 0, &err) catch return syntaxError(cur, doc, err.pos);
        return RC.OK;
    }
    if (t.spec != null and doc[at] == '{') {
        // WITH over an object: the object is the row.
        c.single = json.scan(doc, at, 0, &err) catch return syntaxError(cur, doc, err.pos);
    } else c.members = .open(doc, at);
    c.eof = false;
    return next(cur);
}

fn next(cur: *vtab.VtabCursor) i32 {
    const c = Cursor.of(cur);
    if (c.single) |it| {
        if (c.single_done) {
            c.eof = true;
        } else {
            c.single_done = true;
            c.cur = .{ .index = 0, .value = it, .start = it.start };
            c.rowid = 0;
        }
        return RC.OK;
    }
    var m = &(c.members orelse {
        c.eof = true;
        return RC.OK;
    });
    var err: json.SyntaxError = .{};
    const e = m.next(1, &err) catch return syntaxError(cur, c.doc, err.pos);
    if (e) |x| {
        c.cur = x;
        c.rowid = @intCast(x.index);
    } else c.eof = true;
    return RC.OK;
}

fn eof(cur: *vtab.VtabCursor) bool {
    return Cursor.of(cur).eof;
}

fn rowid(cur: *vtab.VtabCursor, r: *i64) i32 {
    r.* = Cursor.of(cur).rowid;
    return RC.OK;
}

fn column(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = Cursor.of(cur);
    const t = tableOf(cur);
    if (i == t.json_col) {
        api.resultText(ctx, c.doc, .transient);
        return RC.OK;
    }
    if (i == t.json_col + 1) {
        if (c.path_text.len == 0) api.resultText(ctx, "$", .static) else api.resultText(ctx, c.path_text, .transient);
        return RC.OK;
    }
    const e = c.cur orelse {
        api.resultNull(ctx);
        return RC.OK;
    };
    const z = c.doc;
    var ar: std.heap.ArenaAllocator = .init(c.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const cols = (t.spec orelse {
        switch (i) {
            0 => if (e.key) |k| {
                const s = json.decodeString(a, k.text(z)) catch return RC.NOMEM;
                api.resultText(ctx, s, .transient);
            } else {
                var buf: [24]u8 = undefined;
                api.resultText(ctx, std.fmt.bufPrint(&buf, "{d}", .{e.index}) catch "", .transient);
            },
            1 => if (e.value.isContainer()) {
                api.resultText(ctx, e.value.text(z), .transient);
            } else if (json.scalarText(a, z, e.value) catch return RC.NOMEM) |s| {
                api.resultText(ctx, s, .transient);
            } else api.resultNull(ctx),
            else => api.resultInt64(ctx, @backingInt(e.value.kind)),
        }
        return RC.OK;
    }).cols;
    const col = cols[@intCast(i)];
    const strict = if (col.path) |p| p.strict else false;
    const found: ?json.Item = if (col.path) |p| json.lookup(z, e.value, p.steps) else json.lookup(z, e.value, &.{.{ .key = col.name }});
    const v = found orelse {
        if (strict) {
            api.resultError(ctx, jf.not_found);
        } else api.resultNull(ctx);
        return RC.OK;
    };
    if (col.as_json or v.isContainer()) {
        if (!col.as_json or !v.isContainer()) {
            if (strict) api.resultError(ctx, jf.no_container) else api.resultNull(ctx);
            return RC.OK;
        }
        api.resultText(ctx, v.text(z), .transient);
        return RC.OK;
    }
    const s = (json.scalarText(a, z, v) catch return RC.NOMEM) orelse {
        api.resultNull(ctx);
        return RC.OK;
    };
    var m: Mem = .init(t.db, .{ .Null = true });
    defer memm.release(&m);
    memm.setStr(&m, s, vi.ENC.UTF8, .static) catch return RC.NOMEM;
    rt.convert(ctx, &m, col.type, .cast);
    if (ctx.is_error != 0) {
        // The value is an nvarchar in SQL Server's message.
        const msg = api.valueText(ctx.out) orelse return RC.OK;
        const from = "converting the varchar value";
        if (std.mem.indexOf(u8, msg, from)) |at| {
            const fixed = std.mem.concat(a, u8, &.{ msg[0..at], "converting the nvarchar value", msg[at + from.len ..] }) catch return RC.NOMEM;
            api.resultError(ctx, fixed);
        }
    }
    return RC.OK;
}

const module: vtab.Module = .{
    .i_version = 0,
    .x_connect = connect,
    .x_best_index = bestIndex,
    .x_disconnect = disconnect,
    .x_open = open,
    .x_close = close,
    .x_filter = filter,
    .x_next = next,
    .x_eof = eof,
    .x_column = column,
    .x_rowid = rowid,
};
