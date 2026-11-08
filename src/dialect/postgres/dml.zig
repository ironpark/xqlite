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
const Quoted = @import("../dialect.zig").Quoted('"');
const parser = @import("parser.zig");
const rows = @import("rows.zig");

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
};

fn target(ps: *Parser, q: tree.QName) Error!Target {
    const p = ps.p.?;
    const a = ps.arena;
    try ps.readSchema();
    const t = build.findTable(p.db, q.name.text, if (q.schema) |s| s.text else null) orelse
        return ps.c.failState(q.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{q.name.text});
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

/// The names and types of the result columns of `s`, lowered and
/// resolved in a Parse of its own (its error the statement's).
fn probe(ps: *Parser, s: *tree.Select) Error![]rows.Col {
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
    const tgt = try target(ps, m.target);
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
    const kinds = .{ .{ .matched, "{s}.rowid IS NOT NULL AND {s}.\"xq_m\" IS NOT NULL" }, .{ .not_matched, "{s}.\"xq_m\" IS NOT NULL" }, .{ .by_source, "{s}.rowid IS NOT NULL" } };
    inline for (kinds) |k| {
        var inner: std.ArrayList(u8) = .empty;
        for (m.clauses, 1..) |c, n| if (c.kind == k[0]) {
            try inner.print(a, " WHEN ({s}) THEN {d}", .{ c.cond_text orelse "true", n });
        };
        if (inner.items.len > 0) {
            try case.appendSlice(a, " WHEN ");
            switch (k[0]) {
                .matched => try case.print(a, k[1], .{ talias, salias }),
                .not_matched => try case.print(a, k[1], .{salias}),
                .by_source => try case.print(a, k[1], .{talias}),
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
        .sql = try std.fmt.allocPrint(a, "{s}SELECT {s}.rowid, {s}, {s}.* FROM {s} AS {s} {s} (SELECT *, true AS \"xq_m\" FROM {s}) AS {s} ON {s}", .{
            with_text, talias, case.items, salias, m.target_text, talias, join, m.source_text, salias, m.on_text,
        }),
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
    const returning = if (ret_slot != null) try std.fmt.allocPrint(a, " RETURNING {s}, rowid", .{try capture(a, tgt.cols)}) else "";
    const join_rows = try rows.moduleName(a, src_cols);
    const join_from = try std.fmt.allocPrint(a, "{f}({d}) AS {s}", .{ Quoted{ .z = join_rows }, join_slot, salias });
    for (m.clauses, 1..) |c, n| {
        var step: rows.Step = .{ .kind = .action, .a = join_slot, .b = @intCast(n), .c = if (ret_slot) |r| r else -1 };
        switch (c.action) {
            .nothing => continue,
            .update => |set| {
                step.d = 2;
                step.sql = try std.fmt.allocPrint(a, "{s}UPDATE {s} AS {s} SET {s} FROM {s} WHERE {s}.xq_tag = {d} AND {s}.rowid = {s}.xq_target{s}", .{
                    with_text, m.target_text, talias, set, join_from, salias, n, talias, salias, returning,
                });
            },
            .delete => {
                step.d = 3;
                step.sql = try std.fmt.allocPrint(a, "{s}DELETE FROM {s} AS {s} WHERE {s}.rowid IN (SELECT xq_target FROM {f}({d}) WHERE xq_tag = {d}){s}", .{
                    with_text, m.target_text, talias, talias, Quoted{ .z = join_rows }, join_slot, n, returning,
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
                    } else for (tgt.tab.cols) |*tc| {
                        if (!tc.col_flags.intersects(int.COLFLAG.NOINSERT)) try names.append(a, tc.name());
                    }
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
                if (cols.items.len == 0) {
                    step.e = 1;
                    step.sql = try std.fmt.allocPrint(a, "{s}INSERT INTO {s} {s} DEFAULT VALUES{s}", .{ with_text, m.target_text, ins.overriding, returning });
                } else {
                    step.sql = try std.fmt.allocPrint(a, "{s}INSERT INTO {s} ({s}) {s} SELECT {s} FROM {s} WHERE {s}.xq_tag = {d} ORDER BY {s}.rowid{s}", .{
                        with_text, m.target_text, cols.items, ins.overriding, vals.items, join_from, salias, n, salias, returning,
                    });
                }
            },
        }
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
        const tgt = try target(ps, q);
        plan.write_mask |= @as(u32, 1) << @intCast(tgt.i_db);
        const name = if (alias) |n| n.text else q.name.text;
        const pos = cte.name.pos;
        if (returning.len == 0) {
            // Its query may not be read.
            for (w.ctes[ci + 1 ..]) |later| if (later.dml == null) if (refersTo(later.select, cte.name.text)) |at| return noReturning(ps, at, cte.name.text);
            if (try mainRefersTo(ps, w, cte.name.text)) |at| return noReturning(ps, at, cte.name.text);
            try plan.steps.append(a, .{ .kind = .run, .sql = try std.fmt.allocPrint(a, "{s}{s}", .{ head, cte.body }) });
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
