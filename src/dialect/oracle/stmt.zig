//! Oracle statements (parser.zig parses queries and expressions): DML
//! (INSERT, INSERT ALL/FIRST, UPDATE, DELETE, MERGE) with the values
//! stored into columns converted by xq_ora_coerce(), DDL (CREATE/DROP/
//! ALTER/TRUNCATE/RENAME/COMMENT), transaction control and the
//! statements accepted as no-ops.
//!
//! MERGE and INSERT ALL become several tree statements that the frontend
//! lowers into one program (Statement.multi):
//!
//!   MERGE INTO t USING s ON (c)
//!     WHEN MATCHED THEN UPDATE SET ... [WHERE u] [DELETE WHERE d]
//!     WHEN NOT MATCHED THEN INSERT (cols) VALUES (...) [WHERE i]
//!   =>
//!   UPDATE t SET ... FROM s WHERE c [AND u];
//!   INSERT INTO t (cols) SELECT ... FROM s
//!     WHERE NOT EXISTS (SELECT 1 FROM t WHERE c) [AND i];
//!   DELETE FROM t WHERE EXISTS (SELECT 1 FROM s WHERE c [AND u] AND d);
//!
//! The DELETE runs last, so that the INSERT sees the rows it removes as
//! matched; a row the INSERT adds that DELETE WHERE holds for is deleted
//! too (Oracle deletes only rows the merge updated).

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const funcs = @import("funcs.zig");
const ora_state = @import("state.zig");

const Parser = parser.Parser;
const Statement = parser.Statement;
const Error = parser.Error;
const Name = tree.Name;
const Expr = tree.Expr;

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// One statement, to its end.
pub fn statement(p: *Parser) Error!Statement {
    const s = try stmt(p);
    if (p.c.peek().kind != .eof) return p.c.syntaxError();
    return s;
}

fn skipRest(p: *Parser) void {
    while (p.c.peek().kind != .eof) p.c.skip();
}

fn stmt(p: *Parser) Error!Statement {
    const t = p.c.peek();
    if (t.kind == .lparen) return .{ .tree = .{ .select = try p.select() } };
    if (t.kind != .ident) return p.c.fail(t.start, "ORA-00900: invalid SQL statement", .{});
    const w = t.text;
    if (eq(w, "SELECT") or eq(w, "WITH")) return .{ .tree = .{ .select = try p.select() } };
    if (eq(w, "INSERT")) return insert(p);
    if (eq(w, "UPDATE")) return .{ .tree = .{ .update = try update(p) } };
    if (eq(w, "DELETE")) return .{ .tree = .{ .delete = try delete(p) } };
    if (eq(w, "MERGE")) return merge(p);
    if (eq(w, "COMMIT")) {
        p.c.skip();
        _ = p.c.eatKw("work");
        if (p.c.eatKw("comment")) _ = try p.c.expect(.string);
        if (p.c.eatKw("write")) skipRest(p);
        return .{ .tree = .commit };
    }
    if (eq(w, "ROLLBACK")) {
        p.c.skip();
        _ = p.c.eatKw("work");
        if (p.c.eatKw("to")) {
            _ = p.c.eatKw("savepoint");
            return .{ .tree = .{ .rollback_to = try p.colId() } };
        }
        return .{ .tree = .rollback };
    }
    if (eq(w, "SAVEPOINT")) {
        p.c.skip();
        return .{ .tree = .{ .savepoint = try p.colId() } };
    }
    if (eq(w, "SET")) {
        if (p.c.isKwAt(1, "transaction")) {
            skipRest(p);
            return .noop;
        }
        return p.c.fail(t.start, "ORA-00922: missing or invalid option", .{});
    }
    if (eq(w, "LOCK")) {
        // LOCK TABLE: writers are serialized already.
        skipRest(p);
        return .noop;
    }
    if (eq(w, "ALTER")) {
        if (p.c.isKwAt(1, "session") or p.c.isKwAt(1, "system")) {
            skipRest(p);
            return .noop;
        }
        if (p.c.isKwAt(1, "table")) return alterTable(p);
        return p.unsupported(p.c.peekAt(1).start, try std.fmt.allocPrint(p.arena, "ALTER {s}", .{p.c.peekAt(1).text}));
    }
    if (eq(w, "CREATE")) return create(p);
    if (eq(w, "DROP")) return .{ .tree = .{ .drop = try drop(p) } };
    if (eq(w, "TRUNCATE")) {
        p.c.skip();
        try p.c.expectKw("table");
        const q = try p.qname();
        var tr: tree.Truncate = .{ .table = (try p.relation(q)).q };
        tr.restart_identity = false;
        skipRest(p);
        return .{ .tree = .{ .truncate = try p.new(tree.Truncate, tr) } };
    }
    if (eq(w, "RENAME")) {
        p.c.skip();
        const old = try p.colId();
        try p.c.expectKw("to");
        var new = try p.colId();
        // In the current schema, where the object stays.
        const r = try p.relation(.{ .name = old });
        const prefix = Parser.relPrefix(r);
        if (prefix.len > 0) new.text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefix, new.text });
        return .{ .tree = .{ .alter_table = try p.new(tree.AlterTable, .{ .name = r.q, .action = .{ .rename_to = new } }) } };
    }
    if (eq(w, "COMMENT")) return comment(p);
    if (eq(w, "EXPLAIN")) {
        p.c.skip();
        try p.c.expectKw("plan");
        if (p.c.eatKw("set")) {
            try p.c.expectKw("statement_id");
            if (!p.c.eatOp("=")) return p.c.syntaxError();
            _ = try p.c.expect(.string);
        }
        if (p.c.eatKw("into")) _ = try p.qname();
        try p.c.expectKw("for");
        const inner = try stmt(p);
        return switch (inner) {
            .tree => |x| switch (x) {
                .select, .insert, .update, .delete => .{ .tree = .{ .explain = try p.new(tree.Stmt, x) } },
                else => p.unsupported(t.start, "EXPLAIN PLAN of this statement"),
            },
            else => p.unsupported(t.start, "EXPLAIN PLAN of this statement"),
        };
    }
    if (eq(w, "BEGIN") or eq(w, "DECLARE")) return p.unsupported(t.start, "PL/SQL");
    if (eq(w, "GRANT") or eq(w, "REVOKE")) {
        // Privileges: every user may do everything (accepted, ignored).
        skipRest(p);
        return .noop;
    }
    if (eq(w, "AUDIT") or eq(w, "NOAUDIT") or eq(w, "ANALYZE") or eq(w, "PURGE") or eq(w, "FLASHBACK") or eq(w, "CALL")) {
        return p.unsupported(t.start, try std.ascii.allocUpperString(p.arena, w));
    }
    return p.c.fail(t.start, "ORA-00900: invalid SQL statement", .{});
}

// =============================================================== DML

/// A target: `[schema.]t [alias]`.
fn targetTable(p: *Parser) Error!struct { table: tree.QName, alias: ?Name } {
    const q = try p.qname();
    const r = try p.relation(q);
    const table = r.q;
    var alias: ?Name = r.alias;
    const a = p.c.peek();
    if (a.kind == .qident or (a.kind == .ident and !parser.isReserved(a.text) and !a.isAnyKw(&.{ "using", "values", "returning", "log" }))) {
        p.c.skip();
        alias = .{ .text = a.text, .pos = a.start };
    }
    return .{ .table = table, .alias = alias };
}

fn returning(p: *Parser) Error!void {
    if (p.c.isKw("returning") or p.c.isKw("return")) return p.unsupported(p.c.peek().start, "RETURNING (RETURNING ... INTO is PL/SQL)");
    if (p.c.isKw("log") and p.c.isKwAt(1, "errors")) return p.unsupported(p.c.peek().start, "LOG ERRORS");
}

fn insert(p: *Parser) Error!Statement {
    const pos = p.c.advance().start; // INSERT
    if (p.c.isKw("all") or p.c.isKw("first")) return insertMulti(p, pos);
    try p.c.expectKw("into");
    const tgt = try targetTable(p);
    var ins: tree.Insert = .{ .table = tgt.table, .alias = tgt.alias, .source = null, .pos = pos };
    if (p.c.peek().kind == .lparen and !startsQuery(p)) ins.cols = try p.parenNameList();
    if (!p.c.isKw("values") and !p.c.isKw("select") and !p.c.isKw("with") and p.c.peek().kind != .lparen) return p.missing("ORA-00926: missing VALUES keyword");
    ins.source = try p.select();
    try returning(p);
    const x = try p.new(tree.Insert, ins);
    try coerceInsert(p, x);
    return .{ .tree = .{ .insert = x } };
}

fn startsQuery(p: *Parser) bool {
    var k: usize = 0;
    while (p.c.peekAt(k).kind == .lparen) k += 1;
    return k > 0 and (p.c.peekAt(k).isKw("select") or p.c.peekAt(k).isKw("with"));
}

/// INSERT ALL / INSERT FIRST: one INSERT ... SELECT per INTO, each
/// reading the subquery, filtered by its WHEN (for FIRST, the first WHEN
/// that holds).
fn insertMulti(p: *Parser, pos: u32) Error!Statement {
    const first = p.c.advance().isKw("first");
    const Into = struct { table: tree.QName, alias: ?Name, cols: []Name, values: ?[]*Expr, branch: usize };
    var intos: std.ArrayList(Into) = .empty;
    var conds: std.ArrayList(*Expr) = .empty;
    var conditional = false;
    var has_else = false;
    while (true) {
        var branch: usize = 0;
        if (p.c.eatKw("when")) {
            conditional = true;
            try conds.append(p.arena, try p.expr0());
            try p.c.expectKw("then");
            branch = conds.items.len;
        } else if (conditional and p.c.eatKw("else")) {
            has_else = true;
            branch = 0;
        } else if (conditional or !p.c.isKw("into")) break;
        var any = false;
        while (p.c.eatKw("into")) {
            any = true;
            const tgt = try targetTable(p);
            var cols: []Name = &.{};
            if (p.c.peek().kind == .lparen) cols = try p.parenNameList();
            var values: ?[]*Expr = null;
            if (p.c.eatKw("values")) {
                p.nextval_seen.clearRetainingCapacity();
                _ = try p.c.expect(.lparen);
                values = try p.exprList();
                _ = try p.c.expect(.rparen);
            }
            try intos.append(p.arena, .{ .table = tgt.table, .alias = tgt.alias, .cols = cols, .values = values, .branch = branch });
        }
        if (!any) return p.missing("ORA-00905: missing keyword");
        if (has_else) break;
    }
    if (first and !conditional) return p.missing("ORA-00905: missing keyword");
    const source = try p.select();
    var out: std.ArrayList(tree.Stmt) = .empty;
    for (intos.items) |into| {
        // SELECT values FROM (source) [WHERE branch]
        var from = try p.arena.alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = source } };
        var cols: []tree.ResultCol = undefined;
        if (into.values) |vals| {
            cols = try p.arena.alloc(tree.ResultCol, vals.len);
            for (vals, cols) |v, *rc| rc.* = .{ .expr = .{ .e = v } };
        } else {
            cols = try p.arena.alloc(tree.ResultCol, 1);
            cols[0] = .{ .star = pos };
        }
        var where: ?*Expr = null;
        if (conditional) where = try branchTest(p, conds.items, into.branch, first, pos);
        const core = try p.new(tree.Core, .{ .cols = cols, .from = from, .where = where, .pos = pos });
        const sel = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = core }), .pos = pos });
        const ins = try p.new(tree.Insert, .{ .table = into.table, .alias = into.alias, .cols = into.cols, .source = sel, .pos = pos });
        try coerceInsert(p, ins);
        try out.append(p.arena, .{ .insert = ins });
    }
    return .{ .multi = out.items };
}

/// The WHEN of branch `b` (0: ELSE) of INSERT ALL/FIRST: for ALL the
/// branch's condition (ELSE: none holds), for FIRST CASE WHEN c1 THEN 1
/// WHEN c2 THEN 2 ... ELSE 0 END = b.
fn branchTest(p: *Parser, conds: []const *Expr, b: usize, first: bool, pos: u32) Error!*Expr {
    if (!first and b > 0) return conds[b - 1];
    var whens: std.ArrayList(*Expr) = .empty;
    for (conds, 1..) |c, k| {
        try whens.append(p.arena, c);
        try whens.append(p.arena, try intLit(p, pos, if (first) k else 1));
    }
    const case = try tree.expr(p.arena, pos, pos, .{ .case = .{ .operand = null, .whens = whens.items, .@"else" = try intLit(p, pos, 0) } });
    return tree.expr(p.arena, pos, pos, .{ .compare = .{ .op = .eq, .l = case, .r = try intLit(p, pos, b) } });
}

fn intLit(p: *Parser, pos: u32, v: usize) Error!*Expr {
    return tree.expr(p.arena, pos, pos, .{ .integer = try std.fmt.allocPrint(p.arena, "{d}", .{v}) });
}

fn setList(p: *Parser) Error![]tree.SetItem {
    p.nextval_seen.clearRetainingCapacity();
    var out: std.ArrayList(tree.SetItem) = .empty;
    while (true) {
        if (p.c.peek().kind == .lparen) {
            const cols = try p.parenNameList();
            if (!p.c.peek().isOp("=")) return p.missing("ORA-00927: missing equal sign");
            p.c.skip();
            const v = try p.expr0();
            try out.append(p.arena, .{ .cols = cols, .multi = true, .value = v });
        } else {
            var cols = try p.arena.alloc(Name, 1);
            cols[0] = try p.colId();
            // t.col = ...: the target's column.
            if (p.c.peek().kind == .dot) {
                p.c.skip();
                cols[0] = try p.anyName();
            }
            if (!p.c.peek().isOp("=")) return p.missing("ORA-00927: missing equal sign");
            p.c.skip();
            const v = try p.expr0();
            try out.append(p.arena, .{ .cols = cols, .multi = false, .value = v });
        }
        if (!p.c.eat(.comma)) break;
    }
    return out.items;
}

fn update(p: *Parser) Error!*tree.Update {
    const pos = p.c.advance().start; // UPDATE
    const tgt = try targetTable(p);
    var u: tree.Update = .{ .table = tgt.table, .alias = tgt.alias, .sets = &.{}, .pos = pos };
    try p.c.expectKw("set");
    u.sets = try setList(p);
    if (p.c.eatKw("where")) {
        if (p.c.isKw("current") and p.c.isKwAt(1, "of")) return p.unsupported(p.c.peek().start, "WHERE CURRENT OF");
        u.where = try p.expr0();
        u.limit = try p.takeRownum(&u.where);
    }
    try returning(p);
    const x = try p.new(tree.Update, u);
    try coerceSets(p, x.table, x.sets);
    return x;
}

fn delete(p: *Parser) Error!*tree.Delete {
    const pos = p.c.advance().start; // DELETE
    _ = p.c.eatKw("from");
    const tgt = try targetTable(p);
    var d: tree.Delete = .{ .table = tgt.table, .alias = tgt.alias, .pos = pos };
    if (p.c.eatKw("where")) {
        if (p.c.isKw("current") and p.c.isKwAt(1, "of")) return p.unsupported(p.c.peek().start, "WHERE CURRENT OF");
        d.where = try p.expr0();
        d.limit = try p.takeRownum(&d.where);
    }
    try returning(p);
    return p.new(tree.Delete, d);
}

fn merge(p: *Parser) Error!Statement {
    const pos = p.c.advance().start; // MERGE
    try p.c.expectKw("into");
    const tgt = try targetTable(p);
    try p.c.expectKw("using");
    // The source: a table or a subquery, and its alias.
    var src: tree.FromItem = undefined;
    if (p.c.peek().kind == .lparen) {
        p.c.skip();
        const s = try p.select();
        _ = try p.c.expect(.rparen);
        src = .{ .source = .{ .subquery = s } };
    } else {
        const r = try p.relation(try p.qname());
        src = .{ .source = .{ .table = r.q }, .alias = if (r.alias) |a| .{ .name = a } else null };
    }
    {
        const a = p.c.peek();
        if (a.kind == .qident or (a.kind == .ident and !parser.isReserved(a.text))) {
            p.c.skip();
            src.alias = .{ .name = .{ .text = a.text, .pos = a.start } };
        }
    }
    try p.c.expectKw("on");
    _ = try p.c.expect(.lparen);
    const on = try p.expr0();
    _ = try p.c.expect(.rparen);

    var upd: ?struct { sets: []tree.SetItem, where: ?*Expr, delete: ?*Expr } = null;
    var ins: ?struct { cols: []Name, values: []*Expr, where: ?*Expr } = null;
    while (p.c.eatKw("when")) {
        const not = p.c.eatKw("not");
        try p.c.expectKw("matched");
        try p.c.expectKw("then");
        if (!not) {
            if (upd != null) return p.c.syntaxError();
            try p.c.expectKw("update");
            try p.c.expectKw("set");
            const sets = try setList(p);
            var w: ?*Expr = null;
            var d: ?*Expr = null;
            if (p.c.eatKw("where")) w = try p.expr0();
            if (p.c.eatKw("delete")) {
                try p.c.expectKw("where");
                d = try p.expr0();
            }
            upd = .{ .sets = sets, .where = w, .delete = d };
        } else {
            if (ins != null) return p.c.syntaxError();
            try p.c.expectKw("insert");
            var cols: []Name = &.{};
            if (p.c.peek().kind == .lparen) {
                p.c.skip();
                var names: std.ArrayList(Name) = .empty;
                while (true) {
                    var n = try p.colId();
                    if (p.c.peek().kind == .dot) {
                        p.c.skip();
                        n = try p.anyName();
                    }
                    try names.append(p.arena, n);
                    if (!p.c.eat(.comma)) break;
                }
                _ = try p.c.expect(.rparen);
                cols = names.items;
            }
            try p.c.expectKw("values");
            p.nextval_seen.clearRetainingCapacity();
            _ = try p.c.expect(.lparen);
            const values = try p.exprList();
            _ = try p.c.expect(.rparen);
            var w: ?*Expr = null;
            if (p.c.eatKw("where")) w = try p.expr0();
            ins = .{ .cols = cols, .values = values, .where = w };
        }
    }
    if (upd == null and ins == null) return p.missing("ORA-00905: missing keyword");
    try returning(p);

    var out: std.ArrayList(tree.Stmt) = .empty;
    const and_ = struct {
        fn f(pp: *Parser, a: *Expr, b: ?*Expr) Error!*Expr {
            const r = b orelse return a;
            return tree.expr(pp.arena, a.pos, r.end, .{ .binary = .{ .op = .@"and", .l = a, .r = r } });
        }
    }.f;
    if (upd) |u| {
        // The ON condition may not update the columns it reads (ORA-38104).
        for (u.sets) |set| for (set.cols) |col| if (mentions(on, col.text)) {
            return p.c.fail(col.pos, "ORA-38104: Columns referenced in the ON Clause cannot be updated: \"{s}\"", .{col.text});
        };
        var from = try p.arena.alloc(tree.FromItem, 1);
        from[0] = src;
        from[0].join = .none;
        const matched = try and_(p, on, u.where);
        const x = try p.new(tree.Update, .{ .table = tgt.table, .alias = tgt.alias, .sets = u.sets, .from = from, .where = matched, .pos = pos });
        try coerceSets(p, x.table, x.sets);
        try out.append(p.arena, .{ .update = x });
    }
    if (ins) |i| {
        // INSERT ... SELECT values FROM src WHERE NOT EXISTS (match)
        const target_item: tree.FromItem = .{ .source = .{ .table = tgt.table }, .alias = if (tgt.alias) |a| .{ .name = a } else null };
        const exists = try existsFrom(p, target_item, on, pos);
        var where = try tree.expr(p.arena, pos, pos, .{ .unary = .{ .op = .not, .e = exists } });
        where = try and_(p, where, i.where);
        var from = try p.arena.alloc(tree.FromItem, 1);
        from[0] = src;
        from[0].join = .none;
        const cols = try p.arena.alloc(tree.ResultCol, i.values.len);
        for (i.values, cols) |v, *rc| rc.* = .{ .expr = .{ .e = v } };
        const core = try p.new(tree.Core, .{ .cols = cols, .from = from, .where = where, .pos = pos });
        const sel = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = core }), .pos = pos });
        const x = try p.new(tree.Insert, .{ .table = tgt.table, .cols = i.cols, .source = sel, .pos = pos });
        try coerceInsert(p, x);
        try out.append(p.arena, .{ .insert = x });
    }
    if (upd) |u| if (u.delete) |d| {
        // DELETE WHERE: rows the update matched, with their new values;
        // after the INSERT, whose NOT MATCHED must still see them.
        const sub = try existsFrom(p, src, try and_(p, try and_(p, on, u.where), d), pos);
        try out.append(p.arena, .{ .delete = try p.new(tree.Delete, .{ .table = tgt.table, .alias = tgt.alias, .where = sub, .pos = pos }) });
    };
    return .{ .multi = out.items };
}

/// EXISTS (SELECT 1 FROM item WHERE cond).
fn existsFrom(p: *Parser, item: tree.FromItem, cond: *Expr, pos: u32) Error!*Expr {
    var from = try p.arena.alloc(tree.FromItem, 1);
    from[0] = item;
    from[0].join = .none;
    const cols = try p.arena.alloc(tree.ResultCol, 1);
    cols[0] = .{ .expr = .{ .e = try intLit(p, pos, 1) } };
    const core = try p.new(tree.Core, .{ .cols = cols, .from = from, .where = cond, .pos = pos });
    const sel = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = core }), .pos = pos });
    return tree.expr(p.arena, pos, pos, .{ .exists = sel });
}

/// Whether `e` refers to a column named `name`.
fn mentions(e: *const Expr, name: []const u8) bool {
    if (e.kind == .column) {
        const names = e.kind.column;
        return eq(names[names.len - 1].text, name);
    }
    var it = parser.Children.of(e);
    while (it.next()) |c| if (mentions(c, name)) return true;
    return false;
}

// ============================================================ coercion

/// What a column of an Oracle table takes: its declared type (catalog)
/// and NOT NULL.
const ColumnInfo = struct { decl: ?[]const u8, not_null: bool };

fn columnInfo(p: *Parser, t: *int.Table, m: *const catalog.TableMeta, c: *const int.Column) Error!ColumnInfo {
    _ = t;
    // Copied: the catalog in memory may be dropped before the parse ends.
    const decl = if (m.declType(c.name())) |d| try p.arena.dupe(u8, d) else null;
    return .{ .decl = decl, .not_null = c.not_null != .None };
}

fn tableEntries(p: *Parser, q: tree.QName) Error!?struct { t: *int.Table, meta: *const catalog.TableMeta, table: []const u8 } {
    const ps = p.p orelse return null;
    const t = (try p.findTable(q)) orelse return null;
    const schema = catalog.schemaName(ps.db, t);
    if (!catalog.exists(ps.db, schema)) return null;
    const m = (catalog.meta(ps.db, schema, t.name) catch return null) orelse return null;
    return .{ .t = t, .meta = m, .table = t.name };
}

/// `v` as stored into column `c`: xq_ora_coerce(v, 'TYPE', 'T', 'C',
/// flags); DEFAULT as it is.
fn coerced(p: *Parser, v: *Expr, info: ColumnInfo, table: []const u8, col: []const u8) Error!*Expr {
    if (v.kind == .default) return v;
    const decl = info.decl orelse return v;
    const flags: []const u8 = if (info.not_null) "1" else "0";
    const args = try p.list(&.{
        v,
        try p.stringAt(v.pos, decl),
        try p.stringAt(v.pos, table),
        try p.stringAt(v.pos, col),
        try tree.expr(p.arena, v.pos, v.pos, .{ .integer = flags }),
    });
    const f = try p.new(tree.Func, .{ .name = .{ .text = "xq_ora_coerce", .pos = v.pos }, .args = args });
    return tree.expr(p.arena, v.pos, v.end, .{ .func = f });
}

/// The columns an INSERT assigns, in order.
fn insertColumns(p: *Parser, t: *int.Table, names: []const Name) Error![]?*int.Column {
    var out: std.ArrayList(?*int.Column) = .empty;
    if (names.len > 0) {
        for (names) |n| {
            const i = build.columnIndex(t, n.text);
            try out.append(p.arena, if (i >= 0) &t.cols[@intCast(i)] else null);
        }
    } else {
        for (t.cols) |*c| if (!c.col_flags.intersects(int.COLFLAG.NOINSERT)) try out.append(p.arena, c);
    }
    return out.items;
}

/// The values of an INSERT into an Oracle table (one the catalog has
/// types for) converted as Oracle stores them: VALUES items in place, a
/// query's result columns, or a query wrapped as SELECT coerce("1") ...
/// FROM (query) AS xq_src("1", ...) when it is a compound or has `*`.
pub fn coerceInsert(p: *Parser, ins: *tree.Insert) Error!void {
    const src = ins.source orelse return;
    const te = (try tableEntries(p, ins.table)) orelse return;
    const cols = try insertColumns(p, te.t, ins.cols);
    const infos = try p.arena.alloc(ColumnInfo, cols.len);
    var any = false;
    for (cols, infos) |c_opt, *info| {
        info.* = if (c_opt) |c| try columnInfo(p, te.t, te.meta, c) else .{ .decl = null, .not_null = false };
        if (info.decl != null) any = true;
    }
    if (!any) return;
    const colName = struct {
        fn f(c_opt: ?*int.Column) []const u8 {
            return if (c_opt) |c| c.name() else "";
        }
    }.f;
    if (src.body.* == .values and src.with == null and src.order_by.len == 0 and src.limit == null) {
        for (src.body.values) |row| {
            for (row, 0..) |*item, i| {
                if (i >= cols.len) break;
                item.* = try coerced(p, item.*, infos[i], te.table, colName(cols[i]));
            }
        }
        return;
    }
    if (src.body.* == .core and src.order_by.len == 0 and src.limit == null and src.offset == null) {
        const c = src.body.core;
        var plain = c.cols.len == cols.len;
        for (c.cols) |rc| if (rc != .expr) {
            plain = false;
        };
        if (plain) {
            for (c.cols, 0..) |*rc, i| rc.expr.e = try coerced(p, rc.expr.e, infos[i], te.table, colName(cols[i]));
            return;
        }
    }
    // SELECT coerce("XQ_1") ... FROM (src) AS "XQ_SRC"("XQ_1", ...)
    const names = try p.arena.alloc(Name, cols.len);
    const rcs = try p.arena.alloc(tree.ResultCol, cols.len);
    for (names, rcs, 0..) |*n, *rc, i| {
        n.* = .{ .text = try std.fmt.allocPrint(p.arena, "XQ_{d}", .{i + 1}), .pos = src.pos };
        const one = try p.arena.alloc(Name, 1);
        one[0] = n.*;
        const col = try tree.expr(p.arena, src.pos, src.pos, .{ .column = one });
        rc.* = .{ .expr = .{ .e = try coerced(p, col, infos[i], te.table, colName(cols[i])) } };
    }
    var from = try p.arena.alloc(tree.FromItem, 1);
    from[0] = .{ .source = .{ .subquery = src }, .alias = .{ .name = .{ .text = "XQ_SRC", .pos = src.pos }, .cols = names } };
    const core = try p.new(tree.Core, .{ .cols = rcs, .from = from, .pos = src.pos });
    ins.source = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = core }), .pos = src.pos });
}

/// The values of UPDATE SET (and MERGE's) converted as stored.
pub fn coerceSets(p: *Parser, q: tree.QName, sets: []tree.SetItem) Error!void {
    const te = (try tableEntries(p, q)) orelse return;
    for (sets) |*s| {
        if (s.multi) continue;
        const i = build.columnIndex(te.t, s.cols[0].text);
        if (i < 0) continue;
        const c = &te.t.cols[@intCast(i)];
        s.value = try coerced(p, s.value, try columnInfo(p, te.t, te.meta, c), te.table, c.name());
    }
}

// =============================================================== DDL

fn create(p: *Parser) Error!Statement {
    const at = p.c.advance().start; // CREATE
    var or_replace = false;
    if (p.c.eatKw("or")) {
        try p.c.expectKw("replace");
        or_replace = true;
    }
    var temp = false;
    if (p.c.eatKw("global") or p.c.eatKw("private")) {
        if (!p.c.eatKw("temporary")) return p.missing("ORA-00905: missing keyword");
        temp = true;
    }
    _ = p.c.eatKw("noforce") or p.c.eatKw("force");
    if (p.c.isKw("no") and p.c.isKwAt(1, "force")) {
        p.c.skip();
        p.c.skip();
    }
    _ = p.c.eatKw("editionable") or p.c.eatKw("noneditionable");
    if (p.c.isKw("table")) {
        if (or_replace) return p.c.syntaxError();
        return .{ .tree = .{ .create_table = try createTable(p, temp) } };
    }
    if (p.c.eatKw("view")) return .{ .tree = .{ .create_view = try createView(p, or_replace) } };
    if (p.c.eatKw("sequence")) {
        var s: tree.CreateSequence = .{ .name = undefined };
        s.if_not_exists = try p.ifNotExists();
        const q = try p.qname();
        const c = try p.createTarget(q, false, .user_or_role);
        // Sequences are all in main (xq_sequence).
        if (!std.mem.eql(u8, c.t.db, "main")) return p.unsupported(q.schema.?.pos, "a sequence in an attached database");
        s.name = .{ .name = .{ .text = c.t.name, .pos = q.name.pos } };
        s.opts = try seqOptions(p);
        return .{ .tree = .{ .create_sequence = try p.new(tree.CreateSequence, s) } };
    }
    if (p.c.isKw("unique") or p.c.isKw("bitmap") or p.c.isKw("index")) {
        if (or_replace or temp) return p.c.syntaxError();
        return .{ .tree = .{ .create_index = try createIndex(p) } };
    }
    if (p.c.isKw("schema")) {
        if (or_replace or temp) return p.c.syntaxError();
        return createSchema(p);
    }
    if (p.c.isAnyKw(&.{ "procedure", "function", "package", "trigger", "type", "library" })) return p.unsupported(at, "PL/SQL");
    if (p.c.isKw("public") or p.c.isKw("synonym")) return p.unsupported(at, "CREATE SYNONYM");
    if (p.c.isKw("materialized")) return p.unsupported(at, "CREATE MATERIALIZED VIEW");
    if (p.c.peek().kind == .ident) return p.unsupported(at, try std.fmt.allocPrint(p.arena, "CREATE {s}", .{p.c.peek().text}));
    return p.c.fail(at, "ORA-00901: invalid CREATE command", .{});
}

/// CREATE VIEW, after VIEW.
fn createView(p: *Parser, or_replace: bool) Error!*tree.CreateView {
    const q = try p.qname();
    const c = try p.createTarget(q, false, .user_or_role);
    var v: tree.CreateView = .{ .or_replace = or_replace, .name = .{ .schema = .{ .text = c.t.db }, .name = .{ .text = c.t.name, .pos = q.name.pos } }, .select = undefined };
    v.if_not_exists = false;
    if (p.c.peek().kind == .lparen) v.cols = try p.parenNameList();
    try p.c.expectKw("as");
    v.select = try p.select();
    if (p.c.eatKw("with")) {
        if (p.c.eatKw("read")) {
            try p.c.expectKw("only");
        } else {
            try p.c.expectKw("check");
            try p.c.expectKw("option");
            if (p.c.eatKw("constraint")) _ = try p.colId();
        }
    }
    return p.new(tree.CreateView, v);
}

/// CREATE SCHEMA AUTHORIZATION user { CREATE TABLE ... | CREATE VIEW ...
/// | GRANT ... } ...: the tables and views, made by one statement, of
/// the connected user (whose name the statement must give). GRANTs are
/// ignored.
fn createSchema(p: *Parser) Error!Statement {
    p.c.skip(); // SCHEMA
    try p.c.expectKw("authorization");
    const u = try p.colId();
    if (!eq(u.text, ora_state.user)) return p.c.fail(u.pos, "ORA-02421: missing or invalid schema authorization identifier", .{});
    var out: std.ArrayList(tree.Stmt) = .empty;
    p.schema_element = true;
    defer p.schema_element = false;
    while (p.c.peek().kind != .eof) {
        const at = p.c.peek().start;
        if (p.c.eatKw("grant")) {
            while (p.c.peek().kind != .eof and !p.c.isKw("create") and !p.c.isKw("grant")) p.c.skip();
            continue;
        }
        if (!p.c.eatKw("create")) return p.c.fail(at, "ORA-02422: missing or invalid schema element", .{});
        if (p.c.isKw("table")) {
            try out.append(p.arena, .{ .create_table = try createTable(p, false) });
        } else if (p.c.eatKw("view")) {
            try out.append(p.arena, .{ .create_view = try createView(p, false) });
        } else return p.c.fail(at, "ORA-02422: missing or invalid schema element", .{});
    }
    if (out.items.len == 0) return p.c.fail(p.c.peek().start, "ORA-02422: missing or invalid schema element", .{});
    return .{ .ddl = out.items };
}

/// Sequence options; Oracle's defaults are SQLite's (xq_sequence's):
/// START WITH the MINVALUE (1), INCREMENT BY 1, NOCYCLE.
fn seqOptions(p: *Parser) Error!tree.SeqOpts {
    var o: tree.SeqOpts = .{};
    while (true) {
        if (p.c.eatKw("increment")) {
            try p.c.expectKw("by");
            o.increment = try p.signedInt();
        } else if (p.c.eatKw("start")) {
            try p.c.expectKw("with");
            o.start = try p.signedInt();
        } else if (p.c.eatKw("minvalue")) {
            o.min = try p.signedInt();
        } else if (p.c.eatKw("maxvalue")) {
            o.max = bigInt(p) catch |err| return err;
        } else if (p.c.eatKw("cycle")) {
            o.cycle = true;
        } else if (p.c.eatKw("nocycle")) {
            o.cycle = false;
        } else if (p.c.eatKw("cache")) {
            _ = try p.signedInt();
        } else if (p.c.isAnyKw(&.{ "nocache", "order", "noorder", "nominvalue", "nomaxvalue", "keep", "nokeep", "scale", "noscale", "extend", "noextend", "session", "global", "shard", "noshard" })) {
            p.c.skip();
        } else break;
    }
    return o;
}

/// An integer that may be larger than 64 bits (MAXVALUE
/// 9999999999999999999999999999): the largest i64 then.
fn bigInt(p: *Parser) Error!i64 {
    if (p.c.peek().kind == .float) {
        p.c.skip();
        return std.math.maxInt(i64);
    }
    return p.signedInt();
}

fn createTable(p: *Parser, temp: bool) Error!*tree.CreateTable {
    p.c.skip(); // TABLE
    const if_not_exists = try p.ifNotExists();
    const q = try p.qname();
    const dest = try p.createTarget(q, temp, .user);
    p.creating = dest.t;
    var ct: tree.CreateTable = .{
        .temp = temp,
        .if_not_exists = if_not_exists,
        .name = .{ .schema = if (temp) null else dest.schema, .name = .{ .text = dest.t.name, .pos = q.name.pos } },
        .strict = true,
    };
    const table = q.name.text;
    if (p.c.peek().kind == .lparen) {
        p.c.skip();
        var cols: std.ArrayList(tree.ColumnDef) = .empty;
        var cons: std.ArrayList(tree.TableConstraint) = .empty;
        var pk_cols: []Name = &.{};
        while (true) {
            const t = p.c.peek();
            if (t.isAnyKw(&.{ "constraint", "check", "unique", "primary", "foreign" })) {
                const tc = try tableConstraint(p);
                if (tc.kind == .primary_key) pk_cols = tc.kind.primary_key;
                try cons.append(p.arena, tc);
            } else {
                const c = try columnDef(p, table);
                for (cols.items) |prev| if (eq(prev.name.text, c.name.text)) {
                    return p.c.fail(c.name.pos, "ORA-00957: duplicate column name", .{});
                };
                try cols.append(p.arena, c);
            }
            if (!p.c.eat(.comma)) break;
        }
        _ = try p.c.expect(.rparen);
        // Key columns are NOT NULL in Oracle.
        for (pk_cols) |k| for (cols.items) |*c| if (eq(c.name.text, k.text)) try addNotNull(p, c);
        ct.columns = cols.items;
        ct.constraints = cons.items;
        // The identity sequences are in the table's schema.
        try prefixIdentity(p, Parser.prefixOf(dest.t), ct.columns);
    }
    // Physical properties are ignored; ON COMMIT of a temporary table.
    while (p.c.peek().kind != .eof and !p.c.isKw("as") and !(p.schema_element and (p.c.isKw("create") or p.c.isKw("grant")))) {
        if (p.c.isKw("on") and p.c.isKwAt(1, "commit")) {
            p.c.skip();
            p.c.skip();
            if (!p.c.eatKw("preserve")) try p.c.expectKw("delete");
            if (!p.c.eatKw("rows")) try p.c.expectKw("definition");
            continue;
        }
        if (p.c.isKw("organization") and p.c.isKwAt(1, "index")) return p.unsupported(p.c.peek().start, "ORGANIZATION INDEX");
        if (p.c.isKw("partition")) return p.unsupported(p.c.peek().start, "partitioned tables");
        try skipClause(p);
    }
    if (p.c.eatKw("as")) {
        if (ct.columns.len > 0) return p.unsupported(q.name.pos, "a column list with AS");
        ct.as_select = try p.select();
        ct.strict = false;
    } else if (ct.columns.len == 0) return p.missing("ORA-00906: missing left parenthesis");
    return p.new(tree.CreateTable, ct);
}

/// One token of a clause that is ignored, with what is in parentheses
/// after it.
fn skipClause(p: *Parser) Error!void {
    if (p.c.peek().kind == .lparen) {
        var depth: usize = 0;
        while (true) {
            const x = p.c.advance();
            if (x.kind == .lparen) depth += 1;
            if (x.kind == .rparen) {
                depth -= 1;
                if (depth == 0) return;
            }
            if (x.kind == .eof) return p.missing("ORA-00907: missing right parenthesis");
        }
    }
    p.c.skip();
}

/// The identity sequences of `cols` named in schema `prefix` ("S.").
fn prefixIdentity(p: *Parser, prefix: []const u8, cols: []tree.ColumnDef) Error!void {
    if (prefix.len == 0) return;
    for (cols) |c| for (c.constraints) |*cc| if (cc.kind == .identity) {
        cc.kind.identity.sequence = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefix, cc.kind.identity.sequence });
    };
}

fn addNotNull(p: *Parser, c: *tree.ColumnDef) Error!void {
    for (c.constraints) |cc| if (cc.kind == .not_null or cc.kind == .identity) return;
    const out = try std.mem.concat(p.arena, tree.ColConstraint, &.{ &.{.{ .kind = .not_null }}, c.constraints });
    c.constraints = out;
}

/// Constraint states (ENABLE, NOVALIDATE, USING INDEX ...): ignored.
fn constraintState(p: *Parser) Error!void {
    while (true) {
        if (p.c.isAnyKw(&.{ "enable", "disable", "validate", "novalidate", "rely", "norely", "deferrable" })) {
            p.c.skip();
        } else if (p.c.isKw("not") and p.c.isKwAt(1, "deferrable")) {
            p.c.skip();
            p.c.skip();
        } else if (p.c.eatKw("initially")) {
            if (!p.c.eatKw("immediate")) try p.c.expectKw("deferred");
        } else if (p.c.eatKw("using")) {
            try p.c.expectKw("index");
            while (p.c.peek().kind != .eof and p.c.peek().kind != .comma and p.c.peek().kind != .rparen and !p.c.isAnyKw(&.{ "enable", "disable", "constraint", "not", "null", "check", "unique", "primary", "references", "default" })) try skipClause(p);
        } else break;
    }
}

const RawConstraint = struct {
    name: ?Name = null,
    kind: union(enum) {
        not_null,
        null,
        check: *Expr,
        default: *Expr,
        primary_key,
        unique,
        references: tree.Ref,
        identity: struct { always: bool, opts: tree.SeqOpts },
        generated: *Expr,
    },
};

/// A column: `name type [DEFAULT [ON NULL] e] [GENERATED ... AS
/// IDENTITY] [constraints]`, or a virtual column `name [type]
/// [GENERATED ALWAYS] AS (e) [VIRTUAL]`.
pub fn columnDef(p: *Parser, table: []const u8) Error!tree.ColumnDef {
    const name = try p.colId();
    var ty: ?types.TypeName = null;
    if (!p.c.isKw("as") and !p.c.isKw("generated")) ty = try p.typeName();
    var raw: std.ArrayList(RawConstraint) = .empty;
    while (true) {
        var cname: ?Name = null;
        if (p.c.eatKw("constraint")) cname = try p.colId();
        var cc: RawConstraint = .{ .name = cname, .kind = .null };
        if (p.c.eatKw("not")) {
            try p.c.expectKw("null");
            cc.kind = .not_null;
        } else if (p.c.eatKw("null")) {
            cc.kind = .null;
        } else if (p.c.eatKw("check")) {
            _ = try p.c.expect(.lparen);
            cc.kind = .{ .check = try p.expr0() };
            _ = try p.c.expect(.rparen);
        } else if (p.c.eatKw("default")) {
            if (p.c.isKw("on") and p.c.isKwAt(1, "null")) {
                p.c.skip();
                p.c.skip();
            }
            cc.kind = .{ .default = try p.addExpr() };
        } else if (p.c.eatKw("unique")) {
            cc.kind = .unique;
        } else if (p.c.eatKw("primary")) {
            try p.c.expectKw("key");
            cc.kind = .primary_key;
        } else if (p.c.isKw("references")) {
            cc.kind = .{ .references = try references(p) };
        } else if (p.c.isKw("generated") or p.c.isKw("as")) {
            var always = true;
            if (p.c.eatKw("generated")) {
                if (p.c.eatKw("by")) {
                    try p.c.expectKw("default");
                    always = false;
                    if (p.c.isKw("on") and p.c.isKwAt(1, "null")) {
                        p.c.skip();
                        p.c.skip();
                    }
                } else try p.c.expectKw("always");
            }
            try p.c.expectKw("as");
            if (p.c.eatKw("identity")) {
                var opts: tree.SeqOpts = .{};
                if (p.c.peek().kind == .lparen) {
                    p.c.skip();
                    opts = try seqOptions(p);
                    _ = try p.c.expect(.rparen);
                }
                cc.kind = .{ .identity = .{ .always = always, .opts = opts } };
            } else {
                if (!always) return p.c.syntaxError();
                _ = try p.c.expect(.lparen);
                const e = try p.expr0();
                _ = try p.c.expect(.rparen);
                _ = p.c.eatKw("virtual");
                cc.kind = .{ .generated = e };
            }
        } else {
            if (cname != null) return p.c.syntaxError();
            break;
        }
        try constraintState(p);
        try raw.append(p.arena, cc);
    }
    return resolveColumn(p, table, name, ty, raw.items);
}

fn resolveColumn(p: *Parser, table: []const u8, name: Name, ty_opt: ?types.TypeName, raw: []const RawConstraint) Error!tree.ColumnDef {
    var identity = false;
    for (raw) |cc| if (cc.kind == .identity) {
        identity = true;
    };
    var cons: std.ArrayList(tree.ColConstraint) = .empty;
    var storage: ?[:0]const u8 = null;
    var decl: ?[]const u8 = null;
    var info: ?types.Info = null;
    if (ty_opt) |ty| {
        info = types.info(ty) catch return p.c.fail(ty.pos, "ORA-00902: invalid datatype", .{});
        storage = info.?.storage;
        decl = try types.format(p.arena, ty);
    }
    if (identity) {
        if (info) |i| if (i.family != .number) return p.c.fail(name.pos, "ORA-30675: identity column must be a numeric type", .{});
        // Identity values are integers: the rowid when it is the key.
        storage = "INTEGER";
        if (decl == null) decl = "NUMBER";
    }
    for (raw) |cc| {
        const cname: ?[]const u8 = if (cc.name) |n| n.text else null;
        switch (cc.kind) {
            .identity => |id| {
                const seq = try std.fmt.allocPrint(p.arena, "ISEQ$$_{s}_{s}", .{ table, name.text });
                try cons.append(p.arena, .{ .kind = .{ .identity = .{ .sequence = seq, .always = id.always, .opts = id.opts } } });
            },
            .not_null => try cons.append(p.arena, .{ .name = cname, .kind = .not_null }),
            .null => try cons.append(p.arena, .{ .name = cname, .kind = .null }),
            .check => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .check = e } }),
            .default => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .default = e } }),
            .primary_key => {
                // Oracle's key is NOT NULL.
                if (!identity) try cons.append(p.arena, .{ .kind = .not_null });
                try cons.append(p.arena, .{ .name = cname, .kind = .{ .primary_key = .{} } });
            },
            .unique => try cons.append(p.arena, .{ .name = cname, .kind = .unique }),
            .references => |r| try cons.append(p.arena, .{ .name = cname, .kind = .{ .references = r } }),
            .generated => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .generated = .{ .e = e, .stored = false } } }),
        }
    }
    if (ty_opt) |ty| if (info) |i| try typeChecks(p, name, ty, i, &cons);
    // CHAR(n) compares blank-padded: 'ab   ' = 'ab'.
    if (info) |i| if (i.family == .char) try cons.append(p.arena, .{ .kind = .{ .collate = "RTRIM" } });
    return .{ .name = name, .type = storage orelse "ANY", .decl_type = decl, .constraints = cons.items };
}

/// The CHECK constraints of a type, named with Oracle's message.
fn typeChecks(p: *Parser, name: Name, ty: types.TypeName, info: types.Info, cons: *std.ArrayList(tree.ColConstraint)) Error!void {
    const a = p.arena;
    const pos = name.pos;
    const names = try a.alloc(Name, 1);
    names[0] = name;
    const col = try tree.expr(a, pos, pos, .{ .column = names });
    if (info.numeric) {
        const f = try p.call(pos, "typeof", null, &.{col});
        const items = try p.list(&.{ try p.stringAt(pos, "integer"), try p.stringAt(pos, "real"), try p.stringAt(pos, "null") });
        try cons.append(a, .{ .name = "ORA-01722: invalid number", .kind = .{ .check = try tree.expr(a, pos, pos, .{ .in_list = .{ .e = f, .not = false, .items = items } }) } });
    }
    if (info.precision) if (types.precisionBound(ty)) |bound| {
        const abs = try p.call(pos, "abs", null, &.{col});
        const lit: tree.Kind = if (bound < 1e18) .{ .integer = try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(bound))}) } else .{ .float = try std.fmt.allocPrint(a, "{e}", .{bound}) };
        try cons.append(a, .{ .name = "ORA-01438: value larger than specified precision allowed for this column", .kind = .{ .check = try tree.expr(a, pos, pos, .{ .compare = .{ .op = .lt, .l = abs, .r = try tree.expr(a, pos, pos, lit) } }) } });
    };
    if (info.length) {
        const n = ty.precision.?;
        const fname: []const u8 = if (ty.char_semantics or info.family == .raw) "length" else "octet_length";
        const len = try p.call(pos, fname, null, &.{col});
        try cons.append(a, .{
            .name = try std.fmt.allocPrint(a, "ORA-12899: value too large for column (maximum: {d})", .{n}),
            .kind = .{ .check = try tree.expr(a, pos, pos, .{ .compare = .{ .op = .le, .l = len, .r = try intLit(p, pos, @intCast(n)) } }) },
        });
    }
    if (info.json) {
        // RFC 8259 text, which sqlite3 checks too (xq_ora_coerce() stores
        // JSON so).
        try cons.append(a, .{ .name = "ORA-40441: JSON syntax error", .kind = .{ .check = try p.call(pos, "json_valid", null, &.{col}) } });
    }
    if (info.boolean) {
        const items = try p.list(&.{ try intLit(p, pos, 0), try intLit(p, pos, 1) });
        try cons.append(a, .{ .name = "invalid boolean value", .kind = .{ .check = try tree.expr(a, pos, pos, .{ .in_list = .{ .e = col, .not = false, .items = items } }) } });
    }
}

fn references(p: *Parser) Error!tree.Ref {
    try p.c.expectKw("references");
    const q = try p.qname();
    var r: tree.Ref = .{ .table = q.name };
    // SQLite's REFERENCES names a table of the same database.
    if (q.schema) |s| {
        r.table.text = (try p.qualified(s, q.name, .table)).name;
    } else if (p.creating != null and std.mem.eql(u8, p.creating.?.bare, q.name.text)) {
        r.table.text = p.creating.?.name;
    } else if (try p.unqualified(q.name, .relation)) |t| r.table.text = t.name;
    if (p.c.peek().kind == .lparen) r.cols = try p.parenNameList();
    if (p.c.isKw("on") and p.c.isKwAt(1, "delete")) {
        p.c.skip();
        p.c.skip();
        if (p.c.eatKw("cascade")) {
            r.on_delete = .cascade;
        } else {
            try p.c.expectKw("set");
            try p.c.expectKw("null");
            r.on_delete = .set_null;
        }
    }
    return r;
}

fn tableConstraint(p: *Parser) Error!tree.TableConstraint {
    var name: ?Name = null;
    if (p.c.eatKw("constraint")) name = try p.colId();
    var tc: tree.TableConstraint = .{ .name = if (name) |n| n.text else null, .kind = undefined };
    if (p.c.eatKw("check")) {
        _ = try p.c.expect(.lparen);
        tc.kind = .{ .check = try p.expr0() };
        _ = try p.c.expect(.rparen);
    } else if (p.c.eatKw("unique")) {
        tc.kind = .{ .unique = try p.parenNameList() };
    } else if (p.c.eatKw("primary")) {
        try p.c.expectKw("key");
        tc.kind = .{ .primary_key = try p.parenNameList() };
    } else if (p.c.eatKw("foreign")) {
        try p.c.expectKw("key");
        const cols = try p.parenNameList();
        tc.kind = .{ .foreign_key = .{ .cols = cols, .ref = try references(p) } };
    } else return p.missing("ORA-00902: invalid datatype");
    try constraintState(p);
    return tc;
}

fn createIndex(p: *Parser) Error!*tree.CreateIndex {
    var ci: tree.CreateIndex = .{ .name = undefined, .table = undefined, .items = &.{} };
    if (p.c.eatKw("unique")) ci.unique = true else _ = p.c.eatKw("bitmap");
    try p.c.expectKw("index");
    ci.if_not_exists = try p.ifNotExists();
    const iq = try p.qname();
    try p.c.expectKw("on");
    const q = try p.qname();
    const rel = try p.relation(q);
    ci.table = rel.q.name;
    // The index is in its schema (else the current one), its table in
    // the same SQLite database.
    const idx = try p.createTarget(iq, false, .user);
    ci.name = .{ .schema = rel.q.schema, .name = .{ .text = idx.t.name, .pos = iq.name.pos } };
    if (idx.t.mangled or rel.alias != null) ci.name.schema = .{ .text = "main", .pos = iq.name.pos };
    if (iq.schema != null and !idx.t.mangled) ci.name.schema = idx.schema;
    _ = try p.c.expect(.lparen);
    var items: std.ArrayList(tree.IndexItem) = .empty;
    while (true) {
        var item: tree.IndexItem = .{ .expr = try p.addExpr() };
        if (p.c.eatKw("desc")) item.desc = true else _ = p.c.eatKw("asc");
        try items.append(p.arena, item);
        if (!p.c.eat(.comma)) break;
    }
    _ = try p.c.expect(.rparen);
    ci.items = items.items;
    // TABLESPACE, ONLINE, COMPUTE STATISTICS, REVERSE ...: ignored.
    while (p.c.peek().kind != .eof) try skipClause(p);
    return p.new(tree.CreateIndex, ci);
}

fn drop(p: *Parser) Error!*tree.Drop {
    p.c.skip(); // DROP
    const t = p.c.peek();
    var d: tree.Drop = .{ .kind = undefined, .name = undefined };
    if (p.c.eatKw("table")) {
        d.kind = .table;
    } else if (p.c.eatKw("view")) {
        d.kind = .view;
    } else if (p.c.eatKw("index")) {
        d.kind = .index;
    } else if (p.c.eatKw("sequence")) {
        d.kind = .sequence;
    } else if (t.kind == .ident) {
        return p.unsupported(t.start, try std.fmt.allocPrint(p.arena, "DROP {s}", .{t.text}));
    } else return p.c.syntaxError();
    d.if_exists = try p.ifExists();
    const q = try p.qname();
    const kind: Parser.Lookup = switch (d.kind) {
        .table, .view => .relation,
        .index => .index,
        .sequence => .sequence,
    };
    if (d.if_exists and q.schema != null and try p.schemaTarget(q.schema.?, q.name) == null) {
        // No such user: a name nothing has.
        d.name = .{ .schema = .{ .text = "main" }, .name = .{ .text = try catalog.schemas.mangle(p.arena, q.schema.?.text, q.name.text), .pos = q.name.pos } };
    } else {
        const r = try p.lookup(q, kind);
        d.name = r.q;
        // Sequences are all in main.
        if (d.kind == .sequence) d.name.schema = null;
    }
    if (p.c.eatKw("cascade")) try p.c.expectKw("constraints");
    _ = p.c.eatKw("purge");
    _ = p.c.eatKw("online");
    _ = p.c.eatKw("force");
    return p.new(tree.Drop, d);
}

fn alterTable(p: *Parser) Error!Statement {
    p.c.skip(); // ALTER
    p.c.skip(); // TABLE
    const q = try p.qname();
    const r = try p.relation(q);
    const name = r.q;
    const prefix = Parser.relPrefix(r);
    const at = p.c.peek().start;
    var a: tree.AlterTable = .{ .name = name, .action = undefined };
    if (p.c.eatKw("rename")) {
        if (p.c.eatKw("to")) {
            // The table stays in its schema.
            var to = try p.colId();
            if (prefix.len > 0) to.text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefix, to.text });
            a.action = .{ .rename_to = to };
        } else {
            if (p.c.isKw("constraint")) return p.unsupported(at, "ALTER TABLE ... RENAME CONSTRAINT");
            try p.c.expectKw("column");
            const old = try p.colId();
            try p.c.expectKw("to");
            a.action = .{ .rename_column = .{ .old = old, .new = try p.colId() } };
        }
    } else if (p.c.eatKw("add")) {
        if (p.c.isAnyKw(&.{ "constraint", "check", "unique", "primary", "foreign" })) return p.unsupported(at, "ALTER TABLE ... ADD CONSTRAINT");
        const paren = p.c.eat(.lparen);
        var def = try columnDef(p, q.name.text);
        try prefixIdentity(p, prefix, (&def)[0..1]);
        a.action = .{ .add_column = .{ .def = def } };
        if (paren) {
            if (p.c.peek().kind == .comma) return p.unsupported(p.c.peek().start, "adding several columns in one ALTER TABLE (add them one at a time)");
            _ = try p.c.expect(.rparen);
        }
    } else if (p.c.eatKw("drop")) {
        if (p.c.isKw("constraint") or p.c.isKw("primary") or p.c.isKw("unique")) return p.unsupported(at, "ALTER TABLE ... DROP CONSTRAINT");
        var col: Name = undefined;
        if (p.c.eatKw("column")) {
            col = try p.colId();
        } else {
            _ = try p.c.expect(.lparen);
            col = try p.colId();
            if (p.c.peek().kind == .comma) return p.unsupported(p.c.peek().start, "dropping several columns in one ALTER TABLE (drop them one at a time)");
            _ = try p.c.expect(.rparen);
        }
        if (p.c.eatKw("cascade")) try p.c.expectKw("constraints");
        a.action = .{ .drop_column = .{ .name = col } };
    } else if (p.c.isKw("modify")) {
        return p.unsupported(at, "ALTER TABLE ... MODIFY");
    } else return p.c.fail(at, "ORA-01735: invalid ALTER TABLE option", .{});
    return .{ .tree = .{ .alter_table = try p.new(tree.AlterTable, a) } };
}

fn comment(p: *Parser) Error!Statement {
    p.c.skip(); // COMMENT
    try p.c.expectKw("on");
    var q: parser.QName = undefined;
    var column: ?Name = null;
    if (p.c.eatKw("table")) {
        q = try p.qname();
    } else if (p.c.eatKw("column")) {
        const first = try p.colId();
        _ = try p.c.expect(.dot);
        const second = try p.anyName();
        if (p.c.eat(.dot)) {
            q = .{ .schema = first, .name = second };
            column = try p.anyName();
        } else {
            q = .{ .name = first };
            column = second;
        }
    } else return p.unsupported(p.c.peek().start, "this COMMENT ON");
    const table = (try p.relation(q)).q;
    try p.c.expectKw("is");
    const t = try p.c.expect(.string);
    return .{ .comment = .{ .table = table, .column = column, .text = if (t.text.len == 0) null else t.text } };
}
