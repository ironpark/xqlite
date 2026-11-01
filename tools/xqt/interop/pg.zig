//! The PostgreSQL dialect against sqlite3: a database written by
//! `xqlite sql` in the PostgreSQL dialect (STRICT tables, CHECKs, identity
//! sequences, the xq_catalog/xq_sequence catalog, views, indexes) must pass
//! sqlite3's integrity check, and sqlite3 and xqlite (in the SQLite
//! dialect) must read the same rows and schema from it.
//! (Was tools/interop-pg.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;
const BaseDb = @import("base_db.zig");

pub const name = "pg";
pub const about = "a PostgreSQL-dialect database read by sqlite3: integrity, rows, STRICT types";

pub fn register(s: *xqt.Suite) !void {
    const base = try s.arena.allocator().create(BaseDb);
    base.* = .{ .build = build };
    try s.add("integrity_check and foreign_key_check", integrity, .{base});
    try s.add("results", results, .{base});
    for (bad) |stmt| try s.add(try std.fmt.allocPrint(s.arena.allocator(), "sqlite3 rejects: {s}", .{stmt}), rejects, .{ base, stmt });
    try s.add("read back", readBack, .{base});
    try s.add("schema tables", schemaTables, .{base});
    try s.add("json and jsonb columns", jsonColumns, .{base});
}

const db = "pg.db";

const script =
    \\.dialect postgres
    \\CREATE TABLE account (
    \\  id bigserial PRIMARY KEY,
    \\  email varchar(80) NOT NULL UNIQUE,
    \\  active boolean NOT NULL DEFAULT true,
    \\  balance numeric(12,2) DEFAULT 0 CHECK (balance >= 0),
    \\  created_at timestamptz DEFAULT now(),
    \\  meta jsonb
    \\);
    \\CREATE TABLE entry (
    \\  id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    \\  account_id bigint REFERENCES account (id) ON DELETE CASCADE,
    \\  amount int NOT NULL,
    \\  memo text COLLATE "C"
    \\);
    \\CREATE INDEX ON entry (account_id, amount DESC);
    \\CREATE UNIQUE INDEX account_lower_email ON account (lower(email));
    \\CREATE SEQUENCE ticket START WITH 100 INCREMENT BY 10;
    \\INSERT INTO account (email, balance, meta) SELECT 'user' || n || '@example.com', n * 1.5, '{"n": ' || n || '}' FROM generate_series(1, 300) AS g(n);
    \\INSERT INTO entry (account_id, amount, memo) SELECT 1 + n % 300, n, 'm' || n FROM generate_series(1, 2000) AS g(n);
    \\UPDATE account SET active = false WHERE id % 7 = 0 RETURNING id;
    \\DELETE FROM entry e USING account a WHERE a.id = e.account_id AND NOT a.active;
    \\INSERT INTO account (email) VALUES ('user1@example.com') ON CONFLICT (email) DO UPDATE SET balance = account.balance + 1;
    \\CREATE VIEW totals AS SELECT a.email, count(e.id) AS n, sum(e.amount) AS total FROM account a LEFT JOIN entry e ON e.account_id = a.id GROUP BY a.email ORDER BY total DESC NULLS LAST;
    \\SELECT nextval('ticket'), nextval('ticket');
    \\ALTER TABLE entry ADD COLUMN tag varchar(8);
    \\CREATE TABLE gone (x int); DROP TABLE gone;
    \\CREATE SCHEMA sales;
    \\CREATE TABLE sales.orders (id serial PRIMARY KEY, account_id bigint, amount int CHECK (amount > 0));
    \\CREATE INDEX ON sales.orders (account_id);
    \\INSERT INTO sales.orders (account_id, amount) SELECT n, n * 2 FROM generate_series(1, 50) AS g(n);
    \\CREATE VIEW sales.big AS SELECT o.id, o.amount FROM sales.orders o WHERE o.amount > 50;
    \\CREATE SCHEMA tmp; CREATE TABLE tmp.x (a int); DROP SCHEMA tmp CASCADE;
    \\CREATE TABLE doc (id int PRIMARY KEY, body jsonb NOT NULL DEFAULT '{"z": 0, "a": 1}', raw json);
    \\CREATE INDEX ON doc USING gin (body);
    \\INSERT INTO doc VALUES (1, '{"b": [1, 2], "a": {"y": true, "x": null}}', '{"b" : 1,  "a" : 2}');
    \\INSERT INTO doc (id) VALUES (2);
    \\UPDATE doc SET body = body || '{"c": "x"}' WHERE id = 2;
    \\
;

const queries =
    \\SELECT count(*), sum(id), sum(balance), sum(active) FROM account;
    \\SELECT count(*), sum(amount), min(memo), max(memo) FROM entry;
    \\SELECT * FROM totals LIMIT 5;
    \\SELECT count(*), sum(amount) FROM "sales.orders";
    \\SELECT count(*), sum(amount) FROM "sales.big";
    \\SELECT * FROM xq_catalog ORDER BY tbl, col, key;
    \\SELECT * FROM xq_sequence ORDER BY name;
    \\SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;
;

/// sqlite3 enforces the STRICT types and the checks of the PostgreSQL types.
const bad = [_][]const u8{
    "INSERT INTO entry(account_id, amount) VALUES (1, 'x')",
    "INSERT INTO entry(account_id, amount, tag) VALUES (1, 1, 'too long tag')",
    "INSERT INTO entry(account_id, amount) VALUES (1, 3000000000)",
    "UPDATE account SET active = 2 WHERE id = 1",
    "INSERT INTO doc (id, body) VALUES (9, '{')",
};

fn build(c: *Check, file: []const u8) !void {
    _ = try c.runOk(&.{ c.cfg.xq, "sql", file }, .{ .stdin = script });
}

fn integrity(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const ok = std.mem.trimEnd(u8, try c.sqlite3(db, "PRAGMA integrity_check"), "\n");
    _ = c.expect(std.mem.eql(u8, ok, "ok"), "integrity_check: {s}", .{ok});
    const fk = std.mem.trimEnd(u8, try c.sqlite3(db, "PRAGMA foreign_key_check"), "\n");
    _ = c.expect(fk.len == 0, "foreign_key_check: {s}", .{fk});
}

fn results(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const x = try c.xqSql(db, queries);
    const s = try c.sqlite3(db, queries);
    _ = c.expectSame("results", "xqlite", x, "sqlite3", s);
}

fn rejects(c: *Check, base: *BaseDb, stmt: []const u8) !void {
    try base.get(c, db);
    const r = try c.run(&.{ c.cfg.sqlite3, db, stmt }, .{});
    _ = c.expect(!r.ok(), "sqlite3 accepted: {s}", .{stmt});
}

/// The PostgreSQL dialect reads back what sqlite3 changed. The next id is
/// 302: the INSERT ... ON CONFLICT DO UPDATE took 301, as in PostgreSQL.
fn readBack(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    _ = try c.sqlite3(db, "UPDATE account SET balance = balance + 1 WHERE id = 2");
    const out = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = ".dialect postgres\nSELECT balance FROM account WHERE id = 2;\nINSERT INTO account (email) VALUES ($$new@x$$) RETURNING id;\n" });
    const got = std.mem.trimEnd(u8, out, "\n");
    _ = c.expect(std.mem.eql(u8, got, "4.00\n302"), "read back: {s}", .{got});
}

/// A table of CREATE SCHEMA sales is the table "sales.orders" of main:
/// sqlite3 lists it, reads and writes it, and the PostgreSQL dialect reads
/// sqlite3's row as sales.orders (and as orders on search_path sales).
fn schemaTables(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const tables = try c.sqlite3(db, ".tables");
    _ = c.expect(std.mem.indexOf(u8, tables, "sales.orders") != null and std.mem.indexOf(u8, tables, "sales.big") != null, ".tables: {s}", .{tables});
    _ = c.expect(std.mem.indexOf(u8, tables, "tmp.x") == null, ".tables still lists tmp.x: {s}", .{tables});
    _ = try c.sqlite3(db, "INSERT INTO \"sales.orders\" (id, account_id, amount) VALUES (1000, 1, 7)");
    const out = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = ".dialect postgres\nSELECT amount FROM sales.orders WHERE id = 1000;\nSET search_path = sales;\nSELECT count(*) FROM orders;\n" });
    const got = std.mem.trimEnd(u8, out, "\n");
    _ = c.expect(std.mem.eql(u8, got, "7\n51"), "schema read back: {s}", .{got});
}

/// jsonb is stored normalized text that sqlite3's JSON functions read,
/// json as written; a row sqlite3 writes (not normalized) is read by the
/// dialect's operators.
fn jsonColumns(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const rows = std.mem.trimEnd(u8, try c.sqlite3(db, "SELECT body, raw, json_extract(body, '$.b[1]') FROM doc ORDER BY id"), "\n");
    const want =
        \\{"a": {"x": null, "y": true}, "b": [1, 2]}|{"b" : 1,  "a" : 2}|2
        \\{"a": 1, "c": "x", "z": 0}||
    ;
    _ = c.expect(std.mem.eql(u8, rows, want), "sqlite3 reads: {s}", .{rows});
    _ = try c.sqlite3(db, "INSERT INTO doc (id, body) VALUES (3, '{\"z\":1,\"c\":[2]}')");
    const out = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = ".dialect postgres\nSELECT body -> 'c', body ? 'z', body @> '{\"z\": 1}', jsonb_typeof(body -> 'c') FROM doc WHERE id = 3;\n" });
    const got = std.mem.trimEnd(u8, out, "\n");
    _ = c.expect(std.mem.eql(u8, got, "[2]|1|1|array"), "json read back: {s}", .{got});
}
