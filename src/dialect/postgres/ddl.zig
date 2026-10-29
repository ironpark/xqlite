//! PostgreSQL DDL: the checks PostgreSQL reports in its own words before
//! the statement is lowered by the IR (src/ir/lower.zig renders it as
//! SQLite text with ir/render.zig and records the catalog in the same
//! statement), and PostgreSQL's name of an index without one.
//!
//! The tree comes from parser.zig with PostgreSQL's DDL resolved: STRICT
//! storage types with the checks of types.zig, the declared types
//! (format_type() spelling) for xq_catalog, and SERIAL and GENERATED ...
//! AS IDENTITY as tree.Identity columns numbered by a sequence named
//! <table>_<column>_seq (as in PostgreSQL), which the IR creates with the
//! table and drops with it. An identity column is `INTEGER ... NOT NULL
//! DEFAULT (nextval('seq'))`; when it is the primary key it is SQLite's
//! INTEGER PRIMARY KEY (the rowid), which the IR numbers from the
//! sequence when an INSERT leaves it out.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const sequence = catalog.sequence;

const Parse = int.Parse;
pub const Error = lower.Error;

pub const Ddl = struct {
    l: lower.Lowerer,

    pub fn init(p: *Parse, src: [:0]const u8) Ddl {
        return .{ .l = .init(p, src) };
    }

    fn fail(d: *Ddl, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        return d.l.fail(pos, fmt, args);
    }

    fn readSchema(d: *Ddl) Error!void {
        ir.stmt.readSchema(d.l.p) catch return error.Failed;
    }

    pub fn statement(d: *Ddl, s: tree.Stmt) Error!void {
        try d.readSchema();
        switch (s) {
            .create_table => |x| try d.createTable(x),
            .create_index => |x| try d.createIndex(x),
            .create_view => |x| try d.l.createView(x),
            .create_sequence => |x| try d.createSequence(x),
            .alter_table => |x| try d.alterTable(x),
            .drop => |x| try d.drop(x),
            else => unreachable,
        }
        if (d.l.p.n_err > 0) return error.Failed;
    }

    fn createTable(d: *Ddl, ct: *const tree.CreateTable) Error!void {
        const p = d.l.p;
        const schema: []const u8 = if (ct.temp) "temp" else "main";
        // A sequence of an identity column that exists already.
        if (!(ct.if_not_exists and build.findTable(p.db, ct.name.name.text, schema) != null)) {
            for (ct.columns) |c| for (c.constraints) |cc| if (cc.kind == .identity) {
                const seq = cc.kind.identity.sequence;
                if (sequenceExists(p.db, seq)) return d.fail(ct.name.name.pos, "relation \"{s}\" already exists", .{seq});
            };
        }
        try d.l.createTable(ct);
    }

    fn createIndex(d: *Ddl, ci: *const tree.CreateIndex) Error!void {
        var x = ci.*;
        if (x.name.name.text.len == 0) {
            const schema: []const u8 = if (x.name.schema) |s| s.text else "main";
            x.name.name = .{ .text = try d.indexName(ci.table.text, ci.items, schema), .pos = ci.table.pos };
        }
        try d.l.createIndex(&x);
    }

    /// PostgreSQL's name for an index without one: <table>_<columns>_idx
    /// ("expr" for an expression), numbered if taken.
    fn indexName(d: *Ddl, table: []const u8, items: []const tree.IndexItem, schema: []const u8) Error![]const u8 {
        const a = d.l.p.arena;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, table);
        for (items) |it| {
            try out.append(a, '_');
            if (it.expr.kind == .column) {
                const names = it.expr.kind.column;
                try out.appendSlice(a, names[names.len - 1].text);
            } else try out.appendSlice(a, "expr");
        }
        const base = out.items;
        var name = try std.fmt.allocPrint(a, "{s}_idx", .{base});
        var k: usize = 1;
        while (relationExists(d.l.p.db, name, schema)) : (k += 1) {
            name = try std.fmt.allocPrint(a, "{s}_idx{d}", .{ base, k });
        }
        return name;
    }

    fn createSequence(d: *Ddl, s: *const tree.CreateSequence) Error!void {
        const name = s.name.name.text;
        if (relationExists(d.l.p.db, name, catalog.main_schema) or sequenceExists(d.l.p.db, name)) {
            if (s.if_not_exists) return;
            return d.fail(s.name.name.pos, "relation \"{s}\" already exists", .{name});
        }
        d.l.createSequence(s);
    }

    fn alterTable(d: *Ddl, a: *const tree.AlterTable) Error!void {
        const p = d.l.p;
        const table = a.name.name.text;
        const tab = build.findTable(p.db, table, if (a.name.schema) |s| s.text else null) orelse {
            if (a.if_exists) return;
            return d.fail(a.name.name.pos, "relation \"{s}\" does not exist", .{table});
        };
        switch (a.action) {
            .add_column => |ac| if (build.columnIndex(tab, ac.def.name.text) >= 0) {
                if (ac.if_not_exists) return;
                return d.fail(ac.def.name.pos, "column \"{s}\" of relation \"{s}\" already exists", .{ ac.def.name.text, table });
            },
            .drop_column => |dc| if (build.columnIndex(tab, dc.name.text) < 0) {
                if (dc.if_exists) return;
                return d.fail(dc.name.pos, "column \"{s}\" of relation \"{s}\" does not exist", .{ dc.name.text, table });
            },
            else => {},
        }
        try d.l.alterTable(a);
    }

    fn drop(d: *Ddl, x: *const tree.Drop) Error!void {
        const p = d.l.p;
        const name = x.name.name.text;
        switch (x.kind) {
            .table, .view => {
                const db: ?[]const u8 = if (x.name.schema) |s| s.text else null;
                if (build.findTable(p.db, name, db) == null and !x.if_exists) {
                    return d.fail(x.name.name.pos, "{s} \"{s}\" does not exist", .{ if (x.kind == .table) "table" else "view", name });
                }
            },
            .sequence => if (!sequenceExists(p.db, name)) {
                if (x.if_exists) return;
                return d.fail(x.name.name.pos, "sequence \"{s}\" does not exist", .{name});
            },
            .index => {},
        }
        try d.l.drop(x);
    }
};

fn relationExists(db: *int.Sqlite3, name: []const u8, schema: []const u8) bool {
    if (build.findTable(db, name, schema) != null) return true;
    const i = build.findDbName(db, schema) orelse return false;
    return db.dbs.items[i].schema.idx_hash.get(name) != null;
}

/// Whether sequence `name` exists (a query of xq_sequence, now).
pub fn sequenceExists(db: *int.Sqlite3, name: []const u8) bool {
    if (!sequence.exists(db, catalog.main_schema)) return false;
    var q = catalog.Query.init(db, "SELECT 1 FROM main.xq_sequence WHERE name=?1") catch return false;
    defer q.deinit();
    q.bindText(1, name) catch return false;
    return q.step() catch false;
}
