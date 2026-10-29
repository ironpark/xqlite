//! INSERT, REPLACE, UPDATE, DELETE and TRUNCATE.
//!
//!  - Every value stored into a column of a MariaDB table goes through
//!    Parser.wrapValue(): MariaDB's conversion for sql_mode
//!    (types.coerceFunc), AUTO_INCREMENT's 0, DEFAULT.
//!  - INSERT IGNORE is INSERT OR IGNORE with lenient conversion; REPLACE
//!    is INSERT OR REPLACE.
//!  - ON DUPLICATE KEY UPDATE is SQLite's upsert without a conflict
//!    target (`ON CONFLICT DO UPDATE`), which applies to whichever
//!    PRIMARY KEY or UNIQUE constraint the row violates; VALUES(col) is
//!    excluded.col. Unlike MariaDB, a row that conflicts on two
//!    different unique keys with two different rows only updates the
//!    first, and the affected-rows count is SQLite's (1 per row).
//!  - UPDATE/DELETE ... [ORDER BY] LIMIT n run on `rowid IN (SELECT rowid
//!    FROM t WHERE ... ORDER BY ... LIMIT n)`.
//!  - MariaDB evaluates UPDATE's assignments left to right, each seeing
//!    the columns assigned before it; here (as in SQL standard and
//!    MariaDB's SIMULTANEOUS_ASSIGNMENT) all see the old row.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const Select = int.Select;
const TK = int.TK;
const OE = int.OE;
const irTok = parser.irTok;

/// INSERT ... or REPLACE ...
pub fn insert(s: *Parser) Error!void {
    const is_replace = s.isKw("REPLACE");
    s.advance();
    var ignore = false;
    while (true) {
        if (s.eatKw("LOW_PRIORITY") or s.eatKw("DELAYED") or s.eatKw("HIGH_PRIORITY")) {} else if (!is_replace and s.eatKw("IGNORE")) {
            ignore = true;
        } else break;
    }
    _ = s.eatKw("INTO");
    const n1, const n2 = try s.qualifiedName();
    if (s.isKw("PARTITION")) return s.fail("xqlite: PARTITION is not supported", .{});
    var t = try s.target(n1, n2);

    // The column list.
    var id_list: ?*IdList = null;
    var cols: std.ArrayList(*Parser.ColMeta) = .empty;
    var unknown_col = false;
    if (s.isOp("(") and !isSelectAfterParen(s)) {
        s.advance();
        if (!s.isOp(")")) while (true) {
            const c = try s.name();
            id_list = try ir.list.idAppend(s.p, id_list, irTok(c));
            if (Parser.findCol(&t, try s.nameText(c))) |m| try cols.append(s.a, m) else unknown_col = true;
            if (!s.eatOp(",")) break;
        };
        try s.expectOp(")");
    } else if (t.tab != null and !s.isKw("SET")) {
        try cols.appendSlice(s.a, try s.insertColumns(&t));
    }
    // An unknown column: let the INSERT builder report it, unwrapped.
    if (unknown_col) t.cols = &.{};

    var needed = false;
    for (cols.items) |c| needed = needed or c.decl_type != null or c.autoinc;
    const missing = if (unknown_col or s.isKw("SET")) &.{} else try s.missingColumns(&t, cols.items);
    for (missing) |c| id_list = try ir.list.idAppend(s.p, id_list, int.Token.init(c.name));
    if (missing.len > 0 and id_list.?.len() == missing.len) {
        // No column list: name the columns.
        id_list = null;
        for (cols.items) |c| id_list = try ir.list.idAppend(s.p, id_list, int.Token.init(c.name));
        for (missing) |c| id_list = try ir.list.idAppend(s.p, id_list, int.Token.init(c.name));
    }
    const wrap: parser.RowWrap = .{ .target = &t, .cols = if (unknown_col) &.{} else cols.items, .ignore = ignore, .needed = needed and !unknown_col, .missing = missing };

    var sel: ?*Select = null;
    if (s.isKw("VALUES") or s.isKw("VALUE")) {
        const saved = s.allow_default;
        s.allow_default = true;
        defer s.allow_default = saved;
        sel = try s.valuesRows(&wrap);
    } else if (s.eatKw("SET")) {
        // INSERT ... SET a = 1, b = 2: one row.
        if (id_list != null) return s.syntaxError();
        var row: ?*ExprList = null;
        cols.clearRetainingCapacity();
        const saved = s.allow_default;
        s.allow_default = true;
        while (true) {
            const c = try columnName(s);
            try s.expectOp("=");
            const e = try s.expr();
            id_list = try ir.list.idAppend(s.p, id_list, irTok(c));
            const m = Parser.findCol(&t, try s.nameText(c));
            row = try ir.list.append(s.p, row, if (m) |cm| try s.wrapValue(&t, cm, e, 1, ignore) else try noDefault(s, e));
            if (m) |cm| try cols.append(s.a, cm);
            if (!s.eatOp(",")) break;
        }
        s.allow_default = saved;
        for (try s.missingColumns(&t, cols.items)) |c| {
            id_list = try ir.list.idAppend(s.p, id_list, int.Token.init(c.name));
            row = try ir.list.append(s.p, row, try s.wrapValueX(&t, c, try ir.expr.leaf(s.a, TK.NULL, null), 1, ignore, true));
        }
        sel = try ir.select.values(s.p, row);
    } else if (s.isSelectStart()) {
        sel = try s.selectStmt();
        if (wrap.needed or wrap.missing.len > 0) sel = try wrapSelect(s, &wrap, sel.?);
    } else return s.syntaxError();

    var upsert: ?*int.Upsert = null;
    if (s.isKw("ON")) {
        s.advance();
        try s.expectKw("DUPLICATE");
        try s.expectKw("KEY");
        try s.expectKw("UPDATE");
        if (is_replace) return s.syntaxError();
        const set = try assignments(s, &t, ignore, true);
        upsert = try ir.dml.upsertNew(s.p, null, null, set, null, null);
    }
    if (s.eatKw("RETURNING")) try returning(s);
    try s.check();
    const src = try ir.from.fullName(s.p, n1, n2, .{});
    const oe: OE = if (is_replace) .Replace else if (ignore) .Ignore else .Default;
    ir.dml.insert(s.p, src, sel, id_list, oe, upsert);
}

/// Whether `(` at the current token opens a SELECT rather than a column
/// list (INSERT INTO t (SELECT ...)).
fn isSelectAfterParen(s: *Parser) bool {
    const n = s.peek();
    return n.isKw("SELECT") or n.isKw("WITH");
}

/// A column name, maybe qualified (t.c): the column token.
fn columnName(s: *Parser) Error!parser.Token {
    var c = try s.name();
    while (s.eatOp(".")) c = try s.anyName();
    return c;
}

/// INSERT ... SELECT with converted values:
/// WITH xq_src(c1, ..., cn) AS (sel) SELECT wrap(c1), ... FROM xq_src.
fn wrapSelect(s: *Parser, w: *const parser.RowWrap, sel: *Select) Error!*Select {
    var names: ?*ExprList = null;
    var out: ?*ExprList = null;
    for (w.cols, 0..) |c, i| {
        const n = try std.fmt.allocPrint(s.a, "c{d}", .{i + 1});
        names = try ir.list.addIdTerm(s.p, names, int.Token.init(n), false, int.SortOrder.undef);
        const ref = try ir.expr.token(s.p, TK.ID, int.Token.init(n));
        out = try ir.list.append(s.p, out, try s.wrapValue(w.target, c, ref, 1, w.ignore));
    }
    for (w.missing) |c| {
        out = try ir.list.append(s.p, out, try s.wrapValueX(w.target, c, try ir.expr.leaf(s.a, TK.NULL, null), 1, w.ignore, true));
    }
    const cte = try ir.with.cte(s.p, int.Token.init("xq_src"), names, sel, .any);
    const with = try ir.with.add(s.p, null, cte);
    const src = try ir.from.append(s.p, null, int.Token.init("xq_src"), null);
    const outer = try ir.select.new(s.p, out, src, null, null, null, null, .{}, null);
    return ir.select.attachWith(s.p, outer, with) orelse s.syntaxError();
}

/// `col = expr, ...` of UPDATE and ON DUPLICATE KEY UPDATE, the values
/// converted to the column types.
fn assignments(s: *Parser, t: *const Parser.Target, ignore: bool, odku: bool) Error!*ExprList {
    var list: ?*ExprList = null;
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
        if (Parser.findCol(t, try s.nameText(c))) |m| {
            // AUTO_INCREMENT's 0 is for INSERT only.
            var meta = m.*;
            meta.autoinc = false;
            e = try s.wrapValue(t, &meta, e, 1, ignore);
        } else e = try noDefault(s, e);
        list = try ir.list.append(s.p, list, e);
        try ir.list.setName(s.p, list, irTok(c), true);
        if (!s.eatOp(",")) break;
    }
    // ON UPDATE CURRENT_TIMESTAMP columns not assigned.
    if (!odku) for (t.cols) |*c| {
        if (!c.on_update) continue;
        var assigned = false;
        for (list.?.slice()) |item| {
            if (item.e_name) |n| assigned = assigned or std.ascii.eqlIgnoreCase(n, c.name);
        }
        if (assigned) continue;
        list = try ir.list.append(s.p, list, try s.call("datetime", &.{try s.stringExpr("now")}));
        try ir.list.setName(s.p, list, int.Token.init(c.name), false);
    };
    return list.?;
}

/// A DEFAULT marker with no column to take the default of: NULL.
fn noDefault(s: *Parser, e: *Expr) Error!*Expr {
    return if (e.op == TK.DEFAULT) ir.expr.leaf(s.a, TK.NULL, null) else e;
}

fn returning(s: *Parser) Error!void {
    var l: ?*ExprList = null;
    while (true) {
        if (s.isOp("*")) {
            l = try ir.list.star(s.p, l, irTok(s.tok));
            s.advance();
        } else {
            const start = s.tok.text.ptr;
            const e = try s.expr();
            const end = s.prev_end;
            var al: int.Token = .{};
            if (s.eatKw("AS")) al = irTok(try s.anyName()) else if (s.isName()) al = irTok(try s.name());
            l = try ir.list.resultColumn(s.p, l, e, al, start, end);
        }
        if (!s.eatOp(",")) break;
    }
    ir.dml.addReturning(s.p, l);
}

/// UPDATE [LOW_PRIORITY] [IGNORE] t [[AS] a] SET ... [WHERE] [ORDER BY]
/// [LIMIT n].
pub fn update(s: *Parser) Error!void {
    try s.expectKw("UPDATE");
    var ignore = false;
    while (true) {
        if (s.eatKw("LOW_PRIORITY")) {} else if (s.eatKw("IGNORE")) {
            ignore = true;
        } else break;
    }
    const n1, const n2 = try s.qualifiedName();
    var al: int.Token = .{};
    if (s.eatKw("AS")) al = irTok(try s.name()) else if (s.isName()) al = irTok(try s.name());
    if (s.isOp(",") or s.isAnyKw(&.{ "JOIN", "INNER", "LEFT", "RIGHT", "CROSS", "STRAIGHT_JOIN" })) {
        return s.fail("xqlite: multi-table UPDATE is not supported", .{});
    }
    const t = try s.target(n1, n2);
    try s.expectKw("SET");
    const set = try assignments(s, &t, ignore, false);
    const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
    const order, const limit = try orderLimit(s);
    if (s.isKw("RETURNING")) return s.fail("xqlite: UPDATE ... RETURNING is not supported by MariaDB", .{});
    try s.check();
    const src = try ir.from.fullName(s.p, n1, n2, al);
    const w = try limitedWhere(s, n1, n2, al, where, order, limit);
    ir.dml.update(s.p, src, set, w, if (ignore) .Ignore else .Default, null, null, null);
}

fn orderLimit(s: *Parser) Error!struct { ?*ExprList, ?*Expr } {
    var order: ?*ExprList = null;
    if (s.isKw("ORDER")) {
        s.advance();
        try s.expectKw("BY");
        order = try s.sortList();
    }
    var limit: ?*Expr = null;
    if (s.isKw("LIMIT")) {
        limit = try s.limitClause();
        if (limit.?.right != null) return s.syntaxError();
    }
    return .{ order, limit };
}

/// The WHERE of an UPDATE/DELETE with a LIMIT: rowid IN (SELECT rowid
/// FROM t WHERE w ORDER BY o LIMIT n). Without a LIMIT, w (an ORDER BY
/// alone changes nothing).
fn limitedWhere(s: *Parser, n1: int.Token, n2: int.Token, al: int.Token, where: ?*Expr, order: ?*ExprList, limit: ?*Expr) Error!?*Expr {
    const lim = limit orelse return where;
    const inner_src = try ir.from.fullName(s.p, n1, n2, al);
    const rowid = try ir.expr.token(s.p, TK.ID, int.Token.init("rowid"));
    const cols = try ir.list.append(s.p, null, rowid);
    const sub = try ir.select.new(s.p, cols, inner_src, where, null, null, order, .{}, lim);
    const outer_rowid = try ir.expr.token(s.p, TK.ID, int.Token.init("rowid"));
    return ir.expr.inSelect(s.p, outer_rowid, false, sub);
}

/// DELETE [LOW_PRIORITY] [QUICK] [IGNORE] FROM t [[AS] a] [WHERE]
/// [ORDER BY] [LIMIT n] [RETURNING ...].
pub fn delete(s: *Parser) Error!void {
    try s.expectKw("DELETE");
    while (s.eatKw("LOW_PRIORITY") or s.eatKw("QUICK") or s.eatKw("IGNORE")) {}
    if (!s.isKw("FROM")) return s.fail("xqlite: multi-table DELETE is not supported", .{});
    s.advance();
    const n1, const n2 = try s.qualifiedName();
    var al: int.Token = .{};
    if (s.eatKw("AS")) al = irTok(try s.name()) else if (s.isName()) al = irTok(try s.name());
    if (s.isOp(",") or s.isKw("USING") or s.isKw("JOIN")) return s.fail("xqlite: multi-table DELETE is not supported", .{});
    const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
    const order, const limit = try orderLimit(s);
    if (s.eatKw("RETURNING")) try returning(s);
    try s.check();
    const src = try ir.from.fullName(s.p, n1, n2, al);
    const w = try limitedWhere(s, n1, n2, al, where, order, limit);
    ir.dml.delete(s.p, src, w, null, null);
}

/// TRUNCATE [TABLE] t: DELETE FROM t, and the AUTO_INCREMENT counter
/// starts again.
pub fn truncate(s: *Parser) Error!void {
    try s.expectKw("TRUNCATE");
    _ = s.eatKw("TABLE");
    const n1, const n2 = try s.qualifiedName();
    const t = try s.target(n1, n2);
    const src = try ir.from.fullName(s.p, n1, n2, .{});
    ir.dml.delete(s.p, src, null, null, null);
    try s.check();
    if (t.tab) |tab| if (tab.tab_flags.Autoincrement) {
        catalog.codeExecFmt(s.p, t.schema, "DELETE FROM %Q.sqlite_sequence WHERE name=%Q", &.{ .{ .str = t.schema }, .{ .str = tab.name } });
    };
}
