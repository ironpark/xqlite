//! DDL: CREATE/DROP TABLE, INDEX, VIEW, SEQUENCE and ALTER TABLE, as
//! tree statements: src/ir/lower.zig renders them as SQLite text and
//! records the dialect, the declared types and the identity columns in
//! xq_catalog in the same statement.
//!
//!     CREATE TABLE t (id INT IDENTITY(1,1) PRIMARY KEY,
//!                     name NVARCHAR(20) NOT NULL, price DECIMAL(10,2))
//!     -->
//!     CREATE TABLE "main"."t"("id" INTEGER NOT NULL DEFAULT (nextval('t_id_seq'))
//!       PRIMARY KEY CONSTRAINT "..." CHECK(("id" BETWEEN -2147483648 AND 2147483647)),
//!       "name" TEXT NOT NULL COLLATE NOCASE CONSTRAINT "..." CHECK((length("name") <= 20)),
//!       "price" REAL) STRICT
//!     xq_catalog: t||dialect|mssql, t|id|type|int, t|id|identity|t_id_seq, ...
//!
//!  - Storage types and checks: types.zig. The table is STRICT.
//!  - Character columns get an explicit COLLATE: NOCASE for the default
//!    (SQL_Latin1_General_CP1_CI_AS) and the _CI_ collations, BINARY for
//!    _CS_ and _BIN ones; so do the indexes on them.
//!  - IDENTITY(seed, increment) is a tree.Identity column numbered by the
//!    sequence <table>_<column>_seq; with PRIMARY KEY on an integer type
//!    it is SQLite's INTEGER PRIMARY KEY (the rowid).
//!  - A computed column `c AS (expr) [PERSISTED]` is a generated column
//!    (VIRTUAL, or STORED if PERSISTED), of type ANY.
//!  - CLUSTERED/NONCLUSTERED, WITH (...) options and ON filegroup are
//!    accepted and ignored. An INDEX inside CREATE TABLE is created with
//!    the table, in the same statement.
//!  - Index names are the database's (SQL Server's are the table's).

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const render = @import("../../ir/render.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const functions = @import("functions.zig");
const types = @import("types.zig");
const session = @import("session.zig");
const schemas = @import("schemas.zig");
const nsp = catalog.schemas;

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;
const sequence = catalog.sequence;

/// CREATE ...
pub fn create(s: *Parser) Error!void {
    try s.c.expectKw("CREATE");
    var or_alter = false;
    if (s.c.eatKw("OR")) {
        try s.c.expectKw("ALTER");
        or_alter = true;
    }
    if (s.c.isKw("TABLE")) return createTable(s);
    if (s.c.isKw("VIEW")) return createView(s, or_alter, false);
    if (s.c.isKw("SEQUENCE")) return createSequence(s);
    if (s.c.isKw("SCHEMA")) return schemas.create(s);
    const unique = s.c.eatKw("UNIQUE");
    _ = s.c.eatKw("CLUSTERED") or s.c.eatKw("NONCLUSTERED");
    if (s.c.isKw("INDEX")) return createIndex(s, unique);
    if (s.c.isAnyKw(&.{ "PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "TYPE", "DATABASE", "SYNONYM", "LOGIN", "USER", "ROLE" })) {
        return s.c.fail(null, "xqlite: CREATE {s} is not supported in the T-SQL dialect", .{s.c.peek().text});
    }
    return s.c.syntaxError();
}

/// ALTER TABLE / ALTER VIEW.
pub fn alter(s: *Parser) Error!void {
    try s.c.expectKw("ALTER");
    if (s.c.isKw("VIEW")) return createView(s, true, true);
    if (s.c.isKw("TABLE")) return alterTable(s);
    if (s.c.isKw("SCHEMA")) return schemas.transfer(s);
    if (s.c.isKw("USER")) return schemas.alterUser(s);
    return s.c.fail(null, "xqlite: ALTER {s} is not supported in the T-SQL dialect", .{s.c.peek().text});
}

// ======================================================== CREATE TABLE

const Table = struct {
    name: []const u8,
    columns: std.ArrayList(tree.ColumnDef) = .empty,
    constraints: std.ArrayList(tree.TableConstraint) = .empty,
    indexes: std.ArrayList(tree.CreateIndex) = .empty,
};

fn createTable(s: *Parser) Error!void {
    try s.c.expectKw("TABLE");
    const q = try s.qualifiedNameFor(.create);
    const name = q.name.text;
    const temp = name.len > 0 and name[0] == '#';
    const schema: []const u8 = if (temp) "temp" else if (q.schema) |x| x.text else "main";
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (build.findTable(s.p.db, name, schema) != null) return s.c.failState(null, .numbered("42P07", 2714), "There is already an object named '{s}' in the database.", .{try s.bareName(name)});
    const tname: tree.QName = if (temp) .{ .name = q.name } else .{ .schema = .{ .text = schema, .pos = q.name.pos }, .name = q.name };
    try s.c.expectOp("(");
    var t: Table = .{ .name = name };
    while (true) {
        try tableElement(s, &t);
        if (!s.c.eatOp(",")) break;
        // A trailing comma before ) is accepted by SQL Server.
        if (s.c.isOp(")")) break;
    }
    try s.c.expectOp(")");
    try tableOptions(s);
    if (s.n_plus > 0) try resolveTable(s, &t);
    const ct = try s.new(tree.CreateTable, .{
        .temp = temp,
        .name = tname,
        .columns = t.columns.items,
        .constraints = t.constraints.items,
        .strict = true,
    });
    // Sequences of identity columns that a table of this name left
    // (a temporary table's, gone with its connection).
    if (sequence.exists(s.p.db, catalog.main_schema)) for (ct.columns) |c| for (c.constraints) |cc| if (cc.kind == .identity) {
        catalog.codeExecFmt(s.p, catalog.main_schema, "DELETE FROM main.xq_sequence WHERE name=%Q", &.{.{ .str = cc.kind.identity.sequence }});
    };
    try s.lowerStmt(.{ .create_table = ct });
    // The indexes, once the table exists.
    if (t.indexes.items.len > 0) {
        const i_db = catalog.schemaIndex(s.p, schema) orelse return error.ParseFailed;
        for (t.indexes.items) |*ci| {
            ci.name.schema = .{ .text = schema };
            ci.name.name.text = try indexName(s, name, ci.name.name.text);
            var r: render.Renderer = .{ .p = s.p, .src = s.c.sql };
            const text = r.createIndex(ci) catch |err| return parser.lowered(err);
            catalog.codeExec(s.p, i_db, text);
        }
    }
}

/// `+` in the table's expressions, by the types of its columns.
fn resolveTable(s: *Parser, t: *Table) Error!void {
    var cols: std.ArrayList(Parser.ColClass) = .empty;
    for (t.columns.items) |c| {
        const cls: parser.Class = if (c.decl_type) |dt| Parser.typeClass(types.parseText(dt)) else .unknown;
        try cols.append(s.a, .{ .name = c.name.text, .class = cls });
    }
    const scope = try s.a.dupe(Parser.ScopeTable, &.{.{ .label = t.name, .cols = cols.items }});
    for (t.columns.items) |c| for (c.constraints) |cc| switch (cc.kind) {
        .check => |e| s.resolvePlus(e, scope),
        .default => |e| s.resolvePlus(e, scope),
        .generated => |g| s.resolvePlus(g.e, scope),
        else => {},
    };
    for (t.constraints.items) |tc| if (tc.kind == .check) s.resolvePlus(tc.kind.check, scope);
}

/// ON [PRIMARY], TEXTIMAGE_ON x, WITH (...): ignored.
fn tableOptions(s: *Parser) Error!void {
    while (true) {
        if (s.c.eatKw("ON") or s.c.eatKw("TEXTIMAGE_ON") or s.c.eatKw("FILESTREAM_ON")) {
            _ = try s.anyName();
            if (s.c.isOp("(")) try s.skipParens();
        } else if (s.c.isKw("WITH") and s.c.peekAt(1).is("(")) {
            s.c.skip();
            try s.skipParens();
        } else break;
    }
}

fn isConstraintStart(s: *Parser) bool {
    return s.c.isAnyKw(&.{ "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN" }) or
        (s.c.isKw("INDEX") and (s.c.peekAt(1).kind == .ident or s.c.peekAt(1).kind == .quoted_ident) and !s.c.peekAt(1).isKw("INT"));
}

fn tableElement(s: *Parser, t: *Table) Error!void {
    if (s.c.isKw("INDEX") and s.c.peekAt(1).kind != .op) return inlineIndex(s, t);
    if (!isConstraintStart(s)) return t.columns.append(s.a, try columnDef(s, t.name));
    var cname: ?[]const u8 = null;
    if (s.c.eatKw("CONSTRAINT")) cname = try s.nameText(try s.anyName());
    if (s.c.eatKw("PRIMARY")) {
        try s.c.expectKw("KEY");
        _ = s.c.eatKw("CLUSTERED") or s.c.eatKw("NONCLUSTERED");
        const cols = try keyColumns(s);
        try indexOptions(s);
        try t.constraints.append(s.a, .{ .name = cname, .kind = .{ .primary_key = cols } });
    } else if (s.c.eatKw("UNIQUE")) {
        _ = s.c.eatKw("CLUSTERED") or s.c.eatKw("NONCLUSTERED");
        const cols = try keyColumns(s);
        try indexOptions(s);
        try t.constraints.append(s.a, .{ .name = cname, .kind = .{ .unique = cols } });
    } else if (s.c.eatKw("CHECK")) {
        if (s.c.eatKw("NOT")) {
            try s.c.expectKw("FOR");
            try s.c.expectKw("REPLICATION");
        }
        try t.constraints.append(s.a, .{ .name = cname, .kind = .{ .check = try parenExpr(s) } });
    } else if (s.c.eatKw("FOREIGN")) {
        try s.c.expectKw("KEY");
        const cols = try s.nameList();
        const ref = try references(s);
        try t.constraints.append(s.a, .{ .name = cname, .kind = .{ .foreign_key = .{ .cols = cols, .ref = ref } } });
    } else return s.c.syntaxError();
}

/// (col [ASC|DESC], ...) of a key.
fn keyColumns(s: *Parser) Error![]Name {
    try s.c.expectOp("(");
    var out: std.ArrayList(Name) = .empty;
    while (true) {
        try out.append(s.a, try s.nameOf(try s.anyName()));
        _ = s.c.eatKw("ASC") or s.c.eatKw("DESC");
        if (!s.c.eatOp(",")) break;
    }
    try s.c.expectOp(")");
    return out.items;
}

/// WITH (...) / ON filegroup after a key: ignored.
fn indexOptions(s: *Parser) Error!void {
    while (true) {
        if (s.c.isKw("WITH") and s.c.peekAt(1).is("(")) {
            s.c.skip();
            try s.skipParens();
        } else if (s.c.isKw("ON") and !s.c.peekAt(1).isAnyKw(&.{ "DELETE", "UPDATE" })) {
            s.c.skip();
            _ = try s.anyName();
            if (s.c.isOp("(")) try s.skipParens();
        } else break;
    }
}

/// `( expr )` the schema keeps.
fn parenExpr(s: *Parser) Error!*Expr {
    try s.c.expectOp("(");
    const e = try storedExpr(s);
    try s.c.expectOp(")");
    return e;
}

fn storedExpr(s: *Parser) Error!*Expr {
    const saved = s.stored;
    s.stored = true;
    defer s.stored = saved;
    return s.expr();
}

/// REFERENCES t [(cols)] [ON DELETE a] [ON UPDATE a] [NOT FOR REPLICATION].
fn references(s: *Parser) Error!tree.Ref {
    try s.c.expectKw("REFERENCES");
    const q = try s.qualifiedName();
    var ref: tree.Ref = .{ .table = q.name };
    if (s.c.isOp("(")) ref.cols = try s.nameList();
    while (true) {
        if (s.c.isKw("ON") and s.c.peekAt(1).isAnyKw(&.{ "DELETE", "UPDATE" })) {
            s.c.skip();
            const on_delete = s.c.isKw("DELETE");
            s.c.skip();
            const action: tree.RefAction = if (s.c.eatKw("CASCADE"))
                .cascade
            else if (s.c.eatKw("SET")) blk: {
                if (s.c.eatKw("NULL")) break :blk .set_null;
                try s.c.expectKw("DEFAULT");
                break :blk .set_default;
            } else if (s.c.eatKw("NO")) blk: {
                try s.c.expectKw("ACTION");
                break :blk .none;
            } else return s.c.syntaxError();
            if (on_delete) ref.on_delete = action else ref.on_update = action;
        } else if (s.c.isKw("NOT") and s.c.peekAt(1).isKw("FOR")) {
            s.c.skip();
            s.c.skip();
            try s.c.expectKw("REPLICATION");
        } else break;
    }
    return ref;
}

/// INDEX name [UNIQUE] [CLUSTERED|NONCLUSTERED] (cols) inside CREATE TABLE.
fn inlineIndex(s: *Parser, t: *Table) Error!void {
    try s.c.expectKw("INDEX");
    const n = try s.nameOf(try s.anyName());
    const unique = s.c.eatKw("UNIQUE");
    _ = s.c.eatKw("CLUSTERED") or s.c.eatKw("NONCLUSTERED");
    const items = try indexItems(s);
    try indexOptions(s);
    try t.indexes.append(s.a, .{ .unique = unique, .name = .{ .name = n }, .table = .{ .text = t.name }, .items = items });
}

fn indexItems(s: *Parser) Error![]tree.IndexItem {
    try s.c.expectOp("(");
    var items: std.ArrayList(tree.IndexItem) = .empty;
    while (true) {
        const n = try s.nameOf(try s.anyName());
        var it: tree.IndexItem = .{ .expr = try tree.expr(s.a, n.pos, n.pos, .{ .column = try s.a.dupe(Name, &.{n}) }) };
        if (s.c.eatKw("DESC")) {
            it.desc = true;
        } else _ = s.c.eatKw("ASC");
        try items.append(s.a, it);
        if (!s.c.eatOp(",")) break;
    }
    try s.c.expectOp(")");
    return items.items;
}

/// A column definition of table `table`.
fn columnDef(s: *Parser, table: []const u8) Error!tree.ColumnDef {
    const name = try s.nameOf(try s.name());
    var cons: std.ArrayList(tree.ColConstraint) = .empty;
    if (s.c.eatKw("AS")) {
        // A computed column.
        const e = if (s.c.isOp("(")) try parenExpr(s) else try storedExpr(s);
        var stored = false;
        if (s.c.eatKw("PERSISTED")) {
            stored = true;
            if (s.c.isKw("NOT") and s.c.peekAt(1).isKw("NULL")) {
                s.c.skip();
                s.c.skip();
                try cons.append(s.a, .{ .kind = .not_null });
            }
        }
        try cons.append(s.a, .{ .kind = .{ .generated = .{ .e = e, .stored = stored } } });
        try columnConstraints(s, table, name, null, &cons);
        return .{ .name = name, .type = "ANY", .constraints = cons.items };
    }
    const ty = try functions.typeNameOf(s, true);
    try columnConstraints(s, table, name, ty.t, &cons);
    if (ty.t.isChar()) {
        var has_collate = false;
        for (cons.items) |c| if (c.kind == .collate) {
            has_collate = true;
        };
        if (!has_collate) try cons.append(s.a, .{ .kind = .{ .collate = "NOCASE" } });
    }
    if (try typeCheck(s, name, ty.t)) |c| try cons.append(s.a, c);
    return .{ .name = name, .type = ty.t.storage(), .decl_type = ty.text, .constraints = cons.items };
}

fn columnConstraints(s: *Parser, table: []const u8, name: Name, ty: ?types.Type, cons: *std.ArrayList(tree.ColConstraint)) Error!void {
    var identity = false;
    while (true) {
        var cname: ?[]const u8 = null;
        if (s.c.eatKw("CONSTRAINT")) cname = try s.nameText(try s.anyName());
        if (s.c.eatKw("COLLATE")) {
            try cons.append(s.a, .{ .kind = .{ .collate = try s.collationName() } });
        } else if (s.c.isKw("NOT") and s.c.peekAt(1).isKw("NULL")) {
            s.c.skip();
            s.c.skip();
            try cons.append(s.a, .{ .name = cname, .kind = .not_null });
        } else if (s.c.isKw("NOT") and s.c.peekAt(1).isKw("FOR")) {
            s.c.skip();
            s.c.skip();
            try s.c.expectKw("REPLICATION");
        } else if (s.c.eatKw("NULL")) {
            try cons.append(s.a, .{ .kind = .null });
        } else if (s.c.eatKw("DEFAULT")) {
            var e = try storedExpr(s);
            if (ty) |t| if (t.base == .date and e.kind != .string and e.kind != .null) {
                e = try s.mk(e.pos, .{ .cast = .{ .e = e, .target_type = "date", .mode = .{ .func = "date" } } });
            };
            try cons.append(s.a, .{ .name = cname, .kind = .{ .default = e } });
        } else if (s.c.eatKw("IDENTITY")) {
            const t = ty orelse return s.c.syntaxError();
            if (identity) return s.c.failState(null, .numbered("42P16", 2744), "Multiple identity columns specified for table '{s}'. Only one identity column per table is allowed.", .{try s.bareName(table)});
            identity = true;
            if (!t.isInteger() and !(t.isExactNumeric() and t.scaleOf() == 0)) {
                return s.c.failState(null, .numbered("42P16", 2749), "Identity column '{s}' must be of data type int, bigint, smallint, tinyint, or decimal or numeric with a scale of 0, and constrained to be nonnullable.", .{name.text});
            }
            var seed: i64 = 1;
            var inc: i64 = 1;
            if (s.c.eatOp("(")) {
                seed = try signedInt(s);
                try s.c.expectOp(",");
                inc = try signedInt(s);
                try s.c.expectOp(")");
            }
            var opts: tree.SeqOpts = .{ .start = seed, .increment = inc };
            if (t.range()) |r| {
                opts.min = @min(r[0], seed);
                opts.max = @max(r[1], seed);
            } else {
                opts.min = @min(std.math.minInt(i64), seed);
            }
            const seq = try std.fmt.allocPrint(s.a, "{s}_{s}_seq", .{ table, name.text });
            try cons.append(s.a, .{ .kind = .{ .identity = .{ .sequence = seq, .opts = opts } } });
        } else if (s.c.eatKw("PRIMARY")) {
            try s.c.expectKw("KEY");
            _ = s.c.eatKw("CLUSTERED") or s.c.eatKw("NONCLUSTERED");
            try indexOptions(s);
            try cons.append(s.a, .{ .name = cname, .kind = .{ .primary_key = .{} } });
        } else if (s.c.eatKw("UNIQUE")) {
            _ = s.c.eatKw("CLUSTERED") or s.c.eatKw("NONCLUSTERED");
            try indexOptions(s);
            try cons.append(s.a, .{ .name = cname, .kind = .unique });
        } else if (s.c.eatKw("CHECK")) {
            if (s.c.isKw("NOT")) {
                s.c.skip();
                try s.c.expectKw("FOR");
                try s.c.expectKw("REPLICATION");
            }
            try cons.append(s.a, .{ .name = cname, .kind = .{ .check = try parenExpr(s) } });
        } else if (s.c.isKw("REFERENCES") or s.c.isKw("FOREIGN")) {
            if (s.c.eatKw("FOREIGN")) try s.c.expectKw("KEY");
            try cons.append(s.a, .{ .name = cname, .kind = .{ .references = try references(s) } });
        } else if (s.c.eatKw("ROWGUIDCOL") or s.c.eatKw("SPARSE") or s.c.eatKw("FILESTREAM")) {} else {
            if (cname != null) return s.c.syntaxError();
            break;
        }
    }
}

fn signedInt(s: *Parser) Error!i64 {
    const neg = s.c.eatOp("-");
    if (!neg) _ = s.c.eatOp("+");
    if (s.c.peek().kind != .integer) return s.c.syntaxError();
    const v = std.fmt.parseInt(i64, s.c.peek().text, 10) catch return s.c.syntaxError();
    s.c.skip();
    return if (neg) -v else v;
}

/// The CHECK of a column's type (a range, a length), named with SQL
/// Server's message: a value written by another dialect or by sqlite3
/// meets it too.
fn typeCheck(s: *Parser, name: Name, t: types.Type) Error!?tree.ColConstraint {
    const pos = name.pos;
    const col = try tree.expr(s.a, pos, pos, .{ .column = try s.a.dupe(Name, &.{name}) });
    if (t.range()) |r| {
        if (t.base == .bit) {
            return .{ .kind = .{ .check = try s.mk(pos, .{ .in_list = .{ .e = col, .not = false, .items = try s.a.dupe(*Expr, &.{ try s.int_(pos, 0), try s.int_(pos, 1) }) } }) } };
        }
        const msg = try std.fmt.allocPrint(s.a, "Arithmetic overflow error converting expression to data type {s}.", .{@tagName(t.base)});
        return .{ .name = msg, .kind = .{ .check = try s.mk(pos, .{ .between = .{ .e = col, .not = false, .lo = try s.int_(pos, r[0]), .hi = try s.int_(pos, r[1]) } }) } };
    }
    if (t.maxLength()) |n| {
        const len = try s.funcNode(pos, .{ .name = .{ .text = "length", .pos = pos }, .args = try s.a.dupe(*Expr, &.{col}) });
        return .{ .name = "String or binary data would be truncated.", .kind = .{ .check = try s.mk(pos, .{ .compare = .{ .op = .le, .l = len, .r = try s.int_(pos, n) } }) } };
    }
    return null;
}

// ======================================================== CREATE INDEX

fn createIndex(s: *Parser, unique: bool) Error!void {
    try s.c.expectKw("INDEX");
    const n = try s.nameOf(try s.anyName());
    try s.c.expectKw("ON");
    const q = try s.qualifiedName();
    const items = try indexItems(s);
    if (s.c.eatKw("INCLUDE")) _ = try s.nameList();
    var where: ?*Expr = null;
    if (s.c.eatKw("WHERE")) where = try storedExpr(s);
    try indexOptions(s);
    const temp = q.name.text.len > 0 and q.name.text[0] == '#';
    const schema: Name = if (temp) .{ .text = "temp" } else q.schema orelse .{ .text = "main" };
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (build.findTable(s.p.db, q.name.text, schema.text) == null) return s.c.failState(null, .numbered("42P01", 4902), "Cannot find the object \"{s}\" because it does not exist or you do not have permissions.", .{try s.bareName(q.name.text)});
    const iname: Name = .{ .text = try indexName(s, q.name.text, n.text), .pos = n.pos };
    try s.lowerStmt(.{ .create_index = try s.new(tree.CreateIndex, .{ .unique = unique, .name = .{ .schema = schema, .name = iname }, .table = q.name, .items = items, .where = where }) });
}

/// The SQLite name of index `index` of table `table` (its SQLite name):
/// in the table's schema, "s.index" for a table of schema s.
fn indexName(s: *Parser, table: []const u8, index: []const u8) Error![]const u8 {
    const sp = nsp.split(table) orelse return index;
    const info = (try s.findSchema(sp.schema)) orelse return index;
    return nsp.mangle(s.a, info.name, index);
}

// ========================================================= CREATE VIEW

/// CREATE [OR ALTER] VIEW v [(cols)] [WITH SCHEMABINDING] AS query
/// [WITH CHECK OPTION]; ALTER VIEW (`alter`): the view must exist.
fn createView(s: *Parser, or_alter: bool, alter_only: bool) Error!void {
    try s.c.expectKw("VIEW");
    const q = try s.qualifiedNameFor(if (alter_only) .lookup else .create);
    var cols: []Name = &.{};
    if (s.c.isOp("(")) cols = try s.nameList();
    if (s.c.eatKw("WITH")) {
        while (s.c.isAnyKw(&.{ "SCHEMABINDING", "ENCRYPTION", "VIEW_METADATA" })) {
            s.c.skip();
            if (!s.c.eatOp(",")) break;
        }
    }
    try s.c.expectKw("AS");
    const saved = s.stored;
    s.stored = true;
    const sel = try s.subSelect();
    s.stored = saved;
    if (s.c.isKw("WITH") and s.c.peekAt(1).isKw("CHECK")) return s.c.fail(null, "xqlite: WITH CHECK OPTION is not supported", .{});
    if (sel.order_by.len > 0 and sel.limit == null and sel.offset == null) {
        return s.c.failState(null, .numbered("42601", 1033), "The ORDER BY clause is invalid in views, inline functions, derived tables, subqueries, and common table expressions, unless TOP, OFFSET or FOR XML is also specified.", .{});
    }
    if (cols.len == 0) try checkColumnNames(s, sel.body);
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const schema = if (q.schema) |x| x.text else "main";
    const exists = build.findTable(s.p.db, q.name.text, schema) != null;
    if (alter_only and !exists) return s.c.failState(null, .numbered("42P01", 208), "Invalid object name '{s}'.", .{q.name.text});
    if (!or_alter and exists) return s.c.failState(null, .numbered("42P07", 2714), "There is already an object named '{s}' in the database.", .{try s.bareName(q.name.text)});
    const vname: tree.QName = .{ .schema = q.schema orelse .{ .text = "main" }, .name = q.name };
    try s.lowerStmt(.{ .create_view = try s.new(tree.CreateView, .{ .or_replace = or_alter, .name = vname, .cols = cols, .select = sel }) });
}

/// Every column of a view needs a name.
fn checkColumnNames(s: *Parser, b: *const tree.Body) Error!void {
    switch (b.*) {
        .core => |c| for (c.cols, 1..) |rc, i| switch (rc) {
            .expr => |x| if (x.alias == null and x.e.kind != .column) {
                return s.c.failState(null, .numbered("42P16", 4511), "Create View or Function failed because no column name was specified for column {d}.", .{i});
            },
            else => {},
        },
        .compound => |c| try checkColumnNames(s, c.left),
        .nested => |n| try checkColumnNames(s, n.body),
        .values => {},
    }
}

// ===================================================== CREATE SEQUENCE

/// CREATE SEQUENCE s [AS type] [START WITH n] [INCREMENT BY n]
/// [MINVALUE n | NO MINVALUE] [MAXVALUE n | NO MAXVALUE] [[NO] CYCLE]
/// [CACHE n | NO CACHE]: bigint by default, starting at the type's
/// minimum (ascending) as in SQL Server.
fn createSequence(s: *Parser) Error!void {
    try s.c.expectKw("SEQUENCE");
    var q = try s.qualifiedNameFor(.create);
    if (q.schema == null) q.schema = .{ .text = "main" };
    var opts: tree.SeqOpts = .{};
    var ty: types.Type = .{ .base = .bigint };
    while (!s.atStmtEnd()) {
        if (s.c.eatKw("AS")) {
            ty = (try functions.typeNameOf(s, true)).t;
        } else if (s.c.eatKw("START")) {
            try s.c.expectKw("WITH");
            opts.start = try signedInt(s);
        } else if (s.c.eatKw("INCREMENT")) {
            try s.c.expectKw("BY");
            opts.increment = try signedInt(s);
        } else if (s.c.eatKw("MINVALUE")) {
            opts.min = try signedInt(s);
        } else if (s.c.eatKw("MAXVALUE")) {
            opts.max = try signedInt(s);
        } else if (s.c.eatKw("CYCLE")) {
            opts.cycle = true;
        } else if (s.c.eatKw("CACHE")) {
            if (s.c.peek().kind == .integer) s.c.skip();
        } else if (s.c.eatKw("NO")) {
            if (!(s.c.eatKw("MINVALUE") or s.c.eatKw("MAXVALUE") or s.c.eatKw("CYCLE") or s.c.eatKw("CACHE"))) return s.c.syntaxError();
        } else return s.c.syntaxError();
    }
    const r: struct { i64, i64 } = ty.range() orelse .{ std.math.minInt(i64), std.math.maxInt(i64) };
    if (opts.min == null) opts.min = r[0];
    if (opts.max == null) opts.max = r[1];
    if (opts.start == null) opts.start = if ((opts.increment orelse 1) > 0) opts.min else opts.max;
    try s.lowerStmt(.{ .create_sequence = try s.new(tree.CreateSequence, .{ .name = q, .opts = opts }) });
}

// ================================================================ DROP

/// DROP TABLE|VIEW [IF EXISTS] a, b ...; DROP INDEX i ON t | t.i;
/// DROP SEQUENCE s.
pub fn drop(s: *Parser) Error!void {
    try s.c.expectKw("DROP");
    if (s.c.isKw("SCHEMA")) return schemas.drop(s);
    const kind: tree.ObjectKind = if (s.c.eatKw("TABLE")) .table else if (s.c.eatKw("VIEW")) .view else if (s.c.eatKw("INDEX")) .index else if (s.c.eatKw("SEQUENCE")) .sequence else {
        if (s.c.isAnyKw(&.{ "PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "TYPE", "DATABASE" })) return s.c.fail(null, "xqlite: DROP {s} is not supported in the T-SQL dialect", .{s.c.peek().text});
        return s.c.syntaxError();
    };
    const if_exists = s.ifExists();
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    var found: ?tree.QName = null;
    while (true) {
        var q: tree.QName = undefined;
        const start = s.c.peek();
        // DROP INDEX: the index's table (its SQLite name), and the name
        // SQL Server's message shows (t.i).
        var itable: ?[]const u8 = null;
        var iwritten: ?[]const u8 = null;
        if (kind == .index) {
            // DROP INDEX i ON t, or [schema.]t.i: the index's database is
            // its table's.
            var parts: std.ArrayList(Name) = .empty;
            try parts.append(s.a, try s.nameOf(try s.anyName()));
            while (s.c.eatOp(".")) try parts.append(s.a, try s.nameOf(try s.anyName()));
            const ps = parts.items;
            if (s.c.eatKw("ON")) {
                if (ps.len != 1) return s.c.syntaxError();
                const tstart = s.c.peek();
                const t = try s.qualifiedName();
                q = .{ .schema = t.schema, .name = .{ .text = try indexName(s, t.name.text, ps[0].text), .pos = ps[0].pos } };
                if (t.name.text.len > 0 and t.name.text[0] == '#') q.schema = .{ .text = "temp" };
                itable = t.name.text;
                const tw = try writtenName(s, s.c.sql[tstart.start..s.c.lastEnd()]);
                iwritten = try std.fmt.allocPrint(s.a, "{s}.{s}", .{ tw, ps[0].text });
            } else {
                if (ps.len < 2 or ps.len > 4) return s.c.fail(null, "xqlite: DROP INDEX needs the table: DROP INDEX i ON t", .{});
                const table = ps[ps.len - 2];
                const t = try s.resolveParts(ps[0 .. ps.len - 1], .lookup);
                q = .{ .schema = t.schema, .name = .{ .text = try indexName(s, t.name.text, ps[ps.len - 1].text), .pos = ps[ps.len - 1].pos } };
                if (table.text.len > 0 and table.text[0] == '#') q.schema = .{ .text = "temp" };
                itable = t.name.text;
            }
        } else q = try s.qualifiedName();
        // The name as written, for messages.
        const written = s.c.sql[start.start..s.c.lastEnd()];
        if (q.name.text.len > 0 and q.name.text[0] == '#' and q.schema == null) q.schema = .{ .text = "temp" };
        const exists = switch (kind) {
            .table, .view => if (build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null)) |t| (t.isView() == (kind == .view)) else false,
            .index => indexExists(s, q, itable),
            .sequence => true,
        };
        if (!exists and !if_exists) {
            return switch (kind) {
                .table => s.c.failState(null, .numbered("42P01", 3701), "Cannot drop the table '{s}', because it does not exist or you do not have permission.", .{try writtenName(s, written)}),
                .view => s.c.failState(null, .numbered("42P01", 3701), "Cannot drop the view '{s}', because it does not exist or you do not have permission.", .{try writtenName(s, written)}),
                .index => s.c.failState(null, .numbered("42704", 3701), "Cannot drop the index '{s}', because it does not exist or you do not have permission.", .{iwritten orelse try writtenName(s, written)}),
                .sequence => unreachable,
            };
        }
        if (exists) {
            // One schema change per statement: what a DROP compiles reads
            // the schema as it was before the statement.
            if (found != null) return s.c.fail(null, "xqlite: DROP of several existing objects in one statement is not supported (drop them one at a time)", .{});
            found = q;
        }
        if (!s.c.eatOp(",")) break;
    }
    const q = found orelse return session.emptyStatement(s);
    try s.lowerStmt(.{ .drop = try s.new(tree.Drop, .{ .kind = kind, .if_exists = if_exists, .name = q }) });
}

/// A name as written ([db].[s].t ...) as SQL Server's messages show it:
/// its parts without their quotes, joined by dots.
fn writtenName(s: *Parser, text: []const u8) Error![]const u8 {
    var lx: @import("lexer.zig").Lexer = .init(try s.a.dupeSentinel(u8, text, 0));
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const t = lx.next();
        switch (t.kind) {
            .eof => break,
            .ident, .quoted_ident => try out.appendSlice(s.a, try s.nameText(t)),
            else => try out.appendSlice(s.a, t.text),
        }
    }
    return out.items;
}

/// Whether index `q` of table `table` (any table if null) exists.
fn indexExists(s: *Parser, q: tree.QName, table: ?[]const u8) bool {
    const db = s.p.db;
    for (db.dbs.items, 0..) |d, i| {
        if (q.schema) |x| {
            if (build.findDbName(db, x.text) != i) continue;
        }
        const idx = d.schema.idx_hash.get(q.name.text) orelse continue;
        if (table) |t| if (!std.ascii.eqlIgnoreCase(idx.table.name, t)) continue;
        return true;
    }
    return false;
}

// ========================================================= ALTER TABLE

/// ALTER TABLE t ADD col type ... | DROP COLUMN [IF EXISTS] c (one at
/// a time).
fn alterTable(s: *Parser) Error!void {
    try s.c.expectKw("TABLE");
    const q = try s.qualifiedName();
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null) orelse
        return s.c.failState(null, .numbered("42P01", 4902), "Cannot find the object \"{s}\" because it does not exist or you do not have permissions.", .{try s.bareName(q.name.text)});
    const bare = try s.bareName(tab.name);
    if (s.c.eatKw("ADD")) {
        if (s.c.isAnyKw(&.{ "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "DEFAULT" })) {
            return s.c.fail(null, "xqlite: ALTER TABLE ... ADD CONSTRAINT is not supported", .{});
        }
        _ = s.c.eatKw("COLUMN");
        const def = try columnDef(s, tab.name);
        if (s.c.isOp(",")) return s.c.fail(null, "xqlite: ALTER TABLE ... ADD of several columns is not supported (add them one at a time)", .{});
        if (build.columnIndex(tab, def.name.text) >= 0) return s.c.failState(null, .numbered("42701", 2705), "Column names in each table must be unique. Column name '{s}' in table '{s}' is specified more than once.", .{ def.name.text, bare });
        var with_values = false;
        if (s.c.isKw("WITH") and s.c.peekAt(1).isKw("VALUES")) {
            s.c.skip();
            s.c.skip();
            with_values = true;
        }
        try s.lowerStmt(.{ .alter_table = try s.new(tree.AlterTable, .{ .name = q, .action = .{ .add_column = .{ .def = def } } }) });
        // A nullable column's DEFAULT is for new rows: the rows there are
        // get NULL, unless WITH VALUES (SQLite gives them the default).
        var has_default = false;
        var not_null = false;
        for (def.constraints) |cc| switch (cc.kind) {
            .default => has_default = true,
            .not_null => not_null = true,
            else => {},
        };
        if (has_default and !not_null and !with_values) {
            const schema = @import("../../catalog/catalog.zig").schemaName(s.p.db, tab);
            catalog.codeExecFmt(s.p, schema, "UPDATE \"%w\".\"%w\" SET \"%w\" = NULL", &.{ .{ .str = schema }, .{ .str = tab.name }, .{ .str = def.name.text } });
        }
        return;
    }
    if (s.c.eatKw("DROP")) {
        if (!s.c.eatKw("COLUMN")) return s.c.fail(null, "xqlite: ALTER TABLE ... DROP {s} is not supported", .{s.c.peek().text});
        const if_exists = s.ifExists();
        const n = try s.nameOf(try s.anyName());
        if (s.c.isOp(",")) return s.c.fail(null, "xqlite: ALTER TABLE ... DROP COLUMN of several columns is not supported (drop them one at a time)", .{});
        if (build.columnIndex(tab, n.text) < 0) {
            if (if_exists) return session.emptyStatement(s);
            return s.c.failState(null, .numbered("42703", 4924), "ALTER TABLE DROP COLUMN failed because column '{s}' does not exist in table '{s}'.", .{ n.text, bare });
        }
        return s.lowerStmt(.{ .alter_table = try s.new(tree.AlterTable, .{ .name = q, .action = .{ .drop_column = .{ .name = n } } }) });
    }
    return s.c.fail(null, "xqlite: ALTER TABLE ... {s} is not supported", .{s.c.peek().text});
}
