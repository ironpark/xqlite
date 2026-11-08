//! Session and transaction statements of the PostgreSQL dialect:
//!
//!   PREPARE name [(type, ...)] AS statement, EXECUTE name [(arg, ...)],
//!   DEALLOCATE [PREPARE] {name | ALL}
//!       The statement's text is the session's (Prepared, State.prepared,
//!       kept when PREPARE runs: xq_pg_prepare()). EXECUTE compiles that
//!       text with each $n replaced by the argument (a cast to the type
//!       PREPARE gave it), so it is compiled where it runs, not planned
//!       once.
//!   DISCARD {ALL | PLANS | SEQUENCES | TEMP | TEMPORARY}
//!       ALL: CLOSE ALL, DEALLOCATE ALL, RESET ALL and the others (outside
//!       a transaction block); PLANS expires the compiled statements;
//!       SEQUENCES forgets currval() and lastval(); TEMP drops the
//!       temporary tables and views.
//!   SET CONSTRAINTS {ALL | name [, ...]} {DEFERRED | IMMEDIATE}
//!       PRAGMA defer_foreign_keys for the transaction (SQLite defers every
//!       foreign key or none, and turns it off when the transaction ends);
//!       a name must be a constraint (whether it is deferrable is not
//!       known: SQLite keeps DEFERRABLE only with INITIALLY DEFERRED).
//!   LOCK [TABLE] [ONLY] name [*] [, ...] [IN mode MODE] [NOWAIT]
//!       Checked (the tables exist, a transaction block), nothing more:
//!       SQLite locks the whole database, a writer at a time.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const prepare = @import("../../sql/prepare.zig");
const main_mod = @import("../../sql/main.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const catalog = @import("../../catalog/catalog.zig");

const Parser = parser.Parser;
const Mem = dfunc.Mem;
const Context = dfunc.Context;
const RC = int.RC;

pub const Error = parser.Error || lower.Error;

const session = @import("session.zig");
const literal = session.literal;
const lowerPg = session.lowerPg;

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether token `t` is the word `w` (lower case; the words of these
/// statements are not all keywords of the lexer).
pub fn isWord(ps: *const Parser, t: lexer.Token, w: []const u8) bool {
    return t.kind == .word and eql(ps.val(t), w);
}

pub fn eatWord(ps: *Parser, w: []const u8) bool {
    if (!isWord(ps, ps.c.peek(), w)) return false;
    ps.c.skip();
    return true;
}

pub fn expectWord(ps: *Parser, w: []const u8) Error!void {
    if (!eatWord(ps, w)) return ps.c.syntaxError();
}

/// Prepare `text` on `db` and finalize it at once: the return code.
pub fn tryPrepare(db: *int.Sqlite3, text: []const u8) i32 {
    var v: ?*vi.Vdbe = null;
    const rc = prepare.prepareLang(db, text, .of(.postgres), 0, &v, null);
    if (v) |x| _ = api.finalize(x);
    return rc;
}

/// `text` compiles, or its error is this statement's: at its place if
/// `at`, where `text` starts in the statement, is given.
pub fn mustCompile(ps: *Parser, text: []const u8, at: ?usize) Error!void {
    const db = ps.p.?.db;
    const rc = tryPrepare(db, text);
    if (rc == RC.OK) return;
    if (rc == RC.NOMEM) return error.OutOfMemory;
    const off = main_mod.errorOffset(db);
    const pos: ?usize = if (at) |s| (if (off >= 0) s + @as(usize, @intCast(off)) else null) else null;
    return ps.c.failState(pos, db.err_state orelse .of("42601"), "{s}", .{main_mod.errmsg(db)});
}

fn expectEnd(ps: *Parser) Error!void {
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
}

/// Compile the statement if it is one of this file's; false if not.
pub fn statement(ps: *Parser) Error!bool {
    const t = ps.c.peek();
    if (isWord(ps, t, "prepare")) {
        try prepareStmt(ps);
        return true;
    }
    if (isWord(ps, t, "execute")) {
        try execute(ps);
        return true;
    }
    if (isWord(ps, t, "deallocate")) {
        try deallocate(ps);
        return true;
    }
    if (isWord(ps, t, "discard")) {
        try discard(ps);
        return true;
    }
    if (isWord(ps, t, "set") and isWord(ps, ps.c.peekAt(1), "constraints")) {
        try setConstraints(ps);
        return true;
    }
    if (isWord(ps, t, "lock")) {
        try lock(ps);
        return true;
    }
    return false;
}

// ==================================================== prepared statements

/// A statement of PREPARE.
pub const Prepared = struct {
    name: []u8,
    /// The PREPARE as written (pg_prepared_statements.statement).
    statement: []u8,
    /// The statement after AS.
    text: []u8,
    /// The types PREPARE gave the parameters, in order ("" for one it did
    /// not), as many as the statement has parameters.
    types: [][]u8,

    fn destroy(x: *Prepared, gpa: std.mem.Allocator) void {
        for (x.types) |t| gpa.free(t);
        gpa.free(x.types);
        gpa.free(x.name);
        gpa.free(x.statement);
        gpa.free(x.text);
        gpa.destroy(x);
    }
};

pub const Statements = struct {
    list: std.ArrayListUnmanaged(*Prepared) = .empty,

    pub fn find(s: *const Statements, name: []const u8) ?*Prepared {
        for (s.list.items) |x| if (eql(x.name, name)) return x;
        return null;
    }

    fn clear(s: *Statements, gpa: std.mem.Allocator) void {
        for (s.list.items) |x| x.destroy(gpa);
        s.list.clearRetainingCapacity();
    }

    fn free(gpa: std.mem.Allocator, p: *anyopaque) void {
        const s: *Statements = @ptrCast(@alignCast(p));
        s.clear(gpa);
        s.list.deinit(gpa);
        gpa.destroy(s);
    }
};

fn statementsOf(db: *const int.Sqlite3) ?*Statements {
    const p = db.xq.postgres.prepared orelse return null;
    return @ptrCast(@alignCast(p));
}

fn statementsFor(db: *int.Sqlite3) error{OutOfMemory}!*Statements {
    if (statementsOf(db)) |s| return s;
    const s = try db.gpa.create(Statements);
    s.* = .{};
    db.xq.postgres.prepared = s;
    db.xq.postgres.prepared_free = Statements.free;
    return s;
}

/// PREPARE name [(type, ...)] AS statement.
fn prepareStmt(ps: *Parser) Error!void {
    const a = ps.arena;
    const sql = ps.c.sql;
    const start = ps.c.advance().start; // PREPARE
    const name = try ps.colId();
    var types: std.ArrayList([]const u8) = .empty;
    if (ps.c.eat(.lparen)) {
        while (true) {
            const at = ps.c.peek().start;
            _ = try ps.typeName();
            try types.append(a, std.mem.trim(u8, sql[at..ps.c.lastEnd()], " \t\r\n"));
            if (!ps.c.eat(.comma)) break;
        }
        _ = try ps.c.expect(.rparen);
    }
    try expectWord(ps, "as");
    const q = ps.c.peek();
    if (!(q.kind == .lparen or isWord(ps, q, "select") or isWord(ps, q, "values") or isWord(ps, q, "table") or isWord(ps, q, "with") or
        isWord(ps, q, "insert") or isWord(ps, q, "update") or isWord(ps, q, "delete") or isWord(ps, q, "merge"))) return ps.c.syntaxError();
    var max_param: usize = 0;
    while (ps.c.peek().kind != .eof) {
        const x = ps.c.advance();
        if (x.kind == .param) max_param = @max(max_param, std.fmt.parseInt(usize, ps.val(x), 10) catch 0);
    }
    const qend = ps.c.lastEnd();
    const text = sql[q.start..qend];
    // The statement compiles, its parameters cast to their types.
    try mustCompile(ps, try substitute(a, sql, q.start, qend, types.items, null), null);
    var all: std.ArrayList(u8) = .empty;
    for (0..@max(max_param, types.items.len)) |i| {
        if (i > 0) try all.append(a, ',');
        if (i < types.items.len) try all.appendSlice(a, types.items[i]);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "SELECT 1 WHERE xq_pg_prepare(");
    try literal(&out, a, name.text);
    try out.appendSlice(a, ", ");
    try literal(&out, a, std.mem.trimEnd(u8, sql[start..@max(ps.end, qend)], " \t\r\n"));
    try out.appendSlice(a, ", ");
    try literal(&out, a, text);
    try out.appendSlice(a, ", ");
    try literal(&out, a, all.items);
    try out.print(a, ", {d}) IS NULL", .{@max(max_param, types.items.len)});
    try lowerPg(ps, try a.dupeSentinel(u8, out.items, 0));
}

/// The text from `from` to `to` of `sql` with each parameter $n replaced
/// by `(args[n-1])::types[n-1]` (args null: NULL), the cast left out
/// where the type is "".
fn substitute(a: std.mem.Allocator, sql: [:0]const u8, from: usize, to: usize, types: []const []const u8, args: ?[]const []const u8) Error![:0]const u8 {
    var sub = Parser.init(a, sql, from, null, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => return a.dupeSentinel(u8, sql[from..to], 0),
    };
    var out: std.ArrayList(u8) = .empty;
    var at = from;
    while (sub.c.peek().kind != .eof) {
        const t = sub.c.advance();
        if (t.start >= to) break;
        if (t.kind != .param) continue;
        const n = std.fmt.parseInt(usize, sub.val(t), 10) catch continue;
        if (n == 0) continue;
        try out.appendSlice(a, sql[at..t.start]);
        const arg: []const u8 = if (args) |xs| (if (n <= xs.len) xs[n - 1] else "NULL") else "NULL";
        const ty: []const u8 = if (n <= types.len) types[n - 1] else "";
        if (ty.len > 0) {
            try out.print(a, "CAST(({s}) AS {s})", .{ arg, ty });
        } else try out.print(a, "({s})", .{arg});
        at = t.end;
    }
    try out.appendSlice(a, sql[at..to]);
    return a.dupeSentinel(u8, out.items, 0);
}

/// EXECUTE name [(arg, ...)]: the statement of PREPARE, its parameters
/// the arguments.
fn execute(ps: *Parser) Error!void {
    const a = ps.arena;
    const sql = ps.c.sql;
    ps.c.skip(); // EXECUTE
    const name = try ps.colId();
    var args: std.ArrayList([]const u8) = .empty;
    if (ps.c.eat(.lparen)) {
        while (true) {
            const at = ps.c.peek().start;
            _ = try ps.expr0();
            try args.append(a, sql[at..ps.c.lastEnd()]);
            if (!ps.c.eat(.comma)) break;
        }
        _ = try ps.c.expect(.rparen);
    }
    try expectEnd(ps);
    const p = ps.p.?;
    const x = (if (statementsOf(p.db)) |s| s.find(name.text) else null) orelse
        return ps.c.failState(null, .of("26000"), "prepared statement \"{s}\" does not exist", .{name.text});
    // A statement of no parameters ignores the arguments (PostgreSQL's).
    if (args.items.len != x.types.len and x.types.len > 0) {
        return ps.failFields(null, .of("42601"), .{
            .message = try std.fmt.allocPrint(a, "wrong number of parameters for prepared statement \"{s}\"", .{x.name}),
            .detail = try std.fmt.allocPrint(a, "Expected {d} parameters but got {d}.", .{ x.types.len, args.items.len }),
        });
    }
    const types = try a.alloc([]const u8, x.types.len);
    for (types, x.types) |*t, y| t.* = y;
    const src = try a.dupeSentinel(u8, x.text, 0);
    const text = try substitute(a, src, 0, src.len, types, args.items);
    var sub = Parser.init(a, text, 0, null, .of(p.db)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => return ps.c.failState(null, .of("42601"), "syntax error in prepared statement \"{s}\"", .{x.name}),
    };
    // The statement's command (the wire server's tag).
    if (p.vdbe == null) _ = @import("../../sql/build.zig").getVdbe(p);
    if (p.vdbe) |v| v.xq_command_sql = v.alloc().dupe(u8, x.text) catch "";
    @import("frontend.zig").compile(p, text, &sub) catch |err| switch (err) {
        error.ParseFailed => return ps.c.failedIn(&sub.c, error.ParseFailed),
        else => |e| return e,
    };
}

/// DEALLOCATE [PREPARE] name | ALL.
fn deallocate(ps: *Parser) Error!void {
    const a = ps.arena;
    ps.c.skip(); // DEALLOCATE
    _ = eatWord(ps, "prepare");
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "SELECT 1 WHERE xq_pg_deallocate(");
    if (eatWord(ps, "all")) {
        try text.appendSlice(a, "NULL");
    } else try literal(&text, a, (try ps.colId()).text);
    try expectEnd(ps);
    try text.appendSlice(a, ") IS NULL");
    try lowerPg(ps, try a.dupeSentinel(u8, text.items, 0));
}

/// Forget every prepared statement (DEALLOCATE ALL, DISCARD ALL).
fn deallocateAll(db: *int.Sqlite3) void {
    if (statementsOf(db)) |s| s.clear(db.gpa);
}

// ================================================================ DISCARD

fn discard(ps: *Parser) Error!void {
    const a = ps.arena;
    ps.c.skip(); // DISCARD
    const t = ps.c.peek();
    const what: []const u8 = if (isWord(ps, t, "all")) "all" else if (isWord(ps, t, "plans")) "plans" else if (isWord(ps, t, "sequences")) "sequences" else if (isWord(ps, t, "temp") or isWord(ps, t, "temporary")) "temp" else return ps.c.syntaxError();
    ps.c.skip();
    try expectEnd(ps);
    const p = ps.p.?;
    if (eql(what, "all") and !main_mod.getAutocommit(p.db)) {
        return ps.c.failState(null, .of("25001"), "DISCARD ALL cannot run inside a transaction block", .{});
    }
    if (eql(what, "all") or eql(what, "temp")) try dropTemp(ps);
    var text: std.ArrayList(u8) = .empty;
    try text.print(a, "SELECT 1 WHERE xq_pg_discard('{s}') IS NULL", .{what});
    try lowerPg(ps, try a.dupeSentinel(u8, text.items, 0));
}

/// DISCARD TEMP: a DROP of each temporary view and table, when the
/// statement runs.
fn dropTemp(ps: *Parser) Error!void {
    const p = ps.p.?;
    const db = p.db;
    var v: ?*vi.Vdbe = null;
    const q = "SELECT type, name FROM temp.sqlite_schema WHERE type IN ('view', 'table') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE 'xq\\_%' ESCAPE '\\' ORDER BY type = 'table', name";
    const rc = prepare.prepareLang(db, q, .of(.sqlite), 0, &v, null);
    const stmt = v orelse {
        if (rc == RC.NOMEM) return error.OutOfMemory;
        return;
    };
    defer _ = api.finalize(stmt);
    while (api.step(stmt) == RC.ROW) {
        const kind = api.columnText(stmt, 0) orelse continue;
        const name = api.columnText(stmt, 1) orelse continue;
        const text = try std.fmt.allocPrintSentinel(ps.arena, "DROP {s} IF EXISTS pg_temp.{f} CASCADE", .{
            if (eql(kind, "view")) "VIEW" else "TABLE", @import("../dialect.zig").Quoted('"'){ .z = name },
        }, 0);
        catalog.codeExecDialect(p, text);
    }
}

// ======================================================== SET CONSTRAINTS

fn setConstraints(ps: *Parser) Error!void {
    ps.c.skipN(2); // SET CONSTRAINTS
    const p = ps.p.?;
    const db = p.db;
    var names: std.ArrayList(tree.Name) = .empty;
    if (!eatWord(ps, "all")) {
        while (true) {
            try names.append(ps.arena, try ps.colId());
            if (ps.c.eat(.dot)) names.items[names.items.len - 1] = try ps.colId();
            if (!ps.c.eat(.comma)) break;
        }
    }
    const deferred = if (eatWord(ps, "deferred")) true else if (eatWord(ps, "immediate")) false else return ps.c.syntaxError();
    try expectEnd(ps);
    // A named constraint exists (pg_constraint). Whether it is
    // deferrable is not checked: SQLite keeps DEFERRABLE only with
    // INITIALLY DEFERRED.
    for (names.items) |n| {
        if (!try constraintExists(db, n.text)) return ps.c.failState(null, .of("42704"), "constraint \"{s}\" does not exist", .{n.text});
    }
    if (main_mod.getAutocommit(db)) {
        @import("../../sql/util.zig").notice(p, .{ .level = .warning, .sqlstate = "25P01".*, .fields = .{ .message = "SET CONSTRAINTS can only be used in transaction blocks" } });
        _ = @import("../../sql/build.zig").getVdbe(p);
        return;
    }
    try @import("../../ir/ir.zig").stmt.lowerSqliteText(p, if (deferred) "PRAGMA defer_foreign_keys = ON" else "PRAGMA defer_foreign_keys = OFF");
}

fn constraintExists(db: *int.Sqlite3, name: []const u8) Error!bool {
    var v: ?*vi.Vdbe = null;
    const rc = prepare.prepareLang(db, "SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = $1", .of(.postgres), 0, &v, null);
    const stmt = v orelse {
        if (rc == RC.NOMEM) return error.OutOfMemory;
        return false;
    };
    defer _ = api.finalize(stmt);
    if (api.bindText(stmt, 1, name) != RC.OK) return error.OutOfMemory;
    return api.step(stmt) == RC.ROW;
}

// =================================================================== LOCK

fn lock(ps: *Parser) Error!void {
    ps.c.skip(); // LOCK
    _ = eatWord(ps, "table");
    while (true) {
        _ = eatWord(ps, "only");
        const q = try ps.qname();
        const r = try ps.lookup(q, .relation);
        try ps.readSchema();
        if (@import("../../sql/build.zig").findTable(ps.p.?.db, r.q.name.text, if (r.q.schema) |s| s.text else null) == null) {
            return ps.c.failState(q.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{q.name.text});
        }
        _ = ps.c.eatOp("*");
        if (!ps.c.eat(.comma)) break;
    }
    if (eatWord(ps, "in")) {
        // ACCESS SHARE, ROW SHARE, ROW EXCLUSIVE, SHARE UPDATE EXCLUSIVE,
        // SHARE, SHARE ROW EXCLUSIVE, EXCLUSIVE, ACCESS EXCLUSIVE.
        if (eatWord(ps, "access")) {
            if (!eatWord(ps, "share")) try expectWord(ps, "exclusive");
        } else if (eatWord(ps, "row")) {
            if (!eatWord(ps, "share")) try expectWord(ps, "exclusive");
        } else if (eatWord(ps, "share")) {
            if (eatWord(ps, "update")) {
                try expectWord(ps, "exclusive");
            } else if (eatWord(ps, "row")) try expectWord(ps, "exclusive");
        } else try expectWord(ps, "exclusive");
        try expectWord(ps, "mode");
    }
    _ = eatWord(ps, "nowait");
    try expectEnd(ps);
    const p = ps.p.?;
    if (main_mod.getAutocommit(p.db)) return ps.c.failState(null, .of("25P01"), "LOCK TABLE can only be used in transaction blocks", .{});
    _ = @import("../../sql/build.zig").getVdbe(p);
}

// ============================================================== functions

pub const functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_prepare", 5, .{ .unsafe = true, .direct_only = true }, prepareFunc),
    dfunc.scalar("xq_pg_deallocate", 1, .{ .unsafe = true, .direct_only = true }, deallocateFunc),
    dfunc.scalar("xq_pg_discard", 1, .{ .unsafe = true, .direct_only = true }, discardFunc),
};

/// xq_pg_prepare(name, statement, text, types, n): keep the statement.
fn prepareFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const gpa = db.gpa;
    const name = api.valueText(argv[0]) orelse return api.resultErrorNomem(ctx);
    const s = statementsFor(db) catch return api.resultErrorNomem(ctx);
    if (s.find(name) != null) {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("42P05"), std.fmt.bufPrint(&buf, "prepared statement \"{s}\" already exists", .{name[0..@min(name.len, 100)]}) catch "prepared statement already exists");
    }
    const n: usize = @intCast(@max(api.valueInt64(argv[4]), 0));
    const x = gpa.create(Prepared) catch return api.resultErrorNomem(ctx);
    x.* = .{ .name = &.{}, .statement = &.{}, .text = &.{}, .types = &.{} };
    (blk: {
        x.name = gpa.dupe(u8, name) catch |e| break :blk e;
        x.statement = gpa.dupe(u8, api.valueText(argv[1]) orelse "") catch |e| break :blk e;
        x.text = gpa.dupe(u8, api.valueText(argv[2]) orelse "") catch |e| break :blk e;
        x.types = gpa.alloc([]u8, n) catch |e| break :blk e;
        for (x.types) |*t| t.* = &.{};
        var it = std.mem.splitScalar(u8, api.valueText(argv[3]) orelse "", ',');
        for (x.types) |*t| t.* = gpa.dupe(u8, it.next() orelse "") catch |e| break :blk e;
        s.list.append(gpa, x) catch |e| break :blk e;
    }) catch {
        x.destroy(gpa);
        return api.resultErrorNomem(ctx);
    };
    api.resultInt64(ctx, 0);
}

/// xq_pg_deallocate(name): forget it; NULL: every one.
fn deallocateFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_NULL) {
        deallocateAll(db);
        return api.resultInt64(ctx, 0);
    }
    const name = api.valueText(argv[0]) orelse "";
    const s = statementsOf(db);
    const x = (if (s) |y| y.find(name) else null) orelse {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("26000"), std.fmt.bufPrint(&buf, "prepared statement \"{s}\" does not exist", .{name[0..@min(name.len, 100)]}) catch "prepared statement does not exist");
    };
    for (s.?.list.items, 0..) |y, i| if (y == x) {
        _ = s.?.list.orderedRemove(i);
        break;
    };
    x.destroy(db.gpa);
    api.resultInt64(ctx, 0);
}

/// xq_pg_discard(what): DISCARD ALL, PLANS, SEQUENCES or TEMP (its
/// tables are dropped by the statement).
fn discardFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const what = api.valueText(argv[0]) orelse "";
    const all = eql(what, "all");
    if (all) {
        @import("cursor.zig").closeAll(db);
        deallocateAll(db);
        db.xq.postgres.resetParams(db.gpa);
    }
    if (all or eql(what, "sequences")) {
        var it = db.xq.currval.keyIterator();
        while (it.next()) |k| db.gpa.free(k.*);
        db.xq.currval.clearRetainingCapacity();
        if (db.xq.last_sequence) |z| db.gpa.free(z);
        db.xq.last_sequence = null;
    }
    if (all or eql(what, "plans")) @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
    api.resultInt64(ctx, 0);
}

// ================================================================ helpers

// ================================================================== tests

const testing = std.testing;
const Conn = @import("../../sql/sql_test.zig").Conn;

test "pg: PREPARE, EXECUTE, DEALLOCATE, DISCARD, SET CONSTRAINTS, LOCK" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    main_mod.setDialect(c.db, .postgres);
    try c.exec("CREATE TABLE t (a int, b text)");
    try c.exec("PREPARE ins (int, text) AS INSERT INTO t VALUES ($1, $2)");
    try c.exec("EXECUTE ins(1, 'x')");
    try c.exec("EXECUTE ins (2 + 1, upper('y'))");
    try c.exec("PREPARE q AS SELECT a, b FROM t WHERE a > $1 ORDER BY a");
    try c.expectRows("EXECUTE q(0)", "1|x\n3|Y\n");
    try c.expectRows("EXECUTE q('2')", "3|Y\n");
    try c.expectError("PREPARE q AS SELECT 1", "prepared statement \"q\" already exists");
    try c.expectError("EXECUTE nosuch", "prepared statement \"nosuch\" does not exist");
    try c.expectError("EXECUTE q", "wrong number of parameters for prepared statement \"q\"\nDETAIL:  Expected 1 parameters but got 0.");
    try c.exec("DEALLOCATE q");
    try c.expectError("DEALLOCATE PREPARE q", "prepared statement \"q\" does not exist");
    try c.exec("DEALLOCATE ALL");
    try c.expectError("EXECUTE ins(4, 'z')", "prepared statement \"ins\" does not exist");
    // DISCARD.
    try c.exec("CREATE TEMP TABLE tt (x int); CREATE TEMP VIEW tv AS SELECT x FROM tt");
    try c.exec("DISCARD TEMP");
    try c.expectError("SELECT * FROM tt", "relation \"tt\" does not exist");
    try c.exec("DISCARD PLANS; DISCARD SEQUENCES; DISCARD ALL");
    try c.expectError("BEGIN; DISCARD ALL", "DISCARD ALL cannot run inside a transaction block");
    try c.exec("ROLLBACK");
    // SET CONSTRAINTS, LOCK.
    try c.expectError("LOCK t", "LOCK TABLE can only be used in transaction blocks");
    try c.exec("BEGIN; LOCK TABLE t IN ACCESS EXCLUSIVE MODE NOWAIT; LOCK ONLY t, t * IN SHARE MODE");
    try c.expectError("LOCK nosuch", "relation \"nosuch\" does not exist");
    try c.exec("SET CONSTRAINTS ALL DEFERRED; SET CONSTRAINTS ALL IMMEDIATE");
    try c.expectError("SET CONSTRAINTS nosuch DEFERRED", "constraint \"nosuch\" does not exist");
    try c.exec("ROLLBACK");
}
