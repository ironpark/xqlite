//! MERGE and the data-modifying statements of WITH, which SQLite has
//! not: made of statements of the dialect that run one after the other
//! when the statement runs (rows.zig: OP_SqlExec's 0x0008, in the
//! statement's own transaction, so that an error undoes them all), each
//! compiled then, and the statement's own query, compiled now, reading
//! the rows they keep (the table-valued function of rows.zig).
//!
//! MERGE INTO t [AS a] USING source [AS s] ON cond WHEN ... [RETURNING ...]
//!
//!  1. The join, into a slot (Kind.join): for each pair of rows (and each
//!     row of either without the other: a FULL JOIN when a WHEN NOT
//!     MATCHED BY SOURCE is there, else a RIGHT JOIN of the target and
//!     the source when a WHEN NOT MATCHED is, else an inner join), the
//!     target's rowid, the WHEN clause it takes (the first whose
//!     condition holds, as a CASE: conditions read the rows as the join
//!     sees them), and the source's columns;
//!  2. a target's row that two rows of the join would change: 21000
//!     (Kind.twice);
//!  3. for each WHEN clause, in order, a statement doing its action to
//!     the rows of the join that take it (Kind.action): an UPDATE ...
//!     FROM the join's rows (as the source's name, its columns the
//!     source's) of the target's rows by rowid, a DELETE of them, an
//!     INSERT ... SELECT of the clause's values from the join's rows
//!     (a DEFAULT among them: the column left out; DEFAULT VALUES: once
//!     per row). Each has the constraints, defaults, identities and store
//!     conversions of its statement. Their changes are MERGE's count;
//!  4. RETURNING: each of these statements returns the target's columns
//!     of each row it changed (a DELETE's as they were), kept with the
//!     action and the row of the join it comes from; the statement's
//!     query reads them, joined to the join's rows (the source's
//!     columns), in the order of the join. merge_action() is the
//!     action's column (parser.zig).
//!
//!  A view as the target (an automatically updatable one: View) is read
//!  as its query with its table's rowid, and its table written; an
//!  UPDATE's values are computed first, in a step of their own
//!  (viewUpdate()). EXPLAIN shows each step's plan (Plan.explain()).
//!
//! WITH d AS (INSERT | UPDATE | DELETE ... [RETURNING ...]) ... statement
//!
//!  Each data-modifying statement runs before the statement, in order,
//!  under the WITH queries before it (the text of each, a data-modifying
//!  one as the query of what it returned), and keeps the target's columns
//!  of the rows it returns; its query (the CTE's) is its RETURNING list
//!  over them. Unlike PostgreSQL, where the statements and the query all
//!  see the database as it was before the statement, each sees what the
//!  ones before it did.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const prepare = @import("../../sql/prepare.zig");
const select_mod = @import("../../sql/select.zig");
const main_mod = @import("../../sql/main.zig");
const typing = @import("../../sql/typing.zig");
const types = @import("../../sql/types.zig");
const util = @import("../../sql/util.zig");
const catalog = @import("../../catalog/catalog.zig");
const aux = @import("../../vdbe/aux.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const lower = @import("../../ir/lower.zig");
const callback = @import("../../sql/callback.zig");
const Quoted = @import("../dialect.zig").Quoted('"');
const parser = @import("parser.zig");
const rows = @import("rows.zig");
const catalog_funcs = @import("catalog_funcs.zig");
const Violation = @import("../dialect.zig").Violation;
const Desugar = @import("../../ir/desugar.zig").Desugar;

const Parser = parser.Parser;
const Error = parser.Error;
const Name = tree.Name;
const Allocator = std.mem.Allocator;

// ============================================================ the tree

pub const Merge = struct {
    with: ?*tree.With = null,
    /// `WITH ...` as written before MERGE, or "".
    with_text: []const u8 = "",
    /// The target, resolved, and as written.
    target: tree.QName,
    target_text: []const u8,
    /// The target's alias, else its name.
    alias: []const u8,
    alias_given: bool = false,
    source: tree.FromItem,
    /// The source as written, with its alias.
    source_text: []const u8,
    /// The name its columns are qualified with ("" for a subquery of no
    /// alias).
    source_alias: []const u8,
    on_text: []const u8,
    clauses: []Clause = &.{},
    returning: []tree.ResultCol = &.{},
    returning_pos: u32 = 0,
    pos: u32,
};

pub const Clause = struct {
    kind: enum { matched, not_matched, by_source },
    cond_text: ?[]const u8 = null,
    action: union(enum) {
        nothing,
        delete,
        /// The SET list as written.
        update: []const u8,
        insert: Insert,
    },
    /// The SET list read (an UPDATE into a view: View).
    sets: []tree.SetItem = &.{},
    pos: u32,
};

pub const Insert = struct {
    cols: []Name = &.{},
    /// OVERRIDING ... VALUE as written, or "".
    overriding: []const u8 = "",
    /// Null for DEFAULT VALUES.
    values: ?[]const Value = null,
};

pub const Value = struct { text: []const u8, default: bool };

/// The query a data-modifying CTE stands for until dml.zig replaces it.
pub fn placeholder(a: Allocator, pos: u32) error{OutOfMemory}!*tree.Select {
    const cols = try a.alloc(tree.ResultCol, 1);
    cols[0] = .{ .expr = .{ .e = try tree.expr(a, pos, pos, .null) } };
    return selectOf(a, cols, &.{}, pos);
}

fn selectOf(a: Allocator, cols: []tree.ResultCol, from: []tree.FromItem, pos: u32) error{OutOfMemory}!*tree.Select {
    const c = try tree.new(a, tree.Core, .{ .cols = cols, .from = from, .pos = pos });
    return tree.new(a, tree.Select, .{ .body = try tree.new(a, tree.Body, .{ .core = c }), .pos = pos });
}

// ============================================================== plans

/// The steps a statement runs before its query, and the slots it frees
/// after it.
pub const Plan = struct {
    steps: std.ArrayList(rows.Step) = .empty,
    slots: std.ArrayList(u32) = .empty,
    /// The databases (by index) the steps write.
    write_mask: u32 = 0,
    /// The statement counts the changes of the steps (MERGE).
    counts: bool = false,

    pub fn active(plan: *const Plan) bool {
        return plan.steps.items.len > 0;
    }

    fn slot(plan: *Plan, a: Allocator, db: *int.Sqlite3) Error!u32 {
        const id = try rows.newSlot(db);
        try plan.slots.append(a, id);
        try plan.steps.append(a, .{ .kind = .clear, .a = id });
        return id;
    }

    /// Code the steps, before the statement's query.
    pub fn begin(plan: *Plan, p: *int.Parse) Error!void {
        const v = build.getVdbe(p) orelse return error.OutOfMemory;
        for (0..p.db.dbs.items.len) |i| if (plan.write_mask & (@as(u32, 1) << @intCast(i)) != 0) build.beginWriteOperation(p, true, i);
        main_mod.mayAbort(p);
        _ = aux.addOp4Str(v, vi.OP.SqlExec, 0x0008, 0, 0, try rows.encode(p.arena, plan.steps.items));
        if (plan.counts) aux.countChanges(v);
    }

    /// EXPLAIN of the statement: the plan of each step's statement, under
    /// a line naming the step, before the plan of the statement's query.
    /// The steps do not run.
    pub fn explain(plan: *Plan, ps: *Parser) Error!void {
        const p = ps.p.?;
        const v = build.getVdbe(p) orelse return error.OutOfMemory;
        for (plan.steps.items) |s| {
            if (s.label.len == 0) continue;
            const this = v.nOp();
            _ = aux.addOp4(v, vi.OP.Explain, this, 0, 0, .{ .z = try v.alloc().dupeSentinel(u8, s.label, 0) });
            rows.explainInto(p, s.sql, this) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Failed => {
                    ps.err_in_parse = true;
                    return error.ParseFailed;
                },
            };
        }
    }

    /// Code the freeing of the slots, after the statement's query.
    pub fn end(plan: *Plan, p: *int.Parse) Error!void {
        const v = build.getVdbe(p) orelse return error.OutOfMemory;
        var free: std.ArrayList(rows.Step) = .empty;
        for (plan.slots.items) |id| try free.append(p.arena, .{ .kind = .free, .a = id });
        _ = aux.addOp4Str(v, vi.OP.SqlExec, 0x0008, 0, 0, try rows.encode(p.arena, free.items));
    }
};

/// A table's columns, as the rows of the table-valued function have them.
const Target = struct {
    tab: *int.Table,
    i_db: usize,
    cols: []rows.Col,
    /// MERGE into a view: the view's columns are `cols`.
    view: ?*View = null,
};

/// The target `q` of a data-modifying statement; a view only for MERGE
/// (`view_ok`).
fn target(ps: *Parser, q: tree.QName, view_ok: bool) Error!Target {
    const p = ps.p.?;
    const a = ps.arena;
    try ps.readSchema();
    const t = build.findTable(p.db, q.name.text, if (q.schema) |s| s.text else null) orelse
        return ps.c.failState(q.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{q.name.text});
    if (t.isView() and view_ok) {
        const i = prepare.schemaToIndex(p.db, t.schema);
        const i_db: usize = if (i < 0) 0 else @intCast(i);
        // The view's columns as a query reads them.
        const star = try a.alloc(tree.ResultCol, 1);
        star[0] = .{ .star = q.name.pos };
        const from = try a.alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .table = q } };
        const cols = try probe(ps, try selectOf(a, star, from, q.name.pos));
        return .{ .tab = t, .i_db = i_db, .cols = cols, .view = try viewOf(ps, t, i_db, q.name.pos) };
    }
    if (t.isView() or t.isVirtual()) return ps.unsupported(q.name.pos, "MERGE or a data-modifying WITH of a view");
    const m = catalog.metaOf(p.db, t) catch null;
    const cols = try a.alloc(rows.Col, t.cols.len);
    for (t.cols, cols) |*c, *rc| {
        rc.* = .{ .name = c.name() };
        if (m) |mm| if (mm.column(c.name())) |cm| if (cm.decl_type) |d| {
            rc.spelling = d;
            rc.type = cm.type;
        };
    }
    const i = prepare.schemaToIndex(p.db, t.schema);
    return .{ .tab = t, .i_db = if (i < 0) 0 else @intCast(i), .cols = cols };
}

/// A view MERGE writes, as PostgreSQL's automatically updatable views
/// are written: its rows are rows of one table (`base`), each column of
/// the view that is a column of that table is that column. Read from
/// its query as pg_get_viewdef() prints it.
const View = struct {
    /// The view's name, as PostgreSQL's errors name it.
    name: []const u8,
    /// Why it is not automatically updatable, else null.
    why: ?NotUpdatable = null,
    /// The table, as the view's query names it, and the name its columns
    /// are qualified with there (quoted).
    base_text: []const u8 = "",
    qual: []const u8 = "",
    /// The view's query with the table's rowid first, as "xq_rid".
    rows_sql: []const u8 = "",
    /// Of each column of the view, the column of the table it is (null:
    /// not updatable), and its expression in the view's query.
    base_cols: []?[]const u8 = &.{},
    exprs: [][]const u8 = &.{},

    fn updatable(v: *const View) bool {
        for (v.base_cols) |c| if (c != null) return true;
        return false;
    }
};

/// Why a view is not automatically updatable (PostgreSQL's
/// view_query_is_auto_updatable()); its DETAIL is detail().
const NotUpdatable = enum {
    compound,
    not_single,
    distinct,
    group_by,
    having,
    with,
    limit,
    aggregate,
    window,
    no_columns,

    fn detail(why: NotUpdatable) []const u8 {
        return switch (why) {
            .compound => "Views containing UNION, INTERSECT, or EXCEPT are not automatically updatable.",
            .not_single => "Views that do not select from a single table or view are not automatically updatable.",
            .distinct => "Views containing DISTINCT are not automatically updatable.",
            .group_by => "Views containing GROUP BY are not automatically updatable.",
            .having => "Views containing HAVING are not automatically updatable.",
            .with => "Views containing WITH are not automatically updatable.",
            .limit => "Views containing LIMIT or OFFSET are not automatically updatable.",
            .aggregate => "Views that return aggregate functions are not automatically updatable.",
            .window => "Views that return window functions are not automatically updatable.",
            .no_columns => "Views that have no updatable columns are not automatically updatable.",
        };
    }
};

fn viewOf(ps: *Parser, t: *int.Table, i_db: usize, pos: u32) Error!*View {
    const p = ps.p.?;
    const db = p.db;
    const a = ps.arena;
    const v = try a.create(View);
    v.* = .{ .name = Violation.bare(t.name) };
    const text = (try catalog_funcs.viewText(db, a, db.dbs.items[i_db].name, t.name)) orelse {
        // A query deparse.zig does not print: why it is not updatable,
        // from the query SQLite keeps.
        v.why = storedWhy(db, t) orelse return ps.unsupported(pos, "MERGE into this view");
        return v;
    };
    const z = try a.dupeSentinel(u8, std.mem.trim(u8, text, " \t\r\n;"), 0);
    var sub = Parser.init(a, z, 0, null, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return ps.unsupported(pos, "MERGE into this view"),
    };
    sub.p = p;
    sub.schema_read = true;
    const sel = sub.select() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            if (sub.err_in_parse) {
                ps.err_in_parse = true;
                return error.ParseFailed;
            }
            return ps.unsupported(pos, "MERGE into this view");
        },
    };
    // view_query_is_auto_updatable(), in its order.
    const core = switch (sel.body.*) {
        .core => |c| c,
        .compound => {
            v.why = .compound;
            return v;
        },
        else => {
            v.why = .not_single;
            return v;
        },
    };
    v.why = if (core.distinct or core.distinct_on.len > 0)
        .distinct
    else if (core.group_by.len > 0 or core.grouping_sets != null)
        .group_by
    else if (core.having != null)
        .having
    else if (sel.with != null)
        .with
    else if (sel.limit != null or sel.offset != null)
        .limit
    else if (callsIn(p, core.cols, Desugar.aggregateCall))
        .aggregate
    else if (callsIn(p, core.cols, Desugar.windowCall))
        .window
    else if (core.from.len != 1 or core.from[0].source != .table)
        .not_single
    else
        null;
    if (v.why != null) return v;
    const item = core.from[0];
    const bq = item.source.table;
    const base = build.findTable(db, bq.name.text, if (bq.schema) |s| s.text else null) orelse
        return ps.unsupported(pos, "MERGE into this view");
    if (base.isView()) return ps.unsupported(pos, "MERGE into a view of a view");
    if (base.isVirtual()) {
        v.why = .not_single;
        return v;
    }
    if (core.cols.len != t.cols.len) return ps.unsupported(pos, "MERGE into this view");
    // The text of each result column (without its alias) and of the
    // table ([schema.]table), as the query has them.
    v.exprs = try a.alloc([]const u8, core.cols.len);
    v.base_cols = try a.alloc(?[]const u8, core.cols.len);
    @memset(v.base_cols, null);
    for (core.cols, v.exprs) |rc, *x| {
        if (rc != .expr) return ps.unsupported(pos, "MERGE into this view");
        const e = rc.expr.e;
        if (e.end <= e.pos or e.end > z.len) return ps.unsupported(pos, "MERGE into this view");
        x.* = z[e.pos..e.end];
    }
    // Which column of the table each one is, as the core resolves the
    // query (`t.x`, `x` and `"X"` alike; an expression is none), read
    // again: lowering changes the tree.
    {
        var again = Parser.init(a, z, 0, null, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return ps.unsupported(pos, "MERGE into this view"),
        };
        again.p = p;
        again.schema_read = true;
        const s2 = again.select() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return ps.unsupported(pos, "MERGE into this view"),
        };
        _ = probeOf(&again, s2, .{ .base = base, .out = v.base_cols }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                ps.err_in_parse = again.err_in_parse;
                return error.ParseFailed;
            },
        };
    }
    const toks = sub.c.src.toks;
    // The table's name token (its last part) and the text from its
    // first part: [schema .] name (a PostgreSQL schema's table is named
    // by its last part, the schema folded into its name).
    const k = for (toks, 0..) |tk, i| {
        if (tk.start == bq.name.pos) break i;
    } else return ps.unsupported(pos, "MERGE into this view");
    const first = if (bq.schema) |sc| sc.pos else if (k >= 2 and toks[k - 1].kind == .dot) toks[k - 2].start else bq.name.pos;
    v.base_text = z[first..toks[k].end];
    v.qual = try quoted(a, if (item.alias) |al| al.name.text else sub.val(toks[k]));
    v.rows_sql = try std.fmt.allocPrint(a, "SELECT {s}.rowid AS \"xq_rid\", {s}", .{ v.qual, z[toks[1].start..] });
    return v;
}

/// Why view `t` is not automatically updatable, from the query SQLite
/// keeps of it (unresolved), in viewOf()'s order; null where it does not
/// tell.
fn storedWhy(db: *int.Sqlite3, t: *int.Table) ?NotUpdatable {
    const sel = t.u.view.select orelse return null;
    if (sel.prior != null) return .compound;
    if (sel.sel_flags.Distinct) return .distinct;
    if (sel.group_by != null) return .group_by;
    if (sel.having != null) return .having;
    if (sel.with != null) return .with;
    if (sel.limit != null) return .limit;
    if (sel.e_list) |list| {
        for (list.slice()) |item| if (item.expr) |e| if (storedCall(db, e, .aggregate)) return .aggregate;
        for (list.slice()) |item| if (item.expr) |e| if (storedCall(db, e, .window)) return .window;
    }
    // One table or view: not a join, a subquery or a table-valued
    // function (a virtual table, not one PostgreSQL's views select from).
    const src = sel.src orelse return .not_single;
    if (src.len() != 1) return .not_single;
    const item = src.at(0);
    if (item.fg.is_subquery or item.fg.is_tab_func or item.fg.is_nested_from) return .not_single;
    const name = item.name orelse return .not_single;
    const schema: ?[]const u8 = if (item.fg.fixed_schema) null else item.u4.database;
    if (build.findTable(db, name, schema)) |base| if (base.isVirtual()) return .not_single;
    return null;
}

/// Whether `e` calls an aggregate (as the resolver finds the function:
/// SQLite's name, its number of arguments) or a window function, not in
/// its subqueries.
fn storedCall(db: *int.Sqlite3, e: *const int.Expr, comptime kind: enum { aggregate, window }) bool {
    if (e.op == int.TK.FUNCTION) {
        if (e.isWindowFunc()) {
            if (kind == .window) return true;
        } else if (kind == .aggregate) {
            const n: i32 = if (e.x.list) |l| @intCast(l.len()) else 0;
            if (callback.findFunction(db, e.token(), n, db.enc, false)) |def| if (def.x_finalize != null) return true;
        }
    }
    if (e.left) |x| if (storedCall(db, x, kind)) return true;
    if (e.right) |x| if (storedCall(db, x, kind)) return true;
    if (e.useXList()) if (e.x.list) |l| for (l.slice()) |item| if (item.expr) |x| if (storedCall(db, x, kind)) return true;
    return false;
}

/// Whether a column of `cols` calls a function `pred` says yes to (not
/// in their subqueries).
fn callsIn(p: *int.Parse, cols: []const tree.ResultCol, comptime pred: fn (*int.Parse, *const tree.Func) bool) bool {
    for (cols) |rc| if (rc == .expr and Desugar.callIn(p, rc.expr.e, pred)) return true;
    return false;
}

/// The names and types of the result columns of `s`, lowered and
/// resolved in a Parse of its own (its error the statement's).
fn probe(ps: *Parser, s: *tree.Select) Error![]rows.Col {
    return probeOf(ps, s, null);
}

/// probe(), and with `origins` (one for each result column), of each
/// result column that is a column of table `base` (as the core resolves
/// it, not by its name), that column's name; null for another.
fn probeOf(ps: *Parser, s: *tree.Select, origins: ?struct { base: *const int.Table, out: []?[]const u8 }) Error![]rows.Col {
    const outer = ps.p.?;
    const db = outer.db;
    const a = ps.arena;
    try @import("jtype.zig").statement(ps, .{ .select = s });
    var q: int.Parse = .{ .db = db, .arena = outer.arena, .tail = outer.tail, .outer_parse = outer };
    defer build.releaseTableRefs(&q);
    const saved_parse = db.parse;
    db.parse = &q;
    defer db.parse = saved_parse;
    var l: lower.Lowerer = .init(&q, ps.c.sql);
    var failed = false;
    const x = l.select(s) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed => blk: {
            failed = true;
            break :blk null;
        },
    };
    if (x) |sel| select_mod.selectPrep(&q, sel, null);
    if (db.malloc_failed) return error.OutOfMemory;
    if (failed or q.n_err > 0) {
        const at = db.err_byte_offset;
        util.errorMsgState(outer, null, q.err_state, "{s}", .{q.err_msg orelse "error"});
        db.err_byte_offset = at;
        ps.err_in_parse = true;
        return error.ParseFailed;
    }
    // The parameters' types it found are the statement's.
    for (q.xq_param_types.items, 0..) |ty, i| {
        if (ty == 0) continue;
        if (outer.xq_param_types.items.len <= i) try outer.xq_param_types.appendNTimes(outer.arena, 0, i + 1 - outer.xq_param_types.items.len);
        if (outer.xq_param_types.items[i] == 0) outer.xq_param_types.items[i] = ty;
    }
    const list = x.?.e_list orelse return &.{};
    if (origins) |o| for (o.out, 0..) |*bc, i| {
        bc.* = null;
        if (i >= list.len()) continue;
        const e = list.at(i).expr orelse continue;
        if (e.op != int.TK.COLUMN or e.y.tab != o.base) continue;
        const k: i32 = if (e.i_column >= 0) e.i_column else o.base.i_pkey;
        if (k >= 0) bc.* = o.base.cols[@intCast(k)].name();
    };
    const out = try a.alloc(rows.Col, list.len());
    for (list.slice(), out) |*item, *c| {
        c.* = .{ .name = if (item.e_name) |n| try a.dupe(u8, n) else "?column?" };
        const e = item.expr orelse continue;
        if (typing.spelling(db, e.xq_type)) |sp| {
            c.spelling = try a.dupe(u8, sp);
            c.type = typing.typeOf(db, e.xq_type);
        }
    }
    return out;
}

/// A qualified name of `table` in `text` (of the statement): PostgreSQL's
/// error of a WHEN clause naming the relation it cannot see.
fn noReference(ps: *Parser, text: []const u8, table: []const u8) Error!void {
    const start = @intFromPtr(text.ptr) - @intFromPtr(ps.c.sql.ptr);
    const end = start + text.len;
    const toks = ps.c.src.toks;
    for (toks, 0..) |t, i| {
        if (t.start < start or t.end > end or i + 1 >= toks.len) continue;
        if (t.kind != .word and t.kind != .quoted_ident) continue;
        if (toks[i + 1].kind != .dot or !std.mem.eql(u8, ps.val(t), table)) continue;
        if (i > 0 and toks[i - 1].kind == .dot) continue;
        return ps.failFields(t.start, .of("42P01"), .{
            .message = try std.fmt.allocPrint(ps.arena, "invalid reference to FROM-clause entry for table \"{s}\"", .{table}),
            .detail = try std.fmt.allocPrint(ps.arena, "There is an entry for table \"{s}\", but it cannot be referenced from this part of the query.", .{table}),
        });
    }
}

fn quoted(a: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{f}", .{Quoted{ .z = name }});
}

/// `"name"(slot) AS "alias"` of rows of columns `cols`, as a FROM item.
fn rowsItem(a: Allocator, cols: []const rows.Col, slot: u32, alias: []const u8, pos: u32) error{OutOfMemory}!tree.FromItem {
    const name = try rows.moduleName(a, cols);
    const args = try a.alloc(*tree.Expr, 1);
    args[0] = try tree.intConst(a, pos, slot);
    const f = try tree.new(a, tree.Func, .{ .name = .{ .text = name, .pos = pos }, .args = args });
    return .{ .source = .{ .func = f }, .alias = .{ .name = .{ .text = alias, .pos = pos } } };
}

fn column(a: Allocator, pos: u32, names: []const []const u8) error{OutOfMemory}!*tree.Expr {
    const n = try a.alloc(Name, names.len);
    for (names, n) |x, *y| y.* = .{ .text = x, .pos = pos };
    return tree.expr(a, pos, pos, .{ .column = n });
}

/// What a statement returns of each row it changes: the target's
/// columns as RETURNING has them, then as they were (old) and are (new),
/// for RETURNING's OLD and NEW.
fn capture(a: Allocator, cols: []const rows.Col) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try colList(a, cols));
    inline for (.{ "old", "new" }) |q| for (cols) |c| try out.print(a, ", {s}.{f}", .{ q, Quoted{ .z = c.name } });
    return out.items;
}

/// The FROM item of the rows slot `slot` keeps of the target (columns
/// `cols`, capture()), named `name`, which `list` reads: its old and new
/// values hidden columns "old.a" and "new.a", where `list` reads them
/// (RETURNING's OLD and NEW, parser.zig's old_new_markers, made
/// references to those).
fn targetItem(a: Allocator, cols: []const rows.Col, slot: u32, name: []const u8, pos: u32, list: []tree.ResultCol) error{OutOfMemory}!tree.FromItem {
    const uses = usesOldNew(list);
    if (!uses[0] and !uses[1]) return rowsItem(a, cols, slot, name, pos);
    var all: std.ArrayList(rows.Col) = .empty;
    try all.appendSlice(a, cols);
    inline for (.{ "old.", "new." }) |q| for (cols) |c| {
        var x = c;
        x.name = try std.mem.concat(a, u8, &.{ q, c.name });
        try all.append(a, x);
    };
    for (list) |*rc| if (rc.* == .expr) {
        const x = &rc.expr;
        if (x.alias == null and x.e.kind == .column and x.e.kind.column.len == 2 and isMarker(x.e.kind.column[0].text)) x.alias = x.e.kind.column[1];
        try toHidden(a, x.e, name);
    };
    const args = try a.alloc(*tree.Expr, 1);
    args[0] = try tree.intConst(a, pos, slot);
    const f = try tree.new(a, tree.Func, .{ .name = .{ .text = try rows.moduleNameHidden(a, all.items, cols.len), .pos = pos }, .args = args });
    return .{ .source = .{ .func = f }, .alias = .{ .name = .{ .text = name, .pos = pos } } };
}

fn isMarker(q: []const u8) bool {
    for (parser.old_new_markers) |m| if (std.mem.eql(u8, q, m)) return true;
    return false;
}

/// `\x00old.a` made `name."old.a"` (targetItem()).
fn toHidden(a: Allocator, e: *tree.Expr, name: []const u8) error{OutOfMemory}!void {
    if (e.kind == .column) {
        const n = e.kind.column;
        if (n.len != 2 or !isMarker(n[0].text)) return;
        const m = try a.alloc(Name, 2);
        m[0] = .{ .text = name, .pos = n[0].pos };
        m[1] = .{ .text = try std.mem.concat(a, u8, &.{ n[0].text[1..], ".", n[1].text }), .pos = n[1].pos };
        e.kind = .{ .column = m };
        return;
    }
    var it = @import("jtype.zig").Children.of(e);
    while (it.next()) |c| try toHidden(a, c, name);
}

fn usesOldNew(list: []const tree.ResultCol) [2]bool {
    var out = [2]bool{ false, false };
    for (list) |rc| if (rc == .expr) markOldNew(rc.expr.e, &out);
    return out;
}

fn markOldNew(e: *tree.Expr, out: *[2]bool) void {
    if (e.kind == .column) {
        const n = e.kind.column;
        if (n.len == 2) for (parser.old_new_markers, 0..) |m, k| {
            if (std.mem.eql(u8, n[0].text, m)) out[k] = true;
        };
        return;
    }
    var it = @import("jtype.zig").Children.of(e);
    while (it.next()) |c| markOldNew(c, out);
}

/// The target's columns as a list, quoted.
fn colList(a: Allocator, cols: []const rows.Col) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cols, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "{f}", .{Quoted{ .z = c.name }});
    }
    return out.items;
}

/// The largest $N of the statement: the statements of the steps take
/// the statement's parameters (rows.zig), which must have them.
fn maxParam(ps: *Parser) u32 {
    var n: u32 = 0;
    for (ps.c.src.toks) |t| if (t.kind == .param) {
        const x = std.fmt.parseInt(u32, ps.val(t), 10) catch continue;
        n = @max(n, x);
    };
    return n;
}

// ============================================================== MERGE

/// The steps of MERGE `m` in `plan`, and the query of its RETURNING
/// (null without one).
pub fn merge(ps: *Parser, m: *Merge, plan: *Plan) Error!?tree.Stmt {
    plan.counts = true;
    return mergeIn(ps, m, plan, m.with, m.with_text);
}

/// merge() under the WITH queries `scope` (`with_text` their text before
/// the statement's join).
fn mergeIn(ps: *Parser, m: *Merge, plan: *Plan, scope: ?*tree.With, with_text: []const u8) Error!?tree.Stmt {
    const p = ps.p.?;
    const db = p.db;
    const a = ps.arena;
    const pos = m.pos;
    const tgt = try target(ps, m.target, true);
    plan.write_mask |= @as(u32, 1) << @intCast(tgt.i_db);

    // The source's columns.
    const star = try a.alloc(tree.ResultCol, 1);
    star[0] = .{ .star = pos };
    const from = try a.alloc(tree.FromItem, 1);
    from[0] = m.source;
    const src_probe = try selectOf(a, star, from, pos);
    src_probe.with = scope;
    const src_cols = try probe(ps, src_probe);

    // What a WHEN clause may not name: the source in a WHEN NOT MATCHED
    // BY SOURCE, the target in a WHEN NOT MATCHED (its condition and
    // values).
    for (m.clauses) |c| {
        const other = switch (c.kind) {
            .matched => continue,
            .by_source => m.source_alias,
            .not_matched => m.alias,
        };
        if (other.len == 0) continue;
        if (c.cond_text) |t| try noReference(ps, t, other);
        switch (c.action) {
            .update => |t| try noReference(ps, t, other),
            .insert => |ins| if (ins.values) |vals| for (vals) |v| try noReference(ps, v.text, other),
            else => {},
        }
    }

    const talias = try quoted(a, m.alias);
    const salias_name = if (m.source_alias.len > 0) m.source_alias else "xq_source";
    const salias = try quoted(a, salias_name);
    if (tgt.view) |vw| try viewChecks(ps, m, tgt, vw);

    // The target as the join reads it and its rows' rowid there; as the
    // statements of the actions write it, the name its columns have
    // there and its rowid. A view is read as its query with its table's
    // rowid (View.rows_sql); its table is written.
    var tfrom = try std.fmt.allocPrint(a, "{s} AS {s}", .{ m.target_text, talias });
    var trid = try std.fmt.allocPrint(a, "{s}.rowid", .{talias});
    var ttext = m.target_text;
    var tname = talias;
    if (tgt.view) |vw| {
        // Not automatically updatable (DO NOTHING only): no rowid.
        const q = if (vw.why == null) vw.rows_sql else try std.fmt.allocPrint(a, "SELECT *, 0 AS \"xq_rid\" FROM {s}", .{m.target_text});
        tfrom = try std.fmt.allocPrint(a, "({s}) AS {s}", .{ q, talias });
        trid = try std.fmt.allocPrint(a, "{s}.\"xq_rid\"", .{talias});
        ttext = vw.base_text;
        tname = vw.qual;
    }

    // 1. The join.
    var has_not_matched = false;
    var has_by_source = false;
    for (m.clauses) |c| switch (c.kind) {
        .matched => {},
        .not_matched => has_not_matched = true,
        .by_source => has_by_source = true,
    };
    var case: std.ArrayList(u8) = .empty;
    try case.appendSlice(a, "CASE");
    const kinds = .{ .{ .matched, "{s} IS NOT NULL AND {s}.\"xq_m\" IS NOT NULL" }, .{ .not_matched, "{s}.\"xq_m\" IS NOT NULL" }, .{ .by_source, "{s} IS NOT NULL" } };
    inline for (kinds) |k| {
        var inner: std.ArrayList(u8) = .empty;
        for (m.clauses, 1..) |c, n| if (c.kind == k[0]) {
            try inner.print(a, " WHEN ({s}) THEN {d}", .{ c.cond_text orelse "true", n });
        };
        if (inner.items.len > 0) {
            try case.appendSlice(a, " WHEN ");
            switch (k[0]) {
                .matched => try case.print(a, k[1], .{ trid, salias }),
                .not_matched => try case.print(a, k[1], .{salias}),
                .by_source => try case.print(a, k[1], .{trid}),
                else => unreachable,
            }
            try case.print(a, " THEN CASE{s} END", .{inner.items});
        }
    }
    try case.appendSlice(a, " END");
    if (case.items.len == "CASE END".len) case.items = try a.dupe(u8, "NULL");
    const join = if (has_by_source) "FULL JOIN" else if (has_not_matched) "RIGHT JOIN" else "JOIN";
    const join_slot = try plan.slot(a, db);
    try plan.steps.append(a, .{
        .kind = .join,
        .a = join_slot,
        .b = @intCast(src_cols.len),
        .sql = try std.fmt.allocPrint(a, "{s}SELECT {s}, {s}, {s}.* FROM {s} {s} (SELECT *, true AS \"xq_m\" FROM {s}) AS {s} ON {s}", .{
            with_text, trid, case.items, salias, tfrom, join, m.source_text, salias, m.on_text,
        }),
        .label = "MERGE: join of the target and the source",
    });

    // 2. A target's row changed twice.
    var twice: std.ArrayList(u8) = .empty;
    for (m.clauses, 1..) |c, n| if (c.kind == .matched and c.action != .nothing) {
        if (twice.items.len > 0) try twice.append(a, ',');
        try twice.print(a, "{d}", .{n});
    };
    if (twice.items.len > 0) try plan.steps.append(a, .{ .kind = .twice, .a = join_slot, .sql = twice.items });

    // 3. The actions.
    const ret_slot: ?u32 = if (m.returning.len > 0) try plan.slot(a, db) else null;
    // What the statements return of each row they change (the rowid an
    // UPDATE's row had: an UPDATE of an INTEGER PRIMARY KEY moves it).
    var returning: []const u8 = "";
    var upd_returning: []const u8 = "";
    if (ret_slot != null) {
        // A view's columns of the table's row: its query's expressions,
        // over the table named as there.
        const cols = if (tgt.view) |vw| blk: {
            const uses = usesOldNew(m.returning);
            if (uses[0] or uses[1]) return ps.unsupported(m.returning_pos, "RETURNING OLD or NEW of MERGE into a view");
            break :blk try std.mem.join(a, ", ", vw.exprs);
        } else try capture(a, tgt.cols);
        returning = try std.fmt.allocPrint(a, " RETURNING {s}, rowid", .{cols});
        upd_returning = try std.fmt.allocPrint(a, " RETURNING {s}, old.rowid", .{cols});
    }
    const join_rows = try rows.moduleName(a, src_cols);
    const join_from = try std.fmt.allocPrint(a, "{f}({d}) AS {s}", .{ Quoted{ .z = join_rows }, join_slot, salias });
    for (m.clauses, 1..) |c, n| {
        var step: rows.Step = .{ .kind = .action, .a = join_slot, .b = @intCast(n), .c = if (ret_slot) |r| r else -1 };
        switch (c.action) {
            .nothing => continue,
            .update => |set| if (tgt.view) |vw| {
                step.d = 2;
                step.sql = try viewUpdate(ps, m, c, n, tgt, vw, plan, .{
                    .with_text = with_text,
                    .join_slot = join_slot,
                    .join_from = join_from,
                    .src_cols = src_cols,
                    .salias = salias,
                    .salias_name = salias_name,
                    .talias = talias,
                    .returning = upd_returning,
                });
            } else {
                step.d = 2;
                step.sql = try std.fmt.allocPrint(a, "{s}UPDATE {s} AS {s} SET {s} FROM {s} WHERE {s}.xq_tag = {d} AND {s}.rowid = {s}.xq_target{s}", .{
                    with_text, m.target_text, talias, set, join_from, salias, n, talias, salias, upd_returning,
                });
            },
            .delete => {
                step.d = 3;
                step.sql = try std.fmt.allocPrint(a, "{s}DELETE FROM {s} AS {s} WHERE {s}.rowid IN (SELECT xq_target FROM {f}({d}) WHERE xq_tag = {d}){s}", .{
                    with_text, ttext, tname, tname, Quoted{ .z = join_rows }, join_slot, n, returning,
                });
            },
            .insert => |ins| {
                step.d = 1;
                var cols: std.ArrayList(u8) = .empty;
                var vals: std.ArrayList(u8) = .empty;
                if (ins.values) |values| {
                    // The columns given, else the leading ones an INSERT
                    // may assign.
                    var names: std.ArrayList([]const u8) = .empty;
                    if (ins.cols.len > 0) {
                        for (ins.cols) |x| try names.append(a, x.text);
                    } else if (tgt.view != null) {
                        for (tgt.cols) |vc| try names.append(a, vc.name);
                    } else for (tgt.tab.cols) |*tc| {
                        if (!tc.col_flags.intersects(int.COLFLAG.NOINSERT)) try names.append(a, tc.name());
                    }
                    // A view's columns are its table's (viewChecks()).
                    if (tgt.view) |vw| for (names.items) |*x| {
                        if (viewCol(tgt, x.*)) |k| if (vw.base_cols[k]) |bc| {
                            x.* = bc;
                        };
                    };
                    if (values.len > names.items.len) {
                        return ps.c.failState(c.pos, .of("42601"), "INSERT has more expressions than target columns", .{});
                    }
                    if (ins.cols.len > 0 and values.len < names.items.len) {
                        return ps.c.failState(c.pos, .of("42601"), "INSERT has more target columns than expressions", .{});
                    }
                    for (values, 0..) |v, k| {
                        if (v.default) continue;
                        if (cols.items.len > 0) {
                            try cols.appendSlice(a, ", ");
                            try vals.appendSlice(a, ", ");
                        }
                        try cols.print(a, "{f}", .{Quoted{ .z = names.items[k] }});
                        try vals.appendSlice(a, v.text);
                    }
                }
                const into = if (tgt.view != null) try std.fmt.allocPrint(a, "{s} AS {s}", .{ ttext, tname }) else m.target_text;
                if (cols.items.len == 0) {
                    step.e = 1;
                    step.sql = try std.fmt.allocPrint(a, "{s}INSERT INTO {s} {s} DEFAULT VALUES{s}", .{ with_text, into, ins.overriding, returning });
                } else {
                    step.sql = try std.fmt.allocPrint(a, "{s}INSERT INTO {s} ({s}) {s} SELECT {s} FROM {s} WHERE {s}.xq_tag = {d} ORDER BY {s}.rowid{s}", .{
                        with_text, into, cols.items, ins.overriding, vals.items, join_from, salias, n, salias, returning,
                    });
                }
            },
        }
        step.label = try std.fmt.allocPrint(a, "MERGE: WHEN clause {d}: {s}", .{ n, actionWord(c.action) });
        try plan.steps.append(a, step);
    }

    // The parameters, for the statements of the steps.
    const np = maxParam(ps);
    if (np > p.n_var) p.n_var = @intCast(np);

    const r = ret_slot orelse {
        // No query: the slots are freed now.
        for (plan.slots.items) |id| try plan.steps.append(a, .{ .kind = .free, .a = id });
        plan.slots.clearRetainingCapacity();
        return null;
    };
    try plan.steps.append(a, .{ .kind = .sort, .a = r });

    // 4. The query of RETURNING: `*` is the source's columns, then the
    // target's.
    var list: std.ArrayList(tree.ResultCol) = .empty;
    for (m.returning) |rc| switch (rc) {
        .star => |at| {
            const sn = try a.alloc(Name, 1);
            sn[0] = .{ .text = salias_name, .pos = at };
            const tn = try a.alloc(Name, 1);
            tn[0] = .{ .text = m.alias, .pos = at };
            try list.append(a, .{ .table_star = .{ .names = sn, .star_pos = at } });
            try list.append(a, .{ .table_star = .{ .names = tn, .star_pos = at } });
        },
        .expr => |x| {
            var y = x;
            // merge_action(): a column named after the call.
            if (y.alias == null and y.e.kind == .column) if (y.name) |n| {
                y.alias = .{ .text = n, .pos = y.e.pos };
            };
            try list.append(a, .{ .expr = y });
        },
        else => try list.append(a, rc),
    };
    var items: std.ArrayList(tree.FromItem) = .empty;
    try items.append(a, try targetItem(a, tgt.cols, r, m.alias, pos, list.items));
    var src_item = try rowsItem(a, src_cols, join_slot, salias_name, pos);
    src_item.join = .left;
    src_item.on = try tree.expr(a, pos, pos, .{ .compare = .{
        .op = .eq,
        .l = try column(a, pos, &.{ salias_name, "rowid" }),
        .r = try column(a, pos, &.{ m.alias, "xq_key" }),
    } });
    try items.append(a, src_item);
    return .{ .select = try selectOf(a, list.items, items.items, m.returning_pos) };
}

// ======================================================= MERGE INTO view

/// The place of column `name` among the target's (a view's) columns.
fn viewCol(tgt: Target, name: []const u8) ?usize {
    for (tgt.cols, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
    return null;
}

/// PostgreSQL's errors of a MERGE a view cannot take, in its order: the
/// columns it has not (parse analysis), then those of rewriteTargetView():
/// a view not automatically updatable (the first action's), one of no
/// updatable columns (the first INSERT's or UPDATE's), the columns an
/// INSERT assigns, then those an UPDATE does, that are not the table's.
fn viewChecks(ps: *Parser, m: *const Merge, tgt: Target, vw: *const View) Error!void {
    const a = ps.arena;
    const n_cols = tgt.cols.len;
    const ins_cols = try a.alloc(bool, n_cols);
    const upd_cols = try a.alloc(bool, n_cols);
    @memset(ins_cols, false);
    @memset(upd_cols, false);
    for (m.clauses) |c| switch (c.action) {
        .update => for (c.sets) |si| for (si.cols) |col| {
            upd_cols[viewCol(tgt, col.text) orelse return noViewColumn(ps, col, vw.name)] = true;
        },
        .insert => |ins| {
            for (ins.cols) |col| ins_cols[viewCol(tgt, col.text) orelse return noViewColumn(ps, col, vw.name)] = true;
            const vals = ins.values orelse continue;
            if (ins.cols.len == 0) {
                if (vals.len > n_cols) return ps.c.failState(c.pos, .of("42601"), "INSERT has more expressions than target columns", .{});
                for (ins_cols[0..vals.len]) |*x| x.* = true;
            }
        },
        else => {},
    };
    if (vw.why) |why| {
        for (m.clauses) |c| if (c.action != .nothing) return notUpdatable(ps, c, vw.name, why);
        return;
    }
    for (m.clauses) |c| if ((c.action == .insert or c.action == .update) and !vw.updatable())
        return notUpdatable(ps, c, vw.name, .no_columns);
    for ([_][]const bool{ ins_cols, upd_cols }) |set| for (set, vw.base_cols, tgt.cols) |used, bc, col| {
        if (used and bc == null) return ps.failFields(null, .of("0A000"), .{
            .message = try std.fmt.allocPrint(a, "cannot merge into column \"{s}\" of view \"{s}\"", .{ col.name, vw.name }),
            .detail = "View columns that are not columns of their base relation are not updatable.",
        });
    };
}

fn noViewColumn(ps: *Parser, col: Name, view: []const u8) Error {
    return ps.c.failState(col.pos, .of("42703"), "column \"{s}\" of relation \"{s}\" does not exist", .{ col.text, view });
}

fn notUpdatable(ps: *Parser, c: Clause, view: []const u8, why: NotUpdatable) Error {
    const a = ps.arena;
    const verb, const ing = switch (c.action) {
        .insert => .{ "insert into", "inserting into" },
        .update => .{ "update", "updating" },
        else => .{ "delete from", "deleting from" },
    };
    return ps.failFields(null, .of("55000"), .{
        .message = try std.fmt.allocPrint(a, "cannot {s} view \"{s}\"", .{ verb, view }),
        .detail = why.detail(),
        .hint = try std.fmt.allocPrint(a, "To enable {s} the view using MERGE, provide an INSTEAD OF {s} trigger.", .{ ing, actionWord(c.action) }),
    });
}

/// The keyword of the statement an action (a MERGE clause's, a
/// data-modifying CTE's) is: INSERT, UPDATE, else DELETE.
fn actionWord(action: anytype) []const u8 {
    return switch (action) {
        .insert => "INSERT",
        .update => "UPDATE",
        else => "DELETE",
    };
}

/// What viewUpdate() takes of mergeIn().
const JoinInfo = struct {
    with_text: []const u8,
    join_slot: u32,
    join_from: []const u8,
    src_cols: []const rows.Col,
    salias: []const u8,
    salias_name: []const u8,
    talias: []const u8,
    returning: []const u8,
};

/// WHEN clause `n` (`c`, an UPDATE) of a MERGE into view `vw`: a step
/// computing the new values of the rows of the join that take it (the
/// SET list's expressions, which read the view's columns and the
/// source's, as PostgreSQL's do), kept in a slot of their own; the
/// statement returned updates the table's rows from them.
fn viewUpdate(ps: *Parser, m: *const Merge, c: Clause, n: usize, tgt: Target, vw: *const View, plan: *Plan, j: JoinInfo) Error![]const u8 {
    const a = ps.arena;
    const db = ps.p.?.db;
    var vcols: std.ArrayList(rows.Col) = .empty;
    try vcols.append(a, .{ .name = "xq_rid" });
    var exprs: std.ArrayList(*tree.Expr) = .empty;
    var select: std.ArrayList(u8) = .empty;
    var assigns: std.ArrayList(u8) = .empty;
    for (c.sets) |si| {
        const one = try a.alloc(*tree.Expr, 1);
        one[0] = si.value;
        const values: []*tree.Expr = if (!si.multi) one else switch (si.value.kind) {
            .row => |r| r,
            else => return ps.unsupported(si.value.pos, "assigning a subquery to columns of a view"),
        };
        if (values.len != si.cols.len) return ps.c.failState(si.value.pos, .of("42601"), "number of columns does not match number of values", .{});
        for (si.cols, values) |col, e| {
            const bc = vw.base_cols[viewCol(tgt, col.text).?].?;
            if (assigns.items.len > 0) try assigns.appendSlice(a, ", ");
            if (e.kind == .default) {
                // The view's column has no default (PostgreSQL's
                // rewriteTargetListIU() for an UPDATE).
                try assigns.print(a, "{f} = NULL", .{Quoted{ .z = bc }});
                continue;
            }
            // col[i] = v (parser.zig's setList(): no text of its own).
            if (e.pos < col.pos + col.text.len) return ps.unsupported(col.pos, "assigning to an element of a column of a view");
            try select.print(a, ", ({s})", .{ps.c.sql[e.pos..e.end]});
            try assigns.print(a, "{f} = \"xq_u\".\"xq_v{d}\"", .{ Quoted{ .z = bc }, vcols.items.len });
            try vcols.append(a, .{ .name = try std.fmt.allocPrint(a, "xq_v{d}", .{vcols.items.len}) });
            try exprs.append(a, e);
        }
    }
    // The types of the values: those of the expressions where they have
    // one (an UPDATE checks them as its own). A value of none (a literal,
    // a parameter, NULL, an expression the core does not type) is text
    // in the slot: the UPDATE stores a value of a type known as it would
    // store that value (typing.Store.pick(): text and no type go through
    // the same conversion, a literal's), where one of no type would go
    // through what a value of any type does (Store.untyped(): into a
    // text column, a numeric's text_store, which reads 'abc' as a
    // number).
    if (exprs.items.len > 0) {
        const list = try a.alloc(tree.ResultCol, exprs.items.len);
        for (exprs.items, list) |e, *rc| rc.* = .{ .expr = .{ .e = e } };
        const from = try a.alloc(tree.FromItem, 2);
        from[0] = try rowsItem(a, j.src_cols, j.join_slot, j.salias_name, m.pos);
        from[1] = .{ .join = .comma, .source = .{ .table = m.target }, .alias = .{ .name = .{ .text = m.alias, .pos = m.pos } } };
        const literal = try a.alloc(bool, exprs.items.len);
        for (exprs.items, literal) |e, *l| l.* = switch (e.kind) {
            .string, .param, .null => true,
            else => false,
        };
        const probed = try probe(ps, try selectOf(a, list, from, m.pos));
        for (probed, vcols.items[1..], literal) |t, *vc, lit| {
            if (lit or t.spelling.len == 0 or t.type.logical == .unknown or std.mem.eql(u8, t.spelling, "unknown")) {
                vc.spelling = "text";
                vc.type = .{ .logical = .text };
                continue;
            }
            vc.spelling = t.spelling;
            vc.type = t.type;
        }
    }
    const vslot = try plan.slot(a, db);
    try plan.steps.append(a, .{
        .kind = .run,
        .a = vslot,
        .sql = try std.fmt.allocPrint(a, "{s}SELECT {s}.xq_target{s} FROM {s} JOIN ({s}) AS {s} ON {s}.\"xq_rid\" = {s}.xq_target WHERE {s}.xq_tag = {d}", .{
            j.with_text, j.salias, select.items, j.join_from, vw.rows_sql, j.talias, j.talias, j.salias, j.salias, n,
        }),
        .label = try std.fmt.allocPrint(a, "MERGE: WHEN clause {d}: new values", .{n}),
    });
    return std.fmt.allocPrint(a, "{s}UPDATE {s} AS {s} SET {s} FROM {f}({d}) AS \"xq_u\" WHERE {s}.rowid = \"xq_u\".\"xq_rid\"{s}", .{
        j.with_text, vw.base_text, vw.qual, assigns.items, Quoted{ .z = try rows.moduleName(a, vcols.items) }, vslot, vw.qual, j.returning,
    });
}

// ======================================================== WITH ... DML

fn noReturning(ps: *Parser, at: u32, name: []const u8) Error {
    return ps.c.failState(at, .of("0A000"), "WITH query \"{s}\" does not have a RETURNING clause", .{name});
}

/// Where the statement whose WITH is `w` reads the relation `name` in a
/// FROM clause (ps.main: the statement).
fn mainRefersTo(ps: *Parser, w: *const tree.With, name: []const u8) Error!?u32 {
    const st = ps.main orelse return null;
    _ = w;
    return switch (st) {
        .select => |x| refersTo(x, name),
        .insert => |x| if (x.source) |src| refersTo(src, name) else null,
        .update => |x| itemsRefer(x.from, name),
        .delete => |x| itemsRefer(x.using, name),
        else => null,
    };
}

/// Where query `s` reads the relation `name` (unqualified) in a FROM
/// clause, its subqueries' included (not those of expressions).
fn refersTo(s: *const tree.Select, name: []const u8) ?u32 {
    return bodyRefers(s.body, name);
}

fn bodyRefers(b: *const tree.Body, name: []const u8) ?u32 {
    return switch (b.*) {
        .core => |c| itemsRefer(c.from, name),
        .values => null,
        .compound => |c| bodyRefers(c.left, name) orelse bodyRefers(c.right, name),
        .nested => |n| refersTo(n, name),
    };
}

fn itemsRefer(items: []const tree.FromItem, name: []const u8) ?u32 {
    for (items) |it| switch (it.source) {
        .table => |q| if (q.schema == null and std.mem.eql(u8, q.name.text, name)) return q.name.pos,
        .subquery => |sq| if (refersTo(sq, name)) |at| return at,
        .nested => |n| if (itemsRefer(n, name)) |at| return at,
        .func => {},
    };
    return null;
}

/// The WITH of `stmt`, if it has a data-modifying statement.
pub fn dmlWith(stmt: tree.Stmt) ?*tree.With {
    const w = switch (stmt) {
        .select => |s| s.with,
        .insert => |s| s.with,
        .update => |s| s.with,
        .delete => |s| s.with,
        else => null,
    } orelse return null;
    for (w.ctes) |c| if (c.dml != null) return w;
    return null;
}

/// The steps of the data-modifying statements of `w` in `plan`, each
/// CTE's query made the query of the rows it returns.
pub fn with(ps: *Parser, w: *tree.With, plan: *Plan) Error!void {
    const p = ps.p.?;
    const db = p.db;
    const a = ps.arena;
    // The WITH queries before each statement, as written (a
    // data-modifying one as its query).
    var prefix: std.ArrayList([]const u8) = .empty;
    for (w.ctes, 0..) |*cte, ci| {
        const d = cte.dml orelse {
            try prefix.append(a, cte.text);
            continue;
        };
        const head = if (prefix.items.len > 0)
            try std.fmt.allocPrint(a, "WITH {s}{s} ", .{ if (w.recursive) "RECURSIVE " else "", try std.mem.join(a, ", ", prefix.items) })
        else
            "";
        if (d.* == .begin) {
            // MERGE: its steps, under the queries before it; its query the
            // CTE's (not one the statements after it can read).
            const m = ps.merge_ctes.get(cte.name.pos).?;
            const scope: ?*tree.With = if (ci == 0) null else try tree.new(a, tree.With, .{ .recursive = w.recursive, .ctes = w.ctes[0..ci] });
            const q = try mergeIn(ps, m, plan, scope, head);
            cte.select = if (q) |x| x.select else try placeholder(a, cte.name.pos);
            cte.dml = null;
            continue;
        }
        const q, const alias, const returning: []const tree.ResultCol, const ret_pos = switch (d.*) {
            .insert => |x| .{ x.table, x.alias, x.returning, x.returning_pos },
            .update => |x| .{ x.table, x.alias, x.returning, x.returning_pos },
            .delete => |x| .{ x.table, x.alias, x.returning, x.returning_pos },
            else => unreachable,
        };
        const tgt = try target(ps, q, false);
        plan.write_mask |= @as(u32, 1) << @intCast(tgt.i_db);
        const name = if (alias) |n| n.text else q.name.text;
        const pos = cte.name.pos;
        const label = try std.fmt.allocPrint(a, "WITH {s}: {s}", .{ cte.name.text, actionWord(d.*) });
        if (returning.len == 0) {
            // Its query may not be read.
            for (w.ctes[ci + 1 ..]) |later| if (later.dml == null) if (refersTo(later.select, cte.name.text)) |at| return noReturning(ps, at, cte.name.text);
            if (try mainRefersTo(ps, w, cte.name.text)) |at| return noReturning(ps, at, cte.name.text);
            try plan.steps.append(a, .{ .kind = .run, .sql = try std.fmt.allocPrint(a, "{s}{s}", .{ head, cte.body }), .label = label });
            // Its query: no rows (PostgreSQL refuses to read it).
            const slot = try plan.slot(a, db);
            const star = try a.alloc(tree.ResultCol, 1);
            star[0] = .{ .star = pos };
            const from = try a.alloc(tree.FromItem, 1);
            from[0] = try rowsItem(a, tgt.cols, slot, name, pos);
            cte.select = try selectOf(a, star, from, pos);
            cte.dml = null;
            try prefix.append(a, try std.fmt.allocPrint(a, "{f} AS (SELECT * FROM {f}({d}) AS {f})", .{ Quoted{ .z = cte.name.text }, Quoted{ .z = try rows.moduleName(a, tgt.cols) }, slot, Quoted{ .z = name } }));
            continue;
        }
        // The statement without its RETURNING, returning the target's
        // columns.
        const body_start = @intFromPtr(cte.body.ptr) - @intFromPtr(ps.c.sql.ptr);
        const stmt_text = std.mem.trimEnd(u8, ps.c.sql[body_start..ret_pos], " \t\r\n");
        const ret_text = ps.c.sql[ret_pos + "returning".len .. body_start + cte.body.len];
        const slot = try plan.slot(a, db);
        try plan.steps.append(a, .{
            .kind = .run,
            .a = slot,
            .sql = try std.fmt.allocPrint(a, "{s}{s} RETURNING {s}", .{ head, stmt_text, try capture(a, tgt.cols) }),
            .label = label,
        });
        const from = try a.alloc(tree.FromItem, 1);
        from[0] = try targetItem(a, tgt.cols, slot, name, pos, @constCast(returning));
        cte.select = try selectOf(a, @constCast(returning), from, pos);
        cte.dml = null;
        var text: std.ArrayList(u8) = .empty;
        try text.print(a, "{f}", .{Quoted{ .z = cte.name.text }});
        if (cte.cols.len > 0) {
            try text.append(a, '(');
            for (cte.cols, 0..) |c, i| {
                if (i > 0) try text.appendSlice(a, ", ");
                try text.print(a, "{f}", .{Quoted{ .z = c.text }});
            }
            try text.append(a, ')');
        }
        try text.print(a, " AS (SELECT {s} FROM {f}({d}) AS {f})", .{ ret_text, Quoted{ .z = try rows.moduleName(a, tgt.cols) }, slot, Quoted{ .z = name } });
        try prefix.append(a, text.items);
    }
    const np = maxParam(ps);
    if (np > p.n_var) p.n_var = @intCast(np);
}

// ============================================================== tests

const testing = std.testing;
const Conn = @import("../../sql/sql_test.zig").Conn;

fn openPg(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .postgres);
}

test "pg: MERGE into a view" {
    try @import("../dialect.zig").Dialect.requireBuilt(&.{.postgres});
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE t (id int PRIMARY KEY, a int, note text DEFAULT 'n');
        \\INSERT INTO t VALUES (1, 10), (2, 2), (3, 30);
        \\CREATE VIEW v (k, x, x1) AS SELECT id, a, a + 1 FROM t WHERE a > 5;
    );
    // The rows the view's WHERE leaves out are not the target's; the
    // view's columns are the table's (renamed; computed ones read only).
    try c.expectRows(
        \\MERGE INTO v USING (VALUES (1, 5), (2, 7), (4, 40)) AS s(k, x) ON v.k = s.k
        \\WHEN MATCHED THEN UPDATE SET x = s.x + v.x1
        \\WHEN NOT MATCHED AND s.k = 2 THEN DO NOTHING
        \\WHEN NOT MATCHED THEN INSERT (k, x) VALUES (s.k, s.x)
        \\WHEN NOT MATCHED BY SOURCE THEN DELETE
        \\RETURNING merge_action(), s.k, v.*
    , "UPDATE|1|1|16|17\nDELETE|NULL|3|30|31\nINSERT|4|4|40|41\n");
    try c.expectRows("SELECT * FROM t ORDER BY id", "1|16|n\n2|2|n\n4|40|n\n");
    // An UPDATE of the key keeps RETURNING's source row.
    try c.expectRows("MERGE INTO v USING (VALUES (4, 'four')) AS s(k, name) ON v.k = s.k WHEN MATCHED THEN UPDATE SET k = 40 RETURNING s.name, v.k", "four|40\n");
    // PostgreSQL's errors.
    try c.expectError("MERGE INTO v USING (VALUES (1)) AS s(k) ON v.k = s.k WHEN MATCHED THEN UPDATE SET x1 = 1", "cannot merge into column \"x1\" of view \"v\"\nDETAIL:  View columns that are not columns of their base relation are not updatable.");
    try c.expectError("MERGE INTO v USING (VALUES (1)) AS s(k) ON v.k = s.k WHEN MATCHED THEN UPDATE SET note = 'x'", "column \"note\" of relation \"v\" does not exist");
    try c.exec("CREATE VIEW vd AS SELECT DISTINCT id FROM t");
    try c.expectError("MERGE INTO vd USING (VALUES (1)) AS s(k) ON vd.id = s.k WHEN MATCHED THEN DELETE", "cannot delete from view \"vd\"\nDETAIL:  Views containing DISTINCT are not automatically updatable.\nHINT:  To enable deleting from the view using MERGE, provide an INSTEAD OF DELETE trigger.");
    try c.exec("MERGE INTO vd USING (VALUES (1)) AS s(k) ON vd.id = s.k WHEN MATCHED THEN DO NOTHING");
    try c.exec("CREATE VIEW vv AS SELECT k FROM v");
    try c.expectError("MERGE INTO vv USING (VALUES (1)) AS s(k) ON vv.k = s.k WHEN MATCHED THEN DELETE", "MERGE into a view of a view is not supported");
}

test "pg: EXPLAIN MERGE and of a data-modifying WITH" {
    try @import("../dialect.zig").Dialect.requireBuilt(&.{.postgres});
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE t (id int PRIMARY KEY, a int);
        \\INSERT INTO t VALUES (1, 1);
        \\CREATE VIEW v AS SELECT id, a FROM t;
    );
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "EXPLAIN MERGE INTO t USING (VALUES (1, 2)) AS s(id, a) ON t.id = s.id WHEN MATCHED THEN DELETE WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.a)", &.{ "MERGE: join of the target and the source", "MERGE: WHEN clause 1: DELETE", "MERGE: WHEN clause 2: INSERT" } },
        .{ "EXPLAIN MERGE INTO v USING (VALUES (1, 2)) AS s(id, a) ON v.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a RETURNING *", &.{ "MERGE: WHEN clause 1: new values", "MERGE: WHEN clause 1: UPDATE" } },
        .{ "EXPLAIN WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", &.{"WITH d: DELETE"} },
    };
    for (cases) |x| {
        const got = try c.query(x[0]);
        defer testing.allocator.free(got);
        for (x[1]) |label| testing.expect(std.mem.indexOf(u8, got, label) != null) catch |err| {
            std.debug.print("{s}\n{s}\n", .{ x[0], got });
            return err;
        };
    }
    // Nothing ran.
    try c.expectRows("SELECT * FROM t", "1|1\n");
}
