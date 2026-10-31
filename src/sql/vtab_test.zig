//! End-to-end tests of virtual tables, in the style of sql_test.zig, with
//! a module written here: "kvtab", a writable in-memory table that keeps
//! a log of the calls the core makes, and "kvepo", an eponymous
//! read-only table.

const std = @import("std");
const testing = std.testing;
const int = @import("sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const api = @import("../vdbe/api.zig");
const vtab = @import("vtab.zig");
const main_mod = @import("main.zig");

const Conn = @import("sql_test.zig").Conn;
const Mem = vi.Mem;
const RC = int.RC;
const IC = vtab.INDEX_CONSTRAINT;
const gpa = testing.allocator;
/// sqlite3_mprintf(): strings handed to the core, which frees them.
const sqlite3_malloc = @import("malloc.zig").allocator;

// ============================================================ the module

/// A column value of a stored row.
const Val = union(enum) {
    null,
    int: i64,
    real: f64,
    text: []u8,

    fn from(m: *Mem) !Val {
        return switch (api.valueType(m)) {
            vi.SQLITE_INTEGER => .{ .int = api.valueInt64(m) },
            vi.SQLITE_FLOAT => .{ .real = api.valueDouble(m) },
            vi.SQLITE_NULL => .null,
            else => .{ .text = try gpa.dupe(u8, api.valueText(m) orelse "") },
        };
    }

    fn dupe(v: Val) !Val {
        return switch (v) {
            .text => |t| .{ .text = try gpa.dupe(u8, t) },
            else => v,
        };
    }

    fn free(v: Val) void {
        if (v == .text) gpa.free(v.text);
    }
};

const Row = struct { rowid: i64, cols: []Val };

/// The content of one kvtab table. It outlives the connections (it is a
/// "file"), so that a table survives closing and reopening the database.
const Data = struct {
    rows: std.ArrayList(Row) = .empty,

    fn deinit(d: *Data) void {
        for (d.rows.items) |r| freeRow(r);
        d.rows.deinit(gpa);
    }

    fn clone(d: *const Data) !Data {
        var n: Data = .{};
        for (d.rows.items) |r| {
            const cols = try gpa.alloc(Val, r.cols.len);
            for (cols, r.cols) |*c, o| c.* = try o.dupe();
            try n.rows.append(gpa, .{ .rowid = r.rowid, .cols = cols });
        }
        return n;
    }

    fn find(d: *Data, rowid: i64) ?usize {
        for (d.rows.items, 0..) |r, i| {
            if (r.rowid == rowid) return i;
        }
        return null;
    }
};

fn freeRow(r: Row) void {
    for (r.cols) |c| c.free();
    gpa.free(r.cols);
}

/// What the module shares between connections (its pAux): the tables by
/// name, and the log of calls.
const Store = struct {
    tables: std.StringHashMapUnmanaged(*Data) = .empty,
    log: std.ArrayList(u8) = .empty,

    fn deinit(s: *Store) void {
        var it = s.tables.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
            gpa.destroy(e.value_ptr.*);
        }
        s.tables.deinit(gpa);
        s.log.deinit(gpa);
    }

    fn note(s: *Store, comptime fmt: []const u8, args: anytype) void {
        s.log.print(gpa, fmt ++ "\n", args) catch {};
    }

    /// The log so far, emptied.
    fn take(s: *Store) ![]u8 {
        return s.log.toOwnedSlice(gpa);
    }
};

const KvVtab = struct {
    base: vtab.Vtab = .{},
    db: *int.Sqlite3,
    store: *Store,
    name: []u8,
    n_col: usize,
    /// Snapshots for xBegin and each xSavepoint level.
    tx: ?Data = null,
    savepoints: std.ArrayList(struct { level: i32, data: Data }) = .empty,

    fn of(p: *vtab.Vtab) *KvVtab {
        return @fieldParentPtr("base", p);
    }

    fn data(t: *KvVtab) *Data {
        return t.store.tables.get(t.name).?;
    }
};

const KvCursor = struct {
    base: vtab.VtabCursor = .{},
    /// The rowids the scan visits.
    rowids: std.ArrayList(i64) = .empty,
    i: usize = 0,

    fn of(cur: *vtab.VtabCursor) *KvCursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }
};

/// argv[3] is the column list ("a,b,c" by default).
fn kvConstruct(db: *int.Sqlite3, store: *Store, argv: []const [:0]const u8, pp: *?*vtab.Vtab, err: *?[:0]u8, create: bool) i32 {
    var cols: []const u8 = if (argv.len > 3) argv[3] else "a,b,c";
    if (cols.len >= 2 and cols[0] == '\'' and cols[cols.len - 1] == '\'') cols = cols[1 .. cols.len - 1];
    store.note("{s}({s}.{s})", .{ if (create) "xCreate" else "xConnect", argv[1], argv[2] });
    if (std.mem.eql(u8, cols, "fail")) {
        err.* = sqlite3_malloc.dupeSentinel(u8, "kvtab refused", 0) catch null;
        return RC.ERROR;
    }
    const sql = std.fmt.allocPrintSentinel(gpa, "CREATE TABLE x({s})", .{cols}, 0) catch return RC.NOMEM;
    defer gpa.free(sql);
    const rc = vtab.declareVtab(db, sql);
    if (rc != RC.OK) {
        err.* = sqlite3_malloc.dupeSentinel(u8, main_mod.errmsg(db), 0) catch null;
        return rc;
    }
    if (create) {
        const name = gpa.dupe(u8, argv[2]) catch return RC.NOMEM;
        const d = gpa.create(Data) catch return RC.NOMEM;
        d.* = .{};
        store.tables.put(gpa, name, d) catch return RC.NOMEM;
    } else if (store.tables.get(argv[2]) == null) {
        err.* = sqlite3_malloc.dupeSentinel(u8, "kvtab: no data", 0) catch null;
        return RC.ERROR;
    }
    const t = gpa.create(KvVtab) catch return RC.NOMEM;
    t.* = .{ .db = db, .store = store, .name = gpa.dupe(u8, argv[2]) catch return RC.NOMEM, .n_col = std.mem.count(u8, cols, ",") + 1 };
    _ = vtab.config(db, vtab.VTAB_CONSTRAINT_SUPPORT, 1);
    pp.* = &t.base;
    return RC.OK;
}

fn kvCreate(db: *int.Sqlite3, store: *Store, argv: []const [:0]const u8, pp: *?*vtab.Vtab, err: *?[:0]u8) i32 {
    return kvConstruct(db, store, argv, pp, err, true);
}

fn kvConnect(db: *int.Sqlite3, store: *Store, argv: []const [:0]const u8, pp: *?*vtab.Vtab, err: *?[:0]u8) i32 {
    return kvConstruct(db, store, argv, pp, err, false);
}

fn freeKv(t: *KvVtab) void {
    if (t.tx) |*d| d.deinit();
    for (t.savepoints.items) |*s| s.data.deinit();
    t.savepoints.deinit(gpa);
    gpa.free(t.name);
    gpa.destroy(t);
}

fn kvDisconnect(p: *vtab.Vtab) i32 {
    const t = KvVtab.of(p);
    t.store.note("xDisconnect({s})", .{t.name});
    freeKv(t);
    return RC.OK;
}

fn kvDestroy(p: *vtab.Vtab) i32 {
    const t = KvVtab.of(p);
    t.store.note("xDestroy({s})", .{t.name});
    if (t.store.tables.fetchRemove(t.name)) |kv| {
        gpa.free(kv.key);
        kv.value.deinit();
        gpa.destroy(kv.value);
    }
    freeKv(t);
    return RC.OK;
}

/// Plans (idx_num): 0 full scan; 1 rowid=?; 2 rowid IN (...) handled all
/// at once by xFilter; 3 column 0 = ?. ORDER BY rowid is consumed, and a
/// LIMIT is taken (0x100) with a full scan.
fn kvBestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    const t = KvVtab.of(p);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    line.print(gpa, "xBestIndex(", .{}) catch {};
    for (info.constraints, 0..) |c, i| {
        var rhs: ?*Mem = null;
        const known = vtab.rhsValue(info, @intCast(i), &rhs) == RC.OK;
        line.print(gpa, "{s}{d}:{d}{s}{s}", .{
            if (i > 0) " " else "",
            c.i_column,
            c.op,
            if (c.usable) "" else "!",
            if (vtab.in(info, @intCast(i), -1)) "in" else "",
        }) catch {};
        if (known) line.print(gpa, "={s}", .{api.valueText(rhs.?) orelse "NULL"}) catch {};
        const coll = vtab.collation(info, @intCast(i)).?;
        if (!std.mem.eql(u8, coll, "BINARY")) line.print(gpa, "/{s}", .{coll}) catch {};
    }
    line.print(gpa, ")", .{}) catch {};
    for (info.order_by) |ob| line.print(gpa, " ob{d}{s}", .{ ob.i_column, if (ob.desc) "d" else "" }) catch {};
    t.store.note("{s}", .{line.items});

    info.estimated_cost = 1000;
    info.estimated_rows = 1000;
    var plan: i32 = 0;
    for (info.constraints, 0..) |c, i| {
        if (!c.usable) continue;
        if (c.i_column == -1 and c.op == IC.EQ) {
            if (vtab.in(info, @intCast(i), 1)) {
                plan = 2;
                info.estimated_cost = 10;
            } else {
                plan = 1;
                info.estimated_cost = 1;
                info.estimated_rows = 1;
                info.idx_flags |= vtab.INDEX_SCAN_UNIQUE;
            }
            info.usage[i] = .{ .argv_index = 1, .omit = true };
            break;
        }
        if (c.i_column == 0 and c.op == IC.EQ and plan == 0) {
            plan = 3;
            info.estimated_cost = 50;
            info.usage[i] = .{ .argv_index = 1 };
        }
    }
    if (plan == 0) {
        for (info.constraints, 0..) |c, i| {
            if (c.usable and c.op == IC.LIMIT) {
                plan = 0x100;
                info.usage[i] = .{ .argv_index = 1, .omit = true };
            }
        }
    }
    if (info.order_by.len == 1 and info.order_by[0].i_column == -1 and !info.order_by[0].desc) {
        info.order_by_consumed = true;
    }
    info.idx_num = plan;
    info.idx_str = std.fmt.allocPrintSentinel(sqlite3_malloc, "plan{d}", .{plan}, 0) catch null;
    info.need_to_free_idx_str = true;
    return RC.OK;
}

fn kvOpen(p: *vtab.Vtab, pp: *?*vtab.VtabCursor) i32 {
    _ = p;
    const c = gpa.create(KvCursor) catch return RC.NOMEM;
    c.* = .{};
    pp.* = &c.base;
    return RC.OK;
}

fn kvClose(cur: *vtab.VtabCursor) i32 {
    const c = KvCursor.of(cur);
    c.rowids.deinit(gpa);
    gpa.destroy(c);
    return RC.OK;
}

fn lessRowid(_: void, a: i64, b: i64) bool {
    return a < b;
}

fn kvFilter(cur: *vtab.VtabCursor, idx_num: i32, idx_str: ?[:0]const u8, argv: []*Mem) i32 {
    const c = KvCursor.of(cur);
    const t = KvVtab.of(cur.vtab);
    const d = t.data();
    c.rowids.clearRetainingCapacity();
    c.i = 0;
    t.store.note("xFilter({d},{s},{d})", .{ idx_num, idx_str orelse "", argv.len });
    switch (idx_num) {
        1 => {
            const r = api.valueInt64(argv[0]);
            if (d.find(r) != null) c.rowids.append(gpa, r) catch return RC.NOMEM;
        },
        2 => {
            var v: ?*Mem = null;
            var rc = vtab.inFirst(argv[0], &v);
            while (rc == RC.OK) : (rc = vtab.inNext(argv[0], &v)) {
                const r = api.valueInt64(v.?);
                t.store.note("  in {d}", .{r});
                if (d.find(r) != null) c.rowids.append(gpa, r) catch return RC.NOMEM;
            }
            if (rc != RC.DONE) return rc;
        },
        3 => {
            const key = api.valueText(argv[0]) orelse "";
            for (d.rows.items) |r| {
                const match = switch (r.cols[0]) {
                    .text => |s| std.mem.eql(u8, s, key),
                    .int => |n| blk: {
                        var buf: [32]u8 = undefined;
                        break :blk std.mem.eql(u8, std.fmt.bufPrint(&buf, "{d}", .{n}) catch "", key);
                    },
                    else => false,
                };
                if (match) c.rowids.append(gpa, r.rowid) catch return RC.NOMEM;
            }
        },
        else => {
            for (d.rows.items) |r| c.rowids.append(gpa, r.rowid) catch return RC.NOMEM;
            std.mem.sort(i64, c.rowids.items, {}, lessRowid);
            if (idx_num == 0x100) {
                const lim: usize = @intCast(@max(0, api.valueInt64(argv[0])));
                if (c.rowids.items.len > lim) c.rowids.shrinkRetainingCapacity(lim);
            }
        },
    }
    std.mem.sort(i64, c.rowids.items, {}, lessRowid);
    return RC.OK;
}

fn kvNext(cur: *vtab.VtabCursor) i32 {
    KvCursor.of(cur).i += 1;
    return RC.OK;
}

fn kvEof(cur: *vtab.VtabCursor) bool {
    const c = KvCursor.of(cur);
    return c.i >= c.rowids.items.len;
}

fn kvColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = KvCursor.of(cur);
    const t = KvVtab.of(cur.vtab);
    const d = t.data();
    const row = d.rows.items[d.find(c.rowids.items[c.i]).?];
    if (vtab.nochange(ctx)) {
        t.store.note("  nochange {d}", .{i});
        return RC.OK;
    }
    switch (row.cols[@intCast(i)]) {
        .null => api.resultNull(ctx),
        .int => |n| api.resultInt64(ctx, n),
        .real => |r| api.resultDouble(ctx, r),
        .text => |s| api.resultText(ctx, s, .transient),
    }
    return RC.OK;
}

fn kvRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    const c = KvCursor.of(cur);
    rowid.* = c.rowids.items[c.i];
    return RC.OK;
}

/// argv[0]: the rowid to delete or replace (NULL: insert); argv[1]: the
/// new rowid (NULL: choose one); then the columns. Column values "bad"
/// fail with SQLITE_CONSTRAINT.
fn kvUpdate(p: *vtab.Vtab, argv: []*Mem, rowid_out: *i64) i32 {
    const t = KvVtab.of(p);
    const d = t.data();
    const old_null = api.valueType(argv[0]) == vi.SQLITE_NULL;
    t.store.note("xUpdate(argc={d},onconflict={d})", .{ argv.len, if (argv.len > 1) vtab.onConflict(t.db) else 0 });
    if (argv.len == 1) {
        const r = api.valueInt64(argv[0]);
        if (d.find(r)) |i| freeRow(d.rows.orderedRemove(i));
        return RC.OK;
    }
    for (argv[2..]) |a| {
        if (api.valueType(a) == vi.SQLITE_TEXT and std.mem.eql(u8, api.valueText(a).?, "bad")) {
            vtab.setErrMsg(t.db, p, "kvtab: bad value", .{});
            return RC.CONSTRAINT;
        }
    }
    var new_rowid: i64 = undefined;
    if (api.valueType(argv[1]) == vi.SQLITE_NULL) {
        var mx: i64 = 0;
        for (d.rows.items) |r| mx = @max(mx, r.rowid);
        new_rowid = mx + 1;
    } else {
        new_rowid = api.valueInt64(argv[1]);
    }
    const cols = gpa.alloc(Val, t.n_col) catch return RC.NOMEM;
    for (cols, argv[2..], 0..) |*c, a, i| {
        // An unchanged column keeps its value.
        if (api.valueNochange(a) and !old_null) {
            const old = d.rows.items[d.find(api.valueInt64(argv[0])).?];
            c.* = old.cols[i].dupe() catch return RC.NOMEM;
        } else {
            c.* = Val.from(a) catch return RC.NOMEM;
        }
    }
    if (!old_null) {
        const r = api.valueInt64(argv[0]);
        if (d.find(r)) |i| freeRow(d.rows.orderedRemove(i));
    }
    if (d.find(new_rowid)) |i| {
        if (vtab.onConflict(t.db) == vtab.SQLITE_REPLACE) {
            freeRow(d.rows.orderedRemove(i));
        } else {
            freeRow(.{ .rowid = new_rowid, .cols = cols });
            vtab.setErrMsg(t.db, p, "kvtab: rowid {d} exists", .{new_rowid});
            return RC.CONSTRAINT;
        }
    }
    d.rows.append(gpa, .{ .rowid = new_rowid, .cols = cols }) catch return RC.NOMEM;
    rowid_out.* = new_rowid;
    return RC.OK;
}

fn kvBegin(p: *vtab.Vtab) i32 {
    const t = KvVtab.of(p);
    t.store.note("xBegin({s})", .{t.name});
    t.tx = t.data().clone() catch return RC.NOMEM;
    return RC.OK;
}

fn kvSync(p: *vtab.Vtab) i32 {
    const t = KvVtab.of(p);
    t.store.note("xSync({s})", .{t.name});
    return RC.OK;
}

fn dropSavepoints(t: *KvVtab, from: usize) void {
    for (t.savepoints.items[from..]) |*s| s.data.deinit();
    t.savepoints.shrinkRetainingCapacity(from);
}

fn kvCommit(p: *vtab.Vtab) i32 {
    const t = KvVtab.of(p);
    t.store.note("xCommit({s})", .{t.name});
    if (t.tx) |*d| d.deinit();
    t.tx = null;
    dropSavepoints(t, 0);
    return RC.OK;
}

fn restore(t: *KvVtab, snap: *const Data) i32 {
    const d = t.data();
    d.deinit();
    d.* = snap.clone() catch return RC.NOMEM;
    return RC.OK;
}

fn kvRollback(p: *vtab.Vtab) i32 {
    const t = KvVtab.of(p);
    t.store.note("xRollback({s})", .{t.name});
    if (t.tx) |*snap| {
        _ = restore(t, snap);
        snap.deinit();
    }
    t.tx = null;
    dropSavepoints(t, 0);
    return RC.OK;
}

fn kvSavepoint(p: *vtab.Vtab, n: i32) i32 {
    const t = KvVtab.of(p);
    t.store.note("xSavepoint({s},{d})", .{ t.name, n });
    t.savepoints.append(gpa, .{ .level = n, .data = t.data().clone() catch return RC.NOMEM }) catch return RC.NOMEM;
    return RC.OK;
}

fn kvRelease(p: *vtab.Vtab, n: i32) i32 {
    const t = KvVtab.of(p);
    t.store.note("xRelease({s},{d})", .{ t.name, n });
    var i: usize = 0;
    while (i < t.savepoints.items.len and t.savepoints.items[i].level < n) i += 1;
    dropSavepoints(t, i);
    return RC.OK;
}

fn kvRollbackTo(p: *vtab.Vtab, n: i32) i32 {
    const t = KvVtab.of(p);
    t.store.note("xRollbackTo({s},{d})", .{ t.name, n });
    var i: usize = 0;
    while (i < t.savepoints.items.len and t.savepoints.items[i].level < n) i += 1;
    if (i < t.savepoints.items.len) {
        const rc = restore(t, &t.savepoints.items[i].data);
        dropSavepoints(t, i + 1);
        return rc;
    }
    return RC.OK;
}

fn kvRename(p: *vtab.Vtab, new_name: [:0]const u8) i32 {
    const t = KvVtab.of(p);
    t.store.note("xRename({s},{s})", .{ t.name, new_name });
    const kv = t.store.tables.fetchRemove(t.name).?;
    gpa.free(kv.key);
    const name = gpa.dupe(u8, new_name) catch return RC.NOMEM;
    t.store.tables.put(gpa, name, kv.value) catch return RC.NOMEM;
    gpa.free(t.name);
    t.name = gpa.dupe(u8, new_name) catch return RC.NOMEM;
    return RC.OK;
}

/// upper() of a kvtab column is "OVERLOADED:" and the value; kvmatch(col,x)
/// is offered to xBestIndex as a constraint (FUNCTION+1).
fn overloadedUpper(ctx: *vi.Context, argv: []*Mem) void {
    const z = api.valueText(argv[0]) orelse "";
    const s = std.fmt.allocPrint(gpa, "OVERLOADED:{s}", .{z}) catch return api.resultErrorNomem(ctx);
    defer gpa.free(s);
    api.resultText(ctx, s, .transient);
}

fn kvMatch(ctx: *vi.Context, argv: []*Mem) void {
    const a = api.valueText(argv[0]) orelse "";
    const b = api.valueText(argv[1]) orelse "";
    api.resultInt64(ctx, @intFromBool(std.mem.indexOf(u8, a, b) != null));
}

fn kvFindFunction(p: *vtab.Vtab, n_arg: i32, name: [:0]const u8, func: *?int.FuncDef.StepFn, arg: *?*anyopaque) i32 {
    _ = p;
    arg.* = null;
    if (n_arg == 1 and std.mem.eql(u8, name, "upper")) {
        func.* = overloadedUpper;
        return 1;
    }
    if (n_arg == 2 and std.ascii.eqlIgnoreCase(name, "kvmatch")) {
        func.* = kvMatch;
        return IC.FUNCTION + 1;
    }
    return 0;
}

fn kvShadowName(_: ?*anyopaque, name: []const u8) bool {
    return std.mem.eql(u8, name, "shadow");
}

const kv_module: vtab.Module = .{
    .i_version = 3,
    .x_create = vtab.Module.constructor(kvCreate),
    .x_connect = vtab.Module.constructor(kvConnect),
    .x_best_index = kvBestIndex,
    .x_disconnect = kvDisconnect,
    .x_destroy = kvDestroy,
    .x_open = kvOpen,
    .x_close = kvClose,
    .x_filter = kvFilter,
    .x_next = kvNext,
    .x_eof = kvEof,
    .x_column = kvColumn,
    .x_rowid = kvRowid,
    .x_update = kvUpdate,
    .x_begin = kvBegin,
    .x_sync = kvSync,
    .x_commit = kvCommit,
    .x_rollback = kvRollback,
    .x_find_function = kvFindFunction,
    .x_rename = kvRename,
    .x_savepoint = kvSavepoint,
    .x_release = kvRelease,
    .x_rollback_to = kvRollbackTo,
    .x_shadow_name = kvShadowName,
};

/// kvepo: the eponymous table of the numbers 1-3 and their squares,
/// with a hidden "lim" argument.
const EpoCursor = struct {
    base: vtab.VtabCursor = .{},
    n: i64 = 0,
    lim: i64 = 3,
};

fn epoConnect(db: *int.Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const rc = vtab.declareVtab(db, "CREATE TABLE x(n, sq, lim HIDDEN)");
    if (rc != RC.OK) return rc;
    const t = gpa.create(vtab.Vtab) catch return RC.NOMEM;
    t.* = .{};
    pp.* = t;
    return RC.OK;
}

fn epoDisconnect(p: *vtab.Vtab) i32 {
    gpa.destroy(p);
    return RC.OK;
}

fn epoBestIndex(_: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    for (info.constraints, 0..) |c, i| {
        if (c.i_column == 2 and c.op == IC.EQ) {
            if (!c.usable) return RC.CONSTRAINT;
            info.usage[i] = .{ .argv_index = 1, .omit = true };
            info.idx_num = 1;
        }
    }
    info.estimated_cost = 10;
    return RC.OK;
}

fn epoOpen(_: *vtab.Vtab, pp: *?*vtab.VtabCursor) i32 {
    const c = gpa.create(EpoCursor) catch return RC.NOMEM;
    c.* = .{};
    pp.* = &c.base;
    return RC.OK;
}

fn epoClose(cur: *vtab.VtabCursor) i32 {
    gpa.destroy(@as(*EpoCursor, @alignCast(@fieldParentPtr("base", cur))));
    return RC.OK;
}

fn epoFilter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c: *EpoCursor = @alignCast(@fieldParentPtr("base", cur));
    c.n = 1;
    c.lim = if (idx_num == 1) api.valueInt64(argv[0]) else 3;
    return RC.OK;
}

fn epoNext(cur: *vtab.VtabCursor) i32 {
    const c: *EpoCursor = @alignCast(@fieldParentPtr("base", cur));
    c.n += 1;
    return RC.OK;
}

fn epoEof(cur: *vtab.VtabCursor) bool {
    const c: *EpoCursor = @alignCast(@fieldParentPtr("base", cur));
    return c.n > c.lim;
}

fn epoColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c: *EpoCursor = @alignCast(@fieldParentPtr("base", cur));
    api.resultInt64(ctx, switch (i) {
        0 => c.n,
        1 => c.n * c.n,
        else => c.lim,
    });
    return RC.OK;
}

fn epoRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    const c: *EpoCursor = @alignCast(@fieldParentPtr("base", cur));
    rowid.* = c.n;
    return RC.OK;
}

const epo_module: vtab.Module = .{
    .x_connect = epoConnect,
    .x_best_index = epoBestIndex,
    .x_disconnect = epoDisconnect,
    .x_open = epoOpen,
    .x_close = epoClose,
    .x_filter = epoFilter,
    .x_next = epoNext,
    .x_eof = epoEof,
    .x_column = epoColumn,
    .x_rowid = epoRowid,
};

var destroyed_aux: usize = 0;

fn destroyAux(p: ?*anyopaque) void {
    _ = p;
    destroyed_aux += 1;
}

/// A connection with both modules registered on `store`.
fn openWith(c: *Conn, store: *Store) !void {
    try c.open();
    try register(c, store);
}

fn register(c: *Conn, store: *Store) !void {
    try testing.expectEqual(RC.OK, vtab.createModuleV2(c.db, "kvtab", &kv_module, vtab.Module.auxFor(kvCreate, store), destroyAux));
    try testing.expectEqual(RC.OK, vtab.createModule(c.db, "kvepo", &epo_module, null));
}

fn clearLog(store: *Store) void {
    store.log.clearRetainingCapacity();
}

fn expectLog(store: *Store, expected: []const u8) !void {
    const got = try store.take();
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

// ================================================================= tests

test "vtab: create, read and write" {
    var store: Store = .{};
    defer store.deinit();
    var c: Conn = undefined;
    try openWith(&c, &store);
    defer c.close();

    try c.exec("CREATE VIRTUAL TABLE kv USING kvtab('a,b,c')");
    // xCreate puts the table in the transaction without xBegin.
    try expectLog(&store, "xCreate(main.kv)\nxSync(kv)\nxCommit(kv)\n");
    try c.exec("INSERT INTO kv VALUES('x',1,2.5),('y',2,NULL); INSERT INTO kv(rowid,a) VALUES(10,'z')");
    try c.expectRows("SELECT rowid, * FROM kv", "1|x|1|2.5\n2|y|2|NULL\n10|z|NULL|NULL\n");
    try c.expectRows("SELECT last_insert_rowid(), changes()", "10|1\n");
    try c.exec("UPDATE kv SET b=b*10 WHERE a='x'");
    try c.exec("UPDATE kv SET rowid=rowid+100 WHERE rowid=2");
    try c.exec("DELETE FROM kv WHERE a='z'");
    try c.expectRows("SELECT rowid, * FROM kv", "1|x|10|2.5\n102|y|2|NULL\n");
    try c.expectRows("SELECT count(*), sum(b) FROM kv", "2|12\n");
    clearLog(&store);

    // Unchanged columns are not read (sqlite3_vtab_nochange()) in UPDATE.
    try c.exec("UPDATE kv SET c=1 WHERE rowid=1");
    try expectLog(&store,
        \\xBestIndex(-1:2=1)
        \\xBegin(kv)
        \\xFilter(1,plan1,1)
        \\  nochange 0
        \\  nochange 1
        \\xUpdate(argc=5,onconflict=4)
        \\xSync(kv)
        \\xCommit(kv)
        \\
    );
    try c.expectRows("SELECT * FROM kv WHERE rowid=1", "x|10|1\n");

    // Constraint violations, and the ON CONFLICT mode.
    try c.expectError("INSERT INTO kv(rowid,a) VALUES(1,'dup')", "kvtab: rowid 1 exists");
    try c.expectError("INSERT INTO kv VALUES('bad',0,0)", "kvtab: bad value");
    try c.exec("INSERT OR IGNORE INTO kv(rowid,a) VALUES(1,'dup')");
    try c.exec("INSERT OR REPLACE INTO kv(rowid,a) VALUES(1,'new')");
    try c.expectRows("SELECT rowid, a FROM kv", "1|new\n102|y\n");
    try c.expectError("CREATE INDEX ki ON kv(a)", "virtual tables may not be indexed");
    try c.expectError("CREATE TRIGGER kt AFTER INSERT ON kv BEGIN SELECT 1; END", "cannot create triggers on virtual tables");
    try c.expectError("ALTER TABLE kv ADD COLUMN d", "virtual tables may not be altered");
    try c.expectError("ALTER TABLE kv RENAME COLUMN a TO z", "cannot rename columns of virtual table \"kv\"");
    try c.expectError("INSERT INTO kv VALUES(1,2,3) ON CONFLICT DO NOTHING", "UPSERT not implemented for virtual table \"kv\"");
    try c.expectError("CREATE VIRTUAL TABLE kv2 USING kvtab(fail)", "kvtab refused");
    try c.expectError("CREATE VIRTUAL TABLE kv3 USING kvtab('a,a')", "duplicate column name: a");
    try c.expectError("CREATE VIRTUAL TABLE kv4 USING nosuch", "no such module: nosuch");
    try c.expectError("CREATE VIRTUAL TABLE kv USING kvtab", "table kv already exists");
    try c.exec("CREATE VIRTUAL TABLE IF NOT EXISTS kv USING kvtab");
    try c.expectRows("PRAGMA table_info(kv)", "0|a||0|NULL|0\n1|b||0|NULL|0\n2|c||0|NULL|0\n");
    try c.expectRows("SELECT type, name, rootpage, sql FROM sqlite_schema", "table|kv|0|CREATE VIRTUAL TABLE kv USING kvtab('a,b,c')\n");
}

test "vtab: xBestIndex constraints, ORDER BY, IN and LIMIT" {
    var store: Store = .{};
    defer store.deinit();
    var c: Conn = undefined;
    try openWith(&c, &store);
    defer c.close();
    try c.exec("CREATE VIRTUAL TABLE kv USING kvtab('a,b COLLATE NOCASE,c'); CREATE TABLE t(x)");
    try c.exec("INSERT INTO kv(rowid,a,b) VALUES(3,'p','q'),(1,'r','s'),(2,'p','u'); INSERT INTO t VALUES(1),(3)");
    clearLog(&store);

    // The operators of the constraints, with the values known while
    // planning and the collations.
    try c.expectRows("SELECT rowid FROM kv WHERE a='p' AND b>'a' AND c IS NULL", "2\n3\n");
    try expectLog(&store, "xBestIndex(0:2=p 1:4=a/NOCASE 2:71)\nxFilter(3,plan3,1)\n");
    try c.expectRows("SELECT rowid FROM kv WHERE a!='p' AND b IS NOT 'z' AND c IS NOT NULL AND a LIKE 'x' AND b GLOB 'y' AND a MATCH 'm'", "");
    try expectLog(&store, "xBestIndex(0:64=m 1:32=y 1:16=z 1:66=y 0:32=X/NOCASE 0:16=y/NOCASE 0:65=x 2:70 1:69=z 0:68=p)\nxFilter(0,plan0,0)\n");
    try c.expectRows("SELECT rowid FROM kv WHERE 5<b AND rowid<=? AND rowid>=10", "");
    try expectLog(&store, "xBestIndex(1:4=5/NOCASE -1:8 -1:32=10)\nxFilter(0,plan0,0)\n");

    // A rowid equality: one row, the constraint omitted.
    try c.expectRows("SELECT a FROM kv WHERE rowid=2", "p\n");
    try expectLog(&store, "xBestIndex(-1:2=2)\nxFilter(1,plan1,1)\n");
    try c.expectRows("EXPLAIN QUERY PLAN SELECT a FROM kv WHERE rowid=2", "2|0|0|SCAN kv VIRTUAL TABLE INDEX 1:plan1\n");
    clearLog(&store);

    // IN: all the values at once through sqlite3_vtab_in().
    try c.expectRows("SELECT rowid, a FROM kv WHERE rowid IN (3,1,7)", "1|r\n3|p\n");
    try expectLog(&store, "xBestIndex(-1:2in)\nxFilter(2,plan2,1)\n  in 1\n  in 3\n  in 7\n");

    // A join: the plans for each set of usable constraints.
    try c.expectRows("SELECT x, a FROM t, kv WHERE kv.rowid=t.x", "1|r\n3|p\n");
    try expectLog(&store, "xBestIndex(-1:2)\nxBestIndex(-1:2!)\nxFilter(1,plan1,1)\nxFilter(1,plan1,1)\n");

    // ORDER BY rowid is consumed; ORDER BY a is not.
    try c.expectRows("SELECT rowid FROM kv ORDER BY rowid", "1\n2\n3\n");
    try expectLog(&store, "xBestIndex() ob-1\nxFilter(0,plan0,0)\n");
    try c.expectRows("SELECT rowid FROM kv ORDER BY a, rowid", "2\n3\n1\n");
    try expectLog(&store, "xBestIndex() ob0 ob-1\nxFilter(0,plan0,0)\n");
    try c.expectRows("EXPLAIN QUERY PLAN SELECT rowid FROM kv ORDER BY rowid", "3|0|99|SCAN kv VIRTUAL TABLE INDEX 0:plan0\n");
    clearLog(&store);

    // LIMIT and OFFSET go to xBestIndex for a single-table query.
    try c.expectRows("SELECT rowid FROM kv LIMIT 2", "1\n2\n");
    try expectLog(&store, "xBestIndex(0:73=2)\nxFilter(256,plan256,1)\n");
    try c.expectRows("SELECT rowid FROM kv LIMIT 1 OFFSET 1", "2\n");
    // The LIMIT taken without the OFFSET: planned again without them.
    try expectLog(&store, "xBestIndex(0:74=1 0:73=1)\nxBestIndex(0:74!=1 0:73!=1)\nxFilter(0,plan0,0)\n");

    // A function a vtab overloads, and one it offers as a constraint.
    try c.expectRows("SELECT upper(a), upper('k') FROM kv WHERE rowid=1", "OVERLOADED:r|K\n");
    try c.exec("SELECT 1");
    clearLog(&store);
    try testing.expectEqual(RC.OK, @import("callback.zig").overloadFunction(c.db, "kvmatch", 2));
    try c.expectRows("SELECT rowid FROM kv WHERE kvmatch(b, 'q')", "3\n");
    try expectLog(&store, "xBestIndex(1:151=q)\nxFilter(0,plan0,0)\n");
    try c.expectError("SELECT kvmatch('a','b')", "unable to use function kvmatch in the requested context");
}

test "vtab: transactions and savepoints" {
    var store: Store = .{};
    defer store.deinit();
    var c: Conn = undefined;
    try openWith(&c, &store);
    defer c.close();
    try c.exec("CREATE VIRTUAL TABLE kv USING kvtab('a'); INSERT INTO kv VALUES(1)");
    clearLog(&store);

    try c.exec("BEGIN; INSERT INTO kv VALUES(2); ROLLBACK");
    try expectLog(&store, "xBegin(kv)\nxUpdate(argc=3,onconflict=4)\nxRollback(kv)\n");
    try c.expectRows("SELECT a FROM kv", "1\n");
    clearLog(&store);

    try c.exec("BEGIN; INSERT INTO kv VALUES(2); SAVEPOINT s1; INSERT INTO kv VALUES(3); ROLLBACK TO s1; INSERT INTO kv VALUES(4); RELEASE s1; COMMIT");
    try expectLog(&store,
        \\xBegin(kv)
        \\xUpdate(argc=3,onconflict=4)
        \\xSavepoint(kv,0)
        \\xUpdate(argc=3,onconflict=4)
        \\xRollbackTo(kv,0)
        \\xUpdate(argc=3,onconflict=4)
        \\xRelease(kv,0)
        \\xSync(kv)
        \\xCommit(kv)
        \\
    );
    try c.expectRows("SELECT a FROM kv", "1\n2\n4\n");

    // A transaction savepoint, with xBegin inside it.
    try c.exec("SAVEPOINT a; INSERT INTO kv VALUES(5); SAVEPOINT b; INSERT INTO kv VALUES(6); ROLLBACK TO b; RELEASE a");
    try c.expectRows("SELECT a FROM kv", "1\n2\n4\n5\n");

    // A failed statement inside a transaction undoes only itself (the
    // statement savepoint).
    clearLog(&store);
    try c.exec("BEGIN");
    try c.expectError("INSERT INTO kv SELECT 7 UNION ALL SELECT 'bad'", "kvtab: bad value");
    try c.exec("COMMIT");
    try expectLog(&store,
        \\xBegin(kv)
        \\xSavepoint(kv,0)
        \\xUpdate(argc=3,onconflict=4)
        \\xUpdate(argc=3,onconflict=4)
        \\xRollbackTo(kv,0)
        \\xRelease(kv,0)
        \\xSync(kv)
        \\xCommit(kv)
        \\
    );
    try c.expectRows("SELECT a FROM kv", "1\n2\n4\n5\n");
}

test "vtab: rename, drop and persistence" {
    var store: Store = .{};
    defer store.deinit();
    var c: Conn = undefined;
    try openWith(&c, &store);
    defer c.close();
    try c.exec("CREATE VIRTUAL TABLE kv USING kvtab('k, v'); INSERT INTO kv VALUES('a',1),('b',2); CREATE TABLE kv_shadow(x)");
    try c.exec("ALTER TABLE kv RENAME TO kv2");
    try c.expectRows("SELECT * FROM kv2", "a|1\nb|2\n");
    try c.expectRows("SELECT name, sql FROM sqlite_schema WHERE type='table' ORDER BY name", "kv2|CREATE VIRTUAL TABLE \"kv2\" USING kvtab('k, v')\nkv_shadow|CREATE TABLE kv_shadow(x)\n");
    try c.expectError("ALTER TABLE kv2 RENAME TO kv_shadow", "there is already another table or index with this name: kv_shadow");
    const log = try store.take();
    defer gpa.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "xRename(kv,kv2)\n") != null);

    // The table, its schema row and its data survive closing the database.
    try c.reopen();
    try register(&c, &store);
    try c.expectRows("SELECT * FROM kv2 ORDER BY k DESC", "b|2\na|1\n");
    try c.exec("INSERT INTO kv2 VALUES('c',3)");
    try c.reopen();
    try register(&c, &store);
    try c.expectRows("SELECT count(*) FROM kv2", "3\n");
    clearLog(&store);

    // A module that is not registered.
    try c.reopen();
    try c.expectError("SELECT * FROM kv2", "no such module: kvtab");
    try register(&c, &store);

    // DROP TABLE connects first; its OP_VBegin has no table, so no xBegin.
    try c.exec("DROP TABLE kv2");
    try expectLog(&store, "xDisconnect(kv2)\nxConnect(main.kv2)\nxDestroy(kv2)\n");
    try testing.expectEqual(@as(u32, 0), store.tables.count());
    try c.reopen();
    try register(&c, &store);
    try c.expectRows("SELECT name FROM sqlite_schema", "kv_shadow\n");
    try c.expectError("SELECT * FROM kv2", "no such table: kv2");

    // TEMP virtual tables.
    try c.exec("CREATE VIRTUAL TABLE temp.tv USING kvtab(x); INSERT INTO tv VALUES(9)");
    try c.expectRows("SELECT x FROM temp.tv", "9\n");
    try c.expectRows("SELECT name FROM sqlite_temp_schema", "tv\n");
    try c.exec("DROP TABLE tv");
    const before = destroyed_aux;
    try c.reopen();
    // The destructor of pAux ran when the connection closed.
    try testing.expectEqual(before + 1, destroyed_aux);
}

test "vtab: eponymous tables and table-valued functions" {
    var store: Store = .{};
    defer store.deinit();
    var c: Conn = undefined;
    try openWith(&c, &store);
    defer c.close();
    try c.expectRows("SELECT * FROM kvepo", "1|1\n2|4\n3|9\n");
    try c.expectRows("SELECT n, sq, lim FROM kvepo(2)", "1|1|2\n2|4|2\n");
    try c.expectRows("SELECT a.n, b.sq FROM kvepo(2) a, kvepo(a.n) b", "1|1\n2|1\n2|4\n");
    try c.expectRows("SELECT * FROM kvepo WHERE lim=1", "1|1\n");
    try c.expectRows("SELECT * FROM main.kvepo(1)", "1|1\n");
    try c.expectError("SELECT * FROM kvepo(1,2)", "too many arguments on kvepo() - max 1");
    try c.expectError("INSERT INTO kvepo VALUES(1,2)", "table kvepo may not be modified");
    try c.expectError("DROP TABLE kvepo", "table kvepo may not be dropped");
    try c.expectError("CREATE VIRTUAL TABLE e USING kvepo", "no such module: kvepo");
    try c.expectRows("PRAGMA table_xinfo(kvepo)", "0|n||0|NULL|0|0\n1|sq||0|NULL|0|0\n2|lim||0|NULL|0|1\n");
    try c.expectRows("SELECT count(*) FROM pragma_table_info('kvepo')", "2\n");
    try c.expectRows("SELECT name FROM pragma_module_list WHERE name LIKE 'kv%' ORDER BY 1", "kvepo\nkvtab\n");
    // Replacing a module drops its eponymous table.
    try testing.expectEqual(RC.OK, vtab.createModule(c.db, "kvepo", &epo_module, null));
    try c.expectRows("SELECT count(*) FROM kvepo", "3\n");
    try testing.expectEqual(RC.OK, vtab.dropModules(c.db, &.{"kvtab"}));
    try c.expectError("SELECT * FROM kvepo", "no such table: kvepo");
    try c.expectRows("SELECT name FROM pragma_module_list WHERE name LIKE 'kv%'", "kvtab\n");
}

test "vtab: built-in table-valued functions" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); CREATE INDEX tb ON t(b)");
    try c.expectRows("SELECT name, type, pk FROM pragma_table_info('t')", "a|INTEGER|1\nb|TEXT|0\n");
    try c.expectRows("SELECT s.name, i.name FROM sqlite_schema s, pragma_index_list(s.name) i", "t|tb\n");
    try c.expectRows("SELECT * FROM pragma_quick_check", "ok\n");
    try c.expectRows("SELECT addr, opcode FROM bytecode('SELECT 1') WHERE opcode='ResultRow'", "2|ResultRow\n");
    try c.expectRows("SELECT type, name, wr FROM tables_used('SELECT b FROM t WHERE b=1')", "index|tb|0\n");
    try c.expectError("SELECT * FROM bytecode(5)", "argument to bytecode() is not a valid SQL statement");
    try c.expectError("SELECT * FROM bytecode", "no query solution");

    // generate_series is the shell's: register it here.
    try testing.expectEqual(RC.OK, @import("../ext/series.zig").init(c.db));
    try c.expectRows("SELECT group_concat(value) FROM generate_series(1,10,3)", "1,4,7,10\n");
    try c.expectRows("SELECT value FROM generate_series(1,100) WHERE value BETWEEN 50 AND 52", "50\n51\n52\n");
    try c.expectRows("SELECT a FROM t, generate_series(1,2) WHERE a=value", "");
    try c.expectError("SELECT * FROM generate_series", "first argument to \"generate_series()\" missing or unusable");
}

test "vtab: declared schemas and the interface outside constructors" {
    var store: Store = .{};
    defer store.deinit();
    var c: Conn = undefined;
    try openWith(&c, &store);
    defer c.close();

    // HIDDEN columns, and the word "hidden" removed from the type.
    try c.exec("CREATE VIRTUAL TABLE kh USING kvtab('a INT HIDDEN, b, c hidden text')");
    try c.expectRows("PRAGMA table_xinfo(kh)", "0|a|INT|0|NULL|0|1\n1|b||0|NULL|0|0\n2|c|text|0|NULL|0|1\n");
    try c.exec("INSERT INTO kh(a,b,c) VALUES(1,2,3)");
    try c.expectRows("SELECT * FROM kh", "2\n");
    try c.expectRows("SELECT a, b, c FROM kh", "1|2|3\n");
    try c.expectError("INSERT INTO kh VALUES(1,2)", "table kh has 1 columns but 2 values were supplied");

    // A writable WITHOUT ROWID virtual table needs a one-column PRIMARY KEY:
    // sqlite3_declare_vtab() fails, leaving no message (the module reports
    // sqlite3_errmsg()).
    try c.expectError("CREATE VIRTUAL TABLE kw USING kvtab('a, b, PRIMARY KEY(a,b)) WITHOUT ROWID; --')", "not an error");
    try c.exec("CREATE VIRTUAL TABLE kw USING kvtab('a PRIMARY KEY, b) WITHOUT ROWID; --')");
    try c.expectRows("SELECT name, pk FROM pragma_table_info('kw')", "a|1\nb|0\n");
    try c.expectError("CREATE VIRTUAL TABLE kx USING kvtab('a CHECK(')", "near \")\": syntax error");

    // sqlite3_declare_vtab() and sqlite3_vtab_config() only work within
    // xCreate and xConnect.
    try testing.expectEqual(RC.MISUSE, vtab.declareVtab(c.db, "CREATE TABLE x(a)"));
    try testing.expectEqual(RC.MISUSE, vtab.config(c.db, vtab.VTAB_INNOCUOUS, 0));
    try testing.expectEqual(RC.ERROR, vtab.declareVtab(c.db, "SELECT 1"));
    try testing.expectEqualStrings("syntax error", main_mod.errmsg(c.db));
}

// ======================================== result codes of module methods

/// "errepo": an eponymous table of one row whose method `fail_method`
/// fails with `fail_code` and a message naming it.
const ErrMethod = enum { none, open, filter, next, column, rowid, best_index };
var fail_method: ErrMethod = .none;
var fail_code: i32 = RC.OK;

fn errFail(vt: *vtab.Vtab, m: ErrMethod) i32 {
    if (fail_method != m) return RC.OK;
    vt.err_msg = std.fmt.allocPrintSentinel(sqlite3_malloc, "x{t} failed", .{m}, 0) catch return RC.NOMEM;
    return fail_code;
}

const ErrCursor = struct { base: vtab.VtabCursor = .{}, n: i64 = 0 };

fn errConnect(db: *int.Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const rc = vtab.declareVtab(db, "CREATE TABLE x(a)");
    if (rc != RC.OK) return rc;
    const t = gpa.create(vtab.Vtab) catch return RC.NOMEM;
    t.* = .{};
    pp.* = t;
    return RC.OK;
}

fn errDisconnect(p: *vtab.Vtab) i32 {
    gpa.destroy(p);
    return RC.OK;
}

fn errBestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    info.estimated_cost = 1;
    return errFail(p, .best_index);
}

fn errOpen(p: *vtab.Vtab, pp: *?*vtab.VtabCursor) i32 {
    const rc = errFail(p, .open);
    if (rc != RC.OK) return rc;
    const c = gpa.create(ErrCursor) catch return RC.NOMEM;
    c.* = .{};
    pp.* = &c.base;
    return RC.OK;
}

fn errClose(cur: *vtab.VtabCursor) i32 {
    gpa.destroy(@as(*ErrCursor, @alignCast(@fieldParentPtr("base", cur))));
    return RC.OK;
}

fn errFilter(cur: *vtab.VtabCursor, _: i32, _: ?[:0]const u8, _: []*Mem) i32 {
    @as(*ErrCursor, @alignCast(@fieldParentPtr("base", cur))).n = 0;
    return errFail(cur.vtab, .filter);
}

fn errNext(cur: *vtab.VtabCursor) i32 {
    @as(*ErrCursor, @alignCast(@fieldParentPtr("base", cur))).n += 1;
    return errFail(cur.vtab, .next);
}

fn errEof(cur: *vtab.VtabCursor) bool {
    return @as(*ErrCursor, @alignCast(@fieldParentPtr("base", cur))).n > 0;
}

fn errColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, _: i32) i32 {
    api.resultInt64(ctx, 7);
    return errFail(cur.vtab, .column);
}

fn errRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = 1;
    return errFail(cur.vtab, .rowid);
}

const err_module: vtab.Module = .{
    .x_connect = errConnect,
    .x_best_index = errBestIndex,
    .x_disconnect = errDisconnect,
    .x_open = errOpen,
    .x_close = errClose,
    .x_filter = errFilter,
    .x_next = errNext,
    .x_eof = errEof,
    .x_column = errColumn,
    .x_rowid = errRowid,
};

test "vtab: the result codes and messages of module methods reach the API" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try testing.expectEqual(RC.OK, vtab.createModule(c.db, "errepo", &err_module, null));
    defer fail_method = .none;
    try c.expectRows("SELECT rowid, a FROM errepo", "1|7\n");
    main_mod.extendedResultCodes(c.db, true);
    for ([_]ErrMethod{ .open, .filter, .next, .column, .rowid }) |m| {
        for ([_]i32{ RC.CONSTRAINT_VTAB, RC.IOERR_WRITE, RC.BUSY_SNAPSHOT, RC.CORRUPT_VTAB, RC.ERROR, RC.NOMEM, RC.TOOBIG, RC.INTERRUPT }) |code| {
            fail_method = m;
            fail_code = code;
            var stmt: ?*vi.Vdbe = null;
            try testing.expectEqual(RC.OK, @import("prepare.zig").prepareV2(c.db, "SELECT rowid, a FROM errepo", &stmt, null));
            var rc = api.step(stmt.?);
            while (rc == RC.ROW) rc = api.step(stmt.?);
            testing.expectEqual(code, rc) catch |err| {
                std.debug.print("x{t}: {s}\n", .{ m, main_mod.errmsg(c.db) });
                return err;
            };
            try testing.expectEqual(code, main_mod.extendedErrcode(c.db));
            var buf: [32]u8 = undefined;
            // A code returned by a method keeps the message of the method,
            // SQLITE_NOMEM too (it is not an allocation failure).
            const msg = try std.fmt.bufPrint(&buf, "x{t} failed", .{m});
            try testing.expectEqualStrings(msg, main_mod.errmsg(c.db));
            try testing.expectEqual(code, api.finalize(stmt.?));
        }
    }
    // xBestIndex fails the prepare, with its message.
    fail_method = .best_index;
    fail_code = RC.ERROR;
    try c.expectError("SELECT a FROM errepo", "xbest_index failed");
    try testing.expectEqual(RC.ERROR, main_mod.extendedErrcode(c.db));
    fail_method = .none;
    try c.expectRows("SELECT rowid, a FROM errepo", "1|7\n");
}
