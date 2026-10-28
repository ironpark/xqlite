//! End-to-end tests of PRAGMA, in the style of sql_test.zig.

const std = @import("std");
const testing = std.testing;
const int = @import("sqlite_int.zig");

const Conn = @import("sql_test.zig").Conn;

test "pragma: schema introspection" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT UNIQUE);
        \\CREATE TABLE t(a INT NOT NULL DEFAULT 5, b TEXT COLLATE NOCASE, c AS (a+1), d REFERENCES p ON DELETE CASCADE, PRIMARY KEY(b, a));
        \\CREATE INDEX t_c ON t(d DESC, a) WHERE d > 0;
        \\CREATE TABLE w(k PRIMARY KEY, v) WITHOUT ROWID;
        \\CREATE VIEW v AS SELECT a, b FROM t;
    );
    try c.expectRows("PRAGMA table_info(t)",
        \\0|a|INT|1|5|2
        \\1|b|TEXT|0|NULL|1
        \\2|d||0|NULL|0
        \\
    );
    try c.expectRows("PRAGMA table_xinfo('t')",
        \\0|a|INT|1|5|2|0
        \\1|b|TEXT|0|NULL|1|0
        \\2|c||0|NULL|0|2
        \\3|d||0|NULL|0|0
        \\
    );
    try c.expectRows("PRAGMA main.table_info(v)", "0|a|INT|0|NULL|0\n1|b|TEXT|0|NULL|0\n");
    try c.expectRows("PRAGMA table_info(nosuch)", "");
    try c.expectRows("PRAGMA index_list(t)", "0|t_c|0|c|1\n1|sqlite_autoindex_t_1|1|pk|0\n");
    try c.expectRows("PRAGMA index_info(t_c)", "0|3|d\n1|0|a\n");
    try c.expectRows("PRAGMA index_xinfo(t_c)", "0|3|d|1|BINARY|1\n1|0|a|0|BINARY|1\n2|-1|NULL|0|BINARY|0\n");
    try c.expectRows("PRAGMA index_info(w)", "0|0|k\n");
    try c.expectRows("PRAGMA index_xinfo(sqlite_autoindex_t_1)", "0|1|b|0|NOCASE|1\n1|0|a|0|BINARY|1\n2|-1|NULL|0|BINARY|0\n");
    try c.expectRows("PRAGMA foreign_key_list(t)", "0|0|p|d|NULL|NO ACTION|CASCADE|NONE\n");
    try c.expectRows("PRAGMA table_list(w)", "main|w|table|2|1|0\n");
    try c.expectRows("PRAGMA table_list(v)", "main|v|view|2|0|0\n");
    try c.expectRows("PRAGMA database_list", "0|main|test.db\n");
    try c.expectColumns("PRAGMA table_info(t)", "cid|name|type|notnull|dflt_value|pk");
    try c.expectColumns("PRAGMA index_xinfo(t_c)", "seqno|cid|name|desc|coll|key");
    try c.expectColumns("PRAGMA foreign_key_check", "table|rowid|parent|fkid");
    try c.expectColumns("PRAGMA user_version", "user_version");
    try c.expectColumns("PRAGMA busy_timeout", "timeout");
    try c.expectColumns("PRAGMA main.default_cache_size", "cache_size");
    try c.expectRows("PRAGMA unknown_pragma", "");
    try c.expectError("PRAGMA nosuch.user_version", "unknown database nosuch");
}

test "pragma: flags and settings" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("PRAGMA foreign_keys", "0\n");
    try c.exec("PRAGMA foreign_keys=ON");
    try c.expectRows("PRAGMA foreign_keys", "1\n");
    try testing.expect(c.db.flags.ForeignKeys);
    try c.exec("PRAGMA recursive_triggers=yes; PRAGMA reverse_unordered_selects=1; PRAGMA count_changes=true");
    try c.expectRows("PRAGMA recursive_triggers; PRAGMA reverse_unordered_selects; PRAGMA count_changes", "1\n1\n1\n");
    try c.exec("PRAGMA count_changes=off");
    try c.exec("BEGIN; PRAGMA foreign_keys=OFF; COMMIT");
    try c.expectRows("PRAGMA foreign_keys", "1\n");
    try c.exec("PRAGMA case_sensitive_like=1");
    try c.expectRows("SELECT 'a' LIKE 'A', 'a' LIKE 'a'", "0|1\n");
    try c.exec("PRAGMA case_sensitive_like=0");
    try c.expectRows("SELECT 'a' LIKE 'A'", "1\n");

    try c.expectRows("PRAGMA synchronous", "2\n");
    try c.exec("PRAGMA synchronous=OFF");
    try c.expectRows("PRAGMA synchronous", "0\n");
    try c.exec("PRAGMA synchronous=extra");
    try c.expectRows("PRAGMA main.synchronous", "3\n");
    try c.expectError("BEGIN; PRAGMA synchronous=1", "Safety level may not be changed inside a transaction");
    try c.exec("ROLLBACK");
    try c.expectRows("PRAGMA secure_delete; PRAGMA secure_delete=fast; PRAGMA secure_delete=0", "0\n2\n0\n");
    try c.expectRows("PRAGMA temp_store; PRAGMA temp_store=memory; PRAGMA temp_store", "0\n2\n");
    try c.expectRows("PRAGMA busy_timeout=1500; PRAGMA busy_timeout", "1500\n1500\n");
    try c.expectRows("PRAGMA threads=4; PRAGMA threads=100", "4\n8\n");
    try c.expectRows("PRAGMA analysis_limit=-1; PRAGMA analysis_limit=300", "0\n300\n");
    try c.expectRows("PRAGMA mmap_size=1000000", "0\n");
    try c.expectRows("PRAGMA locking_mode; PRAGMA locking_mode=normal", "normal\nnormal\n");
    try c.expectError("PRAGMA locking_mode=exclusive", "not supported yet: PRAGMA locking_mode=EXCLUSIVE");
    try c.expectRows("PRAGMA journal_size_limit; PRAGMA journal_size_limit=-5; PRAGMA journal_size_limit=4096", "-1\n-1\n4096\n");
    try c.expectRows("PRAGMA cache_size; PRAGMA cache_size=100; PRAGMA cache_size", "-2000\n100\n");
    try c.expectRows("PRAGMA cache_spill=OFF; PRAGMA cache_spill; PRAGMA cache_spill=250; PRAGMA cache_spill", "0\n250\n");
    try c.expectRows("PRAGMA encoding", "UTF-8\n");
    try c.expectError("PRAGMA encoding='latin1'", "unsupported encoding: latin1");
    const opts = try c.query("PRAGMA compile_options");
    defer testing.allocator.free(opts);
    try testing.expect(std.mem.indexOf(u8, opts, "THREADSAFE=1\n") != null);
    try c.expectRows("PRAGMA shrink_memory", "");
    // Not in WAL mode: nothing to checkpoint.
    try c.expectRows("PRAGMA wal_checkpoint; PRAGMA main.wal_checkpoint(FULL)", "0|-1|-1\n0|-1|-1\n");
    try c.expectRows("PRAGMA wal_autocheckpoint; PRAGMA wal_autocheckpoint=50; PRAGMA wal_autocheckpoint=0", "1000\n50\n0\n");
    const list = try c.query("PRAGMA pragma_list");
    defer testing.allocator.free(list);
    try testing.expect(std.mem.startsWith(u8, list, "analysis_limit\napplication_id\n"));
    try testing.expect(std.mem.indexOf(u8, list, "\nwritable_schema\n") != null);
    const funcs = try c.query("PRAGMA function_list");
    defer testing.allocator.free(funcs);
    try testing.expect(std.mem.indexOf(u8, funcs, "\nsubstr|1|s|utf8|3|2099200\n") != null);
    try c.expectRows("PRAGMA collation_list", "0|BINARY\n1|NOCASE\n2|RTRIM\n");
}

test "pragma: header values and page settings" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA page_size=1024; PRAGMA auto_vacuum=incremental");
    try c.exec("CREATE TABLE t(a); INSERT INTO t SELECT zeroblob(900) FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3)");
    try c.exec("PRAGMA user_version=42; PRAGMA application_id=-7; PRAGMA default_cache_size=-300");
    try c.reopen();
    try c.expectRows("PRAGMA page_size; PRAGMA auto_vacuum; PRAGMA user_version; PRAGMA application_id", "1024\n2\n42\n-7\n");
    try c.expectRows("PRAGMA default_cache_size; PRAGMA cache_size", "300\n300\n");
    // As in SQLite, the switch from the default page size discarded the
    // cache once more.
    try c.expectRows("PRAGMA schema_version; PRAGMA data_version", "1\n2\n");
    try c.expectRows("PRAGMA page_count; PRAGMA freelist_count", "6\n0\n");
    // The page size and auto-vacuum mode of an existing file are fixed.
    try c.exec("PRAGMA page_size=4096; PRAGMA auto_vacuum=none");
    try c.expectRows("PRAGMA page_size; PRAGMA auto_vacuum", "1024\n2\n");
    try c.exec("DELETE FROM t");
    try c.expectRows("PRAGMA freelist_count", "3\n");
    try c.exec("PRAGMA incremental_vacuum(2)");
    try c.expectRows("PRAGMA freelist_count; PRAGMA page_count", "1\n4\n");
    try c.exec("PRAGMA incremental_vacuum");
    try c.expectRows("PRAGMA freelist_count; PRAGMA page_count", "0\n3\n");
    try c.expectRows("PRAGMA max_page_count=2; PRAGMA max_page_count=0x7fffffff", "3\n2147483647\n");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
    for ([_][]const u8{ "persist", "truncate", "off", "delete" }) |mode| {
        const sql = try std.fmt.allocPrint(testing.allocator, "PRAGMA journal_mode={s}", .{mode});
        defer testing.allocator.free(sql);
        const want = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{mode});
        defer testing.allocator.free(want);
        try c.expectRows(sql, want);
        try c.exec("INSERT INTO t VALUES(1)");
    }
    try c.expectRows("PRAGMA journal_mode; PRAGMA journal_mode=bogus", "delete\ndelete\n");
}

test "pragma: integrity_check" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b NOT NULL, c TEXT, d INT CHECK(d < 100), e UNIQUE);
        \\CREATE INDEX t_c ON t(c);
        \\CREATE TABLE w(k, v NOT NULL, PRIMARY KEY(k)) WITHOUT ROWID;
        \\CREATE TABLE s(x INT, y TEXT) STRICT;
        \\INSERT INTO t VALUES(1, 1, 'one', 1, 1), (2, 2, 'two', 2, 2);
        \\INSERT INTO w VALUES('a', 1), ('b', 2);
        \\INSERT INTO s VALUES(1, 'x');
    );
    try c.expectRows("PRAGMA integrity_check", "ok\n");
    try c.expectRows("PRAGMA quick_check", "ok\n");
    try c.expectRows("PRAGMA integrity_check(t)", "ok\n");
    try c.expectRows("PRAGMA main.quick_check(5)", "ok\n");
    try c.expectError("PRAGMA integrity_check(nosuch)", "no such table: nosuch");

    // Break the rules behind the schema's back.
    try c.exec(
        \\PRAGMA writable_schema=ON;
        \\UPDATE sqlite_schema SET sql='CREATE TABLE t(a INTEGER PRIMARY KEY, b, c, d INT, e UNIQUE)' WHERE name='t';
        \\UPDATE sqlite_schema SET sql='CREATE INDEX t_c ON t(d)' WHERE name='t_c';
    );
    try c.reopen();
    try c.exec("INSERT INTO t VALUES(3, NULL, 3, 500, 3)");
    try c.exec(
        \\PRAGMA writable_schema=ON;
        \\UPDATE sqlite_schema SET sql='CREATE TABLE t(a INTEGER PRIMARY KEY, b NOT NULL, c TEXT, d INT CHECK(d < 100), e UNIQUE)' WHERE name='t';
        \\UPDATE sqlite_schema SET sql='CREATE INDEX t_c ON t(c)' WHERE name='t_c';
    );
    try c.reopen();
    try c.expectRows("PRAGMA integrity_check",
        \\NULL value in t.b
        \\NUMERIC value in t.c
        \\CHECK constraint failed in t
        \\row 3 missing from index t_c
        \\
    );
    try c.expectRows("PRAGMA quick_check",
        \\NULL value in t.b
        \\NUMERIC value in t.c
        \\CHECK constraint failed in t
        \\
    );
    try c.expectRows("PRAGMA integrity_check(2)", "NULL value in t.b\nNUMERIC value in t.c\n");
    try c.exec("PRAGMA ignore_check_constraints=ON");
    try c.expectRows("PRAGMA quick_check", "NULL value in t.b\nNUMERIC value in t.c\n");
}

test "pragma: foreign_key_check" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE p(id INTEGER PRIMARY KEY, x);
        \\CREATE TABLE q(a, b, UNIQUE(a, b));
        \\CREATE TABLE c1(r REFERENCES p);
        \\CREATE TABLE c2(u, v, FOREIGN KEY(v, u) REFERENCES q(b, a));
        \\CREATE TABLE c3(z REFERENCES nosuch);
        \\CREATE TABLE p4(x);
        \\CREATE TABLE c4(m REFERENCES p4(x));
        \\INSERT INTO p VALUES(1, 'x');
        \\INSERT INTO q VALUES(1, 2);
        \\INSERT INTO c1 VALUES(1), (2), (NULL);
        \\INSERT INTO c2 VALUES(1, 2), (2, 1);
        \\INSERT INTO c3 VALUES(7);
    );
    try c.expectRows("PRAGMA foreign_key_check(c1)", "c1|2|p|0\n");
    try c.expectRows("PRAGMA foreign_key_check(c2)", "c2|2|q|0\n");
    try c.expectRows("PRAGMA foreign_key_check(c3)", "c3|1|nosuch|0\n");
    try c.expectError("PRAGMA foreign_key_check(c4)", "foreign key mismatch - \"c4\" referencing \"p4\"");
    try c.expectError("PRAGMA foreign_key_check(nosuch)", "no such table: nosuch");
}
