//! Cursors of the PostgreSQL dialect:
//!
//!   DECLARE name [BINARY] [ASENSITIVE | INSENSITIVE] [[NO] SCROLL]
//!       CURSOR [{WITH | WITHOUT} HOLD] FOR query
//!   FETCH [direction] [FROM | IN] name, MOVE [direction] [FROM | IN] name
//!   CLOSE name | ALL
//!   UPDATE ... / DELETE ... WHERE CURRENT OF name
//!
//! A cursor is the session's (State.cursors, owned here). DECLARE runs its
//! query to the end when it executes and keeps the rows in memory
//! (xq_pg_cursor_declare(): a statement of the query prepared and stepped
//! on the connection), so the cursor is insensitive, as PostgreSQL allows
//! and as its holdable cursors are anyway. The cursor keeps the names and
//! the types of the query's columns as the statement gave them.
//!
//! FETCH is compiled into a query of the cursor's columns
//! (xq_pg_cursor_value(name, row, i), each of the type of its column) over
//! json_each() of the row numbers xq_pg_cursor_fetch() returns, which
//! moves the cursor when the statement runs: a FETCH prepared once runs
//! again. MOVE moves it the same way (xq_pg_cursor_move()) and returns no
//! row; the rows it moved over are the statement's changes (the wire
//! server's `MOVE n`). Moving follows PostgreSQL's DoPortalRunFetch() and
//! PortalRunSelect(): the position before the first row, on one, after
//! the last; a NO SCROLL cursor cannot go back.
//!
//! A cursor without HOLD needs a transaction block (an explicit
//! transaction, or the implicit one of the wire server's several
//! statements) and is closed when it ends (ended(), from the core's end
//! of a transaction); one WITH HOLD stays open after COMMIT, and is
//! dropped if the transaction that declared it rolls back.
//!
//! WHERE CURRENT OF works on a cursor of one table (no join, grouping,
//! aggregate, DISTINCT or set operation; an ORDER BY only with FOR
//! UPDATE/SHARE, as PostgreSQL's "simply updatable" scan): DECLARE keeps
//! the rowid of each row (the query run with `, rowid` added to its select
//! list) and the statement's WHERE is `rowid = xq_pg_cursor_rowid(name,
//! table)`.
//!
//! pg_cursors (catalog_views.zig) reads xq_pg_cursors().

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const prepare = @import("../../sql/prepare.zig");
const main_mod = @import("../../sql/main.zig");
const typing = @import("../../sql/typing.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const dialect = @import("../dialect.zig");

const Parser = parser.Parser;
const Name = tree.Name;
const Expr = tree.Expr;
const Mem = dfunc.Mem;
const Context = dfunc.Context;
const RC = int.RC;

pub const Error = parser.Error || lower.Error;

const commands = @import("commands.zig");
const rows_mod = @import("rows.zig");
const eql = commands.eql;
const isWord = commands.isWord;
const eatWord = commands.eatWord;
const expectWord = commands.expectWord;
const literal = @import("session.zig").literal;
const lowerPg = @import("session.zig").lowerPg;

fn skip2(ps: *Parser) bool {
    ps.c.skipN(2);
    return true;
}

// ================================================================ cursors

/// FETCH ALL's count (PostgreSQL's FETCH_ALL, LONG_MAX).
pub const fetch_all: i64 = std.math.maxInt(i64);

/// A direction of FETCH and MOVE (PostgreSQL's FetchDirection).
pub const Direction = enum(u8) { forward = 0, backward = 1, absolute = 2, relative = 3 };

pub const Cursor = struct {
    name: []u8,
    /// pg_cursors.statement: the DECLARE as written.
    statement: []u8,
    hold: bool,
    /// NO SCROLL: no fetch backward.
    no_scroll: bool,
    /// Declared in the transaction that is open: dropped if it rolls back.
    in_tx: bool,
    /// The savepoints open when it was declared (savepointEnded()).
    depth: u32 = 0,
    /// When DECLARE ran: microseconds since 1970 (UTC).
    created: i64,
    /// The result columns: names and types (sql/typing.zig ids of the
    /// connection).
    names: [][]u8,
    types: []typing.TypeId,
    /// The rows, `names.len` values each (copies).
    values: []*Mem,
    nrows: usize,
    /// The rowid of each row in `table` (WHERE CURRENT OF), or empty.
    rowids: []i64 = &.{},
    /// The table of a simply updatable cursor: "schema"."name" as the
    /// parser resolves names (empty for none).
    table: []u8 = &.{},

    // PostgreSQL's Portal: atStart, atEnd, portalPos.
    at_start: bool = true,
    at_end: bool = false,
    portal_pos: u64 = 0,
    /// The executor's position: 0 before the first row, k on row k,
    /// nrows + 1 after the last.
    pos: usize = 0,

    fn ncols(c: *const Cursor) usize {
        return c.names.len;
    }

    fn value(c: *const Cursor, row: usize, col: usize) *Mem {
        return c.values[row * c.names.len + col];
    }

    fn destroy(c: *Cursor, gpa: std.mem.Allocator) void {
        for (c.values) |v| api.valueFree(v);
        gpa.free(c.values);
        for (c.names) |n| gpa.free(n);
        gpa.free(c.names);
        gpa.free(c.types);
        gpa.free(c.rowids);
        gpa.free(c.table);
        gpa.free(c.name);
        gpa.free(c.statement);
        gpa.destroy(c);
    }

    /// Whether the cursor is on a row (FETCH 0 would return one).
    fn onRow(c: *const Cursor) bool {
        return !c.at_start and !c.at_end;
    }

    /// PortalRunSelect(): move `count` rows forward or back (fetch_all:
    /// to the end), appending the rows passed (1-based) to `out`; the
    /// number of rows.
    fn runSelect(c: *Cursor, forward: bool, count_arg: i64, out: ?*std.ArrayList(u32), gpa: std.mem.Allocator) MoveError!u64 {
        var count = count_arg;
        var n: u64 = 0;
        if (forward) {
            if (c.at_end or count <= 0) return 0;
            if (count == fetch_all) count = 0;
            while (count == 0 or n < @as(u64, @intCast(count))) {
                if (c.pos >= c.nrows) {
                    c.pos = c.nrows + 1;
                    break;
                }
                c.pos += 1;
                if (out) |o| try o.append(gpa, @intCast(c.pos));
                n += 1;
            }
            if (n > 0) c.at_start = false;
            if (count == 0 or n < @as(u64, @intCast(count))) c.at_end = true;
            c.portal_pos += n;
        } else {
            if (c.no_scroll) return error.NoScroll;
            if (c.at_start or count <= 0) return 0;
            if (count == fetch_all) count = 0;
            while (count == 0 or n < @as(u64, @intCast(count))) {
                if (c.pos <= 1) {
                    c.pos = 0;
                    break;
                }
                c.pos -= 1;
                if (out) |o| try o.append(gpa, @intCast(c.pos));
                n += 1;
            }
            if (n > 0 and c.at_end) {
                c.at_end = false;
                c.portal_pos += 1;
            }
            if (count == 0 or n < @as(u64, @intCast(count))) {
                c.at_start = true;
                c.portal_pos = 0;
                c.pos = 0;
            } else c.portal_pos -= n;
        }
        return n;
    }

    /// DoPortalRewind().
    fn rewind(c: *Cursor) MoveError!void {
        if (c.at_start and !c.at_end) return;
        if (c.no_scroll) return error.NoScroll;
        c.pos = 0;
        c.at_start = true;
        c.at_end = false;
        c.portal_pos = 0;
    }

    /// DoPortalRunFetch(): FETCH (rows to `out`) or MOVE (`out` null) in
    /// direction `dir` by `count`; the number of rows.
    pub fn fetch(c: *Cursor, dir_arg: Direction, count_arg: i64, out: ?*std.ArrayList(u32), gpa: std.mem.Allocator) MoveError!u64 {
        var dir = dir_arg;
        var count = count_arg;
        switch (dir) {
            .forward => if (count < 0) {
                dir = .backward;
                count = -count;
            },
            .backward => if (count < 0) {
                dir = .forward;
                count = -count;
            },
            .absolute => {
                if (count > 0) {
                    if (@as(u64, @intCast(count - 1)) <= c.portal_pos / 2 or c.portal_pos >= fetch_all) {
                        try c.rewind();
                        if (count > 1) _ = try c.runSelect(true, count - 1, null, gpa);
                    } else {
                        var pos: i64 = @intCast(c.portal_pos);
                        if (c.at_end) pos += 1;
                        if (count <= pos) {
                            _ = try c.runSelect(false, pos - count + 1, null, gpa);
                        } else if (count > pos + 1) {
                            _ = try c.runSelect(true, count - pos - 1, null, gpa);
                        }
                    }
                    return c.runSelect(true, 1, out, gpa);
                } else if (count < 0) {
                    _ = try c.runSelect(true, fetch_all, null, gpa);
                    if (count < -1) _ = try c.runSelect(false, -count - 1, null, gpa);
                    return c.runSelect(false, 1, out, gpa);
                } else {
                    try c.rewind();
                    return c.runSelect(true, 0, out, gpa);
                }
            },
            .relative => {
                if (count > 0) {
                    if (count > 1) _ = try c.runSelect(true, count - 1, null, gpa);
                    return c.runSelect(true, 1, out, gpa);
                } else if (count < 0) {
                    if (count < -1) _ = try c.runSelect(false, -count - 1, null, gpa);
                    return c.runSelect(false, 1, out, gpa);
                }
                dir = .forward;
            },
        }
        var forward = dir == .forward;
        if (count == 0) {
            const on_row = c.onRow();
            // MOVE 0: 1 if FETCH 0 would return a row.
            if (out == null) return @intFromBool(on_row);
            if (on_row) {
                _ = try c.runSelect(false, 1, null, gpa);
                count = 1;
                forward = true;
            }
        }
        // MOVE BACKWARD ALL: a rewind.
        if (!forward and count == fetch_all and out == null) {
            var result = c.portal_pos;
            if (result > 0 and !c.at_end) result -= 1;
            try c.rewind();
            return result;
        }
        return c.runSelect(forward, count, out, gpa);
    }
};

pub const MoveError = error{ NoScroll, OutOfMemory };

/// The cursors of a session, in the order they were declared
/// (State.cursors).
pub const Cursors = struct {
    list: std.ArrayListUnmanaged(*Cursor) = .empty,

    pub fn find(s: *const Cursors, name: []const u8) ?*Cursor {
        for (s.list.items) |c| if (eql(c.name, name)) return c;
        return null;
    }

    fn remove(s: *Cursors, gpa: std.mem.Allocator, c: *Cursor) void {
        for (s.list.items, 0..) |x, i| if (x == c) {
            _ = s.list.orderedRemove(i);
            break;
        };
        c.destroy(gpa);
    }

    fn clear(s: *Cursors, gpa: std.mem.Allocator) void {
        for (s.list.items) |c| c.destroy(gpa);
        s.list.clearRetainingCapacity();
    }

    fn free(gpa: std.mem.Allocator, p: *anyopaque) void {
        const s: *Cursors = @ptrCast(@alignCast(p));
        s.clear(gpa);
        s.list.deinit(gpa);
        gpa.destroy(s);
    }
};

/// The cursors of `db`'s session, if it has any.
pub fn cursorsOf(db: *const int.Sqlite3) ?*Cursors {
    const p = db.xq.postgres.cursors orelse return null;
    return @ptrCast(@alignCast(p));
}

fn cursorsFor(db: *int.Sqlite3) error{OutOfMemory}!*Cursors {
    if (cursorsOf(db)) |s| return s;
    const s = try db.gpa.create(Cursors);
    s.* = .{};
    db.xq.postgres.cursors = s;
    db.xq.postgres.cursors_free = Cursors.free;
    return s;
}

/// The transaction ended (dialect.transactionEnded()): close the cursors
/// without HOLD; those WITH HOLD stay, but not the ones the transaction
/// declared if it rolled back.
pub fn ended(db: *int.Sqlite3, committed: bool) void {
    const s = cursorsOf(db) orelse return;
    var i: usize = 0;
    while (i < s.list.items.len) {
        const c = s.list.items[i];
        if (!c.hold or (!committed and c.in_tx)) {
            _ = s.list.orderedRemove(i);
            c.destroy(db.gpa);
            continue;
        }
        c.in_tx = false;
        i += 1;
    }
}

/// The number of savepoints open on `db`.
fn savepoints(db: *const int.Sqlite3) u32 {
    var n: u32 = 0;
    var it = db.savepoint;
    while (it) |sp| : (it = sp.next) n += 1;
    return n;
}

/// A RELEASE or ROLLBACK TO ran (dialect.savepointEnded()): a rollback to
/// a savepoint drops the cursors declared after it (as PostgreSQL's
/// subtransaction's portals); the ones declared in a released savepoint
/// are now its parent's.
pub fn savepointEnded(db: *int.Sqlite3, rolled_back: bool) void {
    const s = cursorsOf(db) orelse return;
    const n = savepoints(db);
    var i: usize = 0;
    while (i < s.list.items.len) {
        const c = s.list.items[i];
        if (rolled_back and c.in_tx and c.depth >= n and n > 0) {
            _ = s.list.orderedRemove(i);
            c.destroy(db.gpa);
            continue;
        }
        c.depth = @min(c.depth, n);
        i += 1;
    }
}

/// Close every cursor (CLOSE ALL, DISCARD ALL).
pub fn closeAll(db: *int.Sqlite3) void {
    if (cursorsOf(db)) |s| s.clear(db.gpa);
}

// ============================================================= statements

/// Compile the statement if it is one of this file's; false if not.
pub fn statement(ps: *Parser) Error!bool {
    const t = ps.c.peek();
    if (isWord(ps, t, "declare")) {
        try declare(ps);
        return true;
    }
    if (isWord(ps, t, "fetch")) {
        try fetchStmt(ps, false);
        return true;
    }
    if (isWord(ps, t, "move")) {
        try fetchStmt(ps, true);
        return true;
    }
    if (isWord(ps, t, "close")) {
        try close(ps);
        return true;
    }
    return false;
}

/// Flags of xq_pg_cursor_declare().
const flag_hold = 1;
const flag_no_scroll = 2;
const flag_rowid = 4;

fn declare(ps: *Parser) Error!void {
    const a = ps.arena;
    const sql = ps.c.sql;
    const start = ps.c.advance().start; // DECLARE
    const name = try ps.colId();
    var scroll: ?bool = null;
    var sensitive: ?bool = null;
    var binary = false;
    var binary_pos: usize = 0;
    while (true) {
        const at = ps.c.peek().start;
        if ((isWord(ps, ps.c.peek(), "no") and isWord(ps, ps.c.peekAt(1), "scroll") and skip2(ps))) {
            if (scroll == true) return conflict(ps, "SCROLL", "NO SCROLL");
            scroll = false;
        } else if (eatWord(ps, "scroll")) {
            if (scroll == false) return conflict(ps, "SCROLL", "NO SCROLL");
            scroll = true;
        } else if (eatWord(ps, "binary")) {
            binary = true;
            binary_pos = at;
        } else if (eatWord(ps, "insensitive")) {
            if (sensitive == true) return conflict(ps, "ASENSITIVE", "INSENSITIVE");
            sensitive = false;
        } else if (eatWord(ps, "asensitive")) {
            if (sensitive == false) return conflict(ps, "ASENSITIVE", "INSENSITIVE");
            sensitive = true;
        } else break;
    }
    try expectWord(ps, "cursor");
    var hold = false;
    if (eatWord(ps, "with")) {
        try expectWord(ps, "hold");
        hold = true;
    } else if (eatWord(ps, "without")) try expectWord(ps, "hold");
    try expectWord(ps, "for");
    const q = ps.c.peek();
    if (!(q.kind == .lparen or isWord(ps, q, "select") or isWord(ps, q, "values") or isWord(ps, q, "table") or isWord(ps, q, "with"))) return ps.c.syntaxError();
    // The query's tokens: its end, its parameters, FOR UPDATE/SHARE and
    // where its FROM is.
    var depth: usize = 0;
    var max_param: u32 = 0;
    var lock: ?[]const u8 = null;
    var from_at: ?usize = null;
    while (ps.c.peek().kind != .eof) {
        const x = ps.c.advance();
        switch (x.kind) {
            .lparen => depth += 1,
            .rparen => depth -|= 1,
            .param => max_param = @max(max_param, std.fmt.parseInt(u32, ps.val(x), 10) catch 0),
            else => if (depth == 0) {
                if (isWord(ps, x, "from") and from_at == null) from_at = x.start;
                if (lock == null and isWord(ps, x, "for")) lock = lockStrength(ps);
            },
        }
    }
    const qend = ps.c.lastEnd();
    const query = sql[q.start..qend];
    if (binary) return ps.unsupported(binary_pos, "DECLARE BINARY");
    const p = ps.p.?;
    const db = p.db;
    const shape = try analyze(ps, q.start, lock != null);
    // The table of a simply updatable cursor, the query with its rowid.
    var table: []const u8 = "";
    var run_query: []const u8 = query;
    if (from_at) |f| if (shape.table) |tbl| {
        const with_rowid = try std.fmt.allocPrint(a, "{s}, rowid {s}", .{ sql[q.start..f], sql[f..qend] });
        if (check(db, with_rowid)) {
            table = tbl;
            run_query = with_rowid;
        }
    };
    // The query compiles (its errors are DECLARE's, at their place).
    if (table.len == 0) try commands.mustCompile(ps, query, q.start);
    if (lock) |l| {
        if (hold) return readOnly(ps, .of("0A000"), "DECLARE CURSOR WITH HOLD ... {s} is not supported", l, "Holdable");
        if (scroll == true) return readOnly(ps, .of("0A000"), "DECLARE SCROLL CURSOR ... {s} is not supported", l, "Scrollable");
        if (sensitive == false) return readOnly(ps, .of("42P11"), "DECLARE INSENSITIVE CURSOR ... {s} is not valid", l, "Insensitive");
    }
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "SELECT 1 WHERE xq_pg_cursor_declare(");
    try literal(&text, a, name.text);
    var flags: u32 = 0;
    if (hold) flags |= flag_hold;
    // Without SCROLL, PostgreSQL scrolls a plan that can run backward
    // (shape.scrollable).
    if (scroll == false or (scroll == null and !shape.scrollable)) flags |= flag_no_scroll;
    if (table.len > 0) flags |= flag_rowid;
    try text.print(a, ", {d}, ", .{flags});
    try literal(&text, a, run_query);
    try text.appendSlice(a, ", ");
    const stmt_end = std.mem.trimEnd(u8, sql[start..@max(ps.end, qend)], " \t\r\n");
    try literal(&text, a, stmt_end);
    try text.appendSlice(a, ", ");
    try literal(&text, a, table);
    for (1..max_param + 1) |i| try text.print(a, ", ${d}", .{i});
    try text.appendSlice(a, ") IS NULL");
    try lowerPg(ps, try a.dupeSentinel(u8, text.items, 0));
}

fn conflict(ps: *Parser, x: []const u8, y: []const u8) Error {
    return ps.c.failState(null, .of("42P11"), "cannot specify both {s} and {s}", .{ x, y });
}

fn readOnly(ps: *Parser, state: int.ErrorState, comptime fmt: []const u8, lock: []const u8, kind: []const u8) Error {
    return ps.failFields(null, state, .{
        .message = try std.fmt.allocPrint(ps.arena, fmt, .{lock}),
        .detail = try std.fmt.allocPrint(ps.arena, "{s} cursors must be READ ONLY.", .{kind}),
    });
}

/// After FOR: the locking clause as PostgreSQL names it (FOR UPDATE, FOR
/// NO KEY UPDATE, FOR SHARE, FOR KEY SHARE), null if it is none.
fn lockStrength(ps: *Parser) ?[]const u8 {
    const t = ps.c.peek();
    const u = ps.c.peekAt(1);
    if (isWord(ps, t, "update")) return "FOR UPDATE";
    if (isWord(ps, t, "share")) return "FOR SHARE";
    if (isWord(ps, t, "no") and isWord(ps, u, "key")) return "FOR NO KEY UPDATE";
    if (isWord(ps, t, "key") and isWord(ps, u, "share")) return "FOR KEY SHARE";
    return null;
}

/// Whether `query` compiles.
fn check(db: *int.Sqlite3, query: []const u8) bool {
    return commands.tryPrepare(db, query) == RC.OK;
}

/// What the plan of a query would allow in PostgreSQL, from its shape.
const Shape = struct {
    /// The table of a simply updatable scan of one ("schema"."name").
    table: ?[]const u8 = null,
    /// Without SCROLL, fetches may go backward (PostgreSQL's
    /// ExecSupportsBackwardScan()): no aggregate, grouping, window,
    /// DISTINCT, set operation, join, semi-join or locking clause.
    scrollable: bool = true,
};

/// The Shape of the query at `at` (FOR UPDATE/SHARE: `locked`).
fn analyze(ps: *Parser, at: usize, locked: bool) Error!Shape {
    var sub = Parser.init(ps.arena, ps.c.sql, at, null, .{}) catch return .{ .scrollable = false };
    sub.p = ps.p;
    const st = sub.statement() catch return .{ .scrollable = false };
    if (st != .select) return .{ .scrollable = false };
    const s = st.select;
    var shape: Shape = .{ .scrollable = !locked and scrollable(s) };
    if (s.with != null or (s.order_by.len > 0 and !locked)) return shape;
    const core = switch (s.body.*) {
        .core => |c| c,
        else => return shape,
    };
    if (!plainCore(core) or core.from.len != 1) return shape;
    const q = switch (core.from[0].source) {
        .table => |q| q,
        else => return shape,
    };
    shape.table = try tableKey(ps.arena, q);
    return shape;
}

/// Whether a core has no DISTINCT, grouping, window or aggregate.
fn plainCore(core: *const tree.Core) bool {
    if (core.distinct or core.group_by.len > 0 or core.having != null or core.windows.len > 0) return false;
    for (core.cols) |rc| switch (rc) {
        .expr => |e| if (aggregate(e.e)) return false,
        else => {},
    };
    return true;
}

/// Whether PostgreSQL's plan of `s` can run backward (Shape.scrollable).
fn scrollable(s: *const tree.Select) bool {
    if (s.with) |w| for (w.ctes) |c| if (!scrollable(c.select)) return false;
    // An ORDER BY the planner sorts for last (a Sort runs backward).
    const sorted = s.order_by.len > 0;
    return switch (s.body.*) {
        // One row of VALUES is a Result, which does not.
        .values => |rows| rows.len > 1,
        .nested => |n| scrollable(n),
        .compound => false,
        .core => |core| {
            if (core.from.len == 0) return false;
            // Hashed grouping, DISTINCT, semi-join: sorted after.
            if (core.group_by.len > 0 or core.having != null or core.distinct) return sorted;
            for (core.cols) |rc| switch (rc) {
                .expr => |e| if (aggregate(e.e)) return false,
                else => {},
            };
            if (core.windows.len > 0 or core.from.len > 1) return false;
            if (core.where) |w| if (semiJoin(w)) return sorted;
            return switch (core.from[0].source) {
                .table, .func => true,
                .subquery => |q| sorted or scrollable(q),
                else => false,
            };
        },
    };
}

/// Whether a condition has IN (SELECT ...) or EXISTS (a semi-join).
fn semiJoin(e: *const Expr) bool {
    return switch (e.kind) {
        .in_select, .exists => true,
        .binary => |x| semiJoin(x.l) or semiJoin(x.r),
        .unary => |x| semiJoin(x.e),
        else => false,
    };
}

/// Whether `e` has a call of an aggregate or window function (outside
/// subqueries).
fn aggregate(e: *const Expr) bool {
    switch (e.kind) {
        .func => |f| {
            if (f.over != null or f.star or f.distinct or f.order_by.len > 0 or f.filter != null) return true;
            const names = [_][]const u8{ "count", "sum", "avg", "min", "max", "total", "group_concat", "string_agg", "array_agg", "bool_and", "bool_or", "every", "json_agg", "jsonb_agg", "json_object_agg", "jsonb_object_agg", "json_group_array", "json_group_object", "stddev", "stddev_pop", "stddev_samp", "variance", "var_pop", "var_samp" };
            for (names) |n| if (std.ascii.eqlIgnoreCase(f.name.text, n) and f.args.len > 0) {
                // max(a, b) and min(a, b) are scalar.
                if ((eql(n, "max") or eql(n, "min")) and f.args.len > 1) continue;
                return true;
            };
            for (f.args) |x| if (aggregate(x)) return true;
            return false;
        },
        .unary => |x| return aggregate(x.e),
        .binary => |x| return aggregate(x.l) or aggregate(x.r),
        .div => |x| return aggregate(x.l) or aggregate(x.r),
        .compare => |x| return aggregate(x.l) or aggregate(x.r),
        .cast => |x| return aggregate(x.e),
        .collate => |x| return aggregate(x.e),
        .concat => |x| {
            for (x.args) |y| if (aggregate(y)) return true;
            return false;
        },
        .case => |x| {
            if (x.operand) |o| if (aggregate(o)) return true;
            for (x.whens) |y| if (aggregate(y)) return true;
            if (x.@"else") |y| if (aggregate(y)) return true;
            return false;
        },
        else => return false,
    }
}

fn tableKey(a: std.mem.Allocator, q: tree.QName) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{f}.{f}", .{ dialect.Quoted('"'){ .z = if (q.schema) |s| s.text else "main" }, dialect.Quoted('"'){ .z = q.name.text } });
}

const FetchArgs = struct { dir: Direction, count: i64, name: Name };

/// FETCH or MOVE: [direction] [FROM | IN] name.
fn fetchArgs(ps: *Parser) Error!FetchArgs {
    var r: FetchArgs = .{ .dir = .forward, .count = 1, .name = undefined };
    const t = ps.c.peek();
    const has_more = ps.c.peekAt(1).kind != .eof;
    if (t.kind == .integer or (t.kind == .op and eql(ps.val(t), "-"))) {
        r.count = try ps.signedInt();
    } else if (has_more and t.kind == .word) {
        const w = ps.val(t);
        if (eql(w, "next")) {
            ps.c.skip();
        } else if (eql(w, "prior")) {
            ps.c.skip();
            r.dir = .backward;
        } else if (eql(w, "first")) {
            ps.c.skip();
            r.dir = .absolute;
        } else if (eql(w, "last")) {
            ps.c.skip();
            r.dir = .absolute;
            r.count = -1;
        } else if (eql(w, "absolute") or eql(w, "relative")) {
            ps.c.skip();
            r.dir = if (eql(w, "absolute")) .absolute else .relative;
            r.count = try ps.signedInt();
        } else if (eql(w, "all")) {
            ps.c.skip();
            r.count = fetch_all;
        } else if (eql(w, "forward") or eql(w, "backward")) {
            ps.c.skip();
            r.dir = if (eql(w, "forward")) .forward else .backward;
            const n = ps.c.peek();
            if (ps.c.peekAt(1).kind != .eof and (n.kind == .integer or (n.kind == .op and eql(ps.val(n), "-")))) {
                r.count = try ps.signedInt();
            } else if (ps.c.peekAt(1).kind != .eof and isWord(ps, n, "all")) {
                ps.c.skip();
                r.count = fetch_all;
            }
        }
    }
    _ = eatWord(ps, "from") or eatWord(ps, "in");
    r.name = try ps.colId();
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    return r;
}

fn notExist(ps: *Parser, name: []const u8) Error {
    return ps.c.failState(null, .of("34000"), "cursor \"{s}\" does not exist", .{name});
}

/// FETCH: the cursor's columns over the rows xq_pg_cursor_fetch() moves
/// over when the statement runs; MOVE: no row, the rows moved over its
/// changes.
fn fetchStmt(ps: *Parser, move: bool) Error!void {
    const a = ps.arena;
    ps.c.skip(); // FETCH, MOVE
    const f = try fetchArgs(ps);
    const p = ps.p.?;
    if (move) {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "SELECT 1 WHERE xq_pg_cursor_move(");
        try literal(&text, a, f.name.text);
        try text.print(a, ", {d}, {d}) IS NULL", .{ @backingInt(f.dir), f.count });
        try lowerPg(ps, try a.dupeSentinel(u8, text.items, 0));
        if (p.vdbe) |v| @import("../../vdbe/aux.zig").countChanges(v);
        return;
    }
    const c = (if (cursorsOf(p.db)) |s| s.find(f.name.text) else null) orelse return notExist(ps, f.name.text);
    const pos: u32 = 0;
    const name_lit = try tree.expr(a, pos, pos, .{ .string = f.name.text });
    // json_each(xq_pg_cursor_fetch(name, dir, count, ncols)) AS j
    const fetch_call = try tree.new(a, tree.Func, .{
        .name = .{ .text = "xq_pg_cursor_fetch" },
        .dialect = .postgres,
        .args = try list(a, &.{
            name_lit,
            try tree.intConst(a, pos, @backingInt(f.dir)),
            try tree.intConst(a, pos, f.count),
            try tree.intConst(a, pos, @intCast(c.ncols())),
        }),
    });
    const each = try tree.new(a, tree.Func, .{ .name = .{ .text = "json_each" }, .args = try list(a, &.{try tree.expr(a, pos, pos, .{ .func = fetch_call })}) });
    const from = try a.alloc(tree.FromItem, 1);
    from[0] = .{ .source = .{ .func = each }, .alias = .{ .name = .{ .text = "j" } } };
    const value_ref = try a.alloc(Name, 2);
    value_ref[0] = .{ .text = "j" };
    value_ref[1] = .{ .text = "value" };
    const cols = try a.alloc(tree.ResultCol, c.ncols());
    for (cols, 0..) |*rc, i| {
        const call = try tree.new(a, tree.Func, .{
            .name = .{ .text = "xq_pg_cursor_value" },
            .dialect = .postgres,
            .args = try list(a, &.{ name_lit, try tree.expr(a, pos, pos, .{ .column = value_ref }), try tree.intConst(a, pos, @intCast(i)) }),
            .result_type_id = c.types[i],
        });
        rc.* = .{ .expr = .{ .e = try tree.expr(a, pos, pos, .{ .func = call }), .alias = .{ .text = try a.dupe(u8, c.names[i]) } } };
    }
    const body = try tree.new(a, tree.Body, .{ .core = try tree.new(a, tree.Core, .{ .cols = cols, .from = from }) });
    const sel = try tree.new(a, tree.Select, .{ .body = body });
    var l: lower.Lowerer = .init(p, ps.c.sql);
    try l.statement(.{ .select = sel });
}

fn list(a: std.mem.Allocator, items: []const *Expr) error{OutOfMemory}![]*Expr {
    return a.dupe(*Expr, items);
}

/// CLOSE name | ALL.
fn close(ps: *Parser) Error!void {
    const a = ps.arena;
    ps.c.skip(); // CLOSE
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "SELECT 1 WHERE xq_pg_cursor_close(");
    if (eatWord(ps, "all")) {
        try text.appendSlice(a, "NULL");
    } else try literal(&text, a, (try ps.colId()).text);
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    try text.appendSlice(a, ") IS NULL");
    try lowerPg(ps, try a.dupeSentinel(u8, text.items, 0));
}

/// WHERE CURRENT OF name of an UPDATE or DELETE of `table` (after WHERE):
/// `rowid = xq_pg_cursor_rowid(name, table, bare name)`.
pub fn currentOf(ps: *Parser, table: tree.QName, alias: ?Name) parser.Error!*Expr {
    const a = ps.arena;
    const pos = ps.c.peek().start;
    ps.c.skipN(2); // CURRENT OF
    const name = try ps.colId();
    const rowid = try a.alloc(Name, if (alias != null) 2 else 1);
    if (alias) |al| {
        rowid[0] = al;
        rowid[1] = .{ .text = "rowid", .pos = pos };
    } else rowid[0] = .{ .text = "rowid", .pos = pos };
    const bare = if (std.mem.lastIndexOfScalar(u8, table.name.text, '.')) |i| table.name.text[i + 1 ..] else table.name.text;
    const call = try tree.new(a, tree.Func, .{
        .name = .{ .text = "xq_pg_cursor_rowid", .pos = pos },
        .dialect = .postgres,
        .args = try list(a, &.{
            try tree.expr(a, pos, pos, .{ .string = name.text }),
            try tree.expr(a, pos, pos, .{ .string = try tableKey(a, table) }),
            try tree.expr(a, pos, pos, .{ .string = bare }),
        }),
    });
    return tree.expr(a, pos, pos, .{ .compare = .{
        .op = .eq,
        .l = try tree.expr(a, pos, pos, .{ .column = rowid }),
        .r = try tree.expr(a, pos, pos, .{ .func = call }),
    } });
}

// ============================================================== functions

pub const functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_cursor_declare", -1, .{ .unsafe = true, .direct_only = true }, declareFunc),
    dfunc.scalar("xq_pg_cursor_fetch", 4, .{ .unsafe = true, .direct_only = true }, fetchFunc),
    dfunc.scalar("xq_pg_cursor_move", 3, .{ .unsafe = true, .direct_only = true }, moveFunc),
    dfunc.scalar("xq_pg_cursor_value", 3, .{ .unsafe = true, .direct_only = true }, valueFunc),
    dfunc.scalar("xq_pg_cursor_close", 1, .{ .unsafe = true, .direct_only = true }, closeFunc),
    dfunc.scalar("xq_pg_cursor_rowid", 3, .{ .unsafe = true, .direct_only = true }, rowidFunc),
    dfunc.scalar("xq_pg_cursors", 0, .{ .unsafe = true, .direct_only = true }, cursorsFunc),
};

fn missing(ctx: *Context, name: []const u8) void {
    var buf: [200]u8 = undefined;
    api.resultErrorState(ctx, .of("34000"), std.fmt.bufPrint(&buf, "cursor \"{s}\" does not exist", .{name[0..@min(name.len, 100)]}) catch "cursor does not exist");
}

fn noScroll(ctx: *Context) void {
    api.resultErrorFields(ctx, .of("55000"), .{ .message = "cursor can only scan forward", .hint = "Declare it with SCROLL option to enable backward scan." });
}

fn findArg(ctx: *Context, arg: *Mem) ?*Cursor {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(arg) orelse "";
    if (cursorsOf(db)) |s| if (s.find(name)) |c| return c;
    missing(ctx, name);
    return null;
}

/// xq_pg_cursor_declare(name, flags, query, statement, table, params...):
/// run the query, keep its rows as cursor `name`.
fn declareFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const gpa = db.gpa;
    if (argv.len < 5) return api.resultError(ctx, "xq_pg_cursor_declare: arguments");
    const name = api.valueText(argv[0]) orelse return api.resultErrorNomem(ctx);
    const flags: u32 = @truncate(@as(u64, @bitCast(api.valueInt64(argv[1]))));
    const query = api.valueText(argv[2]) orelse return api.resultErrorNomem(ctx);
    const stmt_text = api.valueText(argv[3]) orelse "";
    const table = api.valueText(argv[4]) orelse "";
    const hold = flags & flag_hold != 0;
    const in_tx = !main_mod.getAutocommit(db);
    if (!hold and !in_tx) return api.resultErrorState(ctx, .of("25P01"), "DECLARE CURSOR can only be used in transaction blocks");
    const s = cursorsFor(db) catch return api.resultErrorNomem(ctx);
    if (s.find(name) != null) {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("42P03"), std.fmt.bufPrint(&buf, "cursor \"{s}\" already exists", .{name[0..@min(name.len, 100)]}) catch "cursor already exists");
    }
    const c = materialize(ctx, db, query, argv[5..], flags & flag_rowid != 0) orelse return;
    c.hold = hold;
    c.no_scroll = flags & flag_no_scroll != 0;
    c.in_tx = in_tx;
    c.depth = savepoints(db);
    c.created = (api.stmtCurrentTime(ctx) - 210866760000000) * 1000;
    (blk: {
        c.name = gpa.dupe(u8, name) catch |e| break :blk e;
        c.statement = gpa.dupe(u8, stmt_text) catch |e| break :blk e;
        if (c.rowids.len > 0 or flags & flag_rowid != 0) c.table = gpa.dupe(u8, table) catch |e| break :blk e;
        s.list.append(gpa, c) catch |e| break :blk e;
    }) catch {
        c.destroy(gpa);
        return api.resultErrorNomem(ctx);
    };
    api.resultInt64(ctx, 0);
}

/// Run `query` (its parameters `params`), its rows a new cursor (null
/// with the error the result); with `rowid`, its last column is the
/// rowid of the row.
fn materialize(ctx: *Context, db: *int.Sqlite3, query: []const u8, params: []*Mem, rowid: bool) ?*Cursor {
    const gpa = db.gpa;
    var v: ?*vi.Vdbe = null;
    const rc = prepare.prepareLang(db, query, .of(.postgres), 0, &v, null);
    const stmt = v orelse {
        if (rc == RC.NOMEM or rc == RC.OK) return failNomem(ctx);
        api.resultErrorState(ctx, db.err_state orelse .of("XX000"), main_mod.errmsg(db));
        return null;
    };
    defer _ = api.finalize(stmt);
    for (params, 1..) |m, i| {
        if (i > api.bindParameterCount(stmt)) break;
        if (api.bindValue(stmt, i, m) != RC.OK) return failNomem(ctx);
    }
    const all = api.columnCount(stmt);
    const n = if (rowid and all > 0) all - 1 else all;
    const c = gpa.create(Cursor) catch return failNomem(ctx);
    c.* = .{ .name = &.{}, .statement = &.{}, .hold = false, .no_scroll = false, .in_tx = false, .created = 0, .names = &.{}, .types = &.{}, .values = &.{}, .nrows = 0 };
    fill(c, db, stmt, n, rowid and all > 0) catch |err| {
        c.destroy(gpa);
        if (err == error.OutOfMemory) return failNomem(ctx);
        api.resultErrorState(ctx, db.err_state orelse .of("XX000"), main_mod.errmsg(db));
        return null;
    };
    return c;
}

/// Fill cursor `c` with the names, types and rows of `stmt`: `n`
/// columns, and the rowid after them if `with_rowid`.
fn fill(c: *Cursor, db: *int.Sqlite3, stmt: *vi.Vdbe, n: usize, with_rowid: bool) error{ OutOfMemory, StepFailed }!void {
    const gpa = db.gpa;
    c.names = try gpa.alloc([]u8, n);
    for (c.names) |*x| x.* = &.{};
    c.types = try gpa.alloc(typing.TypeId, n);
    for (0..n) |i| {
        c.names[i] = try gpa.dupe(u8, api.columnName(stmt, i) orelse "?column?");
        c.types[i] = try columnType(db, stmt, i);
    }
    var values: std.ArrayList(*Mem) = .empty;
    errdefer {
        for (values.items) |x| api.valueFree(x);
        values.deinit(gpa);
    }
    var rowids: std.ArrayList(i64) = .empty;
    errdefer rowids.deinit(gpa);
    while (true) {
        const r = api.step(stmt);
        if (r == RC.DONE) break;
        if (r != RC.ROW) return if (r == RC.NOMEM) error.OutOfMemory else error.StepFailed;
        const row = try rows_mod.copyRow(gpa, stmt, 0, n);
        defer gpa.free(row);
        values.appendSlice(gpa, row) catch |e| {
            for (row) |x| api.valueFree(x);
            return e;
        };
        if (with_rowid) try rowids.append(gpa, api.columnInt64(stmt, n));
        c.nrows += 1;
    }
    c.values = try values.toOwnedSlice(gpa);
    c.rowids = try rowids.toOwnedSlice(gpa);
}

fn failNomem(ctx: *Context) ?*Cursor {
    api.resultErrorNomem(ctx);
    return null;
}

/// The type of result column `i` of `v`, as the connection interns it:
/// the type the statement knows under its declared spelling, else the
/// declared type read.
fn columnType(db: *int.Sqlite3, v: *vi.Vdbe, i: usize) error{OutOfMemory}!typing.TypeId {
    const decl: []const u8 = api.columnDecltype(v, i) orelse "";
    if (i < v.xq_col_types.len and v.xq_col_types[i].logical != .unknown) {
        return db.xq.types.addType(db.gpa, .postgres, v.xq_col_types[i], decl);
    }
    return typing.intern(db, .postgres, decl);
}

/// xq_pg_cursor_fetch(name, direction, count, ncols): move the cursor,
/// return the rows passed (1-based) as a JSON array.
fn fetchFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const c = findArg(ctx, argv[0]) orelse return;
    if (@as(i64, @intCast(c.ncols())) != api.valueInt64(argv[3])) {
        return api.resultErrorState(ctx, .of("0A000"), "cached plan must not change result type");
    }
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(db.gpa);
    _ = c.fetch(direction(argv[1]), api.valueInt64(argv[2]), &rows, db.gpa) catch |err| switch (err) {
        error.NoScroll => return noScroll(ctx),
        error.OutOfMemory => return api.resultErrorNomem(ctx),
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(db.gpa);
    (blk: {
        out.append(db.gpa, '[') catch |e| break :blk e;
        for (rows.items, 0..) |r, i| out.print(db.gpa, "{s}{d}", .{ if (i > 0) "," else "", r }) catch |e| break :blk e;
        out.append(db.gpa, ']') catch |e| break :blk e;
    }) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
}

fn direction(m: *Mem) Direction {
    const d = api.valueInt64(m);
    return if (d >= 0 and d <= 3) @fromBackingInt(@intCast(d)) else .forward;
}

/// xq_pg_cursor_move(name, direction, count): move the cursor; the rows
/// moved over are the statement's changes.
fn moveFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const c = findArg(ctx, argv[0]) orelse return;
    const n = c.fetch(direction(argv[1]), api.valueInt64(argv[2]), null, db.gpa) catch |err| switch (err) {
        error.NoScroll => return noScroll(ctx),
        error.OutOfMemory => return api.resultErrorNomem(ctx),
    };
    // The statement's changes (a statement that reads no table leaves
    // db.n_change as it is when it halts).
    const moved: i64 = @intCast(@min(n, std.math.maxInt(i64)));
    if (ctx.vdbe) |v| v.n_change = moved;
    @import("../../vdbe/aux.zig").setChanges(db, moved);
    api.resultInt64(ctx, moved);
}

/// xq_pg_cursor_value(name, row, i): column i of row `row` (1-based).
fn valueFunc(ctx: *Context, argv: []*Mem) void {
    const c = findArg(ctx, argv[0]) orelse return;
    const row = api.valueInt64(argv[1]);
    const col = api.valueInt64(argv[2]);
    if (row < 1 or row > c.nrows or col < 0 or col >= c.ncols()) return api.resultNull(ctx);
    api.resultValue(ctx, c.value(@intCast(row - 1), @intCast(col)));
}

/// xq_pg_cursor_close(name): close it; NULL: every cursor.
fn closeFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_NULL) {
        closeAll(db);
        return api.resultInt64(ctx, 0);
    }
    const c = findArg(ctx, argv[0]) orelse return;
    cursorsOf(db).?.remove(db.gpa, c);
    api.resultInt64(ctx, 0);
}

/// xq_pg_cursor_rowid(name, table, bare name): the rowid of the row the
/// cursor is on (WHERE CURRENT OF), of `table`.
fn rowidFunc(ctx: *Context, argv: []*Mem) void {
    const c = findArg(ctx, argv[0]) orelse return;
    const table = api.valueText(argv[1]) orelse "";
    const bare = api.valueText(argv[2]) orelse "";
    var buf: [300]u8 = undefined;
    if (c.rowids.len != c.nrows or c.table.len == 0 or !eql(c.table, table)) {
        return api.resultErrorState(ctx, .of("24000"), std.fmt.bufPrint(&buf, "cursor \"{s}\" is not a simply updatable scan of table \"{s}\"", .{ c.name[0..@min(c.name.len, 100)], bare[0..@min(bare.len, 100)] }) catch "cursor is not a simply updatable scan");
    }
    if (!c.onRow() or c.pos < 1 or c.pos > c.nrows) {
        return api.resultErrorState(ctx, .of("24000"), std.fmt.bufPrint(&buf, "cursor \"{s}\" is not positioned on a row", .{c.name[0..@min(c.name.len, 100)]}) catch "cursor is not positioned on a row");
    }
    api.resultInt64(ctx, c.rowids[c.pos - 1]);
}

/// xq_pg_cursors(): the session's cursors as a JSON array of objects
/// (pg_cursors' columns).
fn cursorsFunc(ctx: *Context, _: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(db.gpa);
    writeCursors(db, &out) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
}

fn writeCursors(db: *int.Sqlite3, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
    const gpa = db.gpa;
    try out.append(gpa, '[');
    if (cursorsOf(db)) |s| for (s.list.items, 0..) |c, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"name\":");
        try jsonString(gpa, out, c.name);
        try out.appendSlice(gpa, ",\"statement\":");
        try jsonString(gpa, out, c.statement);
        try out.print(gpa, ",\"is_holdable\":{},\"is_binary\":false,\"is_scrollable\":{},\"creation_time\":\"", .{ c.hold, !c.no_scroll });
        try timestamp(gpa, out, c.created);
        try out.appendSlice(gpa, "+00\"}");
    };
    try out.append(gpa, ']');
}

fn jsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), z: []const u8) error{OutOfMemory}!void {
    try out.append(gpa, '"');
    for (z) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...0x1f => try out.print(gpa, "\\u{x:0>4}", .{ch}),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

/// `us` microseconds since 1970 as 'YYYY-MM-DD HH:MM:SS.ffffff' (UTC).
fn timestamp(gpa: std.mem.Allocator, out: *std.ArrayList(u8), us: i64) error{OutOfMemory}!void {
    const secs: u64 = @intCast(@max(@divFloor(us, 1_000_000), 0));
    const frac: u64 = @intCast(@mod(us, 1_000_000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try out.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), frac,
    });
}

// ================================================================== tests

const testing = std.testing;
const Conn = @import("../../sql/sql_test.zig").Conn;

fn openPg(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .postgres);
}

test "pg: cursors" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE t (a int, b text);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, NULL);
    );
    try c.expectError("DECLARE c CURSOR FOR SELECT * FROM t", "DECLARE CURSOR can only be used in transaction blocks");
    try c.expectError("FETCH c", "cursor \"c\" does not exist");
    try c.expectError("CLOSE c", "cursor \"c\" does not exist");
    try c.expectError("MOVE c", "cursor \"c\" does not exist");
    try c.exec("BEGIN");
    try c.exec("DECLARE c SCROLL CURSOR FOR SELECT * FROM t ORDER BY a");
    try c.expectError("DECLARE c CURSOR FOR SELECT 1", "cursor \"c\" already exists");
    try c.expectColumns("FETCH c", "a|b");
    try c.expectRows("FETCH 0 c", "");
    try c.expectRows("FETCH c", "1|x\n");
    try c.expectRows("FETCH 0 c", "1|x\n");
    try c.expectRows("FETCH NEXT FROM c", "2|y\n");
    try c.expectRows("FETCH ALL IN c", "3|NULL\n");
    try c.expectRows("FETCH c", "");
    try c.expectRows("FETCH BACKWARD 2 c", "3|NULL\n2|y\n");
    try c.expectRows("FETCH PRIOR c", "1|x\n");
    try c.expectRows("FETCH PRIOR c", "");
    try c.expectRows("FETCH LAST c", "3|NULL\n");
    try c.expectRows("FETCH FIRST c", "1|x\n");
    try c.expectRows("FETCH ABSOLUTE -2 c", "2|y\n");
    try c.expectRows("FETCH RELATIVE 1 c", "3|NULL\n");
    try c.expectRows("FETCH RELATIVE 0 c", "3|NULL\n");
    try c.expectRows("FETCH ABSOLUTE 9 c", "");
    try c.expectRows("FETCH -1 c", "3|NULL\n");
    try c.expectRows("FETCH FORWARD -1 c", "2|y\n");
    // MOVE: no row; the rows moved over are its changes.
    try c.expectRows("MOVE ALL c", "");
    try testing.expectEqual(@as(i64, 1), api.changes(c.db));
    try c.expectRows("MOVE BACKWARD ALL c", "");
    try testing.expectEqual(@as(i64, 3), api.changes(c.db));
    // A FETCH prepared once moves the cursor each time it runs.
    {
        var v: ?*vi.Vdbe = null;
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "FETCH c", &v, null));
        defer _ = api.finalize(v.?);
        for (1..4) |i| {
            try testing.expectEqual(RC.ROW, api.step(v.?));
            try testing.expectEqual(@as(i64, @intCast(i)), api.columnInt64(v.?, 0));
            try testing.expectEqual(RC.DONE, api.step(v.?));
            _ = api.reset(v.?);
        }
    }
    try c.exec("DECLARE ns NO SCROLL CURSOR FOR VALUES (1), (2)");
    try c.expectRows("FETCH ns", "1\n");
    try c.expectError("FETCH PRIOR ns", "cursor can only scan forward\nHINT:  Declare it with SCROLL option to enable backward scan.");
    try c.expectRows("SELECT name, is_holdable, is_scrollable FROM pg_cursors ORDER BY name", "c|0|1\nns|0|0\n");
    try c.exec("CLOSE ns");
    try c.expectRows("SELECT name FROM pg_cursors", "c\n");
    try c.exec("DECLARE h CURSOR WITH HOLD FOR SELECT a FROM t ORDER BY a");
    try c.exec("COMMIT");
    // COMMIT closed c; h stays, where it was.
    try c.expectError("FETCH c", "cursor \"c\" does not exist");
    try c.expectRows("FETCH h", "1\n");
    try c.exec("BEGIN");
    try c.exec("DECLARE h2 CURSOR WITH HOLD FOR SELECT 1");
    try c.exec("ROLLBACK");
    try c.expectRows("SELECT name FROM pg_cursors", "h\n");
    try c.exec("CLOSE ALL");
    try c.expectRows("SELECT count(*) FROM pg_cursors", "0\n");
    try c.expectError("BEGIN; DECLARE x SCROLL NO SCROLL CURSOR FOR SELECT 1", "cannot specify both SCROLL and NO SCROLL");
    try c.exec("ROLLBACK");
}

test "pg: WHERE CURRENT OF" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE t (a int, b text);
        \\INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'z');
        \\BEGIN;
        \\DECLARE c CURSOR FOR SELECT a FROM t WHERE a > 1;
    );
    try c.expectError("UPDATE t SET b = 'w' WHERE CURRENT OF c", "cursor \"c\" is not positioned on a row");
    try c.expectRows("FETCH c", "2\n");
    try c.exec("UPDATE t SET b = 'w' WHERE CURRENT OF c");
    try c.expectRows("FETCH c", "3\n");
    try c.exec("DELETE FROM t WHERE CURRENT OF c");
    try c.expectRows("SELECT a, b FROM t ORDER BY a", "1|x\n2|w\n");
    try c.exec("DECLARE s CURSOR FOR SELECT a FROM t ORDER BY a");
    try c.expectRows("FETCH s", "1\n");
    try c.expectError("UPDATE t SET b = 'q' WHERE CURRENT OF s", "cursor \"s\" is not a simply updatable scan of table \"t\"");
    try c.exec("ROLLBACK");
}
