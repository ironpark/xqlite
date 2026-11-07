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
const alter = @import("alter.zig");

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

    fn failState(d: *Ddl, pos: u32, state: int.ErrorState, comptime fmt: []const u8, args: anytype) Error {
        return d.l.failState(pos, state, fmt, args);
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
        const found: Existing = if (ct.if_not_exists) skipExisting(p, ct.name.name.text, schema, .table) else .none;
        // An index or a sequence of the name: nothing to make.
        if (found == .other) return;
        // A sequence of an identity column that exists already.
        if (found == .none) {
            for (ct.columns) |c| for (c.constraints) |cc| if (cc.kind == .identity) {
                const seq = cc.kind.identity.sequence;
                if (sequenceExists(p.db, seq)) return d.failState(ct.name.name.pos, .of("42P07"), "relation \"{s}\" already exists", .{shown(p.db, seq)});
            };
        }
        try d.l.createTable(ct);
    }

    fn createIndex(d: *Ddl, ci: *const tree.CreateIndex) Error!void {
        var x = ci.*;
        if (x.name.name.text.len == 0) {
            const schema: []const u8 = if (x.name.schema) |s| s.text else "main";
            x.name.name = .{ .text = try d.indexName(ci.table.text, ci.items, schema), .pos = ci.table.pos };
        } else if (ci.if_not_exists) {
            const schema: []const u8 = if (x.name.schema) |s| s.text else "main";
            if (skipExisting(d.l.p, x.name.name.text, schema, .index) == .other) return;
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
        if (s.if_not_exists) {
            if (skipExisting(d.l.p, name, catalog.main_schema, .sequence) != .none) return;
        } else if (existing(d.l.p.db, name, catalog.main_schema, .sequence) != .none) {
            return d.failState(s.name.name.pos, .of("42P07"), "relation \"{s}\" already exists", .{shown(d.l.p.db, name)});
        }
        d.l.createSequence(s);
    }

    fn alterTable(d: *Ddl, a: *const tree.AlterTable) Error!void {
        const p = d.l.p;
        const table = a.name.name.text;
        const tab = build.findTable(p.db, table, if (a.name.schema) |s| s.text else null) orelse {
            if (a.if_exists) return notice(p, "00000", "relation \"{s}\" does not exist, skipping", .{bare(p.db, table)});
            return d.failState(a.name.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{table});
        };
        if (a.steps.len > 0) return alter.steps(d, a.steps);
        switch (a.action) {
            .add_column => |ac| if (build.columnIndex(tab, ac.def.name.text) >= 0) {
                if (ac.if_not_exists) return notice(p, "42701", "column \"{s}\" of relation \"{s}\" already exists, skipping", .{ ac.def.name.text, shown(p.db, table) });
                return d.failState(ac.def.name.pos, .of("42710"), "column \"{s}\" of relation \"{s}\" already exists", .{ ac.def.name.text, shown(p.db, table) });
            },
            .drop_column => |dc| if (build.columnIndex(tab, dc.name.text) < 0) {
                if (dc.if_exists) return notice(p, "00000", "column \"{s}\" of relation \"{s}\" does not exist, skipping", .{ dc.name.text, shown(p.db, table) });
                return d.failState(dc.name.pos, .of("42703"), "column \"{s}\" of relation \"{s}\" does not exist", .{ dc.name.text, shown(p.db, table) });
            },
            else => {},
        }
        switch (a.action) {
            .add_column => |ac| if (alter.variableDefault(ac.def)) return alter.addColumn(d, a, tab),
            .alter_column => |ac| return alter.alterColumn(d, tab, ac),
            .add_constraint => |tc| return alter.addConstraint(d, a, tab, tc),
            .drop_constraint => |dc| return alter.dropConstraint(d, tab, dc.name, dc.if_exists),
            else => {},
        }
        try d.l.alterTable(a);
    }

    fn drop(d: *Ddl, x: *const tree.Drop) Error!void {
        const p = d.l.p;
        // Each name checked; a missing sequence of IF EXISTS left out.
        var names: std.ArrayList(tree.QName) = .empty;
        for (0..x.others.len + 1) |i| {
            const q = if (i == 0) x.name else x.others[i - 1];
            const name = q.name.text;
            switch (x.kind) {
                .table, .view => {
                    const db: ?[]const u8 = if (q.schema) |s| s.text else null;
                    if (build.findTable(p.db, name, db) == null) {
                        const kind = if (x.kind == .table) "table" else "view";
                        if (!x.if_exists) return d.failState(q.name.pos, .of("42P01"), "{s} \"{s}\" does not exist", .{ kind, shown(p.db, name) });
                        notice(p, "00000", "{s} \"{s}\" does not exist, skipping", .{ kind, bare(p.db, name) });
                    }
                    // Several tables of an auto-vacuum database: dropping one
                    // may move the root pages of the next (SQLite drops one
                    // table a statement).
                    if (x.others.len > 0) if (build.findDbName(p.db, db orelse "main")) |di| if (p.db.dbs.items[di].bt) |bt| if (@backingInt(bt.getAutoVacuum()) != 0) {
                        return d.failState(q.name.pos, .of("0A000"), "dropping several tables of an auto-vacuum database in one statement is not supported", .{});
                    };
                },
                .sequence => if (!sequenceExists(p.db, name)) {
                    if (x.if_exists) {
                        notice(p, "00000", "sequence \"{s}\" does not exist, skipping", .{bare(p.db, name)});
                        continue;
                    }
                    return d.failState(q.name.pos, .of("42704"), "sequence \"{s}\" does not exist", .{shown(p.db, name)});
                },
                .index => if (x.if_exists and build.findIndex(p.db, name, if (q.schema) |s| s.text else null) == null) {
                    notice(p, "00000", "index \"{s}\" does not exist, skipping", .{bare(p.db, name)});
                },
            }
            try names.append(p.arena, q);
        }
        if (names.items.len == 0) return;
        var all = x.*;
        all.name = names.items[0];
        all.others = names.items[1..];
        try d.l.drop(&all);
    }
};

/// PostgreSQL's NOTICE of statement `p` (util.notice()), which has a
/// program even when it does nothing else, so that it reports the notice
/// when it runs.
pub fn notice(p: *Parse, state: *const [5]u8, comptime fmt: []const u8, args: anytype) void {
    @import("../../sql/util.zig").noticeFmt(p, state, fmt, args);
    _ = build.getVdbe(p);
}

/// shown(), and the bare name of a name not on search_path (the parser's
/// pg_temp.<name> that names nothing).
fn bare(db: *int.Sqlite3, name: []const u8) []const u8 {
    if (catalog.schemas.split(name)) |s| if (std.mem.eql(u8, s.schema, "pg_temp")) return s.name;
    return shown(db, name);
}

/// What is of the name of a relation that CREATE makes: none, one of the
/// kind it makes (`.made`: a table for CREATE TABLE), or another relation
/// or a sequence (`.other`), as PostgreSQL's relations share one namespace.
const Existing = enum { none, made, other };

/// The kind of relation a CREATE makes.
const Made = enum { table, index, sequence };

fn existing(db: *int.Sqlite3, name: []const u8, schema: []const u8, kind: Made) Existing {
    const table = build.findTable(db, name, schema) != null;
    const index = !table and build.findIndex(db, name, schema) != null;
    const made = switch (kind) {
        .table => table,
        .index => index,
        .sequence => false,
    };
    if (made) return .made;
    return if (table or index or sequenceExists(db, name)) .other else .none;
}

/// existing() for CREATE ... IF NOT EXISTS, with PostgreSQL's NOTICE when
/// the name is taken. A relation of the kind made is left to the lowered
/// statement, which skips it (SQLite's IF NOT EXISTS); on `.other` there
/// is nothing to make.
fn skipExisting(p: *Parse, name: []const u8, schema: []const u8, kind: Made) Existing {
    const found = existing(p.db, name, schema, kind);
    if (found != .none) notice(p, "42P07", "relation \"{s}\" already exists, skipping", .{shown(p.db, name)});
    return found;
}

pub fn relationExists(db: *int.Sqlite3, name: []const u8, schema: []const u8) bool {
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

/// The name PostgreSQL shows for SQLite name `name`: without its schema
/// if it is an object of a schema of CREATE SCHEMA ("s.t" is t).
pub fn shown(db: *int.Sqlite3, name: []const u8) []const u8 {
    const s = catalog.schemas.split(name) orelse return name;
    return if (catalog.schemas.exists(db, s.schema) catch false) s.name else name;
}
