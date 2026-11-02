//! The MariaDB dialect against sqlite3: a database written by `xqlite sql`
//! in the MariaDB dialect (STRICT tables, named CHECKs, DEFAULT and
//! generated-column expressions, AUTO_INCREMENT, "t$i" indexes renamed
//! with their table, views, the xq_catalog catalog, the tables of CREATE
//! DATABASE as "db.t" tables of main) must pass sqlite3's
//! integrity check, and sqlite3 and xqlite (in the SQLite dialect) must
//! read the same rows and schema from it: what the schema keeps is SQLite
//! text that means what the MariaDB statement meant. The expressions here
//! need no engine function (xq_*), which sqlite3 lacks; those are checked
//! inside xqlite (src/dialect/mariadb/test.zig).
//! (Was tools/interop-mariadb.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;
const BaseDb = @import("base_db.zig");

pub const name = "mariadb";
pub const dialect = "mariadb";
pub const about = "a MariaDB-dialect database read by sqlite3: integrity, rows, CHECKs, defaults";

pub fn register(s: *xqt.Suite) !void {
    const base = try s.arena.allocator().create(BaseDb);
    base.* = .{ .build = build };
    try s.add("integrity_check and foreign_key_check", integrity, .{base});
    try s.add("results", results, .{base});
    try s.add("index names", indexNames, .{base});
    for (bad) |stmt| try s.add(try std.fmt.allocPrint(s.arena.allocator(), "sqlite3 rejects: {s}", .{stmt}), rejects, .{ base, stmt });
    try s.add("read back what sqlite3 wrote", readBack, .{base});
    try s.add("tables of CREATE DATABASE", databaseTables, .{base});
}

const db = "maria.db";

const script =
    \\.dialect mariadb
    \\CREATE TABLE account (
    \\  id int unsigned NOT NULL AUTO_INCREMENT,
    \\  email varchar(80) NOT NULL,
    \\  name varchar(40) NOT NULL DEFAULT (UCASE('anon')),
    \\  balance decimal(12,2) DEFAULT 0 CHECK (balance >= 0),
    \\  half double AS (balance / 2) STORED,
    \\  label varchar(60) AS (CONCAT(name, ':', IF(balance > 100, 'big', 'small'))) VIRTUAL,
    \\  meta json,
    \\  created_at datetime DEFAULT CURRENT_TIMESTAMP,
    \\  PRIMARY KEY (id),
    \\  UNIQUE KEY uq_email (email),
    \\  KEY idx_name (name, balance DESC),
    \\  CONSTRAINT chk_email CHECK (email LIKE '%@%' AND CHAR_LENGTH(email) > 3)
    \\) ENGINE=InnoDB AUTO_INCREMENT=10 DEFAULT CHARSET=utf8mb4;
    \\CREATE TABLE entry (
    \\  id int AUTO_INCREMENT PRIMARY KEY,
    \\  account_id int unsigned NOT NULL,
    \\  amount int NOT NULL,
    \\  ratio double DEFAULT (7 / 2),
    \\  memo varchar(20) COLLATE utf8mb4_bin,
    \\  KEY (memo),
    \\  FOREIGN KEY (account_id) REFERENCES account (id) ON DELETE CASCADE,
    \\  CHECK (amount BETWEEN -1000 AND 1000 || amount = 9999)
    \\);
    \\INSERT INTO account (email, balance, meta) VALUES ('a@x.org', 10, '{"n": 1}'), ('B@x.org', 250.5, NULL), ('c@x.org', 0, '[]');
    \\INSERT INTO entry (account_id, amount, memo) VALUES (10, 5, 'Aa'), (10, -7, 'aa'), (11, 9999, NULL), (12, 1, 'z');
    \\UPDATE account SET balance = balance + 1 WHERE email = 'A@X.ORG';
    \\CREATE VIEW totals AS SELECT a.email, count(e.id) AS n, sum(e.amount) AS total, GREATEST(a.balance, 100) / 4 AS g, a.email LIKE 'a\_%' AS under FROM account a LEFT JOIN entry e ON e.account_id = a.id GROUP BY a.email ORDER BY a.email;
    \\RENAME TABLE entry TO ledger;
    \\ALTER TABLE ledger ADD COLUMN tag varchar(8) DEFAULT 'tag';
    \\CREATE TABLE gone (x int); DROP TABLE gone;
    \\CREATE DATABASE sales;
    \\CREATE TABLE sales.orders (id int AUTO_INCREMENT PRIMARY KEY, account_id int, amount int CHECK (amount > 0), KEY ix_acct (account_id)) AUTO_INCREMENT=100;
    \\INSERT INTO sales.orders (account_id, amount) VALUES (10, 5), (11, 7), (12, 60);
    \\USE sales;
    \\CREATE VIEW big AS SELECT o.id, o.amount FROM orders o WHERE o.amount > 50;
    \\USE main;
    \\CREATE DATABASE tmp; CREATE TABLE tmp.x (a int); DROP DATABASE tmp;
    \\
;

const queries =
    \\SELECT id, email, name, balance, half, label, meta, length(created_at) FROM account ORDER BY id;
    \\SELECT id, account_id, amount, ratio, memo, tag FROM ledger ORDER BY id;
    \\SELECT * FROM totals;
    \\SELECT count(*) FROM ledger WHERE memo = 'aa';
    \\SELECT * FROM xq_catalog ORDER BY tbl, col, key;
    \\SELECT * FROM sqlite_sequence ORDER BY name;
    \\SELECT id, account_id, amount FROM "sales.orders" ORDER BY id;
    \\SELECT * FROM "sales.big";
    \\SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;
;

/// sqlite3 enforces the STRICT types, the CHECKs and the unique key
/// (case-insensitively, as MariaDB).
const bad = [_][]const u8{
    "INSERT INTO account(email) VALUES ('nobody')",
    "INSERT INTO account(email, balance) VALUES ('d@x.org', -1)",
    "INSERT INTO account(email, meta) VALUES ('e@x.org', 'not json')",
    "INSERT INTO account(email) VALUES ('C@X.ORG')",
    "INSERT INTO ledger(account_id, amount) VALUES (10, 5000)",
    "INSERT INTO ledger(account_id, amount) VALUES (10, 'x')",
    "INSERT INTO \"sales.orders\"(account_id, amount) VALUES (1, 0)",
};

fn build(c: *Check, file: []const u8) !void {
    _ = try c.runOk(&.{ c.cfg.xq, "sql", file }, .{ .stdin = script });
}

fn integrityOk(c: *Check, what: []const u8) !void {
    const ok = std.mem.trimEnd(u8, try c.sqlite3(db, "PRAGMA integrity_check"), "\n");
    _ = c.expect(std.mem.eql(u8, ok, "ok"), "{s}: {s}", .{ what, ok });
}

fn integrity(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    try integrityOk(c, "integrity_check");
    const fk = std.mem.trimEnd(u8, try c.sqlite3(db, "PRAGMA foreign_key_check"), "\n");
    _ = c.expect(fk.len == 0, "foreign_key_check: {s}", .{fk});
}

fn results(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const x = try c.xqSql(db, queries);
    const s = try c.sqlite3(db, queries);
    _ = c.expectSame("results", "xqlite", x, "sqlite3", s);
}

/// The indexes were renamed with their table.
fn indexNames(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const idx = std.mem.trimEnd(u8, try c.sqlite3(db, "SELECT group_concat(name, ' ') FROM (SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name)"), "\n");
    _ = c.expect(std.mem.eql(u8, idx, "account$idx_name account$uq_email ledger$memo sales.orders$ix_acct"), "index names: {s}", .{idx});
}

fn rejects(c: *Check, base: *BaseDb, stmt: []const u8) !void {
    try base.get(c, db);
    const r = try c.run(&.{ c.cfg.sqlite3, db, stmt }, .{});
    _ = c.expect(!r.ok(), "sqlite3 accepted: {s}", .{stmt});
}

/// sqlite3's rows get the defaults and generated values the MariaDB
/// dialect's do, and the AUTO_INCREMENT counter moves on.
fn readBack(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    _ = try c.sqlite3(db, "INSERT INTO account(email, balance) VALUES ('s@x.org', 300); INSERT INTO ledger(account_id, amount) VALUES (13, 2)");
    const out = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = ".dialect mariadb\nSELECT id, name, half, label FROM account WHERE email = 'S@X.ORG';\nSELECT ratio, tag FROM ledger WHERE account_id = 13;\nINSERT INTO account (email) VALUES ('t@x.org');\nSELECT LAST_INSERT_ID();\n" });
    const got = std.mem.trimEnd(u8, out, "\n");
    _ = c.expect(std.mem.eql(u8, got, "13|ANON|150.0|ANON:big\n3.5|tag\n14"), "read back: {s}", .{got});
    try integrityOk(c, "integrity_check after writes");
}

/// A table of CREATE DATABASE sales is the table "sales.orders" of main:
/// sqlite3 lists it, reads and writes it (its AUTO_INCREMENT counter
/// moves on), and the MariaDB dialect reads sqlite3's row as sales.orders
/// (and as orders after USE sales).
fn databaseTables(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    const tables = try c.sqlite3(db, ".tables");
    _ = c.expect(std.mem.indexOf(u8, tables, "sales.orders") != null and std.mem.indexOf(u8, tables, "sales.big") != null, ".tables: {s}", .{tables});
    _ = c.expect(std.mem.indexOf(u8, tables, "tmp.x") == null, ".tables still lists tmp.x: {s}", .{tables});
    _ = try c.sqlite3(db, "INSERT INTO \"sales.orders\" (account_id, amount) VALUES (1, 70)");
    const out = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = ".dialect mariadb\nSELECT id, amount FROM sales.orders WHERE account_id = 1;\nUSE sales;\nSELECT count(*) FROM orders;\nSELECT id FROM big ORDER BY id;\nSHOW TABLES;\n" });
    const got = std.mem.trimEnd(u8, out, "\n");
    _ = c.expect(std.mem.eql(u8, got, "103|70\n4\n102\n103\nbig\norders"), "database read back: {s}", .{got});
    try integrityOk(c, "integrity_check after the database writes");
}
