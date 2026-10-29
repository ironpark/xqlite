//! PRAGMA against sqlite3: each pragma runs through `xqlite sql` and
//! through sqlite3 on the same database and must print the same rows.
//! Files whose header PRAGMA changed (page_size, auto_vacuum,
//! user_version, journal_mode, ...) must pass both integrity checks.
//! (Was tools/interop-pragma.sh.)
//!
//! Each statement runs on its own connection, so settings do not carry
//! over, and none of them changes the file: the statement lists are cut
//! into chunks, each run on its own copy of the database.

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "pragma";
pub const about = "each PRAGMA prints the same rows in both engines";

/// Statements per check.
const chunk = 8;

pub fn register(s: *xqt.Suite) !void {
    const a = s.arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, same, '\n');
    while (it.next()) |line| try lines.append(a, line);
    const n = lines.items.len;
    for ([_]Writer{ .sqlite3, .xqlite }) |w| {
        var i: usize = 0;
        while (i < n) : (i += chunk) {
            const end = @min(n, i + chunk);
            try s.add(try std.fmt.allocPrint(a, "{t} file: statements {d}-{d}", .{ w, i + 1, end }), compareSame, .{ w, lines.items[i..end] });
        }
    }
    try s.add("sqlite3 file: sorted", sqliteSorted, .{});
    try s.add("xqlite file: integrity", xqliteIntegrity, .{});
    try s.add("header pragmas", headerPragmas, .{});
    try s.add("auto_vacuum=full", fullAutoVacuum, .{});
    try s.add("journal modes", journalModes, .{});
    try s.add("corrupt file", corruptFile, .{});
}

// Table r has two foreign keys referencing the same parent.
const schema =
    \\CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT);
    \\CREATE TABLE u(name TEXT UNIQUE COLLATE NOCASE);
    \\CREATE TABLE c(x INTEGER NOT NULL DEFAULT 0, y TEXT DEFAULT 'abc', z REAL CHECK(z >= 0),
    \\  pid INTEGER REFERENCES p(id) ON DELETE CASCADE, pname TEXT REFERENCES u(name) ON UPDATE SET NULL,
    \\  g AS (x * 2), PRIMARY KEY(x, y));
    \\CREATE INDEX c_z ON c(z DESC, y);
    \\CREATE INDEX c_part ON c(pid) WHERE pid > 0;
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v BLOB, n INT, UNIQUE(n, k)) WITHOUT ROWID;
    \\CREATE TABLE s(a INT, b TEXT, c ANY) STRICT;
    \\CREATE TABLE e(u, v, FOREIGN KEY(u, v) REFERENCES w(k, n) ON DELETE RESTRICT);
    \\CREATE TABLE q(s, t, FOREIGN KEY(t, s) REFERENCES c(y, x));
    \\CREATE TABLE r(a INTEGER REFERENCES p(id), b INTEGER REFERENCES p(id) ON DELETE SET NULL);
    \\CREATE VIEW vw AS SELECT x, y FROM c;
    \\INSERT INTO p VALUES(1, 'one'), (2, 'two');
    \\INSERT INTO u VALUES('one');
    \\INSERT INTO c(x, y, z, pid, pname) VALUES(1, 'a', 1.5, 1, 'one'), (2, 'b', 2, 3, 'nine'), (3, 'c', NULL, NULL, NULL);
    \\INSERT INTO w VALUES('k1', x'01', 1);
    \\INSERT INTO s VALUES(1, 'x', 2.5);
    \\INSERT INTO e VALUES('k1', 1), ('k2', 2), (NULL, 3);
    \\INSERT INTO q VALUES(1, 'a'), (1, 'b'), (5, NULL);
    \\INSERT INTO r VALUES(1, 2), (3, NULL), (2, 4);
;

// Pragmas whose output is the same in both, one statement per line.
const same =
    \\PRAGMA table_info(c);
    \\PRAGMA table_xinfo(c);
    \\PRAGMA table_info(vw);
    \\PRAGMA table_info(w);
    \\PRAGMA table_xinfo(s);
    \\PRAGMA main.table_info(p);
    \\PRAGMA table_info(nosuch);
    \\PRAGMA index_list(c);
    \\PRAGMA index_list(w);
    \\PRAGMA index_list(p);
    \\PRAGMA index_info(c_z);
    \\PRAGMA index_xinfo(c_z);
    \\PRAGMA index_xinfo(c_part);
    \\PRAGMA index_info(w);
    \\PRAGMA index_xinfo(sqlite_autoindex_u_1);
    \\PRAGMA index_xinfo(sqlite_autoindex_w_2);
    \\PRAGMA foreign_key_list(c);
    \\PRAGMA foreign_key_list(e);
    \\PRAGMA foreign_key_check(c);
    \\PRAGMA foreign_key_check(q);
    \\PRAGMA foreign_key_list(q);
    \\PRAGMA foreign_key_list(r);
    \\PRAGMA foreign_key_check(r);
    \\PRAGMA foreign_keys;
    \\PRAGMA foreign_keys=ON;
    \\PRAGMA foreign_keys;
    \\PRAGMA reverse_unordered_selects;
    \\PRAGMA case_sensitive_like=1;
    \\PRAGMA count_changes;
    \\PRAGMA short_column_names;
    \\PRAGMA full_column_names;
    \\PRAGMA legacy_alter_table;
    \\PRAGMA writable_schema;
    \\PRAGMA ignore_check_constraints;
    \\PRAGMA query_only;
    \\PRAGMA automatic_index;
    \\PRAGMA cell_size_check;
    \\PRAGMA defer_foreign_keys;
    \\PRAGMA user_version;
    \\PRAGMA schema_version;
    \\PRAGMA application_id;
    \\PRAGMA data_version;
    \\PRAGMA freelist_count;
    \\PRAGMA page_size;
    \\PRAGMA page_count;
    \\PRAGMA max_page_count;
    \\PRAGMA max_page_count=100000;
    \\PRAGMA cache_size;
    \\PRAGMA cache_size=-4000;
    \\PRAGMA cache_size;
    \\PRAGMA default_cache_size;
    \\PRAGMA cache_spill=OFF; PRAGMA cache_spill;
    \\PRAGMA cache_size=50; PRAGMA cache_spill=200; PRAGMA cache_spill;
    \\PRAGMA auto_vacuum;
    \\PRAGMA encoding;
    \\PRAGMA journal_mode;
    \\PRAGMA journal_size_limit;
    \\PRAGMA wal_autocheckpoint;
    \\PRAGMA wal_autocheckpoint=100;
    \\PRAGMA wal_checkpoint;
    \\PRAGMA wal_checkpoint(TRUNCATE);
    \\PRAGMA locking_mode;
    \\PRAGMA synchronous;
    \\PRAGMA synchronous=NORMAL;
    \\PRAGMA synchronous;
    \\PRAGMA secure_delete;
    \\PRAGMA secure_delete=FAST;
    \\PRAGMA temp_store;
    \\PRAGMA temp_store=MEMORY;
    \\PRAGMA temp_store;
    \\PRAGMA mmap_size;
    \\PRAGMA busy_timeout=250;
    \\PRAGMA threads;
    \\PRAGMA analysis_limit=50;
    \\PRAGMA soft_heap_limit;
    \\PRAGMA shrink_memory;
    \\PRAGMA no_such_pragma;
    \\PRAGMA database_list;
    \\PRAGMA integrity_check;
    \\PRAGMA integrity_check(c);
    \\PRAGMA quick_check;
    \\PRAGMA main.integrity_check(1);
;
// The order of table_list follows SQLite's hash table, so it is sorted.
const sorted = [_][]const u8{
    "PRAGMA table_list;",
    "PRAGMA foreign_key_check;",
    "PRAGMA table_list(c);",
    "PRAGMA temp.table_list;",
};

const Writer = enum { sqlite3, xqlite };

const Order = enum {
    /// As printed.
    as_is,
    /// Lines sorted.
    sort,
    /// Lines sorted, and of sqlite3's only those xqlite prints too:
    /// sqlite3's shell adds functions of its own to function_list.
    common,
};

/// The database `schema` written by `w`, named `db`.
fn build(c: *Check, w: Writer, db: []const u8) !void {
    switch (w) {
        .sqlite3 => _ = try c.sqlite3(db, schema),
        .xqlite => _ = try c.xqSql(db, schema),
    }
}

/// Runs each statement through both shells on `db`, xqlite first, and
/// compares what they print (standard output and error).
fn compare(c: *Check, label: []const u8, db: []const u8, stmts: []const []const u8, order: Order) !void {
    for (stmts) |stmt| {
        var x = try merged(c, &.{ c.cfg.xq, "sql", db, stmt });
        var s = try merged(c, &.{ c.cfg.sqlite3, db, stmt });
        switch (order) {
            .as_is => {},
            .sort => {
                x = try sortLines(c.arena, x);
                s = try sortLines(c.arena, s);
            },
            .common => {
                x = try sortLines(c.arena, x);
                s = try commonLines(c.arena, try sortLines(c.arena, s), x);
            },
        }
        if (!std.mem.eql(u8, x, s)) {
            c.fail("{s}: {s}", .{ label, stmt });
            c.writeDiff("xqlite", x, "sqlite3", s);
        }
    }
}

/// What `argv > out 2>&1` writes, whatever the exit status: standard
/// output and standard error in one file, as the program interleaves them.
fn merged(c: *Check, argv: []const []const u8) ![]const u8 {
    var p = try c.spawn(argv, .{ .output = "out" });
    defer p.kill();
    _ = try p.close();
    return c.readFile("out");
}

/// The lines of `text` in byte order, each ending with a newline (`sort`).
fn sortLines(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (it.peek() == null and line.len == 0) break;
        try lines.append(arena, line);
    }
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    var w: std.Io.Writer.Allocating = .init(arena);
    for (lines.items) |line| try w.writer.print("{s}\n", .{line});
    return w.written();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The lines of sorted `a` that sorted `b` has too, as often as both have
/// them (`comm -12 a b`).
fn commonLines(arena: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var ia = std.mem.splitScalar(u8, a, '\n');
    var ib = std.mem.splitScalar(u8, b, '\n');
    var la = ia.next();
    var lb = ib.next();
    while (la != null and lb != null and ia.peek() != null and ib.peek() != null) {
        switch (std.mem.order(u8, la.?, lb.?)) {
            .lt => la = ia.next(),
            .gt => lb = ib.next(),
            .eq => {
                try w.writer.print("{s}\n", .{la.?});
                la = ia.next();
                lb = ib.next();
            },
        }
    }
    return w.written();
}

fn integrity(c: *Check, label: []const u8, db: []const u8) !void {
    const s = try c.sqlite3(db, "PRAGMA integrity_check");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, s, "\n"), "ok")) c.fail("{s}: sqlite3 integrity_check: {s}", .{ label, s });
    const x = try c.xqSql(db, "PRAGMA integrity_check");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, x, "\n"), "ok")) c.fail("{s}: xqlite integrity_check: {s}", .{ label, x });
}

/// 1, 2. Introspection of the schema written by either engine.
fn compareSame(c: *Check, w: Writer, stmts: []const []const u8) !void {
    const db = if (w == .sqlite3) "a.db" else "b.db";
    try build(c, w, db);
    try compare(c, if (w == .sqlite3) "sqlite3 file" else "xqlite file", db, stmts, .as_is);
}

/// 1. The pragmas whose rows come in no set order.
fn sqliteSorted(c: *Check) !void {
    try build(c, .sqlite3, "a.db");
    try compare(c, "sqlite3 file", "a.db", &sorted, .sort);
    try compare(c, "sqlite3 file", "a.db", &.{"PRAGMA function_list"}, .common);
}

/// 2. The file xqlite wrote passes both integrity checks.
fn xqliteIntegrity(c: *Check) !void {
    try build(c, .xqlite, "b.db");
    try integrity(c, "xqlite file", "b.db");
}

/// 3. Header pragmas written by xqlite, read back by both.
fn headerPragmas(c: *Check) !void {
    _ = try c.xqSql("h.db", "PRAGMA page_size=8192; PRAGMA auto_vacuum=INCREMENTAL; " ++ schema ++
        \\
        \\PRAGMA user_version=42; PRAGMA application_id=1234; PRAGMA default_cache_size=500;
        \\DELETE FROM c; PRAGMA incremental_vacuum(1);
    );
    try compare(c, "header pragmas", "h.db", &.{
        "PRAGMA page_size;",
        "PRAGMA auto_vacuum;",
        "PRAGMA user_version;",
        "PRAGMA application_id;",
        "PRAGMA default_cache_size;",
        "PRAGMA freelist_count;",
        "PRAGMA page_count;",
        "PRAGMA schema_version",
    }, .as_is);
    try integrity(c, "header pragmas", "h.db");
}

/// 4. Full auto-vacuum.
fn fullAutoVacuum(c: *Check) !void {
    _ = try c.xqSql("f.db", "PRAGMA auto_vacuum=FULL; " ++ schema ++ " DROP TABLE e; DELETE FROM c;");
    try compare(c, "auto_vacuum=full", "f.db", &.{
        "PRAGMA auto_vacuum;",
        "PRAGMA page_count;",
        "PRAGMA freelist_count",
    }, .as_is);
    try integrity(c, "auto_vacuum=full", "f.db");
}

/// 4. Each journal mode in turn on one file.
fn journalModes(c: *Check) !void {
    // The shell turns on defensive mode, which refuses journal_mode=OFF.
    for ([_][]const u8{ "persist", "truncate", "off", "wal", "delete" }) |mode| {
        const sql = try std.fmt.allocPrint(c.arena, "PRAGMA journal_mode={s}; CREATE TABLE IF NOT EXISTS t(a); INSERT INTO t VALUES('{s}');", .{ mode, mode });
        const r = try c.run(&.{ c.cfg.xq, "sql", "j.db", ".dbconfig defensive off", sql }, .{});
        // grep -v '^ *defensive'
        var w: std.Io.Writer.Allocating = .init(c.arena);
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        while (it.next()) |line| {
            if (it.peek() == null and line.len == 0) break;
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "defensive")) continue;
            try w.writer.print("{s}\n", .{line});
        }
        const got = std.mem.trimEnd(u8, w.written(), "\n");
        if (!std.mem.eql(u8, got, mode)) c.fail("journal_mode={s}: {s}", .{ mode, got });
        try integrity(c, try std.fmt.allocPrint(c.arena, "journal_mode={s}", .{mode}), "j.db");
    }
    try compare(c, "journal modes", "j.db", &.{"SELECT group_concat(a) FROM t"}, .as_is);
}

/// 5. Errors found by integrity_check: a NULL in a NOT NULL column and a
/// missing index entry, made with writable_schema.
fn corruptFile(c: *Check) !void {
    for ([_][]const u8{
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b NOT NULL, c);
        \\CREATE INDEX t_c ON t(c);
        \\INSERT INTO t VALUES(1, 1, 10), (2, 2, 20), (3, 3, 30);
        \\PRAGMA writable_schema=ON;
        \\UPDATE sqlite_schema SET sql='CREATE TABLE t(a INTEGER PRIMARY KEY, b, c)' WHERE name='t';
        \\UPDATE sqlite_schema SET sql='CREATE INDEX t_c ON t(b)' WHERE name='t_c';
        ,
        "INSERT INTO t VALUES(4, NULL, 40);",
        \\PRAGMA writable_schema=ON;
        \\UPDATE sqlite_schema SET sql='CREATE TABLE t(a INTEGER PRIMARY KEY, b NOT NULL, c)' WHERE name='t';
        \\UPDATE sqlite_schema SET sql='CREATE INDEX t_c ON t(c)' WHERE name='t_c';
    }) |sql| _ = try c.sqlite3Args(&.{ "-cmd", ".dbconfig defensive off", "bad.db", sql });
    try compare(c, "corrupt file", "bad.db", &.{
        "PRAGMA integrity_check;",
        "PRAGMA quick_check;",
        "PRAGMA integrity_check(2)",
    }, .as_is);
}
