//! JSON_TABLE and the parser's other JSON work at the end of a SELECT.
//!
//! JSON_TABLE(doc, path COLUMNS (...)) AS jt is the FROM item
//!
//!     xq_maria_json_table(doc, 'spec') AS jt
//!
//! an engine table-valued function (an eponymous virtual table of
//! Hooks.engine_modules, `module` below) whose rows are those of the
//! JSON_TABLE, each the JSON array of its column values (column xq_row),
//! already converted to the column types the way MariaDB does; `spec` is
//! the COLUMNS clause as JSON (SpecBuilder). A table-valued function
//! takes its arguments from the tables before it, so the document may
//! name them (FROM t, JSON_TABLE(t.j, ...)), and a LEFT JOIN works. At
//! the end of the SELECT (endCore()) every reference to a column of jt
//! (jt.a, or a alone) becomes `jt.xq_row ->> k` (k its position), and
//! `*`/`jt.*` lists them by name. A view keeps this lowered form (which
//! sqlite3 cannot run, as it lacks the table).
//!
//! The same pass marks the JSON columns of the tables of FROM that are
//! values of JSON_OBJECT/JSON_ARRAY/JSON_SET ... (json.zig): a column
//! with MariaDB's CHECK (json_valid(col)) is wrapped in
//! xq_maria_json_col() so that its value is JSON, not a string.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const api = @import("../../vdbe/api.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const ddl = @import("ddl.zig");
const types = @import("types.zig");
const json = @import("json.zig");
const vtab = @import("../../sql/vtab.zig");

const Allocator = std.mem.Allocator;
const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;

/// A JSON_TABLE of the FROM clause being parsed.
pub const JsonTable = struct {
    alias: []const u8,
    /// The output columns, in order.
    cols: []const []const u8,
};

// ================================================================ syntax

/// JSON_TABLE(doc, path COLUMNS (...)) alias, after `JSON_TABLE`.
pub fn fromItem(s: *Parser, pos: u32) Error!tree.FromItem {
    try s.expectOp("(");
    const doc = try s.expr();
    try s.expectOp(",");
    const path = try s.stringLiteral();
    var b: SpecBuilder = .{ .s = s };
    try b.out.appendSlice(s.a, "{\"p\":");
    try json.appendQuoted(s.a, &b.out, path);
    try b.out.appendSlice(s.a, ",\"c\":");
    try b.columns();
    try s.expectOp(")");
    const al = (try s.alias(false)) orelse return s.fail("Every table function must have an alias.", .{});
    try b.out.appendSlice(s.a, ",\"t\":");
    try json.appendQuoted(s.a, &b.out, al.text);
    try b.out.append(s.a, '}');
    for (b.names.items, 0..) |n, i| for (b.names.items[0..i]) |o| {
        if (std.ascii.eqlIgnoreCase(n, o)) return s.fail("Duplicate column name '{s}'", .{n});
    };
    try s.json_tables.append(s.a, .{ .alias = al.text, .cols = b.names.items });
    const f = try s.new(tree.Func, .{ .name = .{ .text = "xq_maria_json_table", .pos = pos }, .args = try s.a.dupe(*Expr, &.{ doc, try s.str(pos, b.out.items) }) });
    return .{ .source = .{ .func = f }, .alias = .{ .name = al } };
}

/// The COLUMNS clause as JSON: an array of
///  {"n":name,"o":1} (FOR ORDINALITY),
///  {"n":name,"ty":type,"j":1 (JSON),"x":1 (EXISTS),"p":path,"e":on_empty,"r":on_error},
///  {"N":path,"c":[columns]} (NESTED PATH);
/// on_empty/on_error: absent (NULL), "E" (ERROR) or {"d":text} (DEFAULT).
const SpecBuilder = struct {
    s: *Parser,
    out: std.ArrayList(u8) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    fn str(b: *SpecBuilder, z: []const u8) Error!void {
        try json.appendQuoted(b.s.a, &b.out, z);
    }

    fn raw(b: *SpecBuilder, z: []const u8) Error!void {
        try b.out.appendSlice(b.s.a, z);
    }

    fn columns(b: *SpecBuilder) Error!void {
        const s = b.s;
        try s.expectKw("COLUMNS");
        try s.expectOp("(");
        try b.raw("[");
        var first = true;
        while (true) {
            if (!first) try b.raw(",");
            first = false;
            try b.column();
            if (!s.eatOp(",")) break;
        }
        try s.expectOp(")");
        try b.raw("]");
    }

    fn column(b: *SpecBuilder) Error!void {
        const s = b.s;
        if (s.isKw("NESTED")) {
            s.advance();
            _ = s.eatKw("PATH");
            try b.raw("{\"N\":");
            try b.str(try s.stringLiteral());
            try b.raw(",\"c\":");
            try b.columns();
            try b.raw("}");
            return;
        }
        const name = try s.nameOf(try s.name());
        try b.names.append(s.a, name.text);
        try b.raw("{\"n\":");
        try b.str(name.text);
        if (s.eatKw("FOR")) {
            try s.expectKw("ORDINALITY");
            try b.raw(",\"o\":1}");
            return;
        }
        const ty, const is_json = try ddl.dataType(s, name);
        try b.raw(",\"ty\":");
        var w: std.Io.Writer.Allocating = .init(s.a);
        ty.format(&w.writer) catch return error.OutOfMemory;
        try b.str(w.written());
        if (is_json) try b.raw(",\"j\":1");
        if (s.eatKw("EXISTS")) try b.raw(",\"x\":1");
        try s.expectKw("PATH");
        try b.raw(",\"p\":");
        try b.str(try s.stringLiteral());
        // [NULL | ERROR | DEFAULT value] ON EMPTY / ON ERROR, either order.
        var seen_empty = false;
        var seen_error = false;
        while (true) {
            var what: []const u8 = undefined;
            if (s.isKw("NULL") or s.isKw("ERROR")) {
                what = if (s.isKw("NULL")) "" else "\"E\"";
                s.advance();
            } else if (s.isKw("DEFAULT")) {
                s.advance();
                var v: std.ArrayList(u8) = .empty;
                try v.appendSlice(s.a, "{\"d\":");
                const t = s.tok;
                switch (t.kind) {
                    .string => try json.appendQuoted(s.a, &v, try s.stringLiteral()),
                    .integer, .float => {
                        s.advance();
                        try json.appendQuoted(s.a, &v, t.text);
                    },
                    else => return s.syntaxError(),
                }
                try v.append(s.a, '}');
                what = v.items;
            } else break;
            try s.expectKw("ON");
            if (s.eatKw("EMPTY")) {
                if (seen_empty) return s.syntaxError();
                seen_empty = true;
                if (what.len > 0) {
                    try b.raw(",\"e\":");
                    try b.raw(what);
                }
            } else if (s.eatKw("ERROR")) {
                if (seen_error) return s.syntaxError();
                seen_error = true;
                if (what.len > 0) {
                    try b.raw(",\"r\":");
                    try b.raw(what);
                }
            } else return s.syntaxError();
        }
        try b.raw("}");
    }
};

// ================================================================ end of a SELECT

/// What endCore() needs to know of the parser's lists: their lengths
/// when the SELECT started.
pub const Mark = struct { tables: usize, args: usize };

pub fn mark(s: *Parser) Mark {
    return .{ .tables = s.json_tables.items.len, .args = s.json_args.items.len };
}

/// At the end of a SELECT core: mark its JSON columns, then rewrite the
/// references to the columns of its JSON_TABLEs.
pub fn endCore(s: *Parser, m: Mark, core: *tree.Core) Error!void {
    try markJsonColumns(s, m.args, core.from);
    const jts = s.json_tables.items[m.tables..];
    if (jts.len == 0) return;
    var r: Rewriter = .{ .s = s, .jts = jts };
    // `*` and jt.*.
    var cols: std.ArrayList(tree.ResultCol) = .empty;
    for (core.cols) |rc| switch (rc) {
        .star => |pos| {
            try r.starOf(&cols, core.from, pos);
        },
        .table_star => |ts| {
            if (ts.names.len == 1) if (r.table(ts.names[0].text)) |jt| {
                try r.listColumns(&cols, jt, ts.star_pos);
                continue;
            };
            try cols.append(s.a, rc);
        },
        .expr => |x| {
            var e = x;
            if (e.alias == null and e.name == null and e.e.kind == .column) {
                const names = e.e.kind.column;
                if (r.columnOf(names) != null) e.alias = .{ .text = names[names.len - 1].text, .pos = e.e.pos };
            }
            try cols.append(s.a, .{ .expr = e });
        },
    };
    core.cols = cols.items;
    try r.core(core, true);
}

/// At the end of a whole SELECT (its ORDER BY): rewrite the references
/// of the ORDER BY too, and forget its JSON_TABLEs.
pub fn endSelect(s: *Parser, m: Mark, sel: *tree.Select) Error!void {
    const jts = s.json_tables.items[m.tables..];
    if (jts.len > 0) {
        var r: Rewriter = .{ .s = s, .jts = jts };
        for (sel.order_by) |*o| try r.expr(&o.expr, true);
    }
    s.json_tables.shrinkRetainingCapacity(m.tables);
}

const Rewriter = struct {
    s: *Parser,
    jts: []const JsonTable,

    fn table(r: *const Rewriter, alias: []const u8) ?*const JsonTable {
        for (r.jts) |*jt| if (std.ascii.eqlIgnoreCase(jt.alias, alias)) return jt;
        return null;
    }

    const Ref = struct { jt: *const JsonTable, k: usize };

    fn columnOf(r: *const Rewriter, names: []const Name) ?Ref {
        switch (names.len) {
            1 => for (r.jts) |*jt| {
                if (indexOf(jt, names[0].text)) |k| return .{ .jt = jt, .k = k };
            },
            2 => if (r.table(names[0].text)) |jt| {
                if (indexOf(jt, names[1].text)) |k| return .{ .jt = jt, .k = k };
            },
            else => {},
        }
        return null;
    }

    fn indexOf(jt: *const JsonTable, n: []const u8) ?usize {
        for (jt.cols, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c, n)) return i;
        return null;
    }

    /// jt.xq_row ->> k
    fn valueOf(r: *Rewriter, jt: *const JsonTable, k: usize, pos: u32) Error!*Expr {
        const s = r.s;
        const names = try s.a.dupe(Name, &.{ .{ .text = jt.alias, .pos = pos }, .{ .text = "xq_row", .pos = pos } });
        const col = try s.mk(pos, .{ .column = names });
        return s.mk(pos, .{ .binary = .{ .op = .json_get_text, .l = col, .r = try s.int_(pos, @intCast(k)) } });
    }

    fn listColumns(r: *Rewriter, out: *std.ArrayList(tree.ResultCol), jt: *const JsonTable, pos: u32) Error!void {
        for (jt.cols, 0..) |c, k| {
            try out.append(r.s.a, .{ .expr = .{ .e = try r.valueOf(jt, k, pos), .alias = .{ .text = c, .pos = pos } } });
        }
    }

    /// `*` over FROM items that include a JSON_TABLE.
    fn starOf(r: *Rewriter, out: *std.ArrayList(tree.ResultCol), items: []const tree.FromItem, pos: u32) Error!void {
        for (items) |item| {
            if (item.source == .nested and item.alias == null) {
                try r.starOf(out, item.source.nested, pos);
                continue;
            }
            const label: []const Name = if (item.alias) |a|
                try r.s.a.dupe(Name, &.{a.name})
            else switch (item.source) {
                .table => |q| if (q.schema) |sc| try r.s.a.dupe(Name, &.{ sc, q.name }) else try r.s.a.dupe(Name, &.{q.name}),
                else => return r.s.fail("Every derived table must have its own alias", .{}),
            };
            if (label.len == 1) if (r.table(label[0].text)) |jt| {
                try r.listColumns(out, jt, pos);
                continue;
            };
            try out.append(r.s.a, .{ .table_star = .{ .names = label, .star_pos = pos } });
        }
    }

    fn core(r: *Rewriter, c: *tree.Core, unqualified: bool) Error!void {
        for (c.cols) |*rc| switch (rc.*) {
            .expr => |*x| try r.expr(&x.e, unqualified),
            else => {},
        };
        try r.from(c.from, unqualified);
        if (c.where) |*w| try r.expr(w, unqualified);
        for (c.group_by) |*g| try r.expr(g, unqualified);
        if (c.having) |*h| try r.expr(h, unqualified);
        for (c.windows) |w| try r.window(w.spec, unqualified);
    }

    fn from(r: *Rewriter, items: []tree.FromItem, unqualified: bool) Error!void {
        for (items) |*item| {
            switch (item.source) {
                .table => {},
                .subquery => |sel| try r.select(sel),
                .func => |f| for (f.args) |*a| try r.expr(a, unqualified),
                .nested => |n| try r.from(n, unqualified),
            }
            if (item.on) |*o| try r.expr(o, unqualified);
        }
    }

    /// A query inside: its unqualified names are its own tables' when it
    /// has a FROM.
    fn select(r: *Rewriter, sel: *tree.Select) Error!void {
        if (sel.with) |w| for (w.ctes) |cte| try r.select(cte.select);
        const own = try r.body(sel.body);
        for (sel.order_by) |*o| try r.expr(&o.expr, !own);
        if (sel.limit) |*l| try r.expr(l, true);
        if (sel.offset) |*o| try r.expr(o, true);
    }

    /// Whether the body has tables of its own.
    fn body(r: *Rewriter, b: *tree.Body) Error!bool {
        switch (b.*) {
            .core => |c| {
                try r.core(c, c.from.len == 0);
                return c.from.len > 0;
            },
            .values => |rows| {
                for (rows) |row| for (row) |*e| try r.expr(e, true);
                return false;
            },
            .compound => |c| {
                const x = try r.body(c.left);
                const y = try r.body(c.right);
                return x or y;
            },
            .nested => |sel| {
                try r.select(sel);
                return true;
            },
        }
    }

    fn window(r: *Rewriter, w: *tree.WindowSpec, unqualified: bool) Error!void {
        for (w.partition) |*p| try r.expr(p, unqualified);
        for (w.order_by) |*o| try r.expr(&o.expr, unqualified);
        if (w.frame) |*f| {
            if (f.start.expr) |*e| try r.expr(e, unqualified);
            if (f.end) |*end| if (end.expr) |*e| try r.expr(e, unqualified);
        }
    }

    fn expr(r: *Rewriter, slot: **Expr, unq: bool) Error!void {
        const e = slot.*;
        switch (e.kind) {
            .column => |names| {
                if (names.len == 1 and !unq) return;
                if (r.columnOf(names)) |ref| slot.* = try r.valueOf(ref.jt, ref.k, e.pos);
            },
            .integer, .float, .string, .blob, .null, .boolean, .param, .default, .identity_default, .named_param => {},
            .unary => |*u| try r.expr(&u.e, unq),
            .binary => |*b| {
                try r.expr(&b.l, unq);
                try r.expr(&b.r, unq);
            },
            .div => |*d| {
                try r.expr(&d.l, unq);
                try r.expr(&d.r, unq);
            },
            .compare => |*c| {
                try r.expr(&c.l, unq);
                try r.expr(&c.r, unq);
            },
            .concat => |c| for (c.args) |*a| try r.expr(a, unq),
            .cast => |*c| try r.expr(&c.e, unq),
            .func => |f| {
                for (f.args) |*a| try r.expr(a, unq);
                for (f.order_by) |*o| try r.expr(&o.expr, unq);
                if (f.filter) |*x| try r.expr(x, unq);
                if (f.over) |w| try r.window(w, unq);
            },
            .case => |*c| {
                if (c.operand) |*o| try r.expr(o, unq);
                for (c.whens) |*w| try r.expr(w, unq);
                if (c.@"else") |*x| try r.expr(x, unq);
            },
            .in_list => |*l| {
                try r.expr(&l.e, unq);
                for (l.items) |*x| try r.expr(x, unq);
            },
            .in_select => |*l| {
                try r.expr(&l.e, unq);
                try r.select(l.sel);
            },
            .exists, .subquery => |sel| try r.select(sel),
            .between => |*b| {
                try r.expr(&b.e, unq);
                try r.expr(&b.lo, unq);
                try r.expr(&b.hi, unq);
            },
            .like => |*l| {
                try r.expr(&l.e, unq);
                try r.expr(&l.pat, unq);
                switch (l.escape) {
                    .expr => |*x| try r.expr(x, unq),
                    else => {},
                }
            },
            .is_null => |*x| try r.expr(&x.e, unq),
            .is_bool => |*x| try r.expr(&x.e, unq),
            .row => |items| for (items) |*x| try r.expr(x, unq),
            .collate => |*c| try r.expr(&c.e, unq),
            .coerce => |*c| try r.expr(&c.e, unq),
        }
    }
};

// ================================================================ JSON columns

/// Wrap the column references of s.json_args (from `start` on: values
/// of the JSON functions) that are JSON columns of the tables of `from`
/// in xq_maria_json_col(); those found in `from` leave the list, the
/// others stay for the enclosing query.
pub fn markJsonColumns(s: *Parser, start: usize, from: []const tree.FromItem) Error!void {
    var keep = start;
    for (s.json_args.items[start..]) |e| {
        const names = e.kind.column;
        switch (try jsonColumn(s, names, from)) {
            .json => {
                const copy = try s.new(Expr, e.*);
                const f = try s.func(e.pos, "xq_maria_json_col", &.{copy});
                e.kind = f.kind;
            },
            .other => {},
            .unknown => {
                s.json_args.items[keep] = e;
                keep += 1;
            },
        }
    }
    s.json_args.shrinkRetainingCapacity(keep);
}

const Found = enum { json, other, unknown };

fn jsonColumn(s: *Parser, names: []const Name, from: []const tree.FromItem) Error!Found {
    if (names.len == 0 or names.len > 3) return .unknown;
    const col = names[names.len - 1].text;
    for (from) |item| {
        switch (item.source) {
            .nested => |n| {
                const f = try jsonColumn(s, names, n);
                if (f != .unknown) return f;
                continue;
            },
            .table => |q| {
                if (names.len >= 2) {
                    const label = if (item.alias) |a| a.name.text else q.name.text;
                    if (!std.ascii.eqlIgnoreCase(label, names[names.len - 2].text)) continue;
                }
                const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |sc| sc.text else null) orelse continue;
                for (tab.cols) |*c| {
                    if (std.ascii.eqlIgnoreCase(c.name(), col)) break;
                } else continue;
                return if (hasJsonCheck(tab, col)) .json else .other;
            },
            else => {
                if (names.len >= 2) {
                    if (item.alias) |a| if (std.ascii.eqlIgnoreCase(a.name.text, names[names.len - 2].text)) return .other;
                }
            },
        }
    }
    return .unknown;
}

/// MariaDB's JSON column: a CHECK named after the column that calls
/// json_valid() (ddl.zig).
fn hasJsonCheck(tab: *int.Table, col: []const u8) bool {
    const checks = tab.check orelse return false;
    for (checks.slice()) |item| {
        const n = item.e_name orelse continue;
        if (!std.ascii.eqlIgnoreCase(n, col)) continue;
        const e = item.expr orelse continue;
        if (e.op == int.TK.FUNCTION and std.ascii.eqlIgnoreCase(e.token(), "json_valid")) return true;
    }
    return false;
}

// ================================================================ runtime

const Context = dfunc.Context;
const Mem = dfunc.Mem;

const OnX = union(enum) { null, err, default: []const u8 };

const Col = struct {
    name: []const u8,
    kind: enum { ordinality, path, exists },
    ty: ?types.Type = null,
    is_json: bool = false,
    path: json.Path = .{ .steps = &.{} },
    on_empty: OnX = .null,
    on_error: OnX = .null,
    out: usize,
};

const Item = union(enum) { col: Col, nested: *Level };

const Level = struct {
    path: json.Path,
    items: []Item,
};

const Failure = error{ OutOfMemory, Failed };

const Runner = struct {
    a: Allocator,
    alias: []const u8 = "",
    n_out: usize = 0,
    /// The rows: JSON arrays of the column values.
    rows: std.ArrayList([]const u8) = .empty,
    msg: []const u8 = "",

    fn fail(r: *Runner, comptime fmt: []const u8, args: anytype) Failure {
        r.msg = try std.fmt.allocPrint(r.a, fmt, args);
        return error.Failed;
    }

    fn badPath(r: *Runner) Failure {
        return r.fail("Syntax error in JSON path in argument 2 to function 'JSON_TABLE' at position 1", .{});
    }

    fn level(r: *Runner, spec: *const json.Node) Failure!*Level {
        const lv = try r.a.create(Level);
        const p = member(spec, "p") orelse member(spec, "N") orelse return r.badPath();
        lv.path = (try json.parsePath(r.a, try json.stringValue(r.a, p))) orelse return r.badPath();
        const cs = member(spec, "c") orelse return r.badPath();
        var items: std.ArrayList(Item) = .empty;
        for (cs.items) |*c| {
            if (member(c, "N") != null) {
                try items.append(r.a, .{ .nested = try r.level(c) });
                continue;
            }
            var col: Col = .{ .name = try json.stringValue(r.a, member(c, "n").?), .kind = .path, .out = r.n_out };
            r.n_out += 1;
            if (member(c, "o") != null) {
                col.kind = .ordinality;
            } else {
                if (member(c, "x") != null) col.kind = .exists;
                col.is_json = member(c, "j") != null;
                col.ty = try types.parse(r.a, try json.stringValue(r.a, member(c, "ty").?));
                col.path = (try json.parsePath(r.a, try json.stringValue(r.a, member(c, "p").?))) orelse return r.badPath();
                col.on_empty = try onX(r.a, member(c, "e"));
                col.on_error = try onX(r.a, member(c, "r"));
            }
            try items.append(r.a, .{ .col = col });
        }
        lv.items = items.items;
        return lv;
    }

    /// The rows of `lv` for context `n`, each starting from `base` (the
    /// values of the enclosing levels).
    fn run(r: *Runner, lv: *const Level, n: *json.Node, base: []?[]const u8) Failure!void {
        var matches: std.ArrayList(*json.Node) = .empty;
        try json.find(r.a, n, lv.path.steps, &matches);
        for (matches.items, 1..) |m, ord| {
            const row = try r.a.dupe(?[]const u8, base);
            var has_nested = false;
            for (lv.items) |it| switch (it) {
                .col => |*c| row[c.out] = try r.value(c, m, ord),
                .nested => has_nested = true,
            };
            if (!has_nested) {
                try r.emit(row);
                continue;
            }
            const before = r.rows.items.len;
            for (lv.items) |it| switch (it) {
                .nested => |nl| try r.run(nl, m, row),
                .col => {},
            };
            if (r.rows.items.len == before) try r.emit(row);
        }
    }

    fn emit(r: *Runner, row: []const ?[]const u8) Failure!void {
        var out: std.ArrayList(u8) = .empty;
        try out.append(r.a, '[');
        for (row, 0..) |v, i| {
            if (i > 0) try out.append(r.a, ',');
            try out.appendSlice(r.a, v orelse "null");
        }
        try out.append(r.a, ']');
        try r.rows.append(r.a, out.items);
    }

    /// The JSON text of column `c` for context `n` (null for NULL).
    fn value(r: *Runner, c: *const Col, n: *json.Node, ord: usize) Failure!?[]const u8 {
        switch (c.kind) {
            .ordinality => return try std.fmt.allocPrint(r.a, "{d}", .{ord}),
            .exists => {
                var found: std.ArrayList(*json.Node) = .empty;
                try json.find(r.a, n, c.path.steps, &found);
                return try r.convert(c, if (found.items.len > 0) "1" else "0", .number);
            },
            .path => {},
        }
        var found: std.ArrayList(*json.Node) = .empty;
        try json.find(r.a, n, c.path.steps, &found);
        if (found.items.len == 0) return r.onEmpty(c);
        if (found.items.len > 1) return r.onError(c, "Can't store multiple matches of the path in the column '{s}' of JSON_TABLE '{s}'.");
        const v = found.items[0];
        if (v.kind == .null_) return null;
        if (c.is_json) {
            var out: std.ArrayList(u8) = .empty;
            try json.appendQuoted(r.a, &out, v.raw);
            return out.items;
        }
        return switch (v.kind) {
            .null_ => null,
            .object, .array => r.onError(c, "Can't store an array or an object in the scalar column '{s}' of JSON_TABLE '{s}'."),
            .string => try r.convert(c, try json.stringValue(r.a, v), .string),
            .number => try r.convert(c, v.raw, .number),
            .true_ => try r.convert(c, "true", .boolean),
            .false_ => try r.convert(c, "false", .boolean),
        };
    }

    fn onEmpty(r: *Runner, c: *const Col) Failure!?[]const u8 {
        return switch (c.on_empty) {
            .null => null,
            .err => r.fail("Field '{s}' can't be set for JSON_TABLE '{s}'.", .{ c.name, r.alias }),
            .default => |d| try r.convert(c, d, .string),
        };
    }

    fn onError(r: *Runner, c: *const Col, comptime msg: []const u8) Failure!?[]const u8 {
        return switch (c.on_error) {
            .null => null,
            .err => r.fail(msg, .{ c.name, r.alias }),
            .default => |d| try r.convert(c, d, .string),
        };
    }

    /// Scalar `z` (a string's value, a number's text, true/false)
    /// converted to the column's type, as JSON text.
    fn convert(r: *Runner, c: *const Col, z: []const u8, src: enum { string, number, boolean }) Failure![]const u8 {
        const a = r.a;
        var out: std.ArrayList(u8) = .empty;
        if (c.is_json) {
            if (src == .string) {
                var q: std.ArrayList(u8) = .empty;
                try json.appendQuoted(a, &q, z);
                try json.appendQuoted(a, &out, q.items);
            } else try json.appendQuoted(a, &out, z);
            return out.items;
        }
        const ty = c.ty orelse {
            try json.appendQuoted(a, &out, z);
            return out.items;
        };
        const num_text = if (src == .boolean) (if (z[0] == 't') "1" else "0") else z;
        switch (ty.base) {
            .tinyint, .smallint, .mediumint, .int, .bigint, .bit, .year => {
                const lo, const hi = ty.intRange();
                const v: i64 = switch (types.parseNumber(num_text).num) {
                    .int => |i| std.math.clamp(i, lo, hi),
                    .float => |f| blk: {
                        const x = @round(f);
                        if (x <= @as(f64, @floatFromInt(lo))) break :blk lo;
                        if (x >= @as(f64, @floatFromInt(hi))) break :blk hi;
                        break :blk @intFromFloat(x);
                    },
                };
                try out.print(a, "{d}", .{v});
            },
            .decimal, .float, .double => {
                const f: f64 = switch (types.parseNumber(num_text).num) {
                    .int => |i| @floatFromInt(i),
                    .float => |f| f,
                };
                if (ty.base == .decimal) {
                    const scale = ty.scale orelse 0;
                    const p = std.math.pow(f64, 10, @floatFromInt(scale));
                    const x = @round(f * p) / p;
                    if (scale == 0) try out.print(a, "{d}", .{@as(i64, @intFromFloat(x))}) else try json.appendDouble(a, &out, x);
                } else if (ty.base == .float) {
                    try json.appendDouble(a, &out, @floatCast(@as(f32, @floatCast(f))));
                } else try json.appendDouble(a, &out, f);
            },
            .date, .datetime, .timestamp => {
                var buf: [32]u8 = undefined;
                const dt = types.parseDateTime(z);
                const text = if (ty.base == .date)
                    if (dt) |d| std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }) catch unreachable else "0000-00-00"
                else if (dt) |d|
                    std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second }) catch unreachable
                else
                    "0000-00-00 00:00:00";
                try json.appendQuoted(a, &out, text);
            },
            else => {
                var t = z;
                if (ty.maxLen()) |n| {
                    const cut = if (ty.base == .char or ty.base == .varchar) dfunc.charOffset(t, n) else @min(t.len, n);
                    t = t[0..cut];
                }
                try json.appendQuoted(a, &out, t);
            },
        }
        return out.items;
    }
};

fn member(n: *const json.Node, key: []const u8) ?*json.Node {
    if (n.kind != .object) return null;
    for (n.members) |*m| if (std.mem.eql(u8, m.key, key)) return &m.value;
    return null;
}

fn onX(a: Allocator, n: ?*json.Node) Allocator.Error!OnX {
    const x = n orelse return .null;
    if (x.kind == .string) return .err;
    return .{ .default = try json.stringValue(a, member(x, "d").?) };
}

/// The rows of JSON_TABLE for document `doc` (null for NULL) and `spec`.
fn runTable(r: *Runner, doc_text: ?[]const u8, spec_text: []const u8) Failure!void {
    const a = r.a;
    const spec = json.parse(a, spec_text) catch return r.fail("xqlite: bad JSON_TABLE specification", .{});
    r.alias = try json.stringValue(a, member(&spec, "t") orelse return r.badPath());
    const lv = try r.level(&spec);
    const z = doc_text orelse return;
    var pos: usize = 0;
    var doc = json.parseAt(a, z, &pos) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return r.fail("Syntax error in JSON text in argument 1 to function 'JSON_TABLE' at position {d}", .{pos + 1}),
    };
    const base = try a.alloc(?[]const u8, r.n_out);
    @memset(base, null);
    try r.run(lv, &doc, base);
}

// ================================================================ the virtual table

const RC = int.RC;
const IC = vtab.INDEX_CONSTRAINT;

/// xq_maria_json_table(doc, spec): CREATE TABLE x(xq_row, doc HIDDEN,
/// spec HIDDEN).
pub const module: vtab.Module = .{
    .i_version = 0,
    .x_connect = connect,
    .x_best_index = bestIndex,
    .x_disconnect = disconnect,
    .x_open = open,
    .x_close = close,
    .x_filter = filter,
    .x_next = next,
    .x_eof = eof,
    .x_column = column,
    .x_rowid = rowid,
};

const col_doc = 1;
const col_spec = 2;

const Table = struct {
    base: vtab.Vtab = .{},
    db: *int.Sqlite3,
};

const Cursor = struct {
    base: vtab.VtabCursor = .{},
    db: *int.Sqlite3,
    arena: std.heap.ArenaAllocator,
    rows: []const []const u8 = &.{},
    i: usize = 0,

    fn of(cur: *vtab.VtabCursor) *Cursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }
};

fn connect(db: *int.Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const rc = vtab.declareVtab(db, "CREATE TABLE x(xq_row, doc HIDDEN, spec HIDDEN)");
    if (rc != RC.OK) return rc;
    const t = db.gpa.create(Table) catch return RC.NOMEM;
    t.* = .{ .db = db };
    pp_vtab.* = &t.base;
    _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
    return RC.OK;
}

fn disconnect(p: *vtab.Vtab) i32 {
    const t: *Table = @alignCast(@fieldParentPtr("base", p));
    t.db.gpa.destroy(t);
    return RC.OK;
}

/// Both arguments are required, as equality constraints on the hidden
/// columns (a plan where one is not usable yet is refused).
fn bestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    var args: [2]?usize = .{ null, null };
    for (info.constraints, 0..) |c, i| {
        if (c.i_column != col_doc and c.i_column != col_spec) continue;
        if (c.op != IC.EQ) continue;
        if (!c.usable) return RC.CONSTRAINT;
        args[@intCast(c.i_column - col_doc)] = i;
    }
    for (args, 1..) |a, n| {
        const i = a orelse {
            const t: *Table = @alignCast(@fieldParentPtr("base", p));
            vtab.setErrMsg(t.db, p, "xq_maria_json_table() takes a document and a specification", .{});
            return RC.ERROR;
        };
        info.usage[i].argv_index = @intCast(n);
        info.usage[i].omit = true;
    }
    info.estimated_cost = 1;
    info.estimated_rows = 100;
    return RC.OK;
}

fn open(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t: *Table = @alignCast(@fieldParentPtr("base", p));
    const c = t.db.gpa.create(Cursor) catch return RC.NOMEM;
    c.* = .{ .db = t.db, .arena = .init(t.db.gpa) };
    pp_cursor.* = &c.base;
    return RC.OK;
}

fn close(cur: *vtab.VtabCursor) i32 {
    const c = Cursor.of(cur);
    c.arena.deinit();
    c.db.gpa.destroy(c);
    return RC.OK;
}

fn filter(cur: *vtab.VtabCursor, _: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c = Cursor.of(cur);
    _ = c.arena.reset(.retain_capacity);
    c.rows = &.{};
    c.i = 0;
    if (argv.len < 2) return RC.ERROR;
    var r: Runner = .{ .a = c.arena.allocator() };
    const doc: ?[]const u8 = if (dfunc.isNull(argv[0])) null else api.valueText(argv[0]) orelse return RC.NOMEM;
    const spec = api.valueText(argv[1]) orelse return RC.NOMEM;
    runTable(&r, doc, spec) catch |err| switch (err) {
        error.OutOfMemory => return RC.NOMEM,
        error.Failed => {
            vtab.setErrMsg(c.db, cur.vtab, "{s}", .{r.msg});
            return RC.ERROR;
        },
    };
    c.rows = r.rows.items;
    return RC.OK;
}

fn next(cur: *vtab.VtabCursor) i32 {
    Cursor.of(cur).i += 1;
    return RC.OK;
}

fn eof(cur: *vtab.VtabCursor) bool {
    const c = Cursor.of(cur);
    return c.i >= c.rows.len;
}

fn column(cur: *vtab.VtabCursor, ctx: *Context, i: i32) i32 {
    const c = Cursor.of(cur);
    if (i == 0) api.resultText(ctx, c.rows[c.i], .transient) else api.resultNull(ctx);
    return RC.OK;
}

fn rowid(cur: *vtab.VtabCursor, id: *i64) i32 {
    id.* = @intCast(Cursor.of(cur).i + 1);
    return RC.OK;
}
