//! PostgreSQL DDL: rendered as SQLite text (STRICT tables, the checks of
//! types.zig, identity defaults) and lowered with ir.stmt.lowerSqliteText(),
//! with the dialect's metadata recorded in the same statement:
//!
//!  - xq_catalog: the table's dialect, each column's declared type
//!    (format_type() spelling), identity sequences and their kind;
//!  - xq_sequence: the sequences of CREATE SEQUENCE, SERIAL and
//!    GENERATED ... AS IDENTITY (named <table>_<column>_seq, as in
//!    PostgreSQL), dropped with their table.
//!
//! An identity column is `INTEGER ... DEFAULT (nextval('seq')) NOT
//! NULL`; when it is the primary key it is SQLite's INTEGER PRIMARY KEY
//! (the rowid), which lower.zig numbers from the sequence when an INSERT
//! leaves it out.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const sequence = catalog.sequence;
const ast = @import("ast.zig");
const types = @import("types.zig");
const render = @import("render.zig");
const lower = @import("lower.zig");

const Parse = int.Parse;
const Renderer = render.Renderer;
pub const Error = render.Error;

pub const Ddl = struct {
    p: *Parse,
    src: [:0]const u8,

    fn arena(d: *Ddl) std.mem.Allocator {
        return d.p.arena;
    }

    fn renderer(d: *Ddl) Renderer {
        return .{ .p = d.p, .src = d.src };
    }

    fn fail(d: *Ddl, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        var r = d.renderer();
        return r.fail(pos, fmt, args);
    }

    fn check(d: *Ddl) Error!void {
        if (d.p.n_err > 0) return error.Failed;
    }

    fn lowerText(d: *Ddl, text: [:0]const u8) Error!void {
        try ir.stmt.lowerSqliteText(d.p, text);
        try d.check();
    }

    fn readSchema(d: *Ddl) Error!void {
        ir.stmt.readSchema(d.p) catch return error.Failed;
    }

    /// The SQLite database of a qualified name: main, or temp.
    fn schemaOf(d: *Ddl, q: ast.QName, temp: bool) Error![]const u8 {
        if (q.schema) |s| {
            if (std.mem.eql(u8, s.text, "public")) return "main";
            if (std.mem.eql(u8, s.text, "pg_temp")) return "temp";
            return d.fail(s.pos, "schema \"{s}\" does not exist", .{s.text});
        }
        return if (temp) "temp" else "main";
    }

    pub fn statement(d: *Ddl, s: ast.Stmt) Error!void {
        switch (s) {
            .create_table => |x| try d.createTable(x),
            .create_index => |x| try d.createIndex(x),
            .create_view => |x| try d.createView(x),
            .create_sequence => |x| try d.createSequence(x),
            .alter_table => |x| try d.alterTable(x),
            .drop => |x| try d.drop(x),
            else => unreachable,
        }
        try d.check();
    }

    // ========================================================= columns

    /// What CREATE TABLE records for a column.
    const ColumnMeta = struct {
        name: []const u8,
        decl: []const u8,
        identity: ?[]const u8 = null,
        /// "always" or "by default" (GENERATED ... AS IDENTITY).
        identity_kind: ?[]const u8 = null,
        seq_opts: sequence.Options = .{},
    };

    /// Render a column definition of table `table` into `r`.
    fn column(d: *Ddl, r: *Renderer, table: []const u8, c: ast.ColumnDef) Error!ColumnMeta {
        const info = types.info(c.ty) catch |err| return switch (err) {
            error.Array => d.fail(c.ty.pos, "arrays are not supported", .{}),
            error.UnknownType => d.fail(c.ty.pos, "type \"{s}\" does not exist", .{c.ty.name}),
        };
        var meta: ColumnMeta = .{ .name = c.name.text, .decl = try types.format(d.arena(), c.ty) };
        var identity: ?ast.Identity = null;
        var has_default = false;
        for (c.constraints) |cc| switch (cc.kind) {
            .identity => |id| identity = id,
            .default => has_default = true,
            else => {},
        };
        if (identity != null and info.serial) return d.fail(c.name.pos, "multiple default values specified for column \"{s}\" of table \"{s}\"", .{ c.name.text, table });
        if ((identity != null or info.serial) and has_default) return d.fail(c.name.pos, "multiple default values specified for column \"{s}\" of table \"{s}\"", .{ c.name.text, table });
        if (identity != null) {
            if (info.storage[0] != 'I') return d.fail(c.ty.pos, "identity column type must be smallint, integer, or bigint", .{});
        }
        try r.ident(c.name.text);
        try r.print(" {s}", .{info.storage});
        if (identity != null or info.serial) {
            const seq = try std.fmt.allocPrint(d.arena(), "{s}_{s}_seq", .{ table, c.name.text });
            meta.identity = seq;
            if (identity) |id| {
                meta.identity_kind = if (id.always) "always" else "by default";
                meta.seq_opts = .{ .start = id.opts.start, .increment = id.opts.increment orelse 1, .min = id.opts.min, .max = id.opts.max, .cycle = id.opts.cycle orelse false };
            }
            // The range of the column's type bounds the sequence.
            if (meta.seq_opts.max == null and (meta.seq_opts.increment > 0)) {
                if (info.check == .smallint_range) meta.seq_opts.max = 32767;
                if (info.check == .integer_range) meta.seq_opts.max = 2147483647;
            }
            try r.put(" NOT NULL DEFAULT (nextval(");
            try r.string(seq);
            try r.put("))");
        }
        for (c.constraints) |cc| {
            if (cc.name) |n| {
                try r.put(" CONSTRAINT ");
                try r.ident(n.text);
            }
            switch (cc.kind) {
                .not_null => try r.put(" NOT NULL"),
                .null => {},
                .check => |e| {
                    if (cc.name == null) {
                        try r.put(" CONSTRAINT ");
                        try r.ident(try std.fmt.allocPrint(d.arena(), "{s}_{s}_check", .{ table, c.name.text }));
                    }
                    try r.put(" CHECK(");
                    try r.expr(e);
                    try r.put(")");
                },
                .default => |e| {
                    try r.put(" DEFAULT (");
                    try r.expr(e);
                    try r.put(")");
                },
                .primary_key => try r.put(" PRIMARY KEY"),
                .unique => try r.put(" UNIQUE"),
                .references => |ref| try d.references(r, ref),
                .identity => {},
                .generated => |e| {
                    try r.put(" GENERATED ALWAYS AS (");
                    try r.expr(e);
                    try r.put(") STORED");
                },
            }
        }
        if (c.collate) |coll| {
            try r.put(" COLLATE ");
            try r.collation(coll);
        }
        try d.typeCheck(r, c, info);
        return meta;
    }

    /// The CHECK constraint of a type, named with PostgreSQL's message.
    fn typeCheck(d: *Ddl, r: *Renderer, c: ast.ColumnDef, info: types.Info) Error!void {
        _ = d;
        const name = c.name.text;
        switch (info.check) {
            .none => {},
            .smallint_range, .integer_range => {
                const small = info.check == .smallint_range;
                try r.put(if (small) " CONSTRAINT \"smallint out of range\" CHECK(" else " CONSTRAINT \"integer out of range\" CHECK(");
                try r.ident(name);
                try r.put(if (small) " BETWEEN -32768 AND 32767)" else " BETWEEN -2147483648 AND 2147483647)");
            },
            .numeric => {
                try r.put(" CONSTRAINT \"invalid input syntax for type numeric\" CHECK(typeof(");
                try r.ident(name);
                try r.put(") IN ('integer', 'real', 'null'))");
            },
            .boolean => {
                try r.put(" CONSTRAINT \"invalid input syntax for type boolean\" CHECK(");
                try r.ident(name);
                try r.put(" IN (0, 1))");
            },
            .length => {
                const n = types.maxLength(c.ty).?;
                const tname = if (std.mem.eql(u8, c.ty.name, "character")) "character" else "character varying";
                try r.print(" CONSTRAINT \"value too long for type {s}({d})\" CHECK(length(", .{ tname, n });
                try r.ident(name);
                try r.print(") <= {d})", .{n});
            },
            .json => {
                try r.put(" CONSTRAINT \"invalid input syntax for type json\" CHECK(json_valid(");
                try r.ident(name);
                try r.put("))");
            },
        }
    }

    fn references(d: *Ddl, r: *Renderer, ref: ast.Ref) Error!void {
        _ = d;
        try r.put(" REFERENCES ");
        try r.ident(ref.table.name.text);
        if (ref.cols.len > 0) {
            try r.put("(");
            for (ref.cols, 0..) |c, i| {
                if (i > 0) try r.put(", ");
                try r.ident(c.text);
            }
            try r.put(")");
        }
        const acts = [_]struct { ast.RefAction, []const u8 }{
            .{ ref.on_delete, " ON DELETE " }, .{ ref.on_update, " ON UPDATE " },
        };
        for (acts) |x| if (x[0] != .none) {
            try r.put(x[1]);
            try r.put(switch (x[0]) {
                .restrict => "RESTRICT",
                .cascade => "CASCADE",
                .set_null => "SET NULL",
                .set_default => "SET DEFAULT",
                .none => unreachable,
            });
        };
        if (ref.deferred) try r.put(" DEFERRABLE INITIALLY DEFERRED");
    }

    fn nameList(r: *Renderer, names: []const ast.Name) Error!void {
        try r.put("(");
        for (names, 0..) |n, i| {
            if (i > 0) try r.put(", ");
            try r.ident(n.text);
        }
        try r.put(")");
    }

    // ==================================================== CREATE TABLE

    fn createTable(d: *Ddl, ct: *const ast.CreateTable) Error!void {
        const p = d.p;
        try d.readSchema();
        const schema = try d.schemaOf(ct.name, ct.temp);
        const table = ct.name.name.text;
        var r = d.renderer();
        try r.put(if (ct.temp) "CREATE TEMP TABLE " else "CREATE TABLE ");
        if (ct.if_not_exists) try r.put("IF NOT EXISTS ");
        if (ct.temp) try r.ident(table) else {
            if (ct.name.schema != null) try r.put("\"main\".");
            try r.ident(table);
        }
        const exists = build.findTable(p.db, table, schema) != null;
        if (ct.as_select) |s| {
            try r.put(" AS ");
            try r.select(s);
            try d.lowerText(try r.text());
            if (!(ct.if_not_exists and exists)) {
                catalog.codeDeleteTable(p, schema, table);
                catalog.codeSet(p, schema, table, "", catalog.Key.dialect, "postgres");
            }
            return;
        }
        if (ct.columns.len == 0) return d.fail(ct.name.name.pos, "a table must have at least one column", .{});
        var metas: std.ArrayList(ColumnMeta) = .empty;
        try r.put("(");
        for (ct.columns, 0..) |c, i| {
            if (i > 0) try r.put(", ");
            for (ct.columns[0..i]) |prev| if (std.mem.eql(u8, prev.name.text, c.name.text)) {
                return d.fail(c.name.pos, "column \"{s}\" specified more than once", .{c.name.text});
            };
            try metas.append(d.arena(), try d.column(&r, table, c));
        }
        for (ct.constraints) |tc| {
            try r.put(", ");
            if (tc.name) |n| {
                try r.put("CONSTRAINT ");
                try r.ident(n.text);
                try r.put(" ");
            }
            switch (tc.kind) {
                .check => |e| {
                    if (tc.name == null) {
                        try r.put("CONSTRAINT ");
                        try r.ident(try std.fmt.allocPrint(d.arena(), "{s}_check", .{table}));
                        try r.put(" ");
                    }
                    try r.put("CHECK(");
                    try r.expr(e);
                    try r.put(")");
                },
                .unique => |cols| {
                    try r.put("UNIQUE");
                    try nameList(&r, cols);
                },
                .primary_key => |cols| {
                    try r.put("PRIMARY KEY");
                    try nameList(&r, cols);
                },
                .foreign_key => |fk| {
                    try r.put("FOREIGN KEY");
                    try nameList(&r, fk.cols);
                    try d.references(&r, fk.ref);
                },
            }
        }
        try r.put(") STRICT");
        try d.lowerText(try r.text());
        if (ct.if_not_exists and exists) return;

        // The catalog, in the same statement.
        catalog.codeDeleteTable(p, schema, table);
        catalog.codeSet(p, schema, table, "", catalog.Key.dialect, "postgres");
        for (metas.items) |m| {
            catalog.codeSet(p, schema, table, m.name, catalog.Key.decl_type, m.decl);
            if (m.identity) |seq_name| {
                const seq = seq_name;
                if (sequenceExists(p.db, seq)) return d.fail(ct.name.name.pos, "relation \"{s}\" already exists", .{seq});
                catalog.codeSet(p, schema, table, m.name, catalog.Key.identity, seq);
                if (m.identity_kind) |kind| catalog.codeSet(p, schema, table, m.name, catalog.Key.identity_kind, kind);
                sequence.codeCreate(p, catalog.main_schema, seq, m.seq_opts, false);
            }
        }
    }

    // ===================================================== CREATE INDEX

    fn createIndex(d: *Ddl, ci: *const ast.CreateIndex) Error!void {
        try d.readSchema();
        const schema = try d.schemaOf(ci.table, false);
        const table = ci.table.name.text;
        const name: []const u8 = if (ci.name) |n| n.text else try d.indexName(table, ci.items, schema);
        var r = d.renderer();
        try r.put(if (ci.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
        if (ci.if_not_exists) try r.put("IF NOT EXISTS ");
        if (ci.table.schema != null) try r.put("\"main\".");
        try r.ident(name);
        try r.put(" ON ");
        try r.ident(table);
        try r.put("(");
        for (ci.items, 0..) |it, i| {
            if (i > 0) try r.put(", ");
            if (it.expr.kind == .column and it.expr.kind.column.len == 1) {
                try r.ident(it.expr.kind.column[0].text);
            } else {
                try r.put("(");
                try r.expr(it.expr);
                try r.put(")");
            }
            if (it.collate) |c| {
                try r.put(" COLLATE ");
                try r.collation(c);
            }
            if (it.desc) try r.put(" DESC");
        }
        try r.put(")");
        if (ci.where) |w| {
            try r.put(" WHERE ");
            try r.expr(w);
        }
        try d.lowerText(try r.text());
    }

    /// PostgreSQL's name for an index without one: <table>_<columns>_idx
    /// ("expr" for an expression), numbered if taken.
    fn indexName(d: *Ddl, table: []const u8, items: []const ast.IndexItem, schema: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(d.arena(), table);
        for (items) |it| {
            try out.append(d.arena(), '_');
            if (it.expr.kind == .column) {
                const names = it.expr.kind.column;
                try out.appendSlice(d.arena(), names[names.len - 1].text);
            } else try out.appendSlice(d.arena(), "expr");
        }
        const base = out.items;
        var name = try std.fmt.allocPrint(d.arena(), "{s}_idx", .{base});
        var k: usize = 1;
        while (relationExists(d.p.db, name, schema)) : (k += 1) {
            name = try std.fmt.allocPrint(d.arena(), "{s}_idx{d}", .{ base, k });
        }
        return name;
    }

    // ====================================================== CREATE VIEW

    fn createView(d: *Ddl, v: *const ast.CreateView) Error!void {
        const p = d.p;
        try d.readSchema();
        const schema = try d.schemaOf(v.name, v.temp);
        const name = v.name.name.text;
        const replace = v.or_replace and build.findTable(p.db, name, schema) != null;
        if (replace) {
            var drop_text = d.renderer();
            try drop_text.put("DROP VIEW ");
            try drop_text.ident(schema);
            try drop_text.put(".");
            try drop_text.ident(name);
            try d.lowerText(try drop_text.text());
        }
        var r = d.renderer();
        try r.put(if (v.temp) "CREATE TEMP VIEW " else "CREATE VIEW ");
        if (!v.temp) {
            try r.ident(schema);
            try r.put(".");
        }
        try r.ident(name);
        if (v.cols.len > 0) try nameList(&r, v.cols);
        try r.put(" AS ");
        try r.select(v.select);
        if (replace) {
            // The old view is still in the schema while this compiles: the
            // new one is created when the statement runs, after the DROP.
            const i_db = catalog.schemaIndex(p, schema) orelse return error.Failed;
            catalog.codeExec(p, i_db, try r.text());
        } else {
            try d.lowerText(try r.text());
        }
        catalog.codeDeleteTable(p, schema, name);
        catalog.codeSet(p, schema, name, "", catalog.Key.dialect, "postgres");
    }

    // ================================================== CREATE SEQUENCE

    fn createSequence(d: *Ddl, s: *const ast.CreateSequence) Error!void {
        const p = d.p;
        try d.readSchema();
        _ = try d.schemaOf(s.name, false);
        const name = s.name.name.text;
        if (relationExists(p.db, name, catalog.main_schema) or sequenceExists(p.db, name)) {
            if (s.if_not_exists) return;
            return d.fail(s.name.name.pos, "relation \"{s}\" already exists", .{name});
        }
        const o = s.opts;
        sequence.codeCreate(p, catalog.main_schema, name, .{
            .start = o.start,
            .increment = o.increment orelse 1,
            .min = o.min,
            .max = o.max,
            .cycle = o.cycle orelse false,
        }, false);
    }

    // ===================================================== ALTER TABLE

    fn alterTable(d: *Ddl, a: *const ast.AlterTable) Error!void {
        const p = d.p;
        try d.readSchema();
        const schema = try d.schemaOf(a.name, false);
        const table = a.name.name.text;
        const tab = build.findTable(p.db, table, if (a.name.schema != null) schema else null) orelse {
            if (a.if_exists) return;
            return d.fail(a.name.name.pos, "relation \"{s}\" does not exist", .{table});
        };
        const db_name = schemaName(p.db, tab);
        var r = d.renderer();
        try r.put("ALTER TABLE ");
        try r.ident(db_name);
        try r.put(".");
        try r.ident(table);
        const has_catalog = catalog.exists(p.db, db_name);
        switch (a.action) {
            .rename_to => |n| {
                try r.put(" RENAME TO ");
                try r.ident(n.text);
                try d.lowerText(try r.text());
                catalog.codeRenameTable(p, db_name, table, n.text);
            },
            .rename_column => |rc| {
                try r.put(" RENAME COLUMN ");
                try r.ident(rc.old.text);
                try r.put(" TO ");
                try r.ident(rc.new.text);
                try d.lowerText(try r.text());
                if (has_catalog) catalog.codeExecFmt(p, db_name, "UPDATE %Q.xq_catalog SET col=%Q WHERE tbl=%Q AND col=%Q", &.{
                    .{ .str = db_name }, .{ .str = rc.new.text }, .{ .str = table }, .{ .str = rc.old.text },
                });
            },
            .add_column => |ac| {
                if (columnExists(tab, ac.def.name.text)) {
                    if (ac.if_not_exists) return;
                    return d.fail(ac.def.name.pos, "column \"{s}\" of relation \"{s}\" already exists", .{ ac.def.name.text, table });
                }
                try r.put(" ADD COLUMN ");
                const meta = try d.column(&r, table, ac.def);
                if (meta.identity != null) return d.fail(ac.def.name.pos, "adding an identity or serial column is not supported", .{});
                try d.lowerText(try r.text());
                catalog.codeSet(p, db_name, table, meta.name, catalog.Key.decl_type, meta.decl);
            },
            .drop_column => |dc| {
                if (!columnExists(tab, dc.name.text)) {
                    if (dc.if_exists) return;
                    return d.fail(dc.name.pos, "column \"{s}\" of relation \"{s}\" does not exist", .{ dc.name.text, table });
                }
                try r.put(" DROP COLUMN ");
                try r.ident(dc.name.text);
                try d.lowerText(try r.text());
                if (has_catalog) {
                    if (sequenceTableExists(p.db)) catalog.codeExecFmt(p, db_name, "DELETE FROM main.xq_sequence WHERE name IN (SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q AND key='identity')", &.{
                        .{ .str = db_name }, .{ .str = table }, .{ .str = dc.name.text },
                    });
                    catalog.codeExecFmt(p, db_name, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q", &.{
                        .{ .str = db_name }, .{ .str = table }, .{ .str = dc.name.text },
                    });
                }
            },
        }
    }

    // ============================================================ DROP

    fn drop(d: *Ddl, x: *const ast.Drop) Error!void {
        const p = d.p;
        try d.readSchema();
        if (x.names.len > 1) return d.fail(x.names[1].name.pos, "dropping several objects in one statement is not supported", .{});
        const q = x.names[0];
        const name = q.name.text;
        var l: lower.Lowerer = .{ .p = p, .src = d.src };
        switch (x.kind) {
            .table, .view => {
                const db: ?[]const u8 = if (q.schema != null) try d.schemaOf(q, false) else null;
                const tab = build.findTable(p.db, name, db);
                if (tab == null and !x.if_exists) {
                    return d.fail(q.name.pos, "{s} \"{s}\" does not exist", .{ if (x.kind == .table) "table" else "view", name });
                }
                const src = try ir.from.fullName(p, if (db) |s| int.Token.init(s) else try l.nameTok(q.name), if (db != null) try l.nameTok(q.name) else .{}, .{});
                ir.ddl.dropTable(p, src, x.kind == .view, x.if_exists);
                try d.check();
                if (tab) |t| {
                    const db_name = schemaName(p.db, t);
                    if (catalog.exists(p.db, db_name)) {
                        if (x.kind == .table and sequenceTableExists(p.db)) {
                            catalog.codeExecFmt(p, db_name, "DELETE FROM main.xq_sequence WHERE name IN (SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND key='identity')", &.{
                                .{ .str = db_name }, .{ .str = name },
                            });
                        }
                        catalog.codeDeleteTable(p, db_name, name);
                    }
                }
            },
            .index => {
                const db: ?[]const u8 = if (q.schema != null) try d.schemaOf(q, false) else null;
                const src = try ir.from.fullName(p, if (db) |s| int.Token.init(s) else try l.nameTok(q.name), if (db != null) try l.nameTok(q.name) else .{}, .{});
                ir.ddl.dropIndex(p, src, x.if_exists);
            },
            .sequence => {
                if (!sequenceExists(p.db, name)) {
                    if (x.if_exists) return;
                    return d.fail(q.name.pos, "sequence \"{s}\" does not exist", .{name});
                }
                sequence.codeDrop(p, catalog.main_schema, name);
            },
        }
    }
};

fn schemaName(db: *int.Sqlite3, t: *int.Table) []const u8 {
    for (db.dbs.items) |x| if (t.schema != null and x.schema == t.schema.?) return x.name;
    return "main";
}

fn columnExists(t: *int.Table, name: []const u8) bool {
    for (t.cols) |*c| if (std.ascii.eqlIgnoreCase(c.name(), name)) return true;
    return false;
}

fn relationExists(db: *int.Sqlite3, name: []const u8, schema: []const u8) bool {
    if (build.findTable(db, name, schema) != null) return true;
    const i = build.findDbName(db, schema) orelse return false;
    return db.dbs.items[i].schema.idx_hash.get(name) != null;
}

fn sequenceTableExists(db: *int.Sqlite3) bool {
    return build.findTable(db, sequence.table_name, catalog.main_schema) != null;
}

/// Whether sequence `name` exists (a query of xq_sequence, now).
pub fn sequenceExists(db: *int.Sqlite3, name: []const u8) bool {
    if (!sequenceTableExists(db)) return false;
    var q = catalog.Query.initFmt(db, "SELECT 1 FROM main.xq_sequence WHERE name=%Q", &.{.{ .str = name }}) catch return false;
    defer q.deinit();
    return q.step() catch false;
}
