//! The T-SQL dialect against sqlite3: a database written by `xqlite sql`
//! in the T-SQL dialect (STRICT tables with the CHECKs of SQL Server's
//! types, IDENTITY columns and their sequences, computed columns, NOCASE
//! and BINARY collations, indexes, a view, the xq_catalog/xq_sequence
//! catalog, a JSON column checked with ISJSON) must pass sqlite3's
//! integrity check, and sqlite3 and xqlite
//! (in the SQLite dialect) must read the same rows and schema from it:
//! what the schema keeps is SQLite text that means what the T-SQL
//! statement meant. The expressions here need no engine function
//! (xq_tsql_*), which sqlite3 lacks; those are checked inside xqlite
//! (src/dialect/mssql/test.zig).

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;
const BaseDb = @import("base_db.zig");

pub const name = "mssql";
pub const about = "a T-SQL-dialect database read by sqlite3: integrity, rows, CHECKs, computed columns";

pub fn register(s: *xqt.Suite) !void {
    const base = try s.arena.allocator().create(BaseDb);
    base.* = .{ .build = build };
    try s.add("integrity_check and foreign_key_check", integrity, .{base});
    try s.add("results", results, .{base});
    for (bad) |stmt| try s.add(try std.fmt.allocPrint(s.arena.allocator(), "sqlite3 rejects: {s}", .{stmt}), rejects, .{ base, stmt });
    try s.add("read back what sqlite3 wrote", readBack, .{base});
}

const db = "mssql.db";

const script =
    \\.dialect mssql
    \\CREATE TABLE account (
    \\  id INT IDENTITY(1,1) PRIMARY KEY,
    \\  email NVARCHAR(80) NOT NULL UNIQUE,
    \\  name VARCHAR(40) NOT NULL DEFAULT 'anon',
    \\  balance DECIMAL(12,2) DEFAULT 0 CHECK (balance >= 0),
    \\  active BIT NOT NULL DEFAULT 1,
    \\  half AS (balance / 2) PERSISTED,
    \\  label AS (name + ':' + email),
    \\  created DATETIME DEFAULT GETDATE()
    \\);
    \\CREATE TABLE entry (
    \\  id BIGINT IDENTITY PRIMARY KEY,
    \\  account_id INT NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    \\  amount INT NOT NULL CHECK (amount BETWEEN -1000 AND 1000),
    \\  memo VARCHAR(20) COLLATE Latin1_General_CS_AS,
    \\  INDEX ix_memo (memo)
    \\);
    \\CREATE INDEX ix_entry ON entry (account_id, amount DESC);
    \\INSERT INTO account (email, balance) VALUES ('a@x.org', 10), ('B@x.org', 250.5), ('c@x.org', 0);
    \\INSERT INTO entry (account_id, amount, memo) VALUES (1, 5, 'Aa'), (1, -7, 'aa'), (2, 999, NULL), (3, 1, 'z');
    \\UPDATE account SET balance = balance + 1 WHERE email = 'A@X.ORG';
    \\GO
    \\CREATE VIEW totals AS SELECT a.email, COUNT(e.id) AS n, SUM(e.amount) AS total, IIF(a.balance > 100, 'big', 'small') AS size,
    \\  a.name + '/' + a.email AS who FROM account a LEFT JOIN entry e ON e.account_id = a.id GROUP BY a.email, a.balance, a.name
    \\GO
    \\ALTER TABLE entry ADD tag VARCHAR(8) DEFAULT 'tag';
    \\CREATE TABLE gone (x INT); DROP TABLE gone;
    \\CREATE TABLE doc (id INT PRIMARY KEY, body NVARCHAR(MAX) CHECK (ISJSON(body) = 1));
    \\INSERT INTO doc VALUES (1, '{"a":[1,2]}'), (2, NULL);
    \\
;

const queries =
    \\SELECT id, email, name, balance, active, half, label, length(created) FROM account ORDER BY id;
    \\SELECT id, account_id, amount, memo, tag FROM entry ORDER BY id;
    \\SELECT * FROM totals ORDER BY email;
    \\SELECT count(*) FROM entry WHERE memo = 'aa';
    \\SELECT id, body, json_extract(body, '$.a[1]') FROM doc ORDER BY id;
    \\SELECT * FROM xq_catalog ORDER BY tbl, col, key;
    \\SELECT * FROM xq_sequence ORDER BY name;
    \\SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;
;

/// sqlite3 enforces the STRICT types, the CHECKs of the types and the
/// tables, and the unique key (case-insensitively, as SQL Server).
const bad = [_][]const u8{
    "INSERT INTO account(email) VALUES (NULL)",
    "INSERT INTO account(email, balance) VALUES ('d@x.org', -1)",
    "INSERT INTO account(email) VALUES ('C@X.ORG')",
    "UPDATE account SET active = 2 WHERE id = 1",
    "INSERT INTO entry(account_id, amount) VALUES (1, 5000)",
    "INSERT INTO entry(account_id, amount) VALUES (1, 'x')",
    "INSERT INTO entry(account_id, amount, tag) VALUES (1, 1, 'too long tag')",
    // ISJSON is json_valid() and an object or array.
    "INSERT INTO doc VALUES (3, '1')",
    "INSERT INTO doc VALUES (3, '{a:1}')",
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

fn rejects(c: *Check, base: *BaseDb, stmt: []const u8) !void {
    try base.get(c, db);
    const r = try c.run(&.{ c.cfg.sqlite3, db, stmt }, .{});
    _ = c.expect(!r.ok(), "sqlite3 accepted: {s}", .{stmt});
}

/// The T-SQL dialect reads what sqlite3 changed, and its computed
/// columns follow; the identity goes on from where it was.
fn readBack(c: *Check, base: *BaseDb) !void {
    try base.get(c, db);
    _ = try c.sqlite3(db, "UPDATE account SET balance = balance + 1 WHERE id = 2");
    const out = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = ".dialect mssql\nSELECT balance, half FROM account WHERE id = 2;\nINSERT INTO account (email) OUTPUT INSERTED.id, INSERTED.label VALUES ('new@x');\n" });
    const got = std.mem.trimEnd(u8, out, "\n");
    _ = c.expect(std.mem.eql(u8, got, "251.5|125.75\n4|anon:new@x"), "read back: {s}", .{got});
    try integrityOk(c, "integrity_check after writes");
}
