//! INSERT, UPDATE, DELETE, MERGE and TRUNCATE TABLE, as tree statements
//! that src/ir/lower.zig lowers.
//!
//!  - A value stored into a column of a T-SQL table is converted to the
//!    column's type as SQL Server converts it (xq_tsql_store(): rounding
//!    to a decimal's scale, bit's 0/1, a date's format, the errors of an
//!    out-of-range or too long value), unless it is a constant of the
//!    column's kind already.
//!  - Identity columns: an INSERT leaves them out (also without a column
//!    list); a value for one needs SET IDENTITY_INSERT t ON, and moves
//!    the identity on when it is past it (xq_tsql_identity_seen()).
//!  - OUTPUT INSERTED.* / DELETED.* is RETURNING (DELETED in an UPDATE,
//!    the old row, is not supported: RETURNING sees the new one).
//!  - UPDATE/DELETE ... FROM t JOIN u ON c: the target's item leaves the
//!    FROM list and its join condition goes to the WHERE (SQLite's UPDATE
//!    FROM, DELETE ... USING); the target may be named by its alias.
//!  - UPDATE TOP (n) / DELETE TOP (n): tree.Update/Delete.limit.
//!  - MERGE: a sequence of INSERT, UPDATE and DELETE in one statement
//!    (merge()).

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const session = @import("session.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;
const Target = Parser.Target;
const ColMeta = Parser.ColMeta;

/// `TOP (n) [PERCENT]` of INSERT/UPDATE/DELETE/MERGE.
fn dmlTop(s: *Parser) Error!?*Expr {
    if (!s.eatKw("TOP")) return null;
    try s.expectOp("(");
    const n = try s.expr();
    try s.expectOp(")");
    if (s.eatKw("PERCENT")) return s.fail("xqlite: TOP ... PERCENT in INSERT, UPDATE or DELETE is not supported", .{});
    return n;
}

/// The OUTPUT clause: INSERTED.* and DELETED.* are the target's columns.
fn output(s: *Parser, kind: parser.Output) Error![]tree.ResultCol {
    if (!s.eatKw("OUTPUT")) return &.{};
    const saved = s.output;
    s.output = kind;
    defer s.output = saved;
    var l: std.ArrayList(tree.ResultCol) = .empty;
    while (true) {
        if ((s.isKw("INSERTED") or s.isKw("DELETED")) and s.peek().is(".") and s.peek2().is("*")) {
            const ins = s.isKw("INSERTED");
            if ((ins and kind == .delete) or (!ins and kind == .insert)) return s.fail("The multi-part identifier \"{s}.*\" could not be bound.", .{s.tok.text});
            if (!ins and kind == .update) return s.fail("xqlite: OUTPUT DELETED in UPDATE is not supported (RETURNING sees the new row)", .{});
            s.advance();
            s.advance();
            try l.append(s.a, .{ .star = s.here() });
            s.advance();
        } else if (s.isKw("$ACTION")) {
            return s.fail("xqlite: OUTPUT $action is not supported", .{});
        } else {
            const e = try s.expr();
            var al: ?Name = null;
            if (s.eatKw("AS")) {
                al = try s.nameOf(try s.anyName());
            } else if (s.isName() and !s.isKw("INTO")) al = try s.nameOf(try s.name());
            const nm: ?[]const u8 = if (al != null or e.kind == .column) null else "";
            try l.append(s.a, .{ .expr = .{ .e = e, .alias = al, .name = nm } });
        }
        if (!s.eatOp(",")) break;
    }
    if (s.isKw("INTO")) return s.fail("xqlite: OUTPUT ... INTO is not supported", .{});
    return l.items;
}

/// Whether a constant can be stored in a column of type `t` as it is.
fn storesAsIs(e: *const Expr, t: types.Type) bool {
    return switch (e.kind) {
        .null, .default => true,
        .integer => |z| blk: {
            if (t.base == .float or t.base == .real) break :blk true;
            if (!t.isInteger()) break :blk false;
            const v = std.fmt.parseInt(i64, z, 10) catch break :blk false;
            const r = t.range() orelse break :blk true;
            break :blk v >= r[0] and v <= r[1];
        },
        .string => |z| t.isChar() and (if (t.maxLength()) |n| z.len <= n else true),
        else => false,
    };
}

/// The value `e` stored into column `c`: converted to its type, and an
/// explicit identity value moving the identity on.
fn wrapValue(s: *Parser, c: *const ColMeta, e: *Expr) Error!*Expr {
    var x = e;
    if (c.decl_type) |dt| {
        const t = types.parseText(dt);
        if (t == null or !storesAsIs(e, t.?)) {
            x = try tree.expr(s.a, e.pos, e.end, .{ .cast = .{ .e = x, .target_type = dt, .mode = .{ .typed = .{ .func = "xq_tsql_store", .type_arg = c.store_arg } } } });
        }
    }
    if (c.identity) |seq| x = try s.func(e.pos, "xq_tsql_identity_seen", &.{ try s.str(e.pos, seq), x });
    return x;
}

/// Whether SET IDENTITY_INSERT is on for the target.
fn identityInsertOn(s: *Parser, t: *const Target) Error!bool {
    const on = s.p.db.xq.mssql.identity_insert orelse return false;
    const key = try std.ascii.allocLowerString(s.a, try std.fmt.allocPrint(s.a, "{s}.{s}", .{ t.schema, t.name }));
    return std.mem.eql(u8, on, key);
}

/// The columns an INSERT without a column list fills.
fn insertColumns(s: *Parser, t: *const Target) Error![]*ColMeta {
    var out: std.ArrayList(*ColMeta) = .empty;
    for (t.cols) |*c| if (!c.generated and !c.hidden and c.identity == null) try out.append(s.a, c);
    return out.items;
}

const ColumnPlan = struct {
    names: []Name,
    cols: []?*ColMeta,
    overriding: bool,
};

/// The columns of an INSERT into `t`: `written` (null if none), checked
/// against the identity rules.
fn planColumns(s: *Parser, t: *const Target, written: ?[]Name) Error!ColumnPlan {
    const id = t.identity();
    const on = try identityInsertOn(s, t);
    var names: std.ArrayList(Name) = .empty;
    var cols: std.ArrayList(?*ColMeta) = .empty;
    if (written) |w| {
        var has_id = false;
        for (w) |n| {
            const c = t.findCol(n.text);
            if (c != null and c.?.identity != null) has_id = true;
            try names.append(s.a, n);
            try cols.append(s.a, c);
        }
        if (has_id and !on) return s.fail("Cannot insert explicit value for identity column in table '{s}' when IDENTITY_INSERT is set to OFF.", .{t.name});
        if (id != null and on and !has_id) return s.fail("Explicit value must be specified for identity column in table '{s}' either when IDENTITY_INSERT is set to ON or when a replication user is inserting into a NOT FOR REPLICATION identity column.", .{t.name});
        return .{ .names = names.items, .cols = cols.items, .overriding = has_id };
    }
    if (t.tab == null) return .{ .names = &.{}, .cols = &.{}, .overriding = false };
    if (id != null and on) return s.fail("An explicit value for the identity column in table '{s}' can only be specified when a column list is used and IDENTITY_INSERT is ON.", .{t.name});
    for (try insertColumns(s, t)) |c| {
        try names.append(s.a, .{ .text = c.name });
        try cols.append(s.a, c);
    }
    // Without an identity column, SQLite's own list is the same.
    if (id == null) return .{ .names = &.{}, .cols = cols.items, .overriding = false };
    return .{ .names = names.items, .cols = cols.items, .overriding = false };
}

/// [WITH ...] INSERT [TOP (n)] [INTO] t [(cols)] [OUTPUT ...]
/// {VALUES ... | query | DEFAULT VALUES}.
pub fn insert(s: *Parser, with: ?*tree.With) Error!tree.Stmt {
    const pos = s.here();
    try s.expectKw("INSERT");
    const top = try dmlTop(s);
    _ = s.eatKw("INTO");
    if (s.tok.kind == .variable) return s.fail("xqlite: table variables are not supported", .{});
    const q = try s.qualifiedName();
    try s.tableHints();
    const t = try s.target(q);
    var written: ?[]Name = null;
    if (s.isOp("(") and !s.peek().isAnyKw(&.{ "SELECT", "WITH" })) written = try s.nameList();
    const plan = try planColumns(s, &t, written);
    const ret = try output(s, .insert);

    var source: ?*tree.Select = null;
    if (s.isKw("VALUES")) {
        const saved = s.allow_default;
        s.allow_default = true;
        const vpos = s.here();
        const rows = try s.valuesRows();
        s.allow_default = saved;
        for (rows) |*row| {
            if (plan.cols.len > 0 and row.len != plan.cols.len) {
                return s.fail("There are {s} columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.", .{if (row.len < plan.cols.len) "more" else "fewer"});
            }
            var out: std.ArrayList(*Expr) = .empty;
            for (row.*, 0..) |e, i| {
                const c: ?*ColMeta = if (i < plan.cols.len) plan.cols[i] else null;
                try out.append(s.a, if (c) |cm| try wrapValue(s, cm, e) else e);
            }
            row.* = out.items;
        }
        source = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .values = rows }), .pos = vpos });
        if (top != null) return s.fail("xqlite: INSERT TOP with VALUES is not supported", .{});
    } else if (s.eatKw("DEFAULT")) {
        try s.expectKw("VALUES");
        if (written != null) return s.syntaxError();
        return .{ .insert = try s.new(tree.Insert, .{ .with = with, .table = q, .source = null, .returning = ret, .pos = pos }) };
    } else if (s.isSelectStart()) {
        var sel = try s.subSelect();
        if (top) |n| {
            const inner = sel;
            const from = try s.a.dupe(tree.FromItem, &.{.{ .source = .{ .subquery = inner } }});
            const core = try s.new(tree.Core, .{ .cols = try s.a.dupe(tree.ResultCol, &.{.{ .star = inner.pos }}), .from = from, .pos = inner.pos });
            sel = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = core }), .limit = n, .pos = inner.pos });
        }
        source = try wrapSelect(s, plan.cols, sel);
    } else if (s.isKw("EXEC") or s.isKw("EXECUTE")) {
        return s.fail("xqlite: INSERT ... EXEC is not supported", .{});
    } else return s.syntaxError();

    return .{ .insert = try s.new(tree.Insert, .{
        .with = with,
        .table = q,
        .cols = plan.names,
        .source = source,
        .overriding = plan.overriding,
        .returning = ret,
        .pos = pos,
    }) };
}

/// INSERT ... SELECT with converted values: WITH xq_src(c1, ..., cn)
/// AS (sel) SELECT wrap(c1), ... FROM xq_src; `sel` itself if nothing
/// is converted.
fn wrapSelect(s: *Parser, cols: []const ?*ColMeta, sel: *tree.Select) Error!*tree.Select {
    var needed = false;
    for (cols) |c| if (c) |m| {
        if (m.decl_type != null or m.identity != null) needed = true;
    };
    if (!needed) return sel;
    const pos = sel.pos;
    var names: std.ArrayList(Name) = .empty;
    var out: std.ArrayList(tree.ResultCol) = .empty;
    for (cols, 0..) |c, i| {
        const n: Name = .{ .text = try std.fmt.allocPrint(s.a, "c{d}", .{i + 1}), .pos = pos };
        try names.append(s.a, n);
        const ref = try tree.expr(s.a, pos, pos, .{ .column = try s.a.dupe(Name, &.{n}) });
        try out.append(s.a, .{ .expr = .{ .e = if (c) |m| try wrapValue(s, m, ref) else ref } });
    }
    const src: Name = .{ .text = "xq_src", .pos = pos };
    const with = try s.new(tree.With, .{ .recursive = false, .ctes = try s.a.dupe(tree.Cte, &.{.{ .name = src, .cols = names.items, .select = sel }}) });
    const from = try s.a.dupe(tree.FromItem, &.{.{ .source = .{ .table = .{ .name = src } } }});
    const core = try s.new(tree.Core, .{ .cols = out.items, .from = from, .pos = pos });
    return s.new(tree.Select, .{ .with = with, .body = try s.new(tree.Body, .{ .core = core }), .pos = pos });
}

/// The target of UPDATE/DELETE as written (a table or the alias of an
/// item of the FROM clause).
const DmlTarget = struct { q: tree.QName, alias: ?Name = null };

/// The FROM clause of UPDATE/DELETE with the target's item taken out:
/// its join condition joins the WHERE.
const Joined = struct { target: DmlTarget, from: []tree.FromItem, cond: ?*Expr };

fn takeTarget(s: *Parser, written: tree.QName, items: []tree.FromItem) Error!Joined {
    var found: ?usize = null;
    if (written.schema == null) {
        for (items, 0..) |it, i| {
            const label: ?[]const u8 = if (it.alias) |a| a.name.text else if (it.source == .table) it.source.table.name.text else null;
            if (label) |l| if (std.ascii.eqlIgnoreCase(l, written.name.text)) {
                if (found != null) return s.fail("The table '{s}' is ambiguous.", .{written.name.text});
                found = i;
            };
        }
    } else {
        for (items, 0..) |it, i| {
            if (it.alias == null and it.source == .table and std.ascii.eqlIgnoreCase(it.source.table.name.text, written.name.text)) found = i;
        }
    }
    const i = found orelse return .{ .target = .{ .q = written }, .from = items, .cond = null };
    const item = items[i];
    if (item.source != .table) return s.fail("xqlite: an UPDATE or DELETE of a derived table is not supported", .{});
    var rest: std.ArrayList(tree.FromItem) = .empty;
    var cond: ?*Expr = null;
    for (items, 0..) |it, j| {
        if (j == i) continue;
        var x = it;
        // The item after the target joined the target.
        if (j == i + 1 and i == 0) {
            if (x.join == .left or x.join == .right or x.join == .full) return s.fail("xqlite: UPDATE or DELETE ... FROM with an outer join of the target is not supported", .{});
            if (x.on) |on| cond = on;
            x.on = null;
            x.join = .comma;
        }
        if (rest.items.len == 0) x.join = .none;
        try rest.append(s.a, x);
    }
    if (i > 0) {
        if (item.join == .left or item.join == .right or item.join == .full) return s.fail("xqlite: UPDATE or DELETE ... FROM with an outer join of the target is not supported", .{});
        cond = item.on;
    }
    return .{
        .target = .{ .q = item.source.table, .alias = if (item.alias) |a| a.name else null },
        .from = rest.items,
        .cond = cond,
    };
}

fn andOf(s: *Parser, a: ?*Expr, b: ?*Expr) Error!?*Expr {
    const x = a orelse return b;
    const y = b orelse return x;
    return try s.bin(.@"and", x, y);
}

/// `col = expr` assignments of UPDATE (and of MERGE's UPDATE): `t.col`
/// names the target, `col op= expr` is col = col op expr.
fn assignments(s: *Parser, t: *const Target, label: []const u8) Error![]tree.SetItem {
    var list: std.ArrayList(tree.SetItem) = .empty;
    const saved = s.allow_default;
    s.allow_default = true;
    defer s.allow_default = saved;
    while (true) {
        if (s.tok.kind == .variable) return s.fail("xqlite: assigning variables in UPDATE is not supported", .{});
        var c = try s.nameOf(try s.anyName());
        if (s.eatOp(".")) {
            if (!std.ascii.eqlIgnoreCase(c.text, label)) return s.fail("The multi-part identifier \"{s}\" could not be bound.", .{c.text});
            c = try s.nameOf(try s.anyName());
        }
        const op = s.tok;
        if (op.kind != .op or !(op.is("=") or (op.text.len == 2 and op.text[1] == '='))) return s.syntaxError();
        s.advance();
        var e = try s.expr();
        if (op.text.len == 2) {
            const ref = try tree.expr(s.a, c.pos, c.pos, .{ .column = try s.a.dupe(Name, &.{c}) });
            e = try s.compoundAssign(op.text[0], ref, e);
        }
        if (t.findCol(c.text)) |m| {
            if (m.identity != null) return s.fail("Cannot update identity column '{s}'.", .{m.name});
            if (m.decl_type) |dt| {
                const ty = types.parseText(dt);
                if (ty == null or !storesAsIs(e, ty.?)) {
                    e = try tree.expr(s.a, e.pos, e.end, .{ .cast = .{ .e = e, .target_type = dt, .mode = .{ .typed = .{ .func = "xq_tsql_store", .type_arg = m.store_arg } } } });
                }
            }
        }
        try list.append(s.a, .{ .cols = try s.a.dupe(Name, &.{c}), .value = e });
        if (!s.eatOp(",")) break;
    }
    return list.items;
}

/// [WITH ...] UPDATE [TOP (n)] t SET ... [OUTPUT ...] [FROM ...] [WHERE ...].
pub fn update(s: *Parser, with: ?*tree.With) Error!tree.Stmt {
    const pos = s.here();
    try s.expectKw("UPDATE");
    const top = try dmlTop(s);
    if (s.tok.kind == .variable) return s.fail("xqlite: table variables are not supported", .{});
    const written = try s.qualifiedName();
    try s.tableHints();
    try s.expectKw("SET");
    // The SET list names columns of the target, which FROM may define:
    // read ahead to the FROM clause.
    const set_lx = s.lx;
    const set_tok = s.tok;
    const set_prev = s.prev_end;
    try skipSet(s);
    _ = try output(s, .update);
    var from: []tree.FromItem = &.{};
    if (s.eatKw("FROM")) from = try s.tableRefs();
    const j = try takeTarget(s, written, from);
    const t = try s.target(j.target.q);
    const after_lx = s.lx;
    const after_tok = s.tok;
    const after_prev = s.prev_end;
    // Back to SET.
    s.lx = set_lx;
    s.tok = set_tok;
    s.prev_end = set_prev;
    const label = if (j.target.alias) |a| a.text else j.target.q.name.text;
    const sets = try assignments(s, &t, label);
    const ret = try output(s, .update);
    s.lx = after_lx;
    s.tok = after_tok;
    s.prev_end = after_prev;
    var where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
    where = try andOf(s, j.cond, where);
    try optionClause(s);
    {
        var items: std.ArrayList(tree.FromItem) = .empty;
        try items.append(s.a, .{ .source = .{ .table = j.target.q }, .alias = if (j.target.alias) |a| .{ .name = a } else null });
        try items.appendSlice(s.a, j.from);
        try @import("json_sql.zig").resolveKinds(s, 0, items.items);
    }
    if (s.n_plus > 0) {
        var items: std.ArrayList(tree.FromItem) = .empty;
        try items.append(s.a, .{ .source = .{ .table = j.target.q }, .alias = if (j.target.alias) |a| .{ .name = a } else null });
        try items.appendSlice(s.a, j.from);
        const scope = try s.fromScope(items.items);
        for (sets) |it| s.resolvePlus(it.value, scope);
        if (where) |w| s.resolvePlus(w, scope);
    }
    return .{ .update = try s.new(tree.Update, .{
        .with = with,
        .table = j.target.q,
        .alias = j.target.alias,
        .sets = sets,
        .from = j.from,
        .where = where,
        .limit = top,
        .returning = ret,
        .pos = pos,
    }) };
}

/// Skip the SET list (up to OUTPUT, FROM, WHERE, OPTION or the end).
fn skipSet(s: *Parser) Error!void {
    var depth: usize = 0;
    while (s.tok.kind != .eof) {
        if (depth == 0 and (s.isKw("OUTPUT") or s.isKw("FROM") or s.isKw("WHERE") or s.isKw("OPTION") or s.isOp(";") or s.tok.kind == .go)) return;
        if (depth == 0 and parser.startsStatement(s.tok) and !s.isKw("SELECT")) return;
        if (s.isOp("(")) depth += 1;
        if (s.isOp(")")) {
            if (depth == 0) return s.syntaxError();
            depth -= 1;
        }
        s.advance();
    }
}

fn optionClause(s: *Parser) Error!void {
    if (s.isKw("OPTION") and s.peek().is("(")) {
        s.advance();
        try s.skipParens();
    }
}

/// [WITH ...] DELETE [TOP (n)] [FROM] t [OUTPUT ...] [FROM ...] [WHERE ...].
pub fn delete(s: *Parser, with: ?*tree.With) Error!tree.Stmt {
    const pos = s.here();
    try s.expectKw("DELETE");
    const top = try dmlTop(s);
    _ = s.eatKw("FROM");
    if (s.tok.kind == .variable) return s.fail("xqlite: table variables are not supported", .{});
    const written = try s.qualifiedName();
    try s.tableHints();
    const ret = try output(s, .delete);
    var from: []tree.FromItem = &.{};
    if (s.eatKw("FROM")) from = try s.tableRefs();
    const j = try takeTarget(s, written, from);
    _ = try s.target(j.target.q);
    var where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
    where = try andOf(s, j.cond, where);
    try optionClause(s);
    return .{ .delete = try s.new(tree.Delete, .{
        .with = with,
        .table = j.target.q,
        .alias = j.target.alias,
        .using = j.from,
        .where = where,
        .limit = top,
        .returning = ret,
        .pos = pos,
    }) };
}

/// TRUNCATE TABLE t: DELETE FROM t, and the identity starts over.
pub fn truncate(s: *Parser) Error!tree.Stmt {
    try s.expectKw("TRUNCATE");
    try s.expectKw("TABLE");
    const q = try s.qualifiedName();
    if (s.isKw("WITH")) return s.fail("xqlite: TRUNCATE TABLE ... WITH (PARTITIONS) is not supported", .{});
    return .{ .truncate = try s.new(tree.Truncate, .{ .table = q, .restart_identity = true }) };
}

// ================================================================ MERGE

const Action = union(enum) {
    update: []tree.SetItem,
    delete,
    insert: struct { cols: ?[]Name, values: []*Expr },
};

const Clause = struct { cond: ?*Expr, action: Action };

/// MERGE [INTO] target [[AS] t] USING source [[AS] s] ON cond
/// WHEN MATCHED [AND c] THEN UPDATE SET ... | DELETE (up to two),
/// WHEN NOT MATCHED [BY TARGET] [AND c] THEN INSERT [(cols)] VALUES (...),
/// WHEN NOT MATCHED BY SOURCE [AND c] THEN UPDATE SET ... | DELETE.
///
/// One statement runs, in this order:
///
///  1. INSERT INTO target SELECT values FROM source WHERE no target row
///     matches it, marking the source rows it inserts;
///  2. the WHEN NOT MATCHED BY SOURCE clauses: DELETE and UPDATE of the
///     target rows no source row matches, marking them;
///  3. the WHEN MATCHED clauses: DELETE, then UPDATE ... FROM source,
///     leaving out the marked rows.
///
/// So each clause sees the rows as they were before the MERGE: the rows
/// step 1 inserts match their source rows, and step 2 may change a row
/// so that it matches. The source is numbered (row_number() OVER ()) to
/// mark its rows; it is read once per step, so it must give the same
/// rows each time (a subquery reading the target does not). A clause's
/// condition is AND'ed with the earlier clauses' conditions not being
/// true, as SQL Server takes the first clause that applies. Unlike SQL
/// Server, a target row that two source rows match is changed once,
/// with one of them, instead of failing the statement.
pub fn merge(s: *Parser) Error!void {
    try s.expectKw("MERGE");
    if (s.isKw("TOP")) return s.fail("xqlite: MERGE TOP is not supported", .{});
    _ = s.eatKw("INTO");
    const tq = try s.qualifiedName();
    try s.tableHints();
    var talias: ?Name = null;
    if (s.eatKw("AS")) {
        talias = try s.nameOf(try s.anyName());
    } else if (s.isName()) talias = try s.nameOf(try s.name());
    const t = try s.target(tq);
    if (t.tab == null) return s.fail("Invalid object name '{s}'.", .{tq.name.text});
    const tlabel = if (talias) |a| a.text else tq.name.text;
    try s.expectKw("USING");

    // The source, numbered.
    const src_pos = s.here();
    var src_item = try sourceItem(s);
    const slabel: Name = if (src_item.alias) |a| a.name else if (src_item.source == .table) src_item.source.table.name else return s.syntaxError();
    try s.expectKw("ON");
    const on = try s.expr();

    var matched: std.ArrayList(Clause) = .empty;
    var by_source: std.ArrayList(Clause) = .empty;
    var not_matched: ?Clause = null;
    while (s.eatKw("WHEN")) {
        const kind: enum { matched, not_matched, by_source } = if (s.eatKw("MATCHED")) .matched else blk: {
            try s.expectKw("NOT");
            try s.expectKw("MATCHED");
            if (s.eatKw("BY")) {
                if (s.eatKw("SOURCE")) break :blk .by_source;
                try s.expectKw("TARGET");
            }
            break :blk .not_matched;
        };
        const cond: ?*Expr = if (s.eatKw("AND")) try s.expr() else null;
        try s.expectKw("THEN");
        var action: Action = undefined;
        if (s.eatKw("UPDATE")) {
            if (kind == .not_matched) return s.syntaxError();
            try s.expectKw("SET");
            action = .{ .update = try assignments(s, &t, tlabel) };
        } else if (s.eatKw("DELETE")) {
            if (kind == .not_matched) return s.syntaxError();
            action = .delete;
        } else if (s.eatKw("INSERT")) {
            if (kind != .not_matched) return s.syntaxError();
            var cols: ?[]Name = null;
            if (s.isOp("(")) cols = try s.nameList();
            if (s.eatKw("DEFAULT")) return s.fail("xqlite: MERGE ... INSERT DEFAULT VALUES is not supported", .{});
            try s.expectKw("VALUES");
            try s.expectOp("(");
            const saved = s.allow_default;
            s.allow_default = true;
            const values = try s.exprList();
            s.allow_default = saved;
            try s.expectOp(")");
            action = .{ .insert = .{ .cols = cols, .values = values } };
        } else return s.syntaxError();
        const c: Clause = .{ .cond = cond, .action = action };
        switch (kind) {
            .matched => {
                if (matched.items.len == 2) return s.fail("An action of type 'WHEN MATCHED' cannot appear more than once in a 'UPDATE' clause of a MERGE statement.", .{});
                if (matched.items.len == 1 and (std.meta.activeTag(matched.items[0].action) == std.meta.activeTag(action) or matched.items[0].cond == null)) {
                    return s.fail("An action of type '{s}' is not allowed in the 'WHEN MATCHED' clause of a MERGE statement.", .{if (action == .delete) "DELETE" else "UPDATE"});
                }
                try matched.append(s.a, c);
            },
            .by_source => {
                if (by_source.items.len == 2) return s.fail("An action of type 'WHEN NOT MATCHED BY SOURCE' cannot appear more than once in a MERGE statement.", .{});
                try by_source.append(s.a, c);
            },
            .not_matched => {
                if (not_matched != null) return s.fail("An action of type 'INSERT' is not allowed in the 'WHEN MATCHED' clause of a MERGE statement.", .{});
                not_matched = c;
            },
        }
    }
    if (matched.items.len == 0 and by_source.items.len == 0 and not_matched == null) return s.syntaxError();
    if (s.isKw("OUTPUT")) return s.fail("xqlite: MERGE ... OUTPUT is not supported", .{});
    try optionClause(s);
    if (!s.isOp(";")) return s.fail("A MERGE statement must be terminated by a semi-colon (;).", .{});

    // The source numbered: (SELECT row_number() OVER () AS xq_n, *
    // FROM source) AS label.
    const n_name: Name = .{ .text = "xq_merge_n", .pos = src_pos };
    {
        const inner_from = try s.a.dupe(tree.FromItem, &.{src_item});
        const rn = try s.funcNode(src_pos, .{ .name = .{ .text = "row_number", .pos = src_pos }, .over = try s.new(tree.WindowSpec, .{}) });
        const cols = try s.a.dupe(tree.ResultCol, &.{ .{ .expr = .{ .e = rn, .alias = n_name } }, .{ .star = src_pos } });
        const core = try s.new(tree.Core, .{ .cols = cols, .from = inner_from, .pos = src_pos });
        const sel = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = core }), .pos = src_pos });
        src_item = .{ .source = .{ .subquery = sel }, .alias = .{ .name = slabel } };
    }
    const src_n = try col2(s, slabel, n_name);
    const tgt_rowid = try col2(s, .{ .text = tlabel, .pos = src_pos }, .{ .text = "rowid", .pos = src_pos });
    const target_item: tree.FromItem = .{ .source = .{ .table = tq }, .alias = if (talias) |a| .{ .name = a } else null };

    // Start: forget the marks of an earlier MERGE.
    try session.codeEval(s, &.{try s.func(src_pos, "xq_tsql_merge", &.{ try s.int_(src_pos, 0), try s.mk(src_pos, .null) })});

    // 1. INSERT
    if (not_matched) |c| {
        const ins = c.action.insert;
        const plan = try planColumns(s, &t, ins.cols);
        if (plan.cols.len > 0 and ins.values.len != plan.cols.len) return s.fail("The MERGE statement has more or fewer values than columns.", .{});
        var out: std.ArrayList(tree.ResultCol) = .empty;
        for (ins.values, 0..) |e, i| {
            const cm: ?*ColMeta = if (i < plan.cols.len) plan.cols[i] else null;
            if (e.kind == .default) return s.fail("xqlite: DEFAULT in MERGE ... INSERT is not supported", .{});
            try out.append(s.a, .{ .expr = .{ .e = if (cm) |m| try wrapValue(s, m, e) else e } });
        }
        // NOT EXISTS (SELECT 1 FROM target WHERE on) [AND c]
        const exists_core = try s.new(tree.Core, .{ .cols = try oneCol(s, src_pos), .from = try s.a.dupe(tree.FromItem, &.{target_item}), .where = on, .pos = src_pos });
        const exists_sel = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = exists_core }), .pos = src_pos });
        var applies = try s.mk(src_pos, .{ .unary = .{ .op = .not, .e = try s.mk(src_pos, .{ .exists = exists_sel }) } });
        if (c.cond) |x| applies = try s.bin(.@"and", applies, x);
        const where = try marked(s, applies, 1, src_n);
        const core = try s.new(tree.Core, .{ .cols = out.items, .from = try s.a.dupe(tree.FromItem, &.{src_item}), .where = where, .pos = src_pos });
        const sel = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = core }), .pos = src_pos });
        // INSERT ... SELECT keeps its own column list order.
        var names = plan.names;
        if (names.len == 0) {
            var l: std.ArrayList(Name) = .empty;
            for (plan.cols) |cm| try l.append(s.a, .{ .text = cm.?.name });
            names = l.items;
        }
        try s.lowerStmt(.{ .insert = try s.new(tree.Insert, .{ .table = tq, .cols = names, .source = sel, .overriding = plan.overriding, .pos = src_pos }) });
    }

    // 2. WHEN NOT MATCHED BY SOURCE
    if (by_source.items.len > 0) {
        // NOT EXISTS (SELECT 1 FROM source WHERE on)
        const ex_core = try s.new(tree.Core, .{ .cols = try oneCol(s, src_pos), .from = try s.a.dupe(tree.FromItem, &.{src_item}), .where = on, .pos = src_pos });
        const ex_sel = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = ex_core }), .pos = src_pos });
        const unmatched = try s.mk(src_pos, .{ .unary = .{ .op = .not, .e = try s.mk(src_pos, .{ .exists = ex_sel }) } });
        for (try ordered(s, by_source.items)) |oc| {
            const applies = try andOf(s, unmatched, oc.cond);
            const where = try marked(s, applies.?, 3, tgt_rowid);
            switch (oc.action) {
                .delete => try s.lowerStmt(.{ .delete = try s.new(tree.Delete, .{ .table = tq, .alias = talias, .where = where, .pos = src_pos }) }),
                .update => |sets| try s.lowerStmt(.{ .update = try s.new(tree.Update, .{ .table = tq, .alias = talias, .sets = sets, .where = where, .pos = src_pos }) }),
                .insert => unreachable,
            }
        }
    }

    // 3. WHEN MATCHED: DELETE, then UPDATE ... FROM source.
    if (matched.items.len > 0) {
        const fresh = try s.bin(.@"and", try notMarked(s, 2, src_n), try notMarked(s, 4, tgt_rowid));
        for (try ordered(s, matched.items)) |oc| {
            const applies = (try andOf(s, try andOf(s, on, oc.cond), fresh)).?;
            switch (oc.action) {
                .delete => try s.lowerStmt(.{ .delete = try s.new(tree.Delete, .{ .table = tq, .alias = talias, .using = try s.a.dupe(tree.FromItem, &.{src_item}), .where = applies, .pos = src_pos }) }),
                .update => |sets| try s.lowerStmt(.{ .update = try s.new(tree.Update, .{ .table = tq, .alias = talias, .sets = sets, .from = try s.a.dupe(tree.FromItem, &.{src_item}), .where = applies, .pos = src_pos }) }),
                .insert => unreachable,
            }
        }
    }
}

/// The source of MERGE ... USING: a table, a subquery or VALUES, with an
/// alias.
fn sourceItem(s: *Parser) Error!tree.FromItem {
    return s.tableSource();
}

/// `name.col`
fn col2(s: *Parser, t: Name, c: Name) Error!*Expr {
    return tree.expr(s.a, t.pos, t.pos, .{ .column = try s.a.dupe(Name, &.{ t, c }) });
}

fn oneCol(s: *Parser, pos: u32) Error![]tree.ResultCol {
    return s.a.dupe(tree.ResultCol, &.{.{ .expr = .{ .e = try s.int_(pos, 1) } }});
}

/// CASE WHEN applies THEN xq_tsql_merge(op, key) ELSE 0 END: one term,
/// so that the mark is set for the rows the clause applies to only.
fn marked(s: *Parser, applies: *Expr, op: i64, key: *Expr) Error!*Expr {
    const mark = try s.func(applies.pos, "xq_tsql_merge", &.{ try s.int_(applies.pos, op), key });
    return s.mk(applies.pos, .{ .case = .{ .operand = null, .whens = try s.a.dupe(*Expr, &.{ applies, mark }), .@"else" = try s.int_(applies.pos, 0) } });
}

/// NOT xq_tsql_merge(op, key): not marked.
fn notMarked(s: *Parser, op: i64, key: *Expr) Error!*Expr {
    const f = try s.func(key.pos, "xq_tsql_merge", &.{ try s.int_(key.pos, op), key });
    return s.mk(key.pos, .{ .unary = .{ .op = .not, .e = f } });
}

/// The clauses as they run (DELETE before UPDATE), each condition AND'ed
/// with the earlier clauses' (as written) not being true.
fn ordered(s: *Parser, cs: []const Clause) Error![]Clause {
    var out: std.ArrayList(Clause) = .empty;
    for (cs, 0..) |c, i| {
        var cond = c.cond;
        for (cs[0..i]) |prev| if (prev.cond) |pc| {
            const not_true = try s.mk(pc.pos, .{ .is_bool = .{ .e = pc, .value = true, .not = true } });
            cond = try andOf(s, not_true, cond);
        };
        try out.append(s.a, .{ .cond = cond, .action = c.action });
    }
    // DELETE first: it sees the rows before UPDATE changes them.
    std.mem.sort(Clause, out.items, {}, struct {
        fn lt(_: void, a: Clause, b: Clause) bool {
            return a.action == .delete and b.action != .delete;
        }
    }.lt);
    return out.items;
}
