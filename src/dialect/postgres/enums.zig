//! PostgreSQL's enum types: CREATE TYPE name AS ENUM ('a', 'b' ...),
//! ALTER TYPE name ADD VALUE [IF NOT EXISTS] 'c' [BEFORE | AFTER 'a'],
//! ALTER TYPE name RENAME VALUE 'a' TO 'z', DROP TYPE [IF EXISTS] name.
//!
//! A type is a row of xq_catalog, as a schema's (catalog/schema.zig):
//!
//!     tbl = ''   col = <type>   key = 'enum'   value = ["a","b"]
//!
//! its labels in order, a JSON array. A column of the type stores the
//! label's text (types.zig: TEXT) under a CHECK that it is one of them,
//! named with PostgreSQL's message ("invalid input value for enum mood",
//! without the value), which ADD VALUE and RENAME VALUE write again in
//! each table that has such a column (alter.zig's text edits); RENAME
//! VALUE also renames the value in the rows. A cast to the type is
//! xq_pg_enum_in(x, labels, type), an error for what is no label.
//!
//! Known differences: a value compares and sorts as its text, not in the
//! order of the labels; a type is of no schema but public.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const tree = @import("../../ir/tree.zig");
const coldef = @import("../../ir/coldef.zig");
const catalog = @import("../../catalog/catalog.zig");
const build = @import("../../sql/build.zig");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const ddl = @import("ddl.zig");
const alter = @import("alter.zig");

const Parser = parser.Parser;
const Name = tree.Name;
const Allocator = std.mem.Allocator;
pub const Error = parser.Error || @import("../../ir/lower.zig").Error;

/// The xq_catalog key of a type's entry (tbl '', col the type).
pub const key = "enum";

/// PostgreSQL's NAMEDATALEN - 1: the longest label.
const max_label = 63;

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_enum_in", 3, .{ .deterministic = true }, enumInFunc),
};

/// The labels of enum type `name` (a JSON array), null if there is none.
pub fn labels(db: *int.Sqlite3, a: Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
    return catalog.get(db, a, catalog.main_schema, "", name, key) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => null,
    };
}

/// The labels of a JSON array of them.
pub fn parse(a: Allocator, json: []const u8) error{OutOfMemory}![]const []const u8 {
    return std.json.parseFromSliceLeaky([]const []const u8, a, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => &.{},
    };
}

fn jsonOf(a: Allocator, list: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(list, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// The CHECK of a column `col` of enum type `ty`: one of the labels.
pub fn check(a: Allocator, col: *tree.Expr, ty: types.TypeName) error{OutOfMemory}!tree.ColConstraint {
    const list = try parse(a, ty.labels.?);
    const items = try a.alloc(*tree.Expr, list.len);
    for (items, list) |*it, l| it.* = try tree.expr(a, col.pos, col.pos, .{ .string = l });
    const e = if (list.len == 0)
        try tree.expr(a, col.pos, col.pos, .{ .boolean = false })
    else
        try tree.expr(a, col.pos, col.pos, .{ .in_list = .{ .e = col, .not = false, .items = items } });
    return .{ .name = try checkName(a, ty.name), .kind = .{ .check = e } };
}

fn checkName(a: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ types.enum_check_prefix, name });
}

/// xq_pg_enum_in(x, labels, type): x if it is one of the labels (the
/// JSON array), else PostgreSQL's error.
fn enumInFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const x = dfunc.text(ctx, argv[0]) orelse "";
    if (isLabel(ctx, argv[1], x) catch return api.resultErrorNomem(ctx)) return api.resultText(ctx, x, .transient);
    const t = dfunc.text(ctx, argv[2]) orelse "";
    var buf: [256]u8 = undefined;
    api.resultErrorState(ctx, .of("22P02"), std.fmt.bufPrint(&buf, "invalid input value for enum {s}: \"{s}\"", .{ t[0..@min(t.len, 64)], x[0..@min(x.len, 100)] }) catch "invalid input value for enum");
}

/// The parsed labels of a call, kept for the statement (auxdata).
const Labels = struct {
    arena: std.heap.ArenaAllocator,
    list: []const []const u8,

    fn destroy(l: *Labels) void {
        const gpa = l.arena.child_allocator;
        l.arena.deinit();
        gpa.destroy(l);
    }
};

/// Whether `x` is one of the labels of `m` (the JSON array, a constant:
/// parsed once per statement).
fn isLabel(ctx: *dfunc.Context, m: *dfunc.Mem, x: []const u8) error{OutOfMemory}!bool {
    if (api.getAuxdataTyped(ctx, 1, Labels.destroy)) |l| return indexOf(l.list, x) != null;
    const gpa = dfunc.gpa(ctx);
    const l = try gpa.create(Labels);
    l.arena = .init(gpa);
    l.list = parse(l.arena.allocator(), dfunc.text(ctx, m) orelse "[]") catch |err| {
        l.destroy();
        return err;
    };
    const found = indexOf(l.list, x) != null;
    // Freed now if it cannot be kept.
    api.setAuxdataTyped(ctx, 1, Labels.destroy, l);
    return found;
}

// ============================================================ statements

/// CREATE TYPE, ALTER TYPE, DROP TYPE: true if the statement was one.
pub fn statement(ps: *Parser) Error!bool {
    const t = ps.c.peek();
    if (!ps.c.isKwAt(1, "type")) return false;
    if (t.isKw("create")) {
        try create(ps);
    } else if (t.isKw("alter")) {
        try alterType(ps);
    } else if (t.isKw("drop")) {
        try drop(ps);
    } else return false;
    if (ps.p.?.n_err > 0) return error.Failed;
    return true;
}

fn end(ps: *Parser) Error!void {
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
}

/// A type name: of public (or pg_catalog for an error).
fn typeName(ps: *Parser) Error!Name {
    const n = try ps.colId();
    if (ps.c.eat(.dot)) {
        const m = try ps.colId();
        if (!std.mem.eql(u8, n.text, "public")) return ps.c.failState(n.pos, .of("0A000"), "xqlite: an enum type of schema \"{s}\" is not supported", .{n.text});
        return m;
    }
    return n;
}

fn label(ps: *Parser) Error![]const u8 {
    const t = ps.c.peek();
    if (t.kind != .string) return ps.c.syntaxError();
    ps.c.skip();
    const v = ps.val(t);
    if (v.len == 0 or v.len > max_label) return ps.failFields(t.start, .of("22023"), .{
        .message = try std.fmt.allocPrint(ps.arena, "invalid enum label \"{s}\"", .{v}),
        .detail = "Labels must be 63 bytes or less.",
    });
    return v;
}

fn create(ps: *Parser) Error!void {
    ps.c.skip(); // CREATE
    ps.c.skip(); // TYPE
    const name = try typeName(ps);
    try ps.c.expectKw("as");
    if (!ps.c.eatKw("enum")) {
        if (ps.c.isKw("range") or ps.c.peek().kind == .lparen) return ps.c.failState(ps.c.peek().start, .of("0A000"), "xqlite: only enum types can be created (CREATE TYPE ... AS ENUM)", .{});
        return ps.c.syntaxError();
    }
    _ = try ps.c.expect(.lparen);
    var list: std.ArrayList([]const u8) = .empty;
    if (ps.c.peek().kind != .rparen) while (true) {
        const at = ps.c.peek().start;
        const l = try label(ps);
        for (list.items) |x| if (std.mem.eql(u8, x, l)) {
            return ps.c.failState(at, .of("42710"), "enum label \"{s}\" used more than once", .{l});
        };
        try list.append(ps.arena, l);
        if (!ps.c.eat(.comma)) break;
    };
    _ = try ps.c.expect(.rparen);
    try end(ps);
    const p = ps.p.?;
    try ps.readSchema();
    if (try taken(ps, name.text)) return ps.c.failState(name.pos, .of("42710"), "type \"{s}\" already exists", .{name.text});
    catalog.codeSet(p, catalog.main_schema, "", name.text, key, try jsonOf(ps.arena, list.items));
}

/// Whether a type is named `n`: a built-in, an enum, or the row type of
/// a relation.
fn taken(ps: *Parser, n: []const u8) Error!bool {
    if (types.builtin(.{ .name = n, .pos = 0 })) return true;
    const p = ps.p.?;
    if (try labels(p.db, ps.arena, n) != null) return true;
    return build.findTable(p.db, n, catalog.main_schema) != null;
}

/// The columns of type `name` (of its arrays with `arrays`): (table,
/// column) of main.
fn columnsOf(ps: *Parser, name: []const u8, arrays: bool) Error![]const [2][]const u8 {
    const p = ps.p.?;
    var out: std.ArrayList([2][]const u8) = .empty;
    if (!catalog.exists(p.db, catalog.main_schema)) return out.items;
    var q = catalog.Query.initFmt(p.db, "SELECT tbl, col FROM main.xq_catalog WHERE key=%Q AND (value=%Q OR (%d AND value=%Q)) ORDER BY tbl, col", &.{
        .{ .str = catalog.Key.decl_type }, .{ .str = name }, .{ .int = @intFromBool(arrays) }, .{ .str = try std.fmt.allocPrint(ps.arena, "{s}[]", .{name}) },
    }) catch return error.Failed;
    defer q.deinit();
    while (q.step() catch return error.Failed) {
        try out.append(ps.arena, .{
            try ps.arena.dupe(u8, api.columnText(q.v, 0) orelse ""),
            try ps.arena.dupe(u8, api.columnText(q.v, 1) orelse ""),
        });
    }
    return out.items;
}

fn drop(ps: *Parser) Error!void {
    ps.c.skip(); // DROP
    ps.c.skip(); // TYPE
    const if_exists = try ps.c.ifExists();
    var names: std.ArrayList(Name) = .empty;
    while (true) {
        try names.append(ps.arena, try typeName(ps));
        if (!ps.c.eat(.comma)) break;
    }
    if (ps.c.eatKw("cascade")) return ps.c.failState(ps.c.prev().start, .of("0A000"), "xqlite: DROP TYPE ... CASCADE is not supported", .{});
    _ = ps.c.eatKw("restrict");
    try end(ps);
    const p = ps.p.?;
    try ps.readSchema();
    for (names.items) |n| {
        if (try labels(p.db, ps.arena, n.text) == null) {
            if (!if_exists) return ps.c.failState(n.pos, .of("42704"), "type \"{s}\" does not exist", .{n.text});
            ddl.notice(p, "00000", "type \"{s}\" does not exist, skipping", .{n.text});
            continue;
        }
        const cols = try columnsOf(ps, n.text, true);
        if (cols.len > 0) return ps.failFields(n.pos, .of("2BP01"), .{
            .message = try std.fmt.allocPrint(ps.arena, "cannot drop type {s} because other objects depend on it", .{n.text}),
            .detail = try std.fmt.allocPrint(ps.arena, "column {s} of table {s} depends on type {s}", .{ cols[0][1], ddl.shown(p.db, cols[0][0]), n.text }),
            .hint = "Use DROP ... CASCADE to drop the dependent objects too.",
        });
        catalog.codeSet(p, catalog.main_schema, "", n.text, key, null);
    }
    // A statement that drops nothing has a program (its NOTICEs).
    _ = build.getVdbe(p);
}

fn alterType(ps: *Parser) Error!void {
    ps.c.skip(); // ALTER
    ps.c.skip(); // TYPE
    const name = try typeName(ps);
    const p = ps.p.?;
    try ps.readSchema();
    const json = try labels(p.db, ps.arena, name.text) orelse return ps.c.failState(name.pos, .of("42704"), "type \"{s}\" does not exist", .{name.text});
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(ps.arena, try parse(ps.arena, json));
    var renamed: ?[2][]const u8 = null;
    if (ps.c.eatKw("add")) {
        try ps.c.expectKw("value");
        const if_not_exists = try ps.c.ifNotExists();
        const at = ps.c.peek().start;
        const v = try label(ps);
        var pos: usize = list.items.len;
        if (ps.c.eatKw("before") or ps.c.eatKw("after")) {
            const after = ps.c.prev().isKw("after");
            const nat = ps.c.peek().start;
            const n = try label(ps);
            pos = indexOf(list.items, n) orelse return ps.c.failState(nat, .of("22023"), "\"{s}\" is not an existing enum label", .{n});
            if (after) pos += 1;
        }
        try end(ps);
        if (indexOf(list.items, v) != null) {
            if (if_not_exists) return ddl.notice(p, "42710", "enum label \"{s}\" already exists, skipping", .{v});
            return ps.c.failState(at, .of("42710"), "enum label \"{s}\" already exists", .{v});
        }
        try list.insert(ps.arena, pos, v);
    } else if (ps.c.eatKw("rename")) {
        if (ps.c.eatKw("to")) return ps.c.failState(ps.c.prev().start, .of("0A000"), "xqlite: ALTER TYPE ... RENAME TO is not supported", .{});
        try ps.c.expectKw("value");
        const at = ps.c.peek().start;
        const old = try label(ps);
        try ps.c.expectKw("to");
        const nat = ps.c.peek().start;
        const new = try label(ps);
        try end(ps);
        const i = indexOf(list.items, old) orelse return ps.c.failState(at, .of("22023"), "\"{s}\" is not an existing enum label", .{old});
        if (indexOf(list.items, new) != null) return ps.c.failState(nat, .of("42710"), "enum label \"{s}\" already exists", .{new});
        list.items[i] = new;
        renamed = .{ old, new };
    } else if (ps.c.isKw("owner")) {
        // OWNER TO: one role.
        ps.c.skip();
        try ps.c.expectKw("to");
        _ = try ps.colId();
        try end(ps);
        _ = build.getVdbe(p);
        return;
    } else return ps.c.failState(ps.c.peek().start, .of("0A000"), "xqlite: this ALTER TYPE is not supported (ADD VALUE, RENAME VALUE)", .{});
    const new_json = try jsonOf(ps.arena, list.items);
    catalog.codeSet(p, catalog.main_schema, "", name.text, key, new_json);
    // The CHECK of each column of the type, written again (and the rows'
    // values renamed).
    const ty: types.TypeName = .{ .name = name.text, .pos = name.pos, .labels = new_json };
    const cname = try checkName(ps.arena, name.text);
    // By table (columnsOf() is in their order): one edit of each.
    const cols = try columnsOf(ps, name.text, false);
    var k: usize = 0;
    while (k < cols.len) {
        var e = k + 1;
        while (e < cols.len and std.mem.eql(u8, cols[e][0], cols[k][0])) e += 1;
        defer k = e;
        const tab = build.findTable(p.db, cols[k][0], catalog.main_schema) orelse continue;
        var d: ddl.Ddl = .init(p, ps.c.sql);
        const t = try alter.target(&d, tab);
        var edits: std.ArrayList(coldef.Edit) = .empty;
        for (cols[k..e]) |tc| {
            const icol = build.columnIndex(tab, tc[1]);
            if (icol < 0 or @as(usize, @intCast(icol)) >= t.def.columns.len) continue;
            const cdef = t.def.columns[@intCast(icol)];
            for (cdef.clauses) |c| if (c.named(ps.arena, cname) catch false) try edits.append(ps.arena, coldef.remove(c));
            const names = try ps.arena.alloc(Name, 1);
            names[0] = .{ .text = tc[1], .pos = name.pos };
            const col = try tree.expr(ps.arena, name.pos, name.pos, .{ .column = names });
            var r = d.l.renderer();
            try r.colConstraint(try check(ps.arena, col, ty));
            try edits.append(ps.arena, .{ .start = cdef.end, .end = cdef.end, .text = try r.text() });
        }
        try alter.write(&d, t, edits.items);
        if (renamed) |rn| for (cols[k..e]) |tc| {
            catalog.codeExec(p, t.i_db, build.mprintf(p, "UPDATE \"%w\".\"%w\" SET \"%w\" = %Q WHERE \"%w\" = %Q", &.{
                .{ .str = t.schema }, .{ .str = tab.name }, .{ .str = tc[1] }, .{ .str = rn[1] }, .{ .str = tc[1] }, .{ .str = rn[0] },
            }) catch return error.OutOfMemory);
        };
    }
}

fn indexOf(list: []const []const u8, v: []const u8) ?usize {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, v)) return i;
    return null;
}
