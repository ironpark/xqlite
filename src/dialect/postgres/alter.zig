//! PostgreSQL's ALTER TABLE beyond SQLite's (ddl.zig hands these over):
//!
//!  - several actions (`ALTER TABLE t ADD a int, DROP b`): one statement
//!    of the dialect per action (tree.AlterTable.steps), run in order
//!    when the statement runs (catalog.codeExecDialect()), so that each
//!    is compiled against what the one before made;
//!  - ALTER COLUMN ... SET/DROP DEFAULT, SET/DROP NOT NULL, SET DATA TYPE
//!    [USING], ADD CONSTRAINT (CHECK, FOREIGN KEY, UNIQUE) and DROP
//!    CONSTRAINT: the CREATE TABLE text of sqlite_schema is edited
//!    (ir/coldef.zig), as SQLite's ALTER TABLE ... ADD CONSTRAINT edits
//!    it, and the schema read again; the rows are checked first
//!    (sqlite_fail(), with PostgreSQL's message), and a new type's values
//!    are written after (an UPDATE of the column to USING's cast, run
//!    when the new schema is read, so that its type and CHECK hold).
//!
//! A DEFAULT is the value of a column a row's record does not have (the
//! rows from before an ALTER TABLE ADD COLUMN): before its DEFAULT
//! changes, each row is written with all its columns, so that the rows
//! keep their values, as PostgreSQL's do.
//!
//! A UNIQUE constraint is a unique index of its name (SQLite adds no
//! table constraint); DROP CONSTRAINT drops it.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const coldef = @import("../../ir/coldef.zig");
const build = @import("../../sql/build.zig");
const prepare = @import("../../sql/prepare.zig");
const sqlalter = @import("../../sql/alter.zig");
const api = @import("../../vdbe/api.zig");
const catalog = @import("../../catalog/catalog.zig");
const dconstraint = @import("../constraint.zig");
const dialect = @import("../dialect.zig");
const Quoted = dialect.Quoted('"');
const Violation = dialect.Violation;
const types = @import("types.zig");
const ddl = @import("ddl.zig");

const Parse = int.Parse;
const TK = int.TK;
const RC = int.RC;
const Ddl = ddl.Ddl;
pub const Error = lower.Error;

/// The table an action changes, and its CREATE TABLE text.
pub const Target = struct {
    tab: *int.Table,
    schema: []const u8,
    i_db: usize,
    sql: [:0]const u8,
    def: coldef.Table,
};

pub fn target(d: *Ddl, tab: *int.Table) Error!Target {
    const p = d.l.p;
    const a = p.arena;
    const schema = catalog.schemaName(p.db, tab);
    const i_db = catalog.schemaIndex(p, schema) orelse return error.Failed;
    var q = catalog.Query.initFmt(p.db, "SELECT sql FROM \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " WHERE type='table' AND name=%Q", &.{ .{ .str = schema }, .{ .str = tab.name } }) catch return error.Failed;
    defer q.deinit();
    const found = q.step() catch return error.Failed;
    const z = (if (found) api.columnText(q.v, 0) else null) orelse return d.l.fail(0, "table \"{s}\" has no CREATE TABLE text", .{tab.name});
    const sql = try a.dupeSentinel(u8, z, 0);
    const def = coldef.parse(a, sql) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Malformed => return d.l.fail(0, "the definition of table \"{s}\" could not be read", .{tab.name}),
    };
    return .{ .tab = tab, .schema = schema, .i_db = i_db, .sql = sql, .def = def };
}

/// Write `edits` of the table's text to the schema and read it again.
pub fn write(d: *Ddl, t: Target, edits: []coldef.Edit) Error!void {
    if (edits.len == 0) return;
    const new = coldef.apply(d.l.p.arena, t.sql, edits) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Malformed => unreachable,
    };
    try setSql(d, t.schema, t.i_db, t.tab.name, "%Q", new);
}

/// sqlite_schema's text of `table` set to `value` (a format of one %Q:
/// `arg`), and the schema read again (SQLite's renameReloadSchema()).
fn setSql(d: *Ddl, schema: []const u8, i_db: usize, table: []const u8, value: []const u8, arg: []const u8) Error!void {
    const p = d.l.p;
    const fmt = try std.fmt.allocPrint(p.arena, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET sql = {s} WHERE type='table' AND name=%Q", .{value});
    build.nestedParse(p, fmt, &.{
        .{ .str = schema }, .{ .str = arg }, .{ .str = table },
    });
    try d.l.check();
    _ = build.getVdbe(p) orelse return error.OutOfMemory;
    sqlalter.renameReloadSchema(p, i_db, prepare.INITFLAG_AlterDropCons);
}

/// The column's values set to `e` when the statement runs.
fn setColumn(d: *Ddl, schema: []const u8, i_db: usize, table: []const u8, col: []const u8, e: *tree.Expr) Error!void {
    var r = d.l.renderer();
    try r.put("UPDATE ");
    try r.ident(schema);
    try r.put(".");
    try r.ident(table);
    try r.put(" SET ");
    try r.ident(col);
    try r.put(" = ");
    try r.expr(e);
    catalog.codeExec(d.l.p, i_db, try r.text());
}

/// Fail the statement when it runs if `cond` (SQLite text over the
/// table) holds for a row: with `msg` and result code `rc` (whose
/// SQLSTATE the server sends).
fn failIfAny(d: *Ddl, t: Target, cond: []const u8, msg: []const u8, rc: i32) Error!void {
    build.nestedParse(d.l.p, "SELECT sqlite_fail(%Q, %d) FROM \"%w\".\"%w\" WHERE %s", &.{
        .{ .str = msg }, .{ .int = rc }, .{ .str = t.schema }, .{ .str = t.tab.name }, .{ .str = cond },
    });
    try d.l.check();
}

/// Each row written with all its columns (see the top of the file), when
/// the statement runs.
fn fillRows(d: *Ddl, t: Target, col: []const u8) void {
    catalog.codeExec(d.l.p, t.i_db, build.mprintf(d.l.p, "UPDATE \"%w\".\"%w\" SET \"%w\" = \"%w\"", &.{
        .{ .str = t.schema }, .{ .str = t.tab.name }, .{ .str = col }, .{ .str = col },
    }) catch return build.oomFault(d.l.p));
}

// ================================================================ actions

/// Whether ADD COLUMN of `def` needs addColumn(): its DEFAULT is not a
/// constant (now(), nextval() ...), which SQLite's ADD COLUMN refuses
/// for a table with rows.
pub fn variableDefault(def: tree.ColumnDef) bool {
    for (def.constraints) |cc| if (cc.kind == .default) return !constant(cc.kind.default);
    return false;
}

fn constant(e: *const tree.Expr) bool {
    return switch (e.kind) {
        .integer, .float, .string, .blob, .null, .boolean => true,
        .unary => |u| constant(u.e),
        else => false,
    };
}

/// ADD COLUMN of a column whose DEFAULT is not a constant: the column
/// without its DEFAULT and NOT NULL, then (when the statement runs) the
/// rows given the default's value, as PostgreSQL computes it for them,
/// then both added to the column's text (SQLite's
/// sqlite_add_constraint()).
pub fn addColumn(d: *Ddl, a: *const tree.AlterTable, tab: *int.Table) Error!void {
    const p = d.l.p;
    const arena = p.arena;
    const ac = a.action.add_column;
    var kept: std.ArrayList(tree.ColConstraint) = .empty;
    var r = d.l.renderer();
    var value: ?*tree.Expr = null;
    for (ac.def.constraints) |cc| switch (cc.kind) {
        .default => |e| {
            value = e;
            try r.colConstraint(cc);
        },
        .not_null => try r.colConstraint(cc),
        else => try kept.append(arena, cc),
    };
    const added = try r.text();
    var at = a.*;
    at.action = .{ .add_column = .{ .if_not_exists = ac.if_not_exists, .def = .{ .name = ac.def.name, .type = ac.def.type, .decl_type = ac.def.decl_type, .constraints = kept.items } } };
    try d.l.alterTable(&at);
    const schema = catalog.schemaName(p.db, tab);
    const i_db = catalog.schemaIndex(p, schema) orelse return error.Failed;
    try setColumn(d, schema, i_db, tab.name, ac.def.name.text, value.?);
    // The column is the table's last (tab.cols.len before the ADD).
    const add = try std.fmt.allocPrint(arena, "sqlite_add_constraint(sql, %Q, {d})", .{tab.cols.len});
    try setSql(d, schema, i_db, tab.name, add, std.mem.trimStart(u8, added, " "));
}

/// An ALTER TABLE of several actions: its statements, run in order.
pub fn steps(d: *Ddl, list: []const [:0]const u8) Error!void {
    const p = d.l.p;
    catalog.codeExecDialect(p, try std.mem.joinZ(p.arena, ";\n", list));
}

pub fn alterColumn(d: *Ddl, tab: *int.Table, ac: tree.AlterColumn) Error!void {
    const p = d.l.p;
    const arena = p.arena;
    const name = ac.name;
    const shown_table = ddl.shown(p.db, tab.name);
    const i = build.columnIndex(tab, name.text);
    if (i < 0) return d.l.failState(name.pos, .of("42703"), "column \"{s}\" of relation \"{s}\" does not exist", .{ name.text, shown_table });
    const icol: usize = @intCast(i);
    const col = &tab.cols[icol];
    const t = try target(d, tab);
    if (icol >= t.def.columns.len) return d.l.fail(name.pos, "the definition of table \"{s}\" could not be read", .{tab.name});
    const cdef = t.def.columns[icol];
    const meta = catalog.metaOf(p.db, tab) catch null;
    const identity = if (meta) |m| m.value(name.text, catalog.Key.identity_kind) != null else false;
    var edits: std.ArrayList(coldef.Edit) = .empty;
    switch (ac.op) {
        .set_default, .drop_default => {
            if (identity) return d.l.failState(name.pos, .of("42601"), "column \"{s}\" of relation \"{s}\" is an identity column", .{ name.text, shown_table });
            for (cdef.clauses) |c| if (c.kind == TK.DEFAULT) try edits.append(arena, coldef.remove(c));
            if (ac.op == .set_default) {
                var r = d.l.renderer();
                try r.colConstraint(ac.op.set_default);
                try edits.append(arena, .{ .start = cdef.end, .end = cdef.end, .text = try r.text() });
            } else if (edits.items.len == 0) return;
            fillRows(d, t, name.text);
        },
        .set_not_null => {
            if (col.not_null != .None) return;
            const msg = try std.fmt.allocPrint(arena, "column \"{s}\" of relation \"{s}\" contains null values", .{ name.text, shown_table });
            try failIfAny(d, t, try std.fmt.allocPrint(arena, "{f} IS NULL", .{Quoted{ .z = name.text }}), msg, RC.CONSTRAINT_NOTNULL);
            try edits.append(arena, .{ .start = cdef.end, .end = cdef.end, .text = " NOT NULL" });
        },
        .drop_not_null => {
            if (col.col_flags.PRIMKEY) return d.l.failState(name.pos, .of("42P16"), "column \"{s}\" is in a primary key", .{name.text});
            if (identity) return d.l.failState(name.pos, .of("42P16"), "column \"{s}\" of relation \"{s}\" is an identity column", .{ name.text, shown_table });
            for (cdef.clauses) |c| if (c.kind == TK.NOT) try edits.append(arena, coldef.remove(c));
        },
        .set_type => |st| {
            const storage = st.def.type orelse "ANY";
            if (tab.i_pkey >= 0 and icol == @as(usize, @intCast(tab.i_pkey)) and !std.mem.eql(u8, storage, "INTEGER")) {
                return d.l.failState(name.pos, .of("0A000"), "changing the type of an integer primary key column is not supported", .{});
            }
            if (cdef.type_end > cdef.type_start) {
                try edits.append(arena, .{ .start = cdef.type_start, .end = cdef.type_end, .text = storage });
            } else {
                try edits.append(arena, .{ .start = cdef.name_end, .end = cdef.name_end, .text = try std.fmt.allocPrint(arena, " {s}", .{storage}) });
            }
            for (cdef.clauses) |c| {
                const drop = c.kind == TK.COLLATE or (c.kind == TK.CHECK and types.isCheckName(try c.dequoted(arena)));
                if (drop) try edits.append(arena, coldef.remove(c));
            }
            var r = d.l.renderer();
            for (st.def.constraints) |cc| switch (cc.kind) {
                .check, .collate => try r.colConstraint(cc),
                else => {},
            };
            const added = try r.text();
            if (added.len > 0) try edits.append(arena, .{ .start = cdef.end, .end = cdef.end, .text = added });
        },
    }
    try write(d, t, edits.items);
    if (ac.op == .set_type) {
        const st = ac.op.set_type;
        // The values, as the new type has them (when the schema of the
        // new type is read).
        try setColumn(d, t.schema, t.i_db, tab.name, name.text, st.using);
        if (st.def.decl_type) |dt| catalog.codeSet(p, t.schema, tab.name, name.text, catalog.Key.decl_type, dt);
    }
}

pub fn addConstraint(d: *Ddl, a: *const tree.AlterTable, tab: *int.Table, tc_in: tree.TableConstraint) Error!void {
    const p = d.l.p;
    const arena = p.arena;
    const shown_table = ddl.shown(p.db, tab.name);
    var tc = tc_in;
    const t = try target(d, tab);
    // PostgreSQL's names (ChooseConstraintName()): t_a_fkey, t_a_b_key,
    // t_a_check (t_check of no column or of several), numbered from 1
    // while taken.
    if (tc.name == null) {
        var one: ?[]const u8 = null;
        var many = false;
        const cols: []const tree.Name, const suffix: []const u8 = switch (tc.kind) {
            .foreign_key => |fk| .{ fk.cols, "fkey" },
            .unique => |u| .{ u, "key" },
            .check => |e| blk: {
                soleColumn(e, &one, &many);
                break :blk .{ &.{}, "check" };
            },
            .primary_key => unreachable,
        };
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, Violation.bare(tab.name));
        for (cols) |c| try out.print(arena, "_{s}", .{c.text});
        if (one != null and !many) try out.print(arena, "_{s}", .{one.?});
        try out.print(arena, "_{s}", .{suffix});
        const base = out.items;
        var n: usize = 0;
        var name: []const u8 = base;
        while (try taken(d, t, name)) {
            n += 1;
            name = try std.fmt.allocPrint(arena, "{s}{d}", .{ base, n });
        }
        tc.name = name;
    }
    const cname = tc.name.?;
    if (try taken(d, t, cname)) {
        return d.l.failState(a.name.name.pos, .of("42710"), "constraint \"{s}\" for relation \"{s}\" already exists", .{ cname, shown_table });
    }
    switch (tc.kind) {
        .check => |e| {
            const cond = try @import("../../ir/render.zig").expr(p, d.l.src, e);
            const msg = try std.fmt.allocPrint(arena, "check constraint \"{s}\" of relation \"{s}\" is violated by some row", .{ cname, shown_table });
            try failIfAny(d, t, try std.fmt.allocPrint(arena, "({s}) IS FALSE", .{cond}), msg, RC.CONSTRAINT_CHECK);
        },
        .foreign_key => |fk| {
            const parent = build.findTable(p.db, fk.ref.table.text, t.schema) orelse
                return d.l.failState(fk.ref.table.pos, .of("42P01"), "relation \"{s}\" does not exist", .{ddl.shown(p.db, fk.ref.table.text)});
            var refs: std.ArrayList([]const u8) = .empty;
            if (fk.ref.cols.len > 0) {
                try requireColumns(d, parent, fk.ref.cols);
                for (fk.ref.cols) |c| try refs.append(arena, c.text);
            } else for (parent.cols) |*c| if (c.col_flags.PRIMKEY) try refs.append(arena, c.name());
            if (refs.items.len != fk.cols.len) return d.l.failState(a.name.name.pos, .of("42830"), "number of referencing and referenced columns for foreign key disagree", .{});
            try requireColumns(d, tab, fk.cols);
            // A row of the child whose key the parent does not have.
            var cond: std.ArrayList(u8) = .empty;
            for (fk.cols) |c| try cond.print(arena, "{f} IS NOT NULL AND ", .{Quoted{ .z = c.text }});
            try cond.print(arena, "NOT EXISTS (SELECT 1 FROM {f}.{f} AS xq_parent WHERE ", .{ Quoted{ .z = t.schema }, Quoted{ .z = parent.name } });
            for (fk.cols, refs.items, 0..) |c, r, k| {
                if (k > 0) try cond.appendSlice(arena, " AND ");
                try cond.print(arena, "xq_parent.{f} = {f}.{f}", .{ Quoted{ .z = r }, Quoted{ .z = tab.name }, Quoted{ .z = c.text } });
            }
            try cond.append(arena, ')');
            const msg = try std.fmt.allocPrint(arena, "insert or update on table \"{s}\" violates foreign key constraint \"{s}\"", .{ shown_table, cname });
            try failIfAny(d, t, cond.items, msg, RC.CONSTRAINT_FOREIGNKEY);
            try record(d, t, .foreign_key, fk.cols, cname);
        },
        .unique => |u| {
            const items = try arena.alloc(tree.IndexItem, u.len);
            for (items, u) |*it, c| {
                const names = try arena.alloc(tree.Name, 1);
                names[0] = c;
                it.* = .{ .expr = try tree.expr(arena, c.pos, c.pos, .{ .column = names }) };
            }
            const ci: tree.CreateIndex = .{ .unique = true, .name = .{ .schema = .{ .text = t.schema }, .name = .{ .text = cname, .pos = a.name.name.pos } }, .table = .{ .text = tab.name, .pos = a.name.name.pos }, .items = items };
            try d.l.createIndex(&ci);
            return record(d, t, .unique, u, cname);
        },
        .primary_key => unreachable,
    }
    var r = d.l.renderer();
    try r.put(", ");
    try r.tableConstraint(tc);
    var edits = [_]coldef.Edit{.{ .start = t.def.close, .end = t.def.close, .text = try r.text() }};
    try write(d, t, &edits);
}

/// Fail unless each of `cols` is a column of `tab`.
fn requireColumns(d: *Ddl, tab: *int.Table, cols: []const tree.Name) Error!void {
    for (cols) |c| if (build.columnIndex(tab, c.text) < 0) {
        return d.l.failState(c.pos, .of("42703"), "column \"{s}\" referenced in foreign key constraint does not exist", .{c.text});
    };
}

/// The catalog's record of the name of the constraint on `cols`.
fn record(d: *Ddl, t: Target, kind: Violation.Kind, cols: []const tree.Name, cname: []const u8) Error!void {
    const a = d.l.p.arena;
    const names = try a.alloc([]const u8, cols.len);
    for (names, cols) |*z, c| z.* = c.text;
    catalog.codeSet(d.l.p, t.schema, t.tab.name, "", try dconstraint.key(a, kind, names), cname);
}

/// Whether constraint name `n` is taken: by a constraint of the table,
/// or (as the name of a UNIQUE's index) by a relation.
fn taken(d: *Ddl, t: Target, n: []const u8) Error!bool {
    if (try coldefFind(d.l.p.arena, t.def, n) != null) return true;
    return ddl.relationExists(d.l.p.db, n, t.schema);
}

/// The column `e` names, in `one`, `many` if it names several.
fn soleColumn(e: *const tree.Expr, one: *?[]const u8, many: *bool) void {
    if (e.kind == .column) {
        const names = e.kind.column;
        const c = names[names.len - 1].text;
        if (one.*) |x| {
            if (!std.mem.eql(u8, x, c)) many.* = true;
        } else one.* = c;
        return;
    }
    var it = @import("jtype.zig").Children.of(e);
    while (it.next()) |x| soleColumn(x, one, many);
}

fn coldefFind(a: std.mem.Allocator, t: coldef.Table, n: []const u8) Error!?coldef.Clause {
    return coldef.find(a, t, n) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        error.Malformed => null,
    };
}

pub fn dropConstraint(d: *Ddl, tab: *int.Table, name: tree.Name, if_exists: bool) Error!void {
    const p = d.l.p;
    const shown_table = ddl.shown(p.db, tab.name);
    const t = try target(d, tab);
    // The catalog's record of its name.
    const forget = struct {
        fn f(pp: *Parse, schema: []const u8, table: []const u8, n: []const u8) void {
            if (!catalog.exists(pp.db, schema)) return;
            catalog.codeExecFmt(pp, schema, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q AND col='' AND key LIKE 'constraint:%%' AND value=%Q", &.{
                .{ .str = schema }, .{ .str = table }, .{ .str = n },
            });
        }
    }.f;
    // A UNIQUE constraint: its index.
    if (build.findIndex(p.db, name.text, t.schema)) |ix| if (ix.table == tab and ix.on_error != .None) {
        const drop: tree.Drop = .{ .kind = .index, .name = .{ .schema = .{ .text = t.schema }, .name = name } };
        try d.l.drop(&drop);
        forget(p, t.schema, tab.name, name.text);
        return;
    };
    const found = try coldefFind(p.arena, t.def, name.text) orelse {
        if (if_exists) return ddl.notice(p, "00000", "constraint \"{s}\" of relation \"{s}\" does not exist, skipping", .{ name.text, shown_table });
        return d.l.failState(name.pos, .of("42704"), "constraint \"{s}\" of relation \"{s}\" does not exist", .{ name.text, shown_table });
    };
    var edits = [_]coldef.Edit{coldef.remove(found)};
    try write(d, t, &edits);
    forget(p, t.schema, tab.name, name.text);
}
