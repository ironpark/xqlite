//! Rows a statement keeps while it runs, and the statements that make
//! them: what MERGE and the data-modifying statements of WITH (dml.zig)
//! are made of.
//!
//! Such a statement is compiled (dml.zig) as statements of the dialect
//! that run, one after the other, when it runs (OP_SqlExec's 0x0008:
//! Hooks.run_steps, runSteps() here), keeping the rows they return in
//! slots of the connection, and a statement of its own that reads those
//! rows: the rows of MERGE's join, the rows MERGE and a data-modifying
//! statement of WITH changed, read as a table:
//!
//!   "xq_pg_rows_<hash>:<spec>"(slot)
//!       An engine table-valued function (Hooks.table_function): the rows
//!       of slot `slot`, a column per column of the spec (its name and
//!       type, in the name so that a statement compiled again finds it;
//!       <hash> tells apart specs that differ in case only), each of the
//!       type the spec gives it (Hooks.table_function_type), then the
//!       hidden columns xq_slot (the argument), xq_key (a row's key: the
//!       place of the row of MERGE's join it comes from), xq_tag (MERGE's
//!       WHEN clause of a row of the join, its action for a row changed),
//!       xq_action (the action as merge_action() names it) and xq_target
//!       (the rowid of the target's row of a row of the join). The rowid
//!       is the place of the row in its slot.
//!
//! The slots are numbered when the statement is compiled (a counter of
//! the connection), emptied when it runs again, freed when it ends (and
//! with the connection).

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const vtab = @import("../../sql/vtab.zig");
const api = @import("../../vdbe/api.zig");
const aux = @import("../../vdbe/aux.zig");
const prepare = @import("../../sql/prepare.zig");
const main_mod = @import("../../sql/main.zig");
const util = @import("../../sql/util.zig");
const types = @import("../../sql/types.zig");
const ctype = @import("xqlite_base").ctype;

const Sqlite3 = int.Sqlite3;
const Mem = vi.Mem;
const Vdbe = vi.Vdbe;
const RC = int.RC;
const Allocator = std.mem.Allocator;

// ============================================================== slots

pub const Row = struct {
    vals: []*Mem,
    key: i64,
    tag: ?i64 = null,
    target: ?i64 = null,

    fn free(r: *Row, gpa: Allocator) void {
        for (r.vals) |m| api.valueFree(m);
        gpa.free(r.vals);
    }
};

const Slot = struct {
    rows: std.ArrayList(Row) = .empty,

    fn clear(s: *Slot, gpa: Allocator) void {
        for (s.rows.items) |*r| r.free(gpa);
        s.rows.clearRetainingCapacity();
    }

    fn destroy(s: *Slot, gpa: Allocator) void {
        s.clear(gpa);
        s.rows.deinit(gpa);
        gpa.destroy(s);
    }
};

/// The slots of a connection (State.dml_rows).
const Store = struct {
    slots: std.AutoHashMapUnmanaged(u32, *Slot) = .empty,
    next_id: u32 = 1,

    fn get(s: *Store, gpa: Allocator, id: u32) error{OutOfMemory}!*Slot {
        const gop = try s.slots.getOrPut(gpa, id);
        if (!gop.found_existing) {
            const slot = gpa.create(Slot) catch |e| {
                s.slots.removeByPtr(gop.key_ptr);
                return e;
            };
            slot.* = .{};
            gop.value_ptr.* = slot;
        }
        return gop.value_ptr.*;
    }

    fn drop(s: *Store, gpa: Allocator, id: u32) void {
        const kv = s.slots.fetchRemove(id) orelse return;
        kv.value.destroy(gpa);
    }

    fn free(gpa: Allocator, p: *anyopaque) void {
        const s: *Store = @ptrCast(@alignCast(p));
        var it = s.slots.valueIterator();
        while (it.next()) |slot| slot.*.destroy(gpa);
        s.slots.deinit(gpa);
        gpa.destroy(s);
    }
};

fn storeOf(db: *Sqlite3) error{OutOfMemory}!*Store {
    const st = &db.xq.postgres;
    if (st.dml_rows) |p| return @ptrCast(@alignCast(p));
    const s = try db.gpa.create(Store);
    s.* = .{};
    st.dml_rows = s;
    st.dml_rows_free = &Store.free;
    return s;
}

/// A new slot number of connection `db`, for a statement compiled.
pub fn newSlot(db: *Sqlite3) error{OutOfMemory}!u32 {
    const s = try storeOf(db);
    const id = s.next_id;
    s.next_id +%= 1;
    if (s.next_id == 0) s.next_id = 1;
    return id;
}

/// The rows slot `id` of connection `db` keeps, null if it is not
/// there (tests).
pub fn slotCount(db: *Sqlite3, id: u32) ?usize {
    const s = slotRows(db, id) orelse return null;
    return s.rows.items.len;
}

fn slotRows(db: *Sqlite3, id: u32) ?*Slot {
    const p = db.xq.postgres.dml_rows orelse return null;
    const s: *Store = @ptrCast(@alignCast(p));
    return s.slots.get(id);
}

// =============================================================== spec

pub const prefix = "xq_pg_rows_";

/// A column of the rows of a slot: its name and type (the spelling in
/// PostgreSQL's words, and what it is).
pub const Col = struct {
    name: []const u8,
    spelling: []const u8 = "",
    type: types.Type = .{ .logical = .unknown },
};

const Spec = struct {
    arena: std.heap.ArenaAllocator,
    cols: []Col,
    /// The columns from this one on are hidden.
    hidden_from: usize = std.math.maxInt(usize),
};

/// The name of the table-valued function of rows of columns `cols`.
pub fn moduleName(a: Allocator, cols: []const Col) error{OutOfMemory}![]const u8 {
    return moduleNameHidden(a, cols, cols.len);
}

/// moduleName() of columns of which those from `hidden_from` on are
/// hidden.
pub fn moduleNameHidden(a: Allocator, cols: []const Col, hidden_from: usize) error{OutOfMemory}![]const u8 {
    var spec: std.ArrayList(u8) = .empty;
    try spec.print(a, "{d};", .{hidden_from});
    for (cols, 0..) |c, i| {
        if (i > 0) try spec.append(a, ',');
        try pct(a, &spec, c.name);
        try spec.append(a, ':');
        try pct(a, &spec, c.spelling);
        const t = c.type;
        try spec.print(a, ":{d}:", .{@backingInt(t.logical)});
        if (t.length) |n| try spec.print(a, "{d}", .{n});
        try spec.append(a, ':');
        if (t.precision) |n| try spec.print(a, "{d}", .{n});
        try spec.append(a, ':');
        if (t.scale) |n| try spec.print(a, "{d}", .{n});
        try spec.print(a, ":{d}", .{@backingInt(t.element)});
    }
    const h = std.hash.Wyhash.hash(0, spec.items);
    return std.fmt.allocPrint(a, "{s}{x:0>16}:{s}", .{ prefix, h, spec.items });
}

/// `s` with %, :, ", and , written %XX.
fn pct(a: Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    for (s) |c| switch (c) {
        '%', ':', ',', '"' => try out.print(a, "%{X:0>2}", .{c}),
        else => try out.append(a, c),
    };
}

fn unpct(a: Allocator, s: []const u8) error{ OutOfMemory, Bad }![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') {
            try out.append(a, s[i]);
            continue;
        }
        if (i + 3 > s.len) return error.Bad;
        try out.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.Bad);
        i += 2;
    }
    return out.items;
}

const LogicalInt = @typeInfo(types.Logical).@"enum".tag_type;

fn optInt(comptime T: type, s: []const u8) error{Bad}!?T {
    if (s.len == 0) return null;
    return std.fmt.parseInt(T, s, 10) catch error.Bad;
}

fn readSpec(a: Allocator, text: []const u8) error{ OutOfMemory, Bad }![]Col {
    var cols: std.ArrayList(Col) = .empty;
    if (text.len == 0) return cols.items;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |entry| {
        var f: [7][]const u8 = undefined;
        var n: usize = 0;
        var fi = std.mem.splitScalar(u8, entry, ':');
        while (fi.next()) |x| : (n += 1) {
            if (n >= f.len) return error.Bad;
            f[n] = x;
        }
        if (n != f.len) return error.Bad;
        const logical = std.fmt.parseInt(u8, f[2], 10) catch return error.Bad;
        const element = std.fmt.parseInt(u8, f[6], 10) catch return error.Bad;
        if (logical >= std.enums.values(types.Logical).len or element >= std.enums.values(types.Logical).len) return error.Bad;
        try cols.append(a, .{
            .name = try unpct(a, f[0]),
            .spelling = try unpct(a, f[1]),
            .type = .{
                .logical = @fromBackingInt(@as(LogicalInt, @intCast(logical))),
                .length = try optInt(u32, f[3]),
                .precision = try optInt(u8, f[4]),
                .scale = try optInt(u8, f[5]),
                .element = @fromBackingInt(@as(LogicalInt, @intCast(element))),
            },
        });
    }
    return cols.items;
}

/// Hooks.table_function: the module of rows called `name`, registered
/// on `db`.
pub fn register(db: *Sqlite3, name: []const u8) ?*int.Module {
    if (name.len <= prefix.len or !ctype.eqlNoCase(name[0..prefix.len], prefix)) return null;
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
    const h = std.fmt.parseInt(u64, name[prefix.len..colon], 16) catch return null;
    const text = name[colon + 1 ..];
    if (std.hash.Wyhash.hash(0, text) != h) return null;
    const spec = db.gpa.create(Spec) catch {
        db.oomFault();
        return null;
    };
    spec.* = .{ .arena = .init(db.gpa), .cols = &.{} };
    const semi = std.mem.indexOfScalar(u8, text, ';') orelse {
        destroySpec(spec);
        return null;
    };
    spec.hidden_from = std.fmt.parseInt(usize, text[0..semi], 10) catch {
        destroySpec(spec);
        return null;
    };
    spec.cols = readSpec(spec.arena.allocator(), text[semi + 1 ..]) catch {
        destroySpec(spec);
        return null;
    };
    return vtab.createModuleInternal(db, name, &module, vtab.Module.auxFor(connect, spec), int.destructor(destroySpec));
}

fn destroySpec(spec: *Spec) void {
    const gpa = spec.arena.child_allocator;
    spec.arena.deinit();
    gpa.destroy(spec);
}

/// Hooks.table_function_type: the type of column `i` of the rows module
/// `name` (registered on `db`), and its spelling; null for none.
pub fn columnType(db: *Sqlite3, name: []const u8, i: usize) ?struct { types.Type, []const u8 } {
    if (name.len <= prefix.len or !ctype.eqlNoCase(name[0..prefix.len], prefix)) return null;
    const m = db.modules.get(name) orelse return null;
    if (m.module != &module) return null;
    const spec: *const Spec = @ptrCast(@alignCast(m.aux orelse return null));
    const n_vis = @min(spec.hidden_from, spec.cols.len);
    const k = if (i < n_vis) i else if (i >= n_vis + hidden.len) i - hidden.len else return null;
    if (k >= spec.cols.len) return null;
    const c = spec.cols[k];
    if (c.type.logical == .unknown or c.spelling.len == 0) return null;
    return .{ c.type, c.spelling };
}

// =============================================================== vtab

const hidden = [_][]const u8{ "xq_slot", "xq_key", "xq_tag", "xq_action", "xq_target" };

const Table = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
    /// The visible columns (the spec's hidden ones follow the fixed
    /// hidden columns).
    n_cols: i32,
};

const Cursor = struct {
    base: vtab.VtabCursor = .{},
    slot_id: u32 = 0,
    /// The slot, looked up when the scan starts (a slot is freed only
    /// after the statement's query: Plan.end()).
    slot: ?*Slot = null,
    i: usize = 0,
    /// One past the last row read (a rowid lookup reads one).
    end: usize = 0,

    fn of(c: *vtab.VtabCursor) *Cursor {
        return @alignCast(@fieldParentPtr("base", c));
    }
};

const Quoted = @import("../dialect.zig").Quoted('"');

/// The CREATE TABLE of the rows of `spec`, for declareVtab().
fn declSql(a: Allocator, spec: *const Spec) error{OutOfMemory}![:0]u8 {
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "CREATE TABLE x(");
    // A name a column has already is the name and its number.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const n_vis = @min(spec.hidden_from, spec.cols.len);
    for (spec.cols[0..n_vis], 0..) |c, i| {
        var name = c.name;
        var lower = try std.ascii.allocLowerString(a, name);
        if (seen.contains(lower) or isHidden(lower)) {
            name = try std.fmt.allocPrint(a, "{s}:{d}", .{ c.name, i + 1 });
            lower = try std.ascii.allocLowerString(a, name);
        }
        try seen.put(a, lower, {});
        try sql.print(a, "{f}, ", .{Quoted{ .z = name }});
    }
    for (hidden, 0..) |h, i| {
        if (i > 0) try sql.appendSlice(a, ", ");
        try sql.print(a, "{s} HIDDEN", .{h});
    }
    // The spec's hidden columns, after those (a table-valued function's
    // argument is its first hidden column: xq_slot).
    for (spec.cols[n_vis..]) |c| try sql.print(a, ", {f} HIDDEN", .{Quoted{ .z = c.name }});
    try sql.append(a, ')');
    return sql.toOwnedSliceSentinel(a, 0);
}

fn connect(db: *Sqlite3, spec: *const Spec, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    var ar: std.heap.ArenaAllocator = .init(db.gpa);
    defer ar.deinit();
    const sql = declSql(ar.allocator(), spec) catch return RC.NOMEM;
    const rc = vtab.declareVtab(db, sql);
    if (rc != RC.OK) return rc;
    const t = db.gpa.create(Table) catch return RC.NOMEM;
    t.* = .{ .db = db, .n_cols = @intCast(@min(spec.hidden_from, spec.cols.len)) };
    pp_vtab.* = &t.base;
    _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
    return RC.OK;
}

fn isHidden(lower: []const u8) bool {
    for (hidden) |h| if (std.mem.eql(u8, h, lower)) return true;
    return false;
}

/// xq_slot = ? is required; rowid = ? reads one row.
fn bestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    const t: *Table = @alignCast(@fieldParentPtr("base", p));
    var slot: i32 = -1;
    var rowid_eq: i32 = -1;
    var unusable = false;
    for (info.constraints, 0..) |cons, i| {
        if (cons.i_column == t.n_cols) {
            if (!cons.usable) {
                unusable = true;
            } else if (cons.op == vtab.INDEX_CONSTRAINT.EQ) slot = @intCast(i);
        } else if (cons.i_column == -1 and cons.usable and cons.op == vtab.INDEX_CONSTRAINT.EQ) rowid_eq = @intCast(i);
    }
    if (slot < 0) {
        if (unusable) return RC.CONSTRAINT;
        info.idx_num = 0;
        info.estimated_cost = 1e99;
        return RC.OK;
    }
    info.usage[@intCast(slot)].argv_index = 1;
    info.usage[@intCast(slot)].omit = true;
    info.idx_num = 1;
    info.estimated_cost = 1000;
    info.estimated_rows = 1000;
    if (rowid_eq >= 0) {
        info.usage[@intCast(rowid_eq)].argv_index = 2;
        info.usage[@intCast(rowid_eq)].omit = true;
        info.idx_num = 2;
        info.estimated_cost = 1;
        info.estimated_rows = 1;
        info.idx_flags |= vtab.INDEX_SCAN_UNIQUE;
    }
    if (info.order_by.len == 1 and info.order_by[0].i_column == -1 and !info.order_by[0].desc) info.order_by_consumed = true;
    return RC.OK;
}

const lifecycle = vtab.Lifecycle(Table, Cursor);

fn tableOf(cur: *vtab.VtabCursor) *Table {
    return @alignCast(@fieldParentPtr("base", cur.vtab));
}

fn rowsOf(c: *Cursor) []Row {
    const s = c.slot orelse return &.{};
    return s.rows.items;
}

fn filter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c = Cursor.of(cur);
    const t = tableOf(cur);
    c.* = .{ .base = c.base };
    if (idx_num == 0 or argv.len == 0) return RC.OK;
    c.slot_id = std.math.cast(u32, api.valueInt64(argv[0])) orelse return RC.OK;
    c.slot = slotRows(t.db, c.slot_id);
    const n = rowsOf(c).len;
    c.end = n;
    if (idx_num == 2 and argv.len > 1) {
        if (api.valueType(argv[1]) != vi.SQLITE_INTEGER) {
            c.end = 0;
            return RC.OK;
        }
        const r = api.valueInt64(argv[1]);
        if (r < 0 or r >= n) {
            c.end = 0;
            return RC.OK;
        }
        c.i = @intCast(r);
        c.end = c.i + 1;
    }
    return RC.OK;
}

fn next(cur: *vtab.VtabCursor) i32 {
    Cursor.of(cur).i += 1;
    return RC.OK;
}

fn eof(cur: *vtab.VtabCursor) bool {
    const c = Cursor.of(cur);
    return c.i >= c.end or c.i >= rowsOf(c).len;
}

fn rowid(cur: *vtab.VtabCursor, r: *i64) i32 {
    r.* = @intCast(Cursor.of(cur).i);
    return RC.OK;
}

fn column(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = Cursor.of(cur);
    const t = tableOf(cur);
    const rows = rowsOf(c);
    if (c.i >= rows.len) {
        api.resultNull(ctx);
        return RC.OK;
    }
    const row = &rows[c.i];
    if (i < t.n_cols or i >= t.n_cols + @as(i32, hidden.len)) {
        const k: usize = @intCast(if (i < t.n_cols) i else i - @as(i32, hidden.len));
        if (k < row.vals.len) api.resultValue(ctx, row.vals[k]) else api.resultNull(ctx);
        return RC.OK;
    }
    switch (i - t.n_cols) {
        0 => api.resultInt64(ctx, c.slot_id),
        1 => api.resultInt64(ctx, row.key),
        2 => if (row.tag) |x| api.resultInt64(ctx, x) else api.resultNull(ctx),
        3 => if (row.tag) |x| api.resultText(ctx, actionName(x), .static) else api.resultNull(ctx),
        else => if (row.target) |x| api.resultInt64(ctx, x) else api.resultNull(ctx),
    }
    return RC.OK;
}

/// merge_action() of an action's code (Step.action).
fn actionName(code: i64) []const u8 {
    return switch (code) {
        1 => "INSERT",
        2 => "UPDATE",
        3 => "DELETE",
        else => "",
    };
}

const module: vtab.Module = .{
    .i_version = 0,
    .x_connect = vtab.Module.constructor(connect),
    .x_best_index = bestIndex,
    .x_disconnect = lifecycle.disconnect,
    .x_open = lifecycle.open,
    .x_close = lifecycle.close,
    .x_filter = filter,
    .x_next = next,
    .x_eof = eof,
    .x_column = column,
    .x_rowid = rowid,
};

// ============================================================== steps

/// What a step does (encode(), runSteps()).
pub const Kind = enum(u8) {
    /// Empty slot `a`.
    clear = 'Z',
    /// Run the query of MERGE's join into slot `a`: each row is the
    /// target's rowid (or NULL), the WHEN clause it takes (or NULL), the
    /// `b` columns of the source, and a column more.
    join = 'S',
    /// Fail if a target's rowid comes twice in the rows of slot `a` that
    /// take one of the WHEN clauses listed (comma-separated) in `sql`.
    twice = 'T',
    /// Run a statement doing the action of WHEN clause `b` to the rows
    /// of join slot `a`; its changes are counted. With `c` >= 0, keep
    /// what it returns in slot `c`: the target's columns and the rowid,
    /// with action code `d` (1 INSERT, 2 UPDATE, 3 DELETE) and the key of
    /// the row of the join it comes from. With `e` 1, run it once for
    /// each row of the join that takes the clause (INSERT DEFAULT
    /// VALUES).
    action = 'A',
    /// Run a statement (of WITH), keeping what it returns in slot `a` if
    /// `a` >= 0. Its changes are not counted.
    run = 'C',
    /// Sort slot `a` by key.
    sort = 'O',
    /// Free slot `a`.
    free = 'F',
};

pub const Step = struct {
    kind: Kind,
    a: i64 = -1,
    b: i64 = -1,
    c: i64 = -1,
    d: i64 = -1,
    e: i64 = 0,
    sql: []const u8 = "",
    /// What EXPLAIN calls the step (dml.zig's Plan.explain()); not
    /// encoded. A step without one is not shown.
    label: []const u8 = "",
};

/// The text of OP_SqlExec's 0x0008 of `steps`.
pub fn encode(a: Allocator, steps: []const Step) error{OutOfMemory}![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (steps) |s| try out.print(a, "{c}{d},{d},{d},{d},{d},{d}:{s}", .{ @backingInt(s.kind), s.a, s.b, s.c, s.d, s.e, s.sql.len, s.sql });
    return out.toOwnedSliceSentinel(a, 0);
}

fn decode(text: []const u8, i: *usize) error{Bad}!?Step {
    if (i.* >= text.len) return null;
    var s: Step = .{ .kind = std.enums.fromInt(Kind, text[i.*]) orelse return error.Bad };
    i.* += 1;
    var nums: [6]i64 = undefined;
    for (&nums, 0..) |*n, k| {
        const stop: u8 = if (k == 5) ':' else ',';
        const end = std.mem.indexOfScalarPos(u8, text, i.*, stop) orelse return error.Bad;
        n.* = std.fmt.parseInt(i64, text[i.*..end], 10) catch return error.Bad;
        i.* = end + 1;
    }
    const len = std.math.cast(usize, nums[5]) orelse return error.Bad;
    if (i.* + len > text.len) return error.Bad;
    s.a = nums[0];
    s.b = nums[1];
    s.c = nums[2];
    s.d = nums[3];
    s.e = nums[4];
    s.sql = text[i.* .. i.* + len];
    i.* += len;
    return s;
}

/// The failure of a step: its message (from db.gpa) and state.
const Failure = struct {
    msg: ?[:0]u8 = null,
    state: ?int.ErrorState = null,
    rc: i32 = RC.OK,
};

/// Hooks.run_steps: run the steps `text` (encode()) of statement `v`, in
/// the connection's dialect (the caller's to set). An error leaves its
/// message in `err_msg` (from db.gpa) and its state in `state`.
pub fn runSteps(db: *Sqlite3, v: *Vdbe, text: [:0]const u8, err_msg: *?[:0]u8, state: *?int.ErrorState) i32 {
    var f: Failure = .{};
    run(db, v, text, &f) catch |err| switch (err) {
        error.OutOfMemory => {
            db.oomFault();
            if (f.msg) |m| db.gpa.free(m);
            return RC.NOMEM;
        },
        error.Failed => {},
    };
    if (f.rc == RC.OK) return RC.OK;
    err_msg.* = f.msg;
    state.* = f.state;
    return f.rc;
}

const RunError = error{ OutOfMemory, Failed };

fn fail(db: *Sqlite3, f: *Failure, st: int.ErrorState, fields: util.ErrorFields) RunError {
    const text, const s = try util.joinFields(db.gpa, st, fields);
    f.* = .{ .msg = text, .state = s, .rc = RC.ERROR };
    return error.Failed;
}

fn run(db: *Sqlite3, v: *Vdbe, text: [:0]const u8, f: *Failure) RunError!void {
    const gpa = db.gpa;
    const store = try storeOf(db);
    var i: usize = 0;
    while (decode(text, &i) catch return fail(db, f, .of("XX000"), .{ .message = "bad steps" })) |s| {
        switch (s.kind) {
            .clear => (try store.get(gpa, @intCast(s.a))).clear(gpa),
            .free => store.drop(gpa, @intCast(s.a)),
            .sort => {
                const slot = try store.get(gpa, @intCast(s.a));
                std.sort.block(Row, slot.rows.items, {}, struct {
                    fn lt(_: void, x: Row, y: Row) bool {
                        return x.key < y.key;
                    }
                }.lt);
            },
            .twice => {
                const slot = try store.get(gpa, @intCast(s.a));
                var clauses: std.ArrayList(i64) = .empty;
                defer clauses.deinit(gpa);
                var it = std.mem.tokenizeScalar(u8, s.sql, ',');
                while (it.next()) |x| try clauses.append(gpa, std.fmt.parseInt(i64, x, 10) catch continue);
                var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
                defer seen.deinit(gpa);
                for (slot.rows.items) |r| {
                    const tag = r.tag orelse continue;
                    const target = r.target orelse continue;
                    if (std.mem.indexOfScalar(i64, clauses.items, tag) == null) continue;
                    const gop = try seen.getOrPut(gpa, target);
                    if (gop.found_existing) return fail(db, f, .of("21000"), .{
                        .message = "MERGE command cannot affect row a second time",
                        .hint = "Ensure that not more than one source row matches any one target row.",
                    });
                }
            },
            .join => {
                const slot = try store.get(gpa, @intCast(s.a));
                slot.clear(gpa);
                var sink: JoinSink = .{ .slot = slot, .gpa = gpa, .n_src = @intCast(s.b) };
                try runStatement(db, v, s.sql, f, &sink, JoinSink.row);
            },
            .action => {
                const snap = try store.get(gpa, @intCast(s.a));
                var sink: ActionSink = .{ .gpa = gpa, .snap = snap, .clause = s.b, .code = s.d, .insert = s.d == 1 };
                if (s.c >= 0) sink.out = try store.get(gpa, @intCast(s.c));
                defer sink.map.deinit(gpa);
                var times: usize = 1;
                if (s.e == 1) {
                    times = 0;
                    for (snap.rows.items) |r| if (r.tag == s.b) {
                        times += 1;
                    };
                }
                try runStatementTimes(db, v, s.sql, f, &sink, ActionSink.row, times, true);
            },
            .run => {
                var sink: RunSink = .{ .gpa = gpa };
                if (s.a >= 0) sink.out = try store.get(gpa, @intCast(s.a));
                try runStatement(db, v, s.sql, f, &sink, RunSink.row);
            },
        }
    }
}

/// The values of the columns `from`.. of the current row of `stmt`, as
/// copies.
pub fn copyRow(gpa: Allocator, stmt: *Vdbe, from: usize, n: usize) error{OutOfMemory}![]*Mem {
    const vals = try gpa.alloc(*Mem, n);
    var done: usize = 0;
    errdefer {
        for (vals[0..done]) |m| api.valueFree(m);
        gpa.free(vals);
    }
    while (done < n) : (done += 1) {
        vals[done] = api.valueDup(api.columnValue(stmt, from + done)) orelse return error.OutOfMemory;
    }
    return vals;
}

fn intOrNull(stmt: *Vdbe, i: usize) ?i64 {
    if (api.columnType(stmt, i) == vi.SQLITE_NULL) return null;
    return api.columnInt64(stmt, i);
}

const JoinSink = struct {
    slot: *Slot,
    gpa: Allocator,
    n_src: usize,

    fn row(k: *JoinSink, stmt: *Vdbe) error{OutOfMemory}!void {
        const n = api.columnCount(stmt);
        const n_src = @min(k.n_src, n -| 2);
        const vals = try copyRow(k.gpa, stmt, 2, n_src);
        k.slot.rows.append(k.gpa, .{
            .vals = vals,
            .key = @intCast(k.slot.rows.items.len),
            .target = intOrNull(stmt, 0),
            .tag = intOrNull(stmt, 1),
        }) catch |e| {
            var r: Row = .{ .vals = vals, .key = 0 };
            r.free(k.gpa);
            return e;
        };
    }
};

const ActionSink = struct {
    gpa: Allocator,
    snap: *Slot,
    clause: i64,
    code: i64,
    insert: bool,
    out: ?*Slot = null,
    /// The key of each target rowid of the clause's rows of the join.
    map: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    mapped: bool = false,
    /// The next row of the join an INSERT's row comes from.
    next: usize = 0,

    fn row(k: *ActionSink, stmt: *Vdbe) error{OutOfMemory}!void {
        const out = k.out orelse return;
        const n = api.columnCount(stmt);
        if (n == 0) return;
        var key: i64 = std.math.maxInt(i64);
        if (k.insert) {
            while (k.next < k.snap.rows.items.len) : (k.next += 1) {
                const r = k.snap.rows.items[k.next];
                if (r.tag == k.clause) {
                    key = r.key;
                    k.next += 1;
                    break;
                }
            }
        } else {
            if (!k.mapped) {
                k.mapped = true;
                for (k.snap.rows.items) |r| if (r.tag == k.clause) if (r.target) |t| try k.map.put(k.gpa, t, r.key);
            }
            if (intOrNull(stmt, n - 1)) |rid| key = k.map.get(rid) orelse key;
        }
        const vals = try copyRow(k.gpa, stmt, 0, n - 1);
        out.rows.append(k.gpa, .{ .vals = vals, .key = key, .tag = k.code }) catch |e| {
            var r: Row = .{ .vals = vals, .key = 0 };
            r.free(k.gpa);
            return e;
        };
    }
};

const RunSink = struct {
    gpa: Allocator,
    out: ?*Slot = null,

    fn row(k: *RunSink, stmt: *Vdbe) error{OutOfMemory}!void {
        const out = k.out orelse return;
        const vals = try copyRow(k.gpa, stmt, 0, api.columnCount(stmt));
        out.rows.append(k.gpa, .{ .vals = vals, .key = @intCast(out.rows.items.len) }) catch |e| {
            var r: Row = .{ .vals = vals, .key = 0 };
            r.free(k.gpa);
            return e;
        };
    }
};

/// Compile and run `sql` (one statement), its parameters those of `v`,
/// passing each row to `on_row(sink, stmt)`.
fn runStatement(db: *Sqlite3, v: *Vdbe, sql: []const u8, f: *Failure, sink: anytype, comptime on_row: anytype) RunError!void {
    return runStatementTimes(db, v, sql, f, sink, on_row, 1, false);
}

/// runStatement() `times` times (none: not compiled), compiled once and
/// reset between the runs; with `counted`, each run's changes are
/// `v`'s.
fn runStatementTimes(db: *Sqlite3, v: *Vdbe, sql: []const u8, f: *Failure, sink: anytype, comptime on_row: anytype, times: usize, counted: bool) RunError!void {
    if (times == 0) return;
    const z = try db.gpa.dupeSentinel(u8, sql, 0);
    defer db.gpa.free(z);
    var stmt_opt: ?*Vdbe = null;
    var rc = prepare.prepareV3Z(db, z, 0, &stmt_opt, null);
    if (rc != RC.OK) return failFromDb(db, f, rc);
    const stmt = stmt_opt orelse return;
    var finalized = false;
    defer if (!finalized) {
        _ = aux.finalize(stmt);
    };
    const n_par = api.bindParameterCount(stmt);
    var k: usize = 1;
    while (k <= n_par and k <= v.vars.len) : (k += 1) {
        rc = api.bindValue(stmt, k, &v.vars[k - 1]);
        if (rc != RC.OK) return failFromDb(db, f, rc);
    }
    for (0..times) |t| {
        while (true) {
            rc = api.step(stmt);
            if (rc == RC.ROW) {
                try on_row(sink, stmt);
                continue;
            }
            break;
        }
        if (t + 1 < times) {
            rc = api.reset(stmt);
        } else {
            finalized = true;
            rc = aux.finalize(stmt);
        }
        if (rc != RC.OK) return failFromDb(db, f, rc);
        if (counted) v.n_change += api.changes(db);
    }
}

/// The lines of EXPLAIN of `sql` (a statement of the dialect, as a step
/// runs it), added to the plan of the statement `p` compiles under its
/// line `parent` (dml.zig's Plan.explain()). The statement's error is
/// `p`'s.
pub fn explainInto(p: *int.Parse, sql: []const u8, parent: i32) error{ OutOfMemory, Failed }!void {
    const db = p.db;
    const v = p.vdbe orelse return error.OutOfMemory;
    const z = try std.fmt.allocPrintSentinel(db.gpa, "EXPLAIN {s}", .{sql}, 0);
    defer db.gpa.free(z);
    var stmt_opt: ?*Vdbe = null;
    var rc = prepare.prepareV3Z(db, z, 0, &stmt_opt, null);
    if (rc != RC.OK) return explainFailed(p, rc);
    const stmt = stmt_opt orelse return;
    defer _ = aux.finalize(stmt);
    // The ids of its lines are the addresses of ours.
    var ids: std.AutoHashMapUnmanaged(i64, i32) = .empty;
    defer ids.deinit(db.gpa);
    while (true) {
        rc = api.step(stmt);
        if (rc != RC.ROW) break;
        const id = api.columnInt64(stmt, 0);
        const up = api.columnInt64(stmt, 1);
        const detail = api.columnText(stmt, 3) orelse "";
        const msg = try v.alloc().dupeSentinel(u8, detail, 0);
        const this = v.nOp();
        _ = aux.addOp4(v, vi.OP.Explain, this, ids.get(up) orelse parent, 0, .{ .z = msg });
        try ids.put(db.gpa, id, this);
    }
    if (rc != RC.DONE) return explainFailed(p, rc);
}

fn explainFailed(p: *int.Parse, rc: i32) error{ OutOfMemory, Failed } {
    const db = p.db;
    if (rc == RC.NOMEM or db.malloc_failed) return error.OutOfMemory;
    const msg = try p.arena.dupe(u8, main_mod.errmsg(db));
    util.errorMsgState(p, null, db.err_state, "{s}", .{msg});
    return error.Failed;
}

fn failFromDb(db: *Sqlite3, f: *Failure, rc: i32) RunError {
    if (rc == RC.NOMEM or db.malloc_failed) return error.OutOfMemory;
    f.* = .{
        .msg = try db.gpa.dupeSentinel(u8, main_mod.errmsg(db), 0),
        .state = db.err_state,
        .rc = rc,
    };
    return error.Failed;
}

test "rows: module name round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cols = [_]Col{
        .{ .name = "id", .spelling = "integer", .type = .{ .logical = .int4 } },
        .{ .name = "a,b:\"c\"%", .spelling = "numeric(6,2)", .type = .{ .logical = .numeric, .precision = 6, .scale = 2 } },
        .{ .name = "x" },
    };
    const name = try moduleName(a, &cols);
    const colon = std.mem.indexOfScalar(u8, name, ':').?;
    const back = try readSpec(a, name[colon + 3 ..]);
    try std.testing.expectEqual(@as(usize, 3), back.len);
    try std.testing.expectEqualStrings("a,b:\"c\"%", back[1].name);
    try std.testing.expectEqualStrings("numeric(6,2)", back[1].spelling);
    try std.testing.expectEqual(@as(?u8, 2), back[1].type.scale);
    try std.testing.expectEqual(types.Logical.unknown, back[2].type.logical);
    const steps = [_]Step{ .{ .kind = .join, .a = 3, .b = 2, .sql = "SELECT 1" }, .{ .kind = .free, .a = 3 } };
    const text = try encode(a, &steps);
    var i: usize = 0;
    const s1 = (try decode(text, &i)).?;
    try std.testing.expectEqual(Kind.join, s1.kind);
    try std.testing.expectEqualStrings("SELECT 1", s1.sql);
    const s2 = (try decode(text, &i)).?;
    try std.testing.expectEqual(Kind.free, s2.kind);
    try std.testing.expect((try decode(text, &i)) == null);
}
