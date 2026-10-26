//! End-to-end tests of the query planner: the plans it chooses (as
//! EXPLAIN QUERY PLAN shows them, checked against sqlite3 3.54.1) and the
//! results of the loops it codes.

const std = @import("std");
const testing = std.testing;
const legacy = @import("legacy.zig");
const RC = @import("sqlite_int.zig").RC;
const Conn = @import("sql_test.zig").Conn;

/// The detail column of `EXPLAIN QUERY PLAN sql`, a line per row, indented
/// two spaces per level as sqlite3's tree.
fn expectPlan(c: *Conn, sql: []const u8, expected: []const u8) !void {
    const Ctx = struct {
        out: std.ArrayList(u8) = .empty,
        ids: [32]i64 = undefined,
        n: usize = 0,

        fn row(ctx: ?*anyopaque, values: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const id = std.fmt.parseInt(i64, std.mem.span(values[0].?), 10) catch return true;
            const parent = std.fmt.parseInt(i64, std.mem.span(values[1].?), 10) catch return true;
            // The depth is the position of the parent among the open rows.
            while (self.n > 0 and self.ids[self.n - 1] != parent) self.n -= 1;
            self.out.appendNTimes(testing.allocator, ' ', 2 * self.n) catch return true;
            self.out.appendSlice(testing.allocator, std.mem.span(values[3].?)) catch return true;
            self.out.append(testing.allocator, '\n') catch return true;
            if (self.n < self.ids.len) {
                self.ids[self.n] = id;
                self.n += 1;
            }
            return false;
        }
    };
    var ctx: Ctx = .{};
    defer ctx.out.deinit(testing.allocator);
    const q = try std.fmt.allocPrint(testing.allocator, "EXPLAIN QUERY PLAN {s}", .{sql});
    defer testing.allocator.free(q);
    var msg: ?[:0]u8 = null;
    const rc = legacy.exec(c.db, q, Ctx.row, &ctx, &msg);
    if (msg) |m| testing.allocator.free(m);
    try testing.expectEqual(RC.OK, rc);
    testing.expectEqualStrings(expected, ctx.out.items) catch |err| {
        std.debug.print("query: {s}\n", .{sql});
        return err;
    };
}

const schema =
    \\CREATE TABLE t1(a INTEGER PRIMARY KEY, b, c, d TEXT);
    \\CREATE INDEX t1b ON t1(b);
    \\CREATE INDEX t1cd ON t1(c, d);
    \\CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT);
    \\CREATE TABLE q(id INTEGER PRIMARY KEY, pid INTEGER, v);
    \\CREATE INDEX qpid ON q(pid);
    \\CREATE TABLE r(x, y);
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300)
    \\  INSERT INTO t1 SELECT i, i%17, i%5, 'v'||i FROM n;
    \\INSERT INTO p VALUES(1,'one'),(2,'two'),(3,'three');
    \\INSERT INTO q VALUES(1,1,10),(2,1,20),(3,3,30),(4,9,40);
    \\INSERT INTO r VALUES(1,'a'),(3,'b'),(7,'c');
;

test "where: access paths" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    try expectPlan(&c, "SELECT * FROM t1 WHERE a=5", "SEARCH t1 USING INTEGER PRIMARY KEY (rowid=?)\n");
    try expectPlan(&c, "SELECT * FROM t1 WHERE a>10 AND a<20", "SEARCH t1 USING INTEGER PRIMARY KEY (rowid>? AND rowid<?)\n");
    try expectPlan(&c, "SELECT * FROM t1 WHERE b=3", "SEARCH t1 USING INDEX t1b (b=?)\n");
    try expectPlan(&c, "SELECT a FROM t1 WHERE b=3", "SEARCH t1 USING COVERING INDEX t1b (b=?)\n");
    try expectPlan(&c, "SELECT * FROM t1 WHERE c=2 AND d>'v2'", "SEARCH t1 USING INDEX t1cd (c=? AND d>?)\n");
    try expectPlan(&c, "SELECT * FROM t1 WHERE c=2 ORDER BY d", "SEARCH t1 USING INDEX t1cd (c=?)\n");
    try expectPlan(&c, "SELECT * FROM t1 WHERE b IN (1,2,3)", "SEARCH t1 USING INDEX t1b (b=?)\n");
    try expectPlan(&c, "SELECT * FROM t1 WHERE b=1 OR c=3",
        \\MULTI-INDEX OR
        \\  INDEX 1
        \\    SEARCH t1 USING INDEX t1b (b=?)
        \\  INDEX 2
        \\    SEARCH t1 USING INDEX t1cd (c=?)
        \\
    );
    try expectPlan(&c, "SELECT max(b) FROM t1", "SEARCH t1 USING COVERING INDEX t1b\n");
    try expectPlan(&c, "SELECT * FROM t1 NOT INDEXED WHERE b=3", "SCAN t1\n");
    try expectPlan(&c, "SELECT * FROM t1 ORDER BY b", "SCAN t1 USING INDEX t1b\n");
    try c.expectRows("SELECT a FROM t1 WHERE b=3 AND c=3", "3\n88\n173\n258\n");
    try c.expectRows("SELECT count(*) FROM t1 WHERE b=1 OR c=3", "74\n");
    try c.expectRows("SELECT a FROM t1 WHERE c=2 ORDER BY d DESC LIMIT 2", "97\n92\n");
}

test "where: joins" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    try expectPlan(&c, "SELECT * FROM p JOIN q ON p.id=q.pid",
        \\SCAN q
        \\SEARCH p USING INTEGER PRIMARY KEY (rowid=?)
        \\
    );
    try expectPlan(&c, "SELECT * FROM r, p WHERE r.x=p.id",
        \\SCAN r
        \\SEARCH p USING INTEGER PRIMARY KEY (rowid=?)
        \\
    );
    try c.expectRows("SELECT p.name, q.v FROM p JOIN q ON p.id=q.pid ORDER BY q.v", "one|10\none|20\nthree|30\n");
    try c.expectRows("SELECT p.id, q.id FROM p LEFT JOIN q ON q.pid=p.id ORDER BY 1, 2", "1|1\n1|2\n2|NULL\n3|3\n");
    try c.expectRows("SELECT p.id, r.y FROM p RIGHT JOIN r ON r.x=p.id ORDER BY r.y", "1|a\n3|b\nNULL|c\n");
    try c.expectRows("SELECT p.id, r.y FROM p FULL JOIN r ON r.x=p.id ORDER BY 1, 2", "NULL|c\n1|a\n2|NULL\n3|b\n");
    try c.expectRows("SELECT name FROM p WHERE id NOT IN (SELECT pid FROM q)", "two\n");
}

test "where: one-pass DELETE and UPDATE through an index" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    try c.exec("DELETE FROM t1 WHERE b=4");
    try c.exec("UPDATE t1 SET b=b+1 WHERE b=3");
    try c.exec("UPDATE t1 SET c=-1 WHERE a IN (1,2,3)");
    try c.expectRows("SELECT count(*), sum(b=4), sum(b=3) FROM t1", "282|18|0\n");
    try c.expectRows("SELECT a, c FROM t1 WHERE c<0", "1|-1\n2|-1\n3|-1\n");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
}

test "where: expression and partial indexes" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE e(a, b, c);
        \\CREATE INDEX epart ON e(b) WHERE c IS NOT NULL;
        \\CREATE INDEX eexpr ON e(a+b);
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<200)
        \\  INSERT INTO e SELECT i, i%7, CASE WHEN i%3 THEN 'C'||i END FROM n;
    );
    try expectPlan(&c, "SELECT * FROM e WHERE a+b=10", "SEARCH e USING INDEX eexpr (<expr>=?)\n");
    try expectPlan(&c, "SELECT * FROM e WHERE b=2 AND c IS NOT NULL", "SEARCH e USING INDEX epart (b=?)\n");
    try c.expectRows("SELECT a FROM e WHERE a+b=10", "5\n");
    try c.expectRows("SELECT a+b FROM e ORDER BY a+b LIMIT 3", "2\n4\n6\n");
    try c.expectRows("SELECT count(*) FROM e WHERE b=2 AND c IS NOT NULL", "19\n");
}
