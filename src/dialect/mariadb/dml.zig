//! INSERT, REPLACE, UPDATE, DELETE and TRUNCATE, as tree statements that
//! src/ir/lower.zig lowers.
//!
//!  - Every value stored into a column of a MariaDB table goes through
//!    Parser.wrapValue(): MariaDB's conversion for sql_mode (a Coerce,
//!    types.coerceFunc), AUTO_INCREMENT's 0. DEFAULT is the column's
//!    default (lower.zig, "DML defaults"), converted too.
//!  - INSERT IGNORE is INSERT OR IGNORE with lenient conversion; REPLACE
//!    is INSERT OR REPLACE.
//!  - ON DUPLICATE KEY UPDATE is SQLite's upsert without a conflict
//!    target (`ON CONFLICT DO UPDATE`), which applies to whichever
//!    PRIMARY KEY or UNIQUE constraint the row violates; VALUES(col) is
//!    excluded.col. Unlike MariaDB, a row that conflicts on two
//!    different unique keys with two different rows only updates the
//!    first, and the affected-rows count is SQLite's (1 per row).
//!  - UPDATE/DELETE ... [ORDER BY] LIMIT n: tree.Update/Delete.limit.
//!  - MariaDB evaluates UPDATE's assignments left to right, each seeing
//!    the columns assigned before it; here (as in SQL standard and
//!    MariaDB's SIMULTANEOUS_ASSIGNMENT) all see the old row.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;

/// INSERT ... or REPLACE ...
pub fn insert(s: *Parser) Error!tree.Stmt {
    const pos = s.here();
    const is_replace = s.isKw("REPLACE");
    s.advance();
    var ignore = false;
    while (true) {
        if (s.eatKw("LOW_PRIORITY") or s.eatKw("DELAYED") or s.eatKw("HIGH_PRIORITY")) {} else if (!is_replace and s.eatKw("IGNORE")) {
            ignore = true;
        } else break;
    }
    _ = s.eatKw("INTO");
    const q = try s.qualifiedName();
    if (s.isKw("PARTITION")) return s.fail("xqlite: PARTITION is not supported", .{});
    var t = try s.target(q);

    // The column list.
    var names: std.ArrayList(Name) = .empty;
    var cols: std.ArrayList(*Parser.ColMeta) = .empty;
    var unknown_col = false;
    if (s.isOp("(") and !isSelectAfterParen(s)) {
        s.advance();
        if (!s.isOp(")")) while (true) {
            const c = try s.nameOf(try s.name());
            try names.append(s.a, c);
            if (Parser.findCol(&t, c.text)) |m| try cols.append(s.a, m) else unknown_col = true;
            if (!s.eatOp(",")) break;
        };
        try s.expectOp(")");
    } else if (t.tab != null and !s.isKw("SET")) {
        try cols.appendSlice(s.a, try s.insertColumns(&t));
    }
    // An unknown column: let lowering report it, unconverted.
    if (unknown_col) {
        t.cols = &.{};
        cols.clearRetainingCapacity();
    }
    var needed = false;
    for (cols.items) |c| needed = needed or c.decl_type != null or c.autoinc;
    const base: Parser.Wrap = .{ .ignore = ignore };

    var source: ?*tree.Select = null;
    var missing: []*Parser.ColMeta = &.{};
    if (s.isKw("VALUES") or s.isKw("VALUE")) {
        const saved = s.allow_default;
        s.allow_default = true;
        const vpos = s.here();
        const rows = try s.valuesRows();
        s.allow_default = saved;
        const empty = for (rows) |row| {
            if (row.len > 0) break false;
        } else true;
        if (empty) {
            // VALUES (): the defaults.
            if (rows.len > 1) return s.fail("xqlite: VALUES () with several rows is not supported", .{});
            names.clearRetainingCapacity();
            cols.clearRetainingCapacity();
        }
        if (!unknown_col) missing = try s.missingColumns(&t, cols.items);
        for (rows, 0..) |*row, ri| {
            if (cols.items.len > 0 and row.len != cols.items.len) {
                return s.fail("Column count doesn't match value count at row {d}", .{ri + 1});
            }
            var w = base;
            w.row = @intCast(@min(ri + 1, std.math.maxInt(u32)));
            w.multi_row = rows.len > 1;
            var out: std.ArrayList(*Expr) = .empty;
            for (row.*, 0..) |e, i| {
                try out.append(s.a, if (needed and i < cols.items.len) try s.wrapValue(&t, cols.items[i], e, w) else e);
            }
            for (missing) |c| try out.append(s.a, try missingValue(s, &t, c, w));
            row.* = out.items;
        }
        if (empty and missing.len == 0) {
            source = null;
        } else {
            source = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .values = rows }), .pos = vpos });
        }
    } else if (s.eatKw("SET")) {
        // INSERT ... SET a = 1, b = 2: one row.
        if (names.items.len > 0) return s.syntaxError();
        cols.clearRetainingCapacity();
        const saved = s.allow_default;
        s.allow_default = true;
        const vpos = s.here();
        var row: std.ArrayList(*Expr) = .empty;
        while (true) {
            const c = try columnName(s);
            try s.expectOp("=");
            const e = try s.expr();
            try names.append(s.a, c);
            const m = Parser.findCol(&t, c.text);
            try row.append(s.a, if (m) |cm| try s.wrapValue(&t, cm, e, base) else e);
            if (m) |cm| try cols.append(s.a, cm);
            if (!s.eatOp(",")) break;
        }
        s.allow_default = saved;
        missing = try s.missingColumns(&t, cols.items);
        for (missing) |c| try row.append(s.a, try missingValue(s, &t, c, base));
        const rows = try s.a.dupe([]*Expr, &.{row.items});
        source = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .values = rows }), .pos = vpos });
    } else if (s.isSelectStart()) {
        source = try s.selectStmt();
        if (!unknown_col) missing = try s.missingColumns(&t, cols.items);
        if (needed or missing.len > 0) source = try wrapSelect(s, &t, cols.items, missing, base, source.?);
    } else return s.syntaxError();
    if (missing.len > 0) {
        // Name the columns, with the ones added.
        if (names.items.len == 0) for (cols.items) |c| try names.append(s.a, .{ .text = c.name });
        for (missing) |c| try names.append(s.a, .{ .text = c.name });
    }

    var on_conflict: ?*tree.OnConflict = null;
    if (s.isKw("ON")) {
        s.advance();
        try s.expectKw("DUPLICATE");
        try s.expectKw("KEY");
        try s.expectKw("UPDATE");
        if (is_replace) return s.syntaxError();
        on_conflict = try s.new(tree.OnConflict, .{ .update = try assignments(s, &t, ignore, true) });
    }
    var ret: []tree.ResultCol = &.{};
    if (s.eatKw("RETURNING")) ret = try returning(s);
    return .{ .insert = try s.new(tree.Insert, .{
        .table = q,
        .cols = names.items,
        .source = source,
        .on_error = if (is_replace) .replace else if (ignore) .ignore else .default,
        .on_conflict = on_conflict,
        .returning = ret,
        .pos = pos,
    }) };
}

/// The NULL an INSERT stores into NOT NULL column `c` without a DEFAULT
/// it leaves out (an error or a warning, as sql_mode says).
fn missingValue(s: *Parser, t: *const Parser.Target, c: *const Parser.ColMeta, w: Parser.Wrap) Error!*Expr {
    var x = w;
    x.missing = true;
    return s.wrapValue(t, c, try s.mk(s.here(), .null), x);
}

/// Whether `(` at the current token opens a SELECT rather than a column
/// list (INSERT INTO t (SELECT ...)).
fn isSelectAfterParen(s: *Parser) bool {
    const n = s.peek();
    return n.isKw("SELECT") or n.isKw("WITH");
}

/// A column name, maybe qualified (t.c): the column's name.
fn columnName(s: *Parser) Error!Name {
    var c = try s.name();
    while (s.eatOp(".")) c = try s.anyName();
    return s.nameOf(c);
}

/// INSERT ... SELECT with converted values:
/// WITH xq_src(c1, ..., cn) AS (sel) SELECT wrap(c1), ... FROM xq_src.
fn wrapSelect(s: *Parser, t: *const Parser.Target, cols: []const *Parser.ColMeta, missing: []const *Parser.ColMeta, w: Parser.Wrap, sel: *tree.Select) Error!*tree.Select {
    const pos = sel.pos;
    var names: std.ArrayList(Name) = .empty;
    var out: std.ArrayList(tree.ResultCol) = .empty;
    for (cols, 0..) |c, i| {
        const n: Name = .{ .text = try std.fmt.allocPrint(s.a, "c{d}", .{i + 1}), .pos = pos };
        try names.append(s.a, n);
        const ref = try tree.expr(s.a, pos, pos, .{ .column = try s.a.dupe(Name, &.{n}) });
        try out.append(s.a, .{ .expr = .{ .e = try s.wrapValue(t, c, ref, w) } });
    }
    for (missing) |c| try out.append(s.a, .{ .expr = .{ .e = try missingValue(s, t, c, w) } });
    const src: Name = .{ .text = "xq_src", .pos = pos };
    const with = try s.new(tree.With, .{ .recursive = false, .ctes = try s.a.dupe(tree.Cte, &.{.{ .name = src, .cols = names.items, .select = sel }}) });
    const from = try s.a.dupe(tree.FromItem, &.{.{ .source = .{ .table = .{ .name = src } } }});
    const core = try s.new(tree.Core, .{ .cols = out.items, .from = from, .pos = pos });
    return s.new(tree.Select, .{ .with = with, .body = try s.new(tree.Body, .{ .core = core }), .pos = pos });
}

/// `col = expr, ...` of UPDATE and ON DUPLICATE KEY UPDATE, the values
/// converted to the column types.
fn assignments(s: *Parser, t: *const Parser.Target, ignore: bool, odku: bool) Error![]tree.SetItem {
    var list: std.ArrayList(tree.SetItem) = .empty;
    const saved_default = s.allow_default;
    const saved_odku = s.in_odku;
    s.allow_default = true;
    s.in_odku = odku;
    defer {
        s.allow_default = saved_default;
        s.in_odku = saved_odku;
    }
    while (true) {
        const c = try columnName(s);
        try s.expectOp("=");
        var e = try s.expr();
        // AUTO_INCREMENT's 0 is for INSERT only.
        if (Parser.findCol(t, c.text)) |m| e = try s.wrapValue(t, m, e, .{ .ignore = ignore, .insert = false });
        try list.append(s.a, .{ .cols = try s.a.dupe(Name, &.{c}), .value = e });
        if (!s.eatOp(",")) break;
    }
    // ON UPDATE CURRENT_TIMESTAMP columns not assigned.
    if (!odku) for (t.cols) |*c| {
        if (!c.on_update) continue;
        const assigned = for (list.items) |it| {
            if (std.ascii.eqlIgnoreCase(it.cols[0].text, c.name)) break true;
        } else false;
        if (assigned) continue;
        const now = try s.func(s.here(), "datetime", &.{try s.str(s.here(), "now")});
        try list.append(s.a, .{ .cols = try s.a.dupe(Name, &.{.{ .text = c.name }}), .value = now });
    };
    return list.items;
}

fn returning(s: *Parser) Error![]tree.ResultCol {
    var l: std.ArrayList(tree.ResultCol) = .empty;
    while (true) {
        if (s.isOp("*")) {
            try l.append(s.a, .{ .star = s.here() });
            s.advance();
        } else {
            const start = s.here();
            const e = try s.expr();
            const end = s.endPos();
            var al: ?Name = null;
            if (s.eatKw("AS")) al = try s.nameOf(try s.anyName()) else if (s.isName()) al = try s.nameOf(try s.name());
            const text: ?[]const u8 = if (al != null or e.kind == .column) null else s.lx.sql[start..end];
            try l.append(s.a, .{ .expr = .{ .e = e, .alias = al, .name = text } });
        }
        if (!s.eatOp(",")) break;
    }
    return l.items;
}

/// `[[AS] alias]` of UPDATE/DELETE.
fn targetAlias(s: *Parser) Error!?Name {
    if (s.eatKw("AS")) return try s.nameOf(try s.name());
    if (s.isName()) return try s.nameOf(try s.name());
    return null;
}

/// UPDATE [LOW_PRIORITY] [IGNORE] t [[AS] a] SET ... [WHERE] [ORDER BY]
/// [LIMIT n].
pub fn update(s: *Parser) Error!tree.Stmt {
    const pos = s.here();
    try s.expectKw("UPDATE");
    var ignore = false;
    while (true) {
        if (s.eatKw("LOW_PRIORITY")) {} else if (s.eatKw("IGNORE")) {
            ignore = true;
        } else break;
    }
    const q = try s.qualifiedName();
    const al = try targetAlias(s);
    if (s.isOp(",") or s.isAnyKw(&.{ "JOIN", "INNER", "LEFT", "RIGHT", "CROSS", "STRAIGHT_JOIN" })) {
        return s.fail("xqlite: multi-table UPDATE is not supported", .{});
    }
    const t = try s.target(q);
    try s.expectKw("SET");
    const sets = try assignments(s, &t, ignore, false);
    const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
    const order, const limit = try orderLimit(s);
    if (s.isKw("RETURNING")) return s.fail("xqlite: UPDATE ... RETURNING is not supported by MariaDB", .{});
    return .{ .update = try s.new(tree.Update, .{
        .table = q,
        .alias = al,
        .on_error = if (ignore) .ignore else .default,
        .sets = sets,
        .where = where,
        .order_by = order,
        .limit = limit,
        .pos = pos,
    }) };
}

fn orderLimit(s: *Parser) Error!struct { []tree.SortItem, ?*Expr } {
    var order: []tree.SortItem = &.{};
    if (s.isKw("ORDER")) {
        s.advance();
        try s.expectKw("BY");
        order = try s.sortList();
    }
    var limit: ?*Expr = null;
    if (s.isKw("LIMIT")) {
        const l = try s.limitClause();
        if (l.offset != null) return s.syntaxError();
        limit = l.limit;
    }
    return .{ order, limit };
}

/// DELETE [LOW_PRIORITY] [QUICK] [IGNORE] FROM t [[AS] a] [WHERE]
/// [ORDER BY] [LIMIT n] [RETURNING ...].
pub fn delete(s: *Parser) Error!tree.Stmt {
    const pos = s.here();
    try s.expectKw("DELETE");
    while (s.eatKw("LOW_PRIORITY") or s.eatKw("QUICK") or s.eatKw("IGNORE")) {}
    if (!s.isKw("FROM")) return s.fail("xqlite: multi-table DELETE is not supported", .{});
    s.advance();
    const q = try s.qualifiedName();
    const al = try targetAlias(s);
    if (s.isOp(",") or s.isKw("USING") or s.isKw("JOIN")) return s.fail("xqlite: multi-table DELETE is not supported", .{});
    const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
    const order, const limit = try orderLimit(s);
    var ret: []tree.ResultCol = &.{};
    if (s.eatKw("RETURNING")) ret = try returning(s);
    return .{ .delete = try s.new(tree.Delete, .{
        .table = q,
        .alias = al,
        .where = where,
        .order_by = order,
        .limit = limit,
        .returning = ret,
        .pos = pos,
    }) };
}

/// TRUNCATE [TABLE] t: DELETE FROM t, and the AUTO_INCREMENT counter
/// starts again.
pub fn truncate(s: *Parser) Error!void {
    try s.expectKw("TRUNCATE");
    _ = s.eatKw("TABLE");
    const q = try s.qualifiedName();
    const t = try s.target(q);
    try s.lowerStmt(.{ .truncate = try s.new(tree.Truncate, .{ .table = q }) });
    if (t.tab) |tab| if (tab.tab_flags.Autoincrement) {
        catalog.codeExecFmt(s.p, t.schema, "DELETE FROM %Q.sqlite_sequence WHERE name=%Q", &.{ .{ .str = t.schema }, .{ .str = tab.name } });
    };
}
