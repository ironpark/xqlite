//! Tests of the Zig API. Every test is leak-checked twice over: the API's
//! own allocations go to std.testing.allocator (the `gpa` of Db.open()),
//! and so does the engine's memory in test builds (malloc.zig).

const std = @import("std");
const xqlite = @import("../xqlite.zig");
const MemVfs = @import("xqlite_vfs").mem.MemVfs;

const testing = std.testing;
const gpa = testing.allocator;
const Db = xqlite.Db;
const Stmt = xqlite.Stmt;

fn memDb() !Db {
    return Db.open(gpa, testing.io, ":memory:", .{});
}

// ================================================================ basics

test "zig api: open, exec, execArgs, one, lastInsertRowid, changes" {
    var db = try memDb();
    defer db.close();
    try db.exec(
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INT);
        \\INSERT INTO t(name, n) VALUES('a', 1), ('b', 2);
    );
    try testing.expectEqual(@as(i64, 2), db.lastInsertRowid());
    try testing.expectEqual(@as(i64, 2), db.changes());
    try db.execArgs("INSERT INTO t(name, n) VALUES(?, ?)", .{ "c", 3 });
    try testing.expectEqual(@as(i64, 3), db.lastInsertRowid());
    try db.execArgs("UPDATE t SET n = n * 10 WHERE n >= ?", .{2});
    try testing.expectEqual(@as(i64, 2), db.changes());
    try testing.expectEqual(@as(i64, 5), db.totalChanges());
    try testing.expectEqual(@as(?i64, 50), try db.one(i64, "SELECT sum(n) FROM t WHERE id > ?", .{1}));
    try testing.expectEqual(@as(?i64, null), try db.one(i64, "SELECT n FROM t WHERE id = ?", .{99}));
}

test "zig api: prepare: one statement only" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT 1; -- trailing comment\n /* block */ ;  ");
    s.finalize();
    try testing.expectError(error.MultipleStatements, db.prepare("SELECT 1; SELECT 2"));
    try testing.expectError(error.EmptyStatement, db.prepare("  -- nothing\n"));
    try testing.expectEqualStrings("prepare: more than one statement; use exec() for scripts", blk: {
        _ = db.prepare("SELECT 1; SELECT 2") catch {};
        break :blk db.lastError().?.message;
    });
}

test "zig api: statement metadata" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE t(a INTEGER, b TEXT)");
    var s = try db.prepare("SELECT a AS Alpha, b FROM t WHERE a = :x OR b = @y");
    defer s.finalize();
    try testing.expectEqual(@as(usize, 2), s.columnCount());
    try testing.expectEqualStrings("Alpha", s.columnName(0));
    try testing.expectEqualStrings("TEXT", s.columnDecltype(1).?);
    try testing.expectEqual(@as(?usize, 0), s.columnIndex("alpha"));
    try testing.expectEqual(@as(usize, 2), s.parameterCount());
    try testing.expectEqualStrings(":x", s.parameterName(1).?);
    try testing.expectEqual(@as(?usize, 2), s.parameterIndex("@y"));
    try testing.expect(s.isReadOnly());
    try testing.expectEqualStrings("SELECT a AS Alpha, b FROM t WHERE a = :x OR b = @y", s.sql());
}

// =============================================================== binding

const Color = enum { red, green, blue };
const Level = enum(u8) {
    low = 1,
    high = 9,
    pub const xqlite_storage: xqlite.EnumStorage = .integer;
};

/// Bind `x` to `SELECT typeof(?1), quote(?1)` and check the result.
fn expectBound(db: *Db, x: anytype, want_type: []const u8, want_quote: []const u8) !void {
    var s = try db.prepare("SELECT typeof(?1), quote(?1)");
    defer s.finalize();
    try s.bind(.{x});
    try testing.expect(try s.step());
    const r = try s.row(struct { []const u8, []const u8 });
    testing.expectEqualStrings(want_type, r[0]) catch |e| {
        std.debug.print("bound {s}\n", .{@typeName(@TypeOf(x))});
        return e;
    };
    try testing.expectEqualStrings(want_quote, r[1]);
}

test "zig api: bind: every supported type" {
    var db = try memDb();
    defer db.close();
    try expectBound(&db, @as(i8, -5), "integer", "-5");
    try expectBound(&db, @as(u8, 255), "integer", "255");
    try expectBound(&db, @as(i16, -300), "integer", "-300");
    try expectBound(&db, @as(u32, 4000000000), "integer", "4000000000");
    try expectBound(&db, @as(i64, std.math.minInt(i64)), "integer", "-9223372036854775808");
    try expectBound(&db, @as(u64, std.math.maxInt(i64)), "integer", "9223372036854775807");
    try expectBound(&db, @as(i128, -7), "integer", "-7");
    try expectBound(&db, @as(u7, 100), "integer", "100");
    try expectBound(&db, 123, "integer", "123");
    try expectBound(&db, @as(f32, 1.5), "real", "1.5");
    try expectBound(&db, @as(f64, -0.25), "real", "-0.25");
    try expectBound(&db, 2.5, "real", "2.5");
    try expectBound(&db, true, "integer", "1");
    try expectBound(&db, false, "integer", "0");
    try expectBound(&db, "lit", "text", "'lit'");
    try expectBound(&db, @as([]const u8, "it's"), "text", "'it''s'");
    try expectBound(&db, @as([:0]const u8, "z"), "text", "'z'");
    var buf = "mutable".*;
    try expectBound(&db, @as([]u8, &buf), "text", "'mutable'");
    try expectBound(&db, xqlite.Blob.init("\x01\xff"), "blob", "X'01FF'");
    try expectBound(&db, xqlite.Blob.init(""), "blob", "X''");
    try expectBound(&db, xqlite.ZeroBlob{ .len = 3 }, "blob", "X'000000'");
    try expectBound(&db, null, "null", "NULL");
    try expectBound(&db, @as(?i64, null), "null", "NULL");
    try expectBound(&db, @as(?i64, 7), "integer", "7");
    try expectBound(&db, @as(??[]const u8, @as(?[]const u8, null)), "null", "NULL");
    try expectBound(&db, Color.green, "text", "'green'");
    try expectBound(&db, Level.high, "integer", "9");
    try expectBound(&db, xqlite.Value{ .integer = 1 }, "integer", "1");
    try expectBound(&db, xqlite.Value{ .float = 0.5 }, "real", "0.5");
    try expectBound(&db, xqlite.Value{ .text = "v" }, "text", "'v'");
    try expectBound(&db, xqlite.Value{ .blob = "\x00" }, "blob", "X'00'");
    try expectBound(&db, @as(xqlite.Value, .null), "null", "NULL");
}

test "zig api: bind: integers that do not fit" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT ?");
    defer s.finalize();
    try testing.expectError(error.IntegerOverflow, s.bind(.{@as(u64, std.math.maxInt(i64) + 1)}));
    try testing.expectError(error.IntegerOverflow, s.bind(.{@as(i128, std.math.maxInt(i64)) + 1}));
    try testing.expectEqual(xqlite.ResultCode.mismatch, db.lastError().?.code);
}

test "zig api: bind: by name, by position, counts" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT :a || '-' || @b || '-' || $c");
    defer s.finalize();
    try s.bind(.{ .c = 3, .a = "x", .b = 2.5 });
    try testing.expect(try s.step());
    try testing.expectEqualStrings("x-2.5-3", try s.column([]const u8, 0));
    // bind() resets: the statement can be bound again right away.
    try s.bind(.{ "p", "q", "r" });
    try testing.expect(try s.step());
    try testing.expectEqualStrings("p-q-r", try s.column([]const u8, 0));

    try testing.expectError(error.UnknownParameter, s.bind(.{ .a = 1, .b = 2, .nope = 3 }));
    try testing.expectError(error.ParameterCountMismatch, s.bind(.{ 1, 2 }));
    try testing.expectError(error.ParameterCountMismatch, s.bind(.{ .a = 1 }));
    try testing.expectEqualStrings("bind: the statement has 3 parameters, got 1 values", db.lastError().?.message);

    // Single parameters, and ?NNN numbering.
    s.reset();
    try s.bindName("@b", "B");
    try s.bindAt(1, "A");
    try s.bindAt(3, @as(xqlite.Value, .null));
    try testing.expect(try s.step());
    try testing.expectEqual(@as(?[]const u8, null), try s.column(?[]const u8, 0));
    try testing.expectError(error.UnknownParameter, s.bindName(":zz", 1));
    s.reset();
    try testing.expectError(error.Range, s.bindAt(4, 1));

    var s2 = try db.prepare("SELECT ?2, ?1");
    defer s2.finalize();
    try s2.bind(.{ "first", "second" });
    try testing.expect(try s2.step());
    try testing.expectEqualStrings("second", try s2.column([]const u8, 0));
}

// ================================================================= reads

test "zig api: column: typed reads, conversions, NULL and overflow" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT 300, -1, 2.75, 'text', x'0102', NULL, '42', 'green', 2, 0, x''");
    defer s.finalize();
    try testing.expect(try s.step());
    try testing.expectEqual(@as(i64, 300), try s.column(i64, 0));
    try testing.expectEqual(@as(u16, 300), try s.column(u16, 0));
    try testing.expectError(error.IntegerOverflow, s.column(u8, 0));
    try testing.expectError(error.IntegerOverflow, s.column(u64, 1));
    try testing.expectEqual(@as(i32, -1), try s.column(i32, 1));
    try testing.expectEqual(@as(f64, 2.75), try s.column(f64, 2));
    try testing.expectEqual(@as(f32, 2.75), try s.column(f32, 2));
    try testing.expectEqual(@as(i64, 2), try s.column(i64, 2));
    try testing.expectEqualStrings("text", try s.column([]const u8, 3));
    try testing.expectEqualStrings("text", try s.column([:0]const u8, 3));
    try testing.expectEqualSlices(u8, "\x01\x02", (try s.column(xqlite.Blob, 4)).data);
    try testing.expectError(error.UnexpectedNull, s.column(i64, 5));
    try testing.expectError(error.UnexpectedNull, s.column([]const u8, 5));
    try testing.expectEqual(@as(?i64, null), try s.column(?i64, 5));
    try testing.expectEqual(@as(i64, 42), try s.column(i64, 6));
    try testing.expectEqual(Color.green, try s.column(Color, 7));
    try testing.expectEqual(Color.blue, try s.column(Color, 8));
    try testing.expectError(error.InvalidEnum, s.column(Color, 3));
    try testing.expectError(error.InvalidEnum, s.column(Level, 0));
    try testing.expectEqual(true, try s.column(bool, 0));
    try testing.expectEqual(false, try s.column(bool, 9));
    try testing.expectEqualSlices(u8, "", (try s.column(xqlite.Blob, 10)).data);
    try testing.expectEqual(xqlite.Kind.blob, s.columnKind(10));
    try testing.expectError(error.ColumnIndexOutOfRange, s.column(i64, 11));

    try testing.expect((xqlite.Value{ .integer = 300 }).eql(try s.column(xqlite.Value, 0)));
    try testing.expect((xqlite.Value{ .float = 2.75 }).eql(try s.column(xqlite.Value, 2)));
    try testing.expect((xqlite.Value{ .text = "text" }).eql(try s.column(xqlite.Value, 3)));
    try testing.expect((xqlite.Value{ .blob = "\x01\x02" }).eql(try s.column(xqlite.Value, 4)));
    try testing.expect(@as(xqlite.Value, .null).eql(try s.column(xqlite.Value, 5)));
    try testing.expectEqual(xqlite.Kind.null, s.columnKind(5));
}

test "zig api: round trip through a table" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE r(i INTEGER, f REAL, t TEXT, b BLOB, n, e TEXT, l INTEGER, flag INTEGER)");
    const Row = struct {
        i: i64,
        f: f64,
        t: []const u8,
        b: xqlite.Blob,
        n: ?i64,
        e: Color,
        l: Level,
        flag: bool,
    };
    const in: Row = .{ .i = -9, .f = 3.5, .t = "héllo", .b = .init("\x00\x01\x02"), .n = null, .e = .blue, .l = .low, .flag = true };
    try db.execArgs("INSERT INTO r VALUES(?, ?, ?, ?, ?, ?, ?, ?)", .{ in.i, in.f, in.t, in.b, in.n, in.e, in.l, in.flag });
    try db.execArgs("INSERT INTO r VALUES(:i, :f, :t, :b, :n, :e, :l, :flag)", in);

    var s = try db.prepare("SELECT * FROM r");
    defer s.finalize();
    var count: usize = 0;
    var it = s.iterator(Row);
    while (try it.next()) |out| : (count += 1) {
        try testing.expectEqual(in.i, out.i);
        try testing.expectEqual(in.f, out.f);
        try testing.expectEqualStrings(in.t, out.t);
        try testing.expectEqualSlices(u8, in.b.data, out.b.data);
        try testing.expectEqual(in.n, out.n);
        try testing.expectEqual(in.e, out.e);
        try testing.expectEqual(in.l, out.l);
        try testing.expectEqual(in.flag, out.flag);
    }
    try testing.expectEqual(@as(usize, 2), count);
    // Enums were stored as text and as an integer respectively.
    try testing.expectEqual(@as(?[2]i64, .{ 2, 2 }), try db.one([2]i64, "SELECT count(*) FILTER (WHERE e = 'blue'), count(*) FILTER (WHERE l = 1) FROM r", .{}));
}

// ================================================================== rows

test "zig api: row: by name, by position, single column, errors" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT 1 AS ID, 'ada' AS name, NULL AS nick");
    defer s.finalize();
    try testing.expect(try s.step());

    const Named = struct { name: []const u8, id: u32, nick: ?[]const u8 };
    const n = try s.row(Named);
    try testing.expectEqual(@as(u32, 1), n.id);
    try testing.expectEqualStrings("ada", n.name);
    try testing.expectEqual(@as(?[]const u8, null), n.nick);

    const t = try s.row(struct { i64, []const u8 });
    try testing.expectEqual(@as(i64, 1), t[0]);
    try testing.expectEqualStrings("ada", t[1]);

    try testing.expectEqual(@as(i64, 1), try s.row(i64));
    try testing.expectError(error.ColumnNotFound, s.row(struct { missing: i64 }));
    try testing.expectError(error.ColumnIndexOutOfRange, s.row(struct { i64, i64, i64, i64 }));
    try testing.expectError(error.UnexpectedNull, s.row(struct { nick: []const u8 }));
    try testing.expectEqualStrings(
        "column 2 (nick) read as []const u8: UnexpectedNull",
        db.lastError().?.message,
    );
}

test "zig api: iterator: borrowed views and owned copies" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE w(word TEXT, n INT); INSERT INTO w VALUES('alpha', 1), ('beta', 2), ('gamma', 3)");

    const W = struct { word: []const u8, n: i64 };
    var owned: std.ArrayList(W) = .empty;
    defer {
        for (owned.items) |w| xqlite.free(gpa, w);
        owned.deinit(gpa);
    }
    {
        var s = try db.prepare("SELECT word, n FROM w ORDER BY n");
        defer s.finalize();
        var it = s.iterator(W);
        // Borrowed: valid until the next step; check it right away.
        const first = (try it.next()).?;
        try testing.expectEqualStrings("alpha", first.word);
        // Owned: survive the statement.
        while (try it.nextAlloc(gpa)) |w| try owned.append(gpa, w);
        try testing.expectEqual(@as(?W, null), try it.next());
    }
    try testing.expectEqual(@as(usize, 2), owned.items.len);
    try testing.expectEqualStrings("beta", owned.items[0].word);
    try testing.expectEqualStrings("gamma", owned.items[1].word);

    // Stmt.next() is the iterator without the cached mapping.
    var s = try db.prepare("SELECT count(*) FROM w");
    defer s.finalize();
    try testing.expectEqual(@as(?i64, 3), try s.next(i64));
    try testing.expectEqual(@as(?i64, null), try s.next(i64));
}

test "zig api: owned reads: columnAlloc, rowAlloc, oneAlloc, all" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE p(name TEXT, data BLOB, v); INSERT INTO p VALUES('x', x'00ff', 'tv'), ('y', NULL, 1.5)");

    const P = struct { name: [:0]const u8, data: ?xqlite.Blob, v: xqlite.Value };
    const one = (try db.oneAlloc(P, gpa, "SELECT * FROM p WHERE name = ?", .{"x"})).?;
    defer xqlite.free(gpa, one);
    try testing.expectEqualStrings("x", one.name);
    try testing.expectEqualSlices(u8, "\x00\xff", one.data.?.data);
    try testing.expectEqualStrings("tv", one.v.text);

    const rows = try db.all(P, gpa, "SELECT * FROM p ORDER BY name", .{});
    defer {
        for (rows) |r| xqlite.free(gpa, r);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(?xqlite.Blob, null), rows[1].data);
    try testing.expectEqual(@as(f64, 1.5), rows[1].v.float);

    var s = try db.prepare("SELECT name FROM p");
    defer s.finalize();
    _ = try s.step();
    const name = try s.columnAlloc([]u8, gpa, 0);
    defer gpa.free(name);
    name[0] = 'X';
    try testing.expectEqualStrings("X", name);
    const r = try s.rowAlloc(struct { []const u8 }, gpa);
    defer xqlite.free(gpa, r);
    try testing.expectEqualStrings("x", r[0]);

    // A failure part way through frees what was already copied.
    try testing.expectError(error.UnexpectedNull, db.oneAlloc(struct { name: []const u8, data: xqlite.Blob }, gpa, "SELECT * FROM p WHERE name = 'y'", .{}));
}

// ================================================================ errors

test "zig api: errors: error set, extended code, message, offset" {
    var db = try memDb();
    defer db.close();
    try testing.expectEqual(@as(?xqlite.ErrorInfo, null), db.lastError());

    try testing.expectError(error.Sql, db.exec("SELEC 1"));
    var e = db.lastError().?;
    try testing.expectEqual(xqlite.ResultCode.@"error", e.code);
    try testing.expectEqualStrings("near \"SELEC\": syntax error", e.message);
    try testing.expectEqual(@as(?usize, 0), e.offset);

    try testing.expectError(error.Sql, db.prepare("SELECT * FROM nowhere"));
    try testing.expectEqualStrings("no such table: nowhere", db.lastError().?.message);

    try db.exec("CREATE TABLE u(id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, CHECK (length(email) > 2))");
    try db.execArgs("INSERT INTO u(email) VALUES(?)", .{"a@b"});
    try testing.expectError(error.Constraint, db.execArgs("INSERT INTO u(email) VALUES(?)", .{"a@b"}));
    e = db.lastError().?;
    try testing.expectEqual(xqlite.ResultCode.constraint_unique, e.code);
    try testing.expectEqual(xqlite.ResultCode.constraint, e.code.primary());
    try testing.expectEqualStrings("UNIQUE constraint failed: u.email", e.message);
    try testing.expectError(error.Constraint, db.execArgs("INSERT INTO u(email) VALUES(?)", .{null}));
    try testing.expectEqual(xqlite.ResultCode.constraint_notnull, db.lastError().?.code);
    try testing.expectError(error.Constraint, db.execArgs("INSERT INTO u(email) VALUES(?)", .{"x"}));
    try testing.expectEqual(xqlite.ResultCode.constraint_check, db.lastError().?.code);

    // A success clears it.
    try db.exec("SELECT 1");
    try testing.expectEqual(@as(?xqlite.ErrorInfo, null), db.lastError());
}

test "zig api: errors: Diagnostics receive every failure, open included" {
    var diag: xqlite.Diagnostics = .{};
    // Opening a missing file without create fails before there is a
    // connection to ask.
    try testing.expectError(error.CantOpen, Db.open(gpa, testing.io, "missing.db", .{ .vfs = .memory, .create = false, .diagnostics = &diag }));
    try testing.expectEqual(xqlite.ResultCode.cantopen, diag.code);
    try testing.expectEqualStrings("unable to open database file", diag.message());

    var db = try Db.open(gpa, testing.io, ":memory:", .{ .diagnostics = &diag });
    defer db.close();
    try db.exec("CREATE TABLE t(a PRIMARY KEY)");
    try db.exec("INSERT INTO t VALUES(1)");
    var s = try db.prepare("INSERT INTO t VALUES(?)");
    defer s.finalize();
    try s.bind(.{1});
    try testing.expectError(error.Constraint, s.step());
    try testing.expectEqual(@as(?xqlite.Error, error.Constraint), diag.err);
    try testing.expectEqual(xqlite.ResultCode.constraint_primarykey, diag.code);
    try testing.expectEqualStrings("UNIQUE constraint failed: t.a", diag.message());
    // Diagnostics outlive the connection's message.
    try db.exec("SELECT 1");
    try testing.expectEqualStrings("UNIQUE constraint failed: t.a", diag.message());

    try testing.expectError(error.ColumnNotFound, db.oneAlloc(struct { b: i64 }, gpa, "SELECT a FROM t", .{}));
    try testing.expectEqual(@as(?xqlite.Error, error.ColumnNotFound), diag.err);
    try testing.expectEqual(xqlite.ResultCode.range, diag.code);
}

test "zig api: errors: read-only connection and busy lock" {
    var mem = MemVfs.init(gpa, testing.io);
    defer mem.deinit();
    {
        var w = try Db.open(gpa, testing.io, "shared.db", .{ .vfs = .{ .custom = mem.interface() } });
        defer w.close();
        try w.exec("CREATE TABLE t(a); INSERT INTO t VALUES(1)");

        var ro = try Db.open(gpa, testing.io, "shared.db", .{ .vfs = .{ .custom = mem.interface() }, .read_only = true });
        defer ro.close();
        try testing.expectEqual(@as(?i64, 1), try ro.one(i64, "SELECT a FROM t", .{}));
        try testing.expectError(error.ReadOnly, ro.exec("INSERT INTO t VALUES(2)"));

        // Another writer holds the lock: BUSY at once without a timeout.
        var other = try Db.open(gpa, testing.io, "shared.db", .{ .vfs = .{ .custom = mem.interface() } });
        defer other.close();
        try w.begin(.immediate);
        try testing.expectError(error.Busy, other.begin(.immediate));
        try testing.expectEqual(xqlite.ResultCode.busy, other.lastError().?.code);
        // With a timeout it still gives up once the time is spent.
        other.setBusyTimeout(5);
        try testing.expectError(error.Busy, other.exec("INSERT INTO t VALUES(3)"));
        try w.commit();
        try other.exec("INSERT INTO t VALUES(3)");
        try testing.expectEqual(@as(?i64, 2), try w.one(i64, "SELECT count(*) FROM t", .{}));
    }
}

test "zig api: close: unfinalized statements" {
    var db = try memDb();
    var s = try db.prepare("SELECT 1");
    try testing.expectError(error.Busy, db.tryClose());
    try testing.expectEqualStrings("unable to close due to unfinalized statements or unfinished backups", db.lastError().?.message);
    s.finalize();
    try db.tryClose();
}

// ========================================================== transactions

fn insertTwo(db: *Db, a: i64, b: i64) !void {
    try db.execArgs("INSERT INTO acct VALUES(?)", .{a});
    try db.execArgs("INSERT INTO acct VALUES(?)", .{b});
}

fn countRows(db: *Db) !i64 {
    return (try db.one(i64, "SELECT count(*) FROM acct", .{})).?;
}

const TxError = error{Refused};

fn refuse(db: *Db) (xqlite.Error || TxError)!u8 {
    try db.execArgs("INSERT INTO acct VALUES(?)", .{100});
    return error.Refused;
}

test "zig api: transactions: begin, commit, rollback, transaction()" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE acct(v INTEGER UNIQUE)");

    try db.begin(.deferred);
    try testing.expect(db.inTransaction());
    try db.execArgs("INSERT INTO acct VALUES(?)", .{1});
    try db.rollback();
    try testing.expect(!db.inTransaction());
    try testing.expectEqual(@as(i64, 0), try countRows(&db));

    try db.begin(.exclusive);
    try db.execArgs("INSERT INTO acct VALUES(?)", .{1});
    try db.commit();
    try testing.expectEqual(@as(i64, 1), try countRows(&db));

    // Commit on success.
    try db.transaction(.immediate, insertTwo, .{ &db, 2, 3 });
    try testing.expectEqual(@as(i64, 3), try countRows(&db));

    // Rollback on an engine error, which is kept as the last error.
    try testing.expectError(error.Constraint, db.transaction(.deferred, insertTwo, .{ &db, 4, 1 }));
    try testing.expectEqualStrings("UNIQUE constraint failed: acct.v", db.lastError().?.message);
    try testing.expectEqual(xqlite.ResultCode.constraint_unique, db.lastError().?.code);
    try testing.expect(!db.inTransaction());
    try testing.expectEqual(@as(i64, 3), try countRows(&db));

    // Rollback on an error of the caller's own error set.
    try testing.expectError(error.Refused, db.transaction(.deferred, refuse, .{&db}));
    try testing.expectEqual(@as(i64, 3), try countRows(&db));

    // Nested: the inner call becomes a savepoint, so its failure undoes
    // only its own work.
    try db.transaction(.deferred, struct {
        fn outer(d: *Db) !void {
            try d.execArgs("INSERT INTO acct VALUES(?)", .{50});
            try testing.expectError(error.Constraint, d.transaction(.immediate, insertTwo, .{ d, 51, 50 }));
            try testing.expect(d.inTransaction());
            try d.transaction(.immediate, insertTwo, .{ d, 52, 53 });
        }
    }.outer, .{&db});
    try testing.expectEqual(@as(?[2]i64, .{ 6, 50 + 52 + 53 + 1 + 2 + 3 }), try db.one([2]i64, "SELECT count(*), sum(v) FROM acct", .{}));

    // A function without errors.
    const r = try db.transaction(.deferred, struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f, .{21});
    try testing.expectEqual(@as(i32, 42), r);
}

fn savepointBatch(db: *Db) !void {
    var sp = try db.savepoint("batch");
    errdefer sp.rollback();
    try db.execArgs("INSERT INTO acct VALUES(?)", .{10});
    try db.execArgs("INSERT INTO acct VALUES(?)", .{1});
    try sp.release();
}

test "zig api: transactions: savepoints" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE acct(v INTEGER UNIQUE)");

    var outer = try db.savepoint("outer");
    try db.execArgs("INSERT INTO acct VALUES(?)", .{1});
    {
        var inner = try db.savepoint("in\"ner");
        try testing.expectEqualStrings("in\"ner", inner.name());
        try db.execArgs("INSERT INTO acct VALUES(?)", .{2});
        inner.rollback();
    }
    {
        var inner = try db.savepoint("kept");
        try db.execArgs("INSERT INTO acct VALUES(?)", .{3});
        try inner.release();
    }
    try testing.expect(db.inTransaction());
    try outer.release();
    try testing.expect(!db.inTransaction());
    try testing.expectEqual(@as(?[2]i64, .{ 2, 4 }), try db.one([2]i64, "SELECT count(*), sum(v) FROM acct", .{}));

    // errdefer pattern: the error that triggers the rollback survives it.
    try testing.expectError(error.Constraint, savepointBatch(&db));
    try testing.expectEqualStrings("UNIQUE constraint failed: acct.v", db.lastError().?.message);
    try testing.expect(!db.inTransaction());
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT count(*) FROM acct WHERE v = 10", .{}));
    try testing.expectError(error.NameTooLong, db.savepoint(&@as([65]u8, @splat('x'))));
}

// ============================================================= functions

fn add(a: i64, b: i64) i64 {
    return a + b;
}

fn greet(arena: std.mem.Allocator, name: ?[]const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "hello, {s}!", .{name orelse "nobody"});
}

fn half(x: f64) ?f64 {
    if (x < 0) return null;
    return x / 2;
}

fn checkedSqrt(x: f64) !f64 {
    if (x < 0) return error.NegativeArgument;
    return @sqrt(x);
}

fn joinAll(arena: std.mem.Allocator, args: xqlite.Args) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..args.len()) |i| {
        if (i > 0) try out.append(arena, ',');
        if (args.kind(i) == .null) {
            try out.appendSlice(arena, "∅");
        } else {
            try out.appendSlice(arena, try args.get([]const u8, i));
        }
    }
    return out.items;
}

const Counter = struct {
    calls: u32 = 0,
    fn bump(self: *Counter, by: u32) u32 {
        self.calls += by;
        return self.calls;
    }
};

fn toColor(name: []const u8) !Color {
    return std.meta.stringToEnum(Color, name) orelse error.UnknownColor;
}

fn bytesOf(b: xqlite.Blob) usize {
    return b.data.len;
}

fn nothing() void {}

test "zig api: functions: scalar, typed arguments and results" {
    var db = try memDb();
    defer db.close();
    try db.createFunction("my_add", {}, add, .{ .deterministic = true });
    try db.createFunction("greet", {}, greet, .{});
    try db.createFunction("half", {}, half, .{});
    try db.createFunction("checked_sqrt", {}, checkedSqrt, .{});
    try db.createFunction("join_all", {}, joinAll, .{});
    try db.createFunction("to_color", {}, toColor, .{});
    try db.createFunction("bytes_of", {}, bytesOf, .{});
    try db.createFunction("void_fn", {}, nothing, .{});
    var counter: Counter = .{};
    try db.createFunction("bump", &counter, Counter.bump, .{});

    try testing.expectEqual(@as(?i64, 5), try db.one(i64, "SELECT my_add(2, 3)", .{}));
    try testing.expectEqual(@as(?i64, 7), try db.one(i64, "SELECT my_add('3', 4.0)", .{}));
    const hello = (try db.oneAlloc([]const u8, gpa, "SELECT greet(?)", .{"zig"})).?;
    defer gpa.free(hello);
    try testing.expectEqualStrings("hello, zig!", hello);
    const nobody = (try db.oneAlloc([]const u8, gpa, "SELECT greet(NULL)", .{})).?;
    defer gpa.free(nobody);
    try testing.expectEqualStrings("hello, nobody!", nobody);
    try testing.expectEqual(@as(?f64, 1.5), try db.one(f64, "SELECT half(3)", .{}));
    try testing.expectEqual(@as(??f64, @as(?f64, null)), try db.one(?f64, "SELECT half(-3)", .{}));
    try testing.expectEqual(@as(?f64, 3), try db.one(f64, "SELECT checked_sqrt(9)", .{}));
    const joined = (try db.oneAlloc([]const u8, gpa, "SELECT join_all(1, 'b', NULL, 2.5)", .{})).?;
    defer gpa.free(joined);
    try testing.expectEqualStrings("1,b,∅,2.5", joined);
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT length(join_all())", .{}));
    try testing.expectEqual(@as(?Color, .red), try db.one(Color, "SELECT to_color('red')", .{}));
    try testing.expectEqual(@as(?i64, 3), try db.one(i64, "SELECT bytes_of(x'010203')", .{}));
    try testing.expectEqual(@as(?bool, true), try db.one(bool, "SELECT void_fn() IS NULL", .{}));
    try testing.expectEqual(@as(?u32, 2), try db.one(u32, "SELECT bump(2)", .{}));
    try testing.expectEqual(@as(?u32, 5), try db.one(u32, "SELECT bump(3)", .{}));
    try testing.expectEqual(@as(u32, 5), counter.calls);

    // Errors: of the function, of argument conversion, of arity.
    try testing.expectError(error.Sql, db.exec("SELECT checked_sqrt(-1)"));
    try testing.expectEqualStrings("NegativeArgument", db.lastError().?.message);
    try testing.expectError(error.Sql, db.exec("SELECT my_add(1, NULL)"));
    try testing.expectEqualStrings("argument 2: UnexpectedNull", db.lastError().?.message);
    try testing.expectError(error.Sql, db.exec("SELECT my_add(1)"));
    try testing.expectEqualStrings("wrong number of arguments to function my_add()", db.lastError().?.message);
    try testing.expectError(error.Sql, db.exec("SELECT to_color('mauve')"));
    try testing.expectEqualStrings("UnknownColor", db.lastError().?.message);

    // Replacing a function frees the old registration.
    try db.createFunction("my_add", {}, struct {
        fn sub(a: i64, b: i64) i64 {
            return a - b;
        }
    }.sub, .{});
    try testing.expectEqual(@as(?i64, -1), try db.one(i64, "SELECT my_add(2, 3)", .{}));
}

test "zig api: functions: deterministic functions in an index" {
    var db = try memDb();
    defer db.close();
    try db.createFunction("my_add", {}, add, .{ .deterministic = true });
    try db.createFunction("half", {}, half, .{});
    try db.exec("CREATE TABLE t(a, b); CREATE INDEX t_ab ON t(my_add(a, b))");
    try db.execArgs("INSERT INTO t VALUES(?, ?)", .{ 1, 2 });
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT count(*) FROM t WHERE my_add(a, b) = 3", .{}));
    try testing.expectError(error.Sql, db.exec("CREATE INDEX t_h ON t(half(a))"));
    try testing.expectEqualStrings("non-deterministic functions prohibited in index expressions", db.lastError().?.message);
}

// ============================================================ aggregates

const Sum = struct {
    total: i64 = 0,
    n: u32 = 0,

    pub fn step(self: *Sum, x: ?i64) void {
        if (x) |v| {
            self.total += v;
            self.n += 1;
        }
    }

    pub fn final(self: *Sum) ?i64 {
        return if (self.n == 0) null else self.total;
    }
};

/// group_concat with a heap buffer: exercises allocator, deinit and the
/// cleanup of abandoned groups.
const Concat = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn step(self: *Concat, gpa_: std.mem.Allocator, s: []const u8, sep: []const u8) !void {
        if (self.buf.items.len > 0) try self.buf.appendSlice(gpa_, sep);
        if (std.mem.eql(u8, s, "boom")) return error.Boom;
        try self.buf.appendSlice(gpa_, s);
    }

    pub fn final(self: *Concat) []const u8 {
        return self.buf.items;
    }

    pub fn deinit(self: *Concat, gpa_: std.mem.Allocator) void {
        self.buf.deinit(gpa_);
    }
};

/// A window-capable sum.
const WinSum = struct {
    total: f64 = 0,

    pub fn step(self: *WinSum, x: f64) void {
        self.total += x;
    }
    pub fn inverse(self: *WinSum, x: f64) void {
        self.total -= x;
    }
    pub fn value(self: *WinSum) f64 {
        return self.total;
    }
    pub fn final(self: *WinSum) f64 {
        return self.total;
    }
};

test "zig api: aggregates: sum, concat with allocator and deinit, window function" {
    var db = try memDb();
    defer db.close();
    try db.createAggregate("my_sum", Sum, .{ .deterministic = true });
    try db.createAggregate("my_concat", Concat, .{});
    try db.createAggregate("win_sum", WinSum, .{});
    try db.exec(
        \\CREATE TABLE g(k TEXT, v INTEGER);
        \\INSERT INTO g VALUES('a', 1), ('a', 2), ('b', 10), ('b', NULL), ('c', NULL);
    );

    const G = struct { k: []const u8, s: ?i64 };
    var s = try db.prepare("SELECT k, my_sum(v) AS s FROM g GROUP BY k ORDER BY k");
    defer s.finalize();
    var it = s.iterator(G);
    try testing.expectEqual(@as(?i64, 3), (try it.next()).?.s);
    try testing.expectEqual(@as(?i64, 10), (try it.next()).?.s);
    try testing.expectEqual(@as(?i64, null), (try it.next()).?.s);
    try testing.expectEqual(@as(?G, null), try it.next());

    // An empty input still calls final().
    try testing.expectEqual(@as(??i64, @as(?i64, null)), try db.one(?i64, "SELECT my_sum(v) FROM g WHERE 0", .{}));

    const c = (try db.oneAlloc([]const u8, gpa, "SELECT my_concat(k || v, '+') FROM g WHERE v IS NOT NULL", .{})).?;
    defer gpa.free(c);
    try testing.expectEqualStrings("a1+a2+b10", c);

    // A failing step: the error is reported and the state still freed
    // (std.testing.allocator would report the leak).
    try testing.expectError(error.Sql, db.exec("SELECT my_concat(x, ',') FROM (SELECT 'ok' AS x UNION ALL SELECT 'boom')"));
    try testing.expectEqualStrings("Boom", db.lastError().?.message);
    // A statement abandoned in the middle of a group.
    {
        var p = try db.prepare("SELECT k, my_concat(k, '') FROM g GROUP BY k");
        defer p.finalize();
        _ = try p.step();
    }

    const W = struct { f64 };
    const rows = try db.all(W, gpa, "SELECT win_sum(v) OVER (ORDER BY rowid ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM g WHERE v IS NOT NULL", .{});
    defer gpa.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(f64, 1), rows[0][0]);
    try testing.expectEqual(@as(f64, 3), rows[1][0]);
    try testing.expectEqual(@as(f64, 12), rows[2][0]);
}

// ============================================================ collations

fn reverseOrder(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, b, a);
}

const ByLength = struct {
    calls: usize = 0,
    fn cmp(self: *ByLength, a: []const u8, b: []const u8) std.math.Order {
        self.calls += 1;
        return std.math.order(a.len, b.len);
    }
};

test "zig api: collations: plain and with context" {
    var db = try memDb();
    defer db.close();
    try db.createCollation("reverse", {}, reverseOrder);
    var by_len: ByLength = .{};
    try db.createCollation("bylen", &by_len, ByLength.cmp);
    try db.exec("CREATE TABLE c(s TEXT); INSERT INTO c VALUES('bb'), ('a'), ('ccc')");

    const rows = try db.all([]const u8, gpa, "SELECT s FROM c ORDER BY s COLLATE reverse", .{});
    defer {
        for (rows) |r| gpa.free(r);
        gpa.free(rows);
    }
    try testing.expectEqualStrings("ccc", rows[0]);
    try testing.expectEqualStrings("bb", rows[1]);
    try testing.expectEqualStrings("a", rows[2]);

    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT count(*) FROM c WHERE s = 'xx' COLLATE bylen", .{}));
    try testing.expect(by_len.calls > 0);
    // Collations in the schema.
    try db.exec("CREATE TABLE d(s TEXT COLLATE bylen UNIQUE)");
    try db.exec("INSERT INTO d VALUES('ab')");
    try testing.expectError(error.Constraint, db.exec("INSERT INTO d VALUES('xy')"));
}

// ================================================== scripts and metadata

test "zig api: script: one statement at a time, empty ones skipped" {
    var db = try memDb();
    defer db.close();
    var it = try db.script("CREATE TABLE t(a INTEGER); ;; -- no statement\n INSERT INTO t VALUES(1), (2); SELECT sum(a) FROM t; /* end */");
    defer it.deinit();
    var sums: std.ArrayList(i64) = .empty;
    defer sums.deinit(gpa);
    var n: usize = 0;
    while (try it.next()) |stmt_| {
        var stmt = stmt_;
        defer stmt.finalize();
        n += 1;
        // Each statement is compiled after the one before ran: the INSERT
        // and SELECT see the table.
        while (try stmt.step()) try sums.append(gpa, try stmt.column(i64, 0));
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(i64, &.{3}, sums.items);
    try testing.expectEqual(@as(?Stmt, null), try it.next());

    // An error stops at the failing statement; the rest is still there.
    var bad = try db.script("SELECT 1; SELECT * FROM nope; SELECT 2");
    defer bad.deinit();
    var first = (try bad.next()).?;
    first.finalize();
    try testing.expectError(error.Sql, bad.next());
    try testing.expect(std.mem.indexOf(u8, bad.rest, "SELECT * FROM nope") != null);
}

test "zig api: columnOrigin and columnTypeAlloc" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name VARCHAR(20))");
    var stmt = try db.prepare("SELECT name AS n, id + 1, id FROM t");
    defer stmt.finalize();
    const o = stmt.columnOrigin(0).?;
    try testing.expectEqualStrings("main", o.database);
    try testing.expectEqualStrings("t", o.table);
    try testing.expectEqualStrings("name", o.column);
    try testing.expectEqual(@as(?xqlite.Origin, null), stmt.columnOrigin(1));
    const ty = (try stmt.columnTypeAlloc(gpa, 0)).?;
    defer gpa.free(ty.text);
    try testing.expectEqualStrings("VARCHAR(20)", ty.text);
    try testing.expectEqual(xqlite.Dialect.sqlite, ty.dialect);
    try testing.expectEqual(@as(?Stmt.TypeName, null), try stmt.columnTypeAlloc(gpa, 1));
    try testing.expect(!stmt.countsChanges());

    // A table of another dialect: its type in that dialect.
    if (!xqlite.Dialect.postgres.built()) return;
    var pg = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres, .column_metadata = true });
    defer pg.close();
    try pg.exec("CREATE TABLE t(name varchar(20), at timestamptz, flag boolean)");
    var q = try pg.prepare("SELECT name, at, flag, 1, NULL FROM t");
    defer q.finalize();
    // An expression: the type the statement gives it, in its dialect.
    for ([_]?[]const u8{ "character varying(20)", "timestamp with time zone", "boolean", "integer", null }, 0..) |want, i| {
        const got = try q.columnTypeAlloc(gpa, i);
        defer if (got) |g| gpa.free(g.text);
        if (want) |w| {
            try testing.expectEqualStrings(w, got.?.text);
            try testing.expectEqual(xqlite.Dialect.postgres, got.?.dialect);
        } else try testing.expectEqual(@as(?Stmt.TypeName, null), got);
    }
    const v0 = pg.schemaVersion("main").?;
    try pg.exec("CREATE TABLE u(a int)");
    try testing.expect(pg.schemaVersion("main").? != v0);
    try testing.expectEqual(@as(?u32, null), pg.schemaVersion("nope"));
    var ins = try pg.prepare("INSERT INTO u VALUES(1)");
    defer ins.finalize();
    try testing.expect(ins.countsChanges());
}

fn expectState(db: *Db, sql: []const u8, sqlstate: []const u8, number: ?u32) !void {
    if (db.exec(sql)) |_| {
        std.debug.print("{s}: no error\n", .{sql});
        return error.TestExpectedError;
    } else |_| {}
    const info = db.lastError().?;
    errdefer std.debug.print("{s}: {s} ({?s}, {?d})\n", .{ sql, info.message, if (info.sqlstate) |*x| x else null, info.dialect_number });
    try testing.expectEqualStrings(sqlstate, &(info.sqlstate orelse return error.NoSqlstate));
    try testing.expectEqual(number, info.dialect_number);
}

test "zig api: errors carry their SQLSTATE and the dialect's number" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE t(a INTEGER)");
    try expectState(&db, "SELECT * FROM nope", "42P01", null);
    try expectState(&db, "SELECT nope FROM t", "42703", null);
    try expectState(&db, "SELECT nofunc(1)", "42883", null);
    try expectState(&db, "SELEC 1", "42601", null);
    try expectState(&db, "CREATE TABLE t(a)", "42P07", null);
    try expectState(&db, "COMMIT", "25P01", null);
    try db.exec("BEGIN");
    try expectState(&db, "BEGIN", "25001", null);
    try db.exec("ROLLBACK");
    // Raised by an aggregate's final step.
    try expectState(&db, "SELECT sum(x) FROM (SELECT 9223372036854775807 AS x UNION ALL SELECT 1)", "22003", null);
    // An error the extended code tells apart has none.
    try db.exec("CREATE TABLE u(a UNIQUE); INSERT INTO u VALUES(1)");
    try testing.expectError(error.Constraint, db.exec("INSERT INTO u VALUES(1)"));
    try testing.expectEqual(@as(?[5]u8, null), db.lastError().?.sqlstate);

    const D = xqlite.Dialect;
    if (D.postgres.built()) {
        var pg = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres });
        defer pg.close();
        try pg.exec("CREATE TABLE t(id integer, s varchar(3))");
        try expectState(&pg, "SELECT * FROM nope", "42P01", null);
        try expectState(&pg, "SELEC 1", "42601", null);
        try expectState(&pg, "CREATE TABLE nosuch.x(a int)", "3F000", null);
        try expectState(&pg, "INSERT INTO t VALUES(1, 'abcd')", "22001", null);
        try expectState(&pg, "INSERT INTO t VALUES(3000000000, 'a')", "22003", null);
        try expectState(&pg, "SELECT mod(1, 0)", "22012", null);
        try expectState(&pg, "CREATE TABLE t(a int)", "42P07", null);
        try expectState(&pg, "SELECT sqrt(-1.0)", "2201F", null);
        try expectState(&pg, "SELECT jsonb_path_query('{\"a\": 1}', 'strict $.b')", "2203A", null);
        try expectState(&pg, "SELECT jsonb_path_query('{}', '$.a[')", "42601", null);
        try expectState(&pg, "SELECT $0", "42P02", null);
        try expectState(&pg, "SET nosuch_parameter = 1", "42704", null);
        try expectState(&pg, "SELECT 'x' FROM t LIMIT 1 LIMIT 2", "42601", null);
    }
    if (D.mariadb.built()) {
        var my = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mariadb });
        defer my.close();
        try my.exec("CREATE TABLE t(id INT, s VARCHAR(3))");
        try expectState(&my, "SELECT * FROM nope", "42P01", 1146);
        try expectState(&my, "SELECT nope FROM t", "42703", 1054);
        try expectState(&my, "SELEC 1", "42601", 1064);
        try expectState(&my, "CREATE TABLE t(a INT)", "42P07", 1050);
        try expectState(&my, "INSERT INTO t VALUES(1, 'abcd')", "22001", 1406);
        try expectState(&my, "CREATE DATABASE main", "42P04", 1007);
        try expectState(&my, "SELECT * FROM JSON_TABLE('[1', '$[*]' COLUMNS(a INT PATH '$')) AS j", "22032", 4038);
    }
    if (D.mssql.built()) {
        var ms = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mssql });
        defer ms.close();
        try ms.exec("CREATE TABLE t(id INT, s VARCHAR(3))");
        try expectState(&ms, "SELECT * FROM nope", "42P01", 208);
        try expectState(&ms, "SELECT nope FROM t", "42703", 207);
        try expectState(&ms, "SELEC 1", "42601", 102);
        try expectState(&ms, "COMMIT", "25P01", 3902);
        try expectState(&ms, "INSERT INTO t VALUES(1, 'abcd')", "22001", 2628);
        try expectState(&ms, "INSERT INTO t VALUES('x', 'a')", "22P02", 245);
        try expectState(&ms, "SELECT DATEADD(year, 9000, CAST('2000-01-01' AS datetime))", "22008", 517);
        try expectState(&ms, "SELECT * FROM OPENJSON('[1', '$')", "22032", 13609);
        try expectState(&ms, "SELECT JSON_VALUE('{\"a\": 1}', 'strict $.b')", "2203A", 13608);
        try expectState(&ms, "SELECT CONCAT('a')", "42883", 189);
        // xqlite's own "xqlite: ... is not supported".
        try expectState(&ms, "SET ROWCOUNT 1", "0A000", null);
    }
    if (D.oracle.built()) {
        var ora = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .oracle });
        defer ora.close();
        try ora.exec("CREATE TABLE t(id NUMBER(5), s VARCHAR2(3))");
        try expectState(&ora, "SELECT * FROM nope", "42P01", 942);
        try expectState(&ora, "SELECT nope FROM t", "42703", 904);
        try expectState(&ora, "INSERT INTO t VALUES(1, 'abcd')", "22001", 12899);
        try expectState(&ora, "INSERT INTO t VALUES('x', 'a')", "22P02", 1722);
        try expectState(&ora, "SELECT FROM dual", "42601", 936);
        try expectState(&ora, "SELECT 'abc FROM dual", "42601", 1756);
    }
}

test "zig api: each dialect's arithmetic errors and foreign keys" {
    const D = xqlite.Dialect;
    const Case = struct { d: D, div: ?[]const u8, div_n: ?u32, ovf: ?[]const u8, ovf_n: ?u32, from: []const u8 };
    const cases = [_]Case{
        .{ .d = .sqlite, .div = null, .div_n = null, .ovf = null, .ovf_n = null, .from = "" },
        .{ .d = .postgres, .div = "22012", .div_n = null, .ovf = "22003", .ovf_n = null, .from = "" },
        .{ .d = .mariadb, .div = null, .div_n = null, .ovf = "22003", .ovf_n = 1690, .from = "" },
        .{ .d = .mssql, .div = "22012", .div_n = 8134, .ovf = "22003", .ovf_n = 8115, .from = "" },
        .{ .d = .oracle, .div = "22012", .div_n = 1476, .ovf = null, .ovf_n = null, .from = " FROM dual" },
    };
    for (cases) |c| {
        if (!c.d.built()) continue;
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = c.d });
        defer db.close();
        var buf: [96]u8 = undefined;
        const div = try std.fmt.bufPrint(&buf, "SELECT 1 / 0{s}", .{c.from});
        if (c.div) |st| try expectState(&db, div, st, c.div_n) else try testing.expectEqual(@as(??i64, @as(?i64, null)), try db.one(?i64, div, .{}));
        var buf2: [96]u8 = undefined;
        const ovf = try std.fmt.bufPrint(&buf2, "SELECT 9223372036854775807 + 1{s}", .{c.from});
        if (c.ovf) |st| try expectState(&db, ovf, st, c.ovf_n) else _ = try db.one(f64, ovf, .{});
        // The dialects' databases enforce foreign keys; SQLite's only on
        // PRAGMA foreign_keys.
        try db.exec("CREATE TABLE p(id INT PRIMARY KEY)");
        try db.exec("CREATE TABLE c(pid INT, FOREIGN KEY (pid) REFERENCES p(id))");
        if (c.d == .sqlite) {
            try db.exec("INSERT INTO c VALUES(1)");
        } else {
            errdefer std.debug.print("{s}: no FK error\n", .{@tagName(c.d)});
            try testing.expectError(error.Constraint, db.exec("INSERT INTO c VALUES(1)"));
        }
    }
    // The setting the application makes stays.
    if (!D.postgres.built()) return;
    var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres });
    defer db.close();
    try db.exec("PRAGMA foreign_keys = OFF");
    try db.exec("CREATE TABLE p(id int PRIMARY KEY); CREATE TABLE c(pid int REFERENCES p(id)); INSERT INTO c VALUES(1)");
    // PostgreSQL's casts to an integer round and check the range.
    try testing.expectEqual(@as(?i64, 3), try db.one(i64, "SELECT 2.5::int", .{}));
    try testing.expectEqual(@as(?i64, -3), try db.one(i64, "SELECT (-2.5)::bigint", .{}));
    try testing.expectEqual(@as(?i64, 42), try db.one(i64, "SELECT ' 42 '::int", .{}));
    try expectState(&db, "SELECT '2.5'::int", "22P02", null);
    try expectState(&db, "SELECT 40000::smallint", "22003", null);
    try expectState(&db, "SELECT 3000000000::integer", "22003", null);
}

/// `sql` (with `args` bound) fails with `msg`, `sqlstate` and `number`.
fn expectFailure(db: *Db, sql: []const u8, args: anytype, msg: []const u8, sqlstate: []const u8, number: ?u32) !void {
    if (db.execArgs(sql, args)) |_| {
        std.debug.print("{s}: no error\n", .{sql});
        return error.TestExpectedError;
    } else |_| {}
    const info = db.lastError().?;
    errdefer std.debug.print("{s}: {s} ({?s}, {?d})\n", .{ sql, info.message, if (info.sqlstate) |*x| x else null, info.dialect_number });
    try testing.expectEqualStrings(msg, info.message);
    try testing.expectEqualStrings(sqlstate, &(info.sqlstate orelse return error.NoSqlstate));
    try testing.expectEqual(number, info.dialect_number);
}

test "zig api: integer arithmetic fails outside the range of its type" {
    const D = xqlite.Dialect;
    // SQLite's (and a bigint's) integers have 64 bits.
    {
        var db = try memDb();
        defer db.close();
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT 2147483647 + 1", .{}));
        try testing.expectEqual(@as(?i64, -2147483648), try db.one(i64, "SELECT -2147483647 - 1", .{}));
    }
    if (D.postgres.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres });
        defer db.close();
        const int4 = "integer out of range";
        const int2 = "smallint out of range";
        // An integer literal of 32 bits is an integer, so is its sum.
        try expectFailure(&db, "SELECT 2147483647 + 1", .{}, int4, "22003", null);
        try expectFailure(&db, "SELECT -2147483647 - 2", .{}, int4, "22003", null);
        try expectFailure(&db, "SELECT 65536 * 65536", .{}, int4, "22003", null);
        try expectFailure(&db, "SELECT -(-2147483647 - 1)", .{}, int4, "22003", null);
        try expectFailure(&db, "SELECT (-2147483647 - 1) / -1", .{}, int4, "22003", null);
        try testing.expectEqual(@as(?i64, 2147483647), try db.one(i64, "SELECT 2147483646 + 1", .{}));
        try testing.expectEqual(@as(?i64, -2147483648), try db.one(i64, "SELECT -2147483647 - 1", .{}));
        // A bigint operand makes a bigint.
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT 2147483647::bigint + 1", .{}));
        try testing.expectEqual(@as(?i64, 4294967296), try db.one(i64, "SELECT 65536 * 65536::int8", .{}));
        try expectFailure(&db, "SELECT 32767::smallint + 1::smallint", .{}, int2, "22003", null);
        try testing.expectEqual(@as(?i64, 32768), try db.one(i64, "SELECT 32767::smallint + 1", .{}));
        // The 64 bits of a bigint: SQLite's overflow.
        try expectFailure(&db, "SELECT 9223372036854775807 + 1", .{}, "bigint out of range", "22003", null);
        try db.exec("CREATE TABLE t (a int, s smallint, g bigint); INSERT INTO t VALUES (2147483647, 32767, 2147483647)");
        try expectFailure(&db, "SELECT a + 1 FROM t", .{}, int4, "22003", null);
        try expectFailure(&db, "SELECT s * s FROM t", .{}, int2, "22003", null);
        try testing.expectEqual(@as(?i64, 65534), try db.one(i64, "SELECT s * 2 FROM t", .{}));
        try expectFailure(&db, "UPDATE t SET g = a + 1", .{}, int4, "22003", null);
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT g + 1 FROM t", .{}));
        try testing.expectEqual(@as(?i64, 2147516414), try db.one(i64, "SELECT g + s FROM t", .{}));
        try expectFailure(&db, "SELECT a + s FROM t", .{}, int4, "22003", null);
        // sum() of integers is a bigint.
        try testing.expectEqual(@as(?i64, 4294967294), try db.one(i64, "SELECT sum(a) FROM (SELECT a FROM t UNION ALL SELECT a FROM t) x", .{}));
        // A parameter computed with an integer is an integer.
        try expectFailure(&db, "SELECT a + $1 FROM t", .{1}, int4, "22003", null);
        // A view computes as the statement that reads it.
        try db.exec("CREATE VIEW v AS SELECT a + 1 AS x FROM t");
        try expectFailure(&db, "SELECT x FROM v", .{}, int4, "22003", null);
    }
    if (D.mssql.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mssql });
        defer db.close();
        const msg = "Arithmetic overflow error converting expression to data type ";
        try expectFailure(&db, "SELECT 2147483647 + 1", .{}, msg ++ "int.", "22003", 8115);
        try expectFailure(&db, "SELECT CAST(32767 AS smallint) + CAST(1 AS smallint)", .{}, "Arithmetic overflow error for data type smallint, value = 32768.", "22003", 220);
        try expectFailure(&db, "SELECT CAST(255 AS tinyint) + CAST(1 AS tinyint)", .{}, "Arithmetic overflow error for data type tinyint, value = 256.", "22003", 220);
        try expectFailure(&db, "SELECT CAST(0 AS tinyint) - CAST(1 AS tinyint)", .{}, "Arithmetic overflow error for data type tinyint, value = -1.", "22003", 220);
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT CAST(2147483647 AS bigint) + 1", .{}));
        try db.exec("CREATE TABLE t (a INT); INSERT INTO t VALUES (2147483647), (1)");
        try expectFailure(&db, "SELECT a + 1 FROM t", .{}, msg ++ "int.", "22003", 8115);
        // SUM() of an int is an int.
        try expectFailure(&db, "SELECT SUM(a) FROM t", .{}, msg ++ "int.", "22003", 8115);
        try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT SUM(a) FROM t WHERE a = 1", .{}));
    }
    // MariaDB's INT arithmetic is a BIGINT's; Oracle's NUMBER has no width.
    if (D.mariadb.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mariadb });
        defer db.close();
        try db.exec("CREATE TABLE t (a INT); INSERT INTO t VALUES (2147483647)");
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT a + 1 FROM t", .{}));
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT 2147483647 + 1", .{}));
    }
    if (D.oracle.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .oracle });
        defer db.close();
        try testing.expectEqual(@as(?i64, 2147483648), try db.one(i64, "SELECT 2147483647 + 1 FROM dual", .{}));
    }
}

test "zig api: a string stored into a PostgreSQL boolean or numeric column" {
    if (!xqlite.Dialect.postgres.built()) return;
    var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres });
    defer db.close();
    try db.exec("CREATE TABLE t (id int, b boolean, n numeric(6,2))");
    try db.exec("INSERT INTO t VALUES (1, 'yes', '1.50'), (2, ' OFF ', ' 3 '), (3, 'T', '-2e1'), (4, 'of', '.5')");
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT b FROM t WHERE id = 1", .{}));
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT b FROM t WHERE id = 2", .{}));
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT b FROM t WHERE id = 3", .{}));
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT b FROM t WHERE id = 4", .{}));
    try testing.expectEqual(@as(?f64, 1.5), try db.one(f64, "SELECT n FROM t WHERE id = 1", .{}));
    try testing.expectEqual(@as(?i64, 3), try db.one(i64, "SELECT n FROM t WHERE id = 2 AND typeof(n) = 'integer'", .{}));
    try testing.expectEqual(@as(?f64, -20), try db.one(f64, "SELECT n FROM t WHERE id = 3", .{}));
    // Parameters bound as text (what the wire protocol sends).
    try db.execArgs("INSERT INTO t VALUES ($1, $2, $3)", .{ "5", "true", "12.25" });
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT b FROM t WHERE id = 5", .{}));
    try testing.expectEqual(@as(?f64, 12.25), try db.one(f64, "SELECT n FROM t WHERE id = 5", .{}));
    try db.execArgs("UPDATE t SET b = $1, n = $2 WHERE id = 5", .{ "f", "7" });
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT b FROM t WHERE id = 5", .{}));
    try testing.expectEqual(@as(?i64, 7), try db.one(i64, "SELECT n FROM t WHERE id = 5 AND typeof(n) = 'integer'", .{}));
    // INSERT ... SELECT, ON CONFLICT DO UPDATE.
    try db.exec("INSERT INTO t (id, b, n) SELECT 6, 'on', '0.25'");
    try testing.expectEqual(@as(?f64, 0.25), try db.one(f64, "SELECT n FROM t WHERE id = 6 AND b = 1", .{}));
    try db.exec("CREATE TABLE k (id int PRIMARY KEY, b boolean)");
    try db.exec("INSERT INTO k VALUES (1, 'no')");
    try db.exec("INSERT INTO k VALUES (1, 'no') ON CONFLICT (id) DO UPDATE SET b = 'yes'");
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT b FROM k", .{}));
    // Not a boolean, not a number.
    try expectFailure(&db, "INSERT INTO t (b) VALUES ('maybe')", .{}, "invalid input syntax for type boolean: \"maybe\"", "22P02", null);
    try expectFailure(&db, "INSERT INTO t (b) VALUES ($1)", .{"o"}, "invalid input syntax for type boolean: \"o\"", "22P02", null);
    try expectFailure(&db, "UPDATE t SET n = '1.2.3'", .{}, "invalid input syntax for type numeric: \"1.2.3\"", "22P02", null);
    try expectFailure(&db, "INSERT INTO t (n) VALUES ($1)", .{"abc"}, "invalid input syntax for type numeric: \"abc\"", "22P02", null);
    // An integer other than 0 and 1 is not a boolean (the column's check).
    try expectFailure(&db, "INSERT INTO t (b) VALUES (2)", .{}, "invalid input syntax for type boolean", "22P02", null);
    // SQLite's dialect stores what it is given (STRICT: not text).
    try db.exec("PRAGMA xq_dialect = 'sqlite'");
    try testing.expectError(error.Constraint, db.exec("INSERT INTO t (b) VALUES ('yes')"));
}

test "zig api: each dialect's constraint errors" {
    const D = xqlite.Dialect;
    // `coerced`: raised by the conversion of the value to the column's type
    // (an SQL function), not by the constraint.
    const Fail = struct { sql: []const u8, msg: []const u8, state: []const u8, number: ?u32 = null, coerced: bool = false };
    const Case = struct { d: D, ddl: []const u8, fails: []const Fail };
    const cases = [_]Case{
        .{ .d = .postgres, .ddl =
        \\CREATE TABLE p (id int PRIMARY KEY, code text, CONSTRAINT p_code_uq UNIQUE (code));
        \\CREATE TABLE c (id int PRIMARY KEY, pid int REFERENCES p (id), n int NOT NULL, q int CHECK (q > 0));
        \\CREATE UNIQUE INDEX c_q ON c (q);
        , .fails = &.{
            .{ .sql = "INSERT INTO p VALUES (1, 'b')", .msg = "duplicate key value violates unique constraint \"p_pkey\"", .state = "23505" },
            .{ .sql = "INSERT INTO p VALUES (2, 'a')", .msg = "duplicate key value violates unique constraint \"p_code_uq\"", .state = "23505" },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 1)", .msg = "duplicate key value violates unique constraint \"c_q\"", .state = "23505" },
            .{ .sql = "INSERT INTO c VALUES (2, 1, NULL, 2)", .msg = "null value in column \"n\" of relation \"c\" violates not-null constraint", .state = "23502" },
            .{ .sql = "UPDATE c SET n = NULL", .msg = "null value in column \"n\" of relation \"c\" violates not-null constraint", .state = "23502" },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 0)", .msg = "new row for relation \"c\" violates check constraint \"c_q_check\"", .state = "23514" },
            .{ .sql = "INSERT INTO c VALUES (2, 9, 1, 2)", .msg = "insert or update on table \"c\" violates foreign key constraint \"c_pid_fkey\"", .state = "23503" },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 2), (3, 9, 1, 3)", .msg = "insert or update on table \"c\" violates foreign key constraint \"c_pid_fkey\"", .state = "23503" },
            .{ .sql = "DELETE FROM p", .msg = "update or delete on table \"p\" violates foreign key constraint \"c_pid_fkey\" on table \"c\"", .state = "23503" },
        } },
        .{ .d = .mariadb, .ddl =
        \\CREATE TABLE p (id INT PRIMARY KEY, code VARCHAR(5), UNIQUE KEY uk (code));
        \\CREATE TABLE c (id INT PRIMARY KEY, pid INT, n INT NOT NULL, q INT CHECK (q > 0), a INT, b INT, UNIQUE KEY ab (a, b), FOREIGN KEY (pid) REFERENCES p (id));
        , .fails = &.{
            .{ .sql = "INSERT INTO p VALUES (1, 'b')", .msg = "Duplicate entry '1' for key 'PRIMARY'", .state = "23505", .number = 1062 },
            .{ .sql = "INSERT INTO p VALUES (2, 'a')", .msg = "Duplicate entry 'a' for key 'uk'", .state = "23505", .number = 1062 },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 1, 7, 8)", .msg = "Duplicate entry '7-8' for key 'ab'", .state = "23505", .number = 1062 },
            .{ .sql = "INSERT INTO c VALUES (2, 1, NULL, 1, 0, 0)", .msg = "Column 'n' cannot be null", .state = "23502", .number = 1048, .coerced = true },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 0, 0, 0)", .msg = "CONSTRAINT `q` failed for `main`.`c`", .state = "23514", .number = 4025 },
            .{ .sql = "INSERT INTO c VALUES (2, 9, 1, 1, 0, 0)", .msg = "Cannot add or update a child row: a foreign key constraint fails (`main`.`c`, CONSTRAINT `c_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `p` (`id`))", .state = "23503", .number = 1452 },
            .{ .sql = "DELETE FROM p", .msg = "Cannot delete or update a parent row: a foreign key constraint fails (`main`.`c`, CONSTRAINT `c_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `p` (`id`))", .state = "23503", .number = 1451 },
        } },
        .{ .d = .mssql, .ddl =
        \\CREATE TABLE p (id INT CONSTRAINT pk_p PRIMARY KEY, code VARCHAR(5) UNIQUE);
        \\CREATE TABLE c (id INT PRIMARY KEY, pid INT REFERENCES p (id), n INT NOT NULL, q INT CONSTRAINT ck_q CHECK (q > 0));
        \\CREATE UNIQUE INDEX ix_q ON c (q);
        , .fails = &.{
            .{ .sql = "INSERT INTO p VALUES (1, 'b')", .msg = "Violation of PRIMARY KEY constraint 'pk_p'. Cannot insert duplicate key in object 'dbo.p'. The duplicate key value is (1).", .state = "23505", .number = 2627 },
            .{ .sql = "INSERT INTO p VALUES (2, 'a')", .msg = "Violation of UNIQUE KEY constraint 'UQ__p__code'. Cannot insert duplicate key in object 'dbo.p'. The duplicate key value is (a).", .state = "23505", .number = 2627 },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 1)", .msg = "Cannot insert duplicate key row in object 'dbo.c' with unique index 'ix_q'. The duplicate key value is (1).", .state = "23505", .number = 2601 },
            .{ .sql = "INSERT INTO c VALUES (2, 1, NULL, 2)", .msg = "Cannot insert the value NULL into column 'n', table 'main.dbo.c'; column does not allow nulls. INSERT fails.", .state = "23502", .number = 515 },
            .{ .sql = "UPDATE c SET n = NULL", .msg = "Cannot insert the value NULL into column 'n', table 'main.dbo.c'; column does not allow nulls. UPDATE fails.", .state = "23502", .number = 515 },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 0)", .msg = "The INSERT statement conflicted with the CHECK constraint \"ck_q\". The conflict occurred in database \"main\", table \"dbo.c\".", .state = "23514", .number = 547 },
            .{ .sql = "INSERT INTO c VALUES (2, 9, 1, 2)", .msg = "The INSERT statement conflicted with the FOREIGN KEY constraint \"FK__c__pid\". The conflict occurred in database \"main\", table \"dbo.p\", column 'id'.", .state = "23503", .number = 547 },
            .{ .sql = "DELETE FROM p", .msg = "The DELETE statement conflicted with the REFERENCE constraint \"FK__c__pid\". The conflict occurred in database \"main\", table \"dbo.c\", column 'pid'.", .state = "23503", .number = 547 },
        } },
        .{ .d = .oracle, .ddl =
        \\CREATE TABLE p (id NUMBER CONSTRAINT p_pk PRIMARY KEY, code VARCHAR2(5) UNIQUE);
        \\CREATE TABLE c (id NUMBER PRIMARY KEY, pid NUMBER CONSTRAINT c_fk REFERENCES p (id), n NUMBER NOT NULL, q NUMBER CONSTRAINT q_ck CHECK (q > 0));
        , .fails = &.{
            .{ .sql = "INSERT INTO p VALUES (1, 'b')", .msg = "ORA-00001: unique constraint (MAIN.P_PK) violated", .state = "23505", .number = 1 },
            .{ .sql = "INSERT INTO p VALUES (2, 'a')", .msg = "ORA-00001: unique constraint (MAIN.SYS_C_P_CODE) violated", .state = "23505", .number = 1 },
            .{ .sql = "INSERT INTO c VALUES (2, 1, NULL, 2)", .msg = "ORA-01400: cannot insert NULL into (\"MAIN\".\"C\".\"N\")", .state = "23502", .number = 1400, .coerced = true },
            .{ .sql = "INSERT INTO c VALUES (2, 1, 1, 0)", .msg = "ORA-02290: check constraint (MAIN.Q_CK) violated", .state = "23514", .number = 2290 },
            .{ .sql = "INSERT INTO c VALUES (2, 9, 1, 2)", .msg = "ORA-02291: integrity constraint (MAIN.C_FK) violated - parent key not found", .state = "23503", .number = 2291 },
            .{ .sql = "DELETE FROM p", .msg = "ORA-02292: integrity constraint (MAIN.C_FK) violated - child record found", .state = "23503", .number = 2292 },
        } },
    };
    for (cases) |c| {
        if (!c.d.built()) continue;
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = c.d });
        defer db.close();
        try db.exec(c.ddl);
        try db.exec("INSERT INTO p VALUES (1, 'a')");
        try db.exec(if (c.d == .mariadb) "INSERT INTO c VALUES (1, 1, 1, 1, 7, 8)" else "INSERT INTO c VALUES (1, 1, 1, 1)");
        for (c.fails) |f| {
            errdefer std.debug.print("{s}: {s}\n", .{ @tagName(c.d), f.sql });
            try expectState(&db, f.sql, f.state, f.number);
            try testing.expectEqualStrings(f.msg, db.lastError().?.message);
            if (!f.coerced) try testing.expectEqual(xqlite.ResultCode.constraint, db.lastError().?.code.primary());
        }
        // A statement compiled in SQLite's dialect keeps SQLite's error.
        try db.exec("PRAGMA xq_dialect = 'sqlite'");
        try testing.expectError(error.Constraint, db.exec("INSERT INTO p VALUES (1, 'x')"));
        try testing.expect(std.mem.endsWith(u8, db.lastError().?.message, "constraint failed: p.id") or std.mem.endsWith(u8, db.lastError().?.message, "constraint failed: P.ID"));
        try testing.expectEqual(@as(?[5]u8, null), db.lastError().?.sqlstate);
    }
}

/// Column `i` of the first row of `sql` as `db`'s dialect shows it (the
/// text in `buf`).
fn shown(db: *Db, cols: *xqlite.display.Columns, sql: []const u8, i: usize, buf: []u8) ![]const u8 {
    var s = try db.prepare(sql);
    defer s.finalize();
    try testing.expect(try s.step());
    const cell = try s.column(xqlite.Value, i);
    var tbuf: [xqlite.display.max_len]u8 = undefined;
    const t = (try cols.ofStmt(&s, i)) orelse return std.fmt.bufPrint(buf, "{f}", .{fmtCell(cell)});
    const z = xqlite.display.text(db.dialect(), t.type, cell, &tbuf) orelse return std.fmt.bufPrint(buf, "{f}", .{fmtCell(cell)});
    return std.fmt.bufPrint(buf, "{s}", .{z});
}

fn fmtCell(c: xqlite.Value) std.fmt.Alt(xqlite.Value, writeCell) {
    return .{ .data = c };
}

fn writeCell(c: xqlite.Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (c) {
        .null => try w.writeAll("NULL"),
        .integer => |v| try w.print("{d}", .{v}),
        .float => |v| try w.print("{d}", .{v}),
        .text, .blob => |v| try w.writeAll(v),
    }
}

test "zig api: values as the dialect shows them, of columns and expressions" {
    const D = xqlite.Dialect;
    var buf: [64]u8 = undefined;
    if (D.postgres.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres, .column_metadata = true });
        defer db.close();
        var cols: xqlite.display.Columns = .init(gpa);
        defer cols.deinit();
        try db.exec("CREATE TABLE t (a int, b int, ok boolean, n numeric(6,2), ts timestamptz)");
        try db.exec("INSERT INTO t VALUES (1, 2, true, 1.5, '2024-01-02 03:04:05')");
        const cases = [_]struct { []const u8, []const u8 }{
            .{ "SELECT ok FROM t", "t" },
            .{ "SELECT n FROM t", "1.50" },
            .{ "SELECT ts FROM t", "2024-01-02 03:04:05+00" },
            .{ "SELECT a = b FROM t", "f" },
            .{ "SELECT true", "t" },
            .{ "SELECT a < b AND ok FROM t", "t" },
            .{ "SELECT a IS NULL FROM t", "f" },
            .{ "SELECT 2.5::numeric(6,2)", "2.50" },
            .{ "SELECT x FROM (SELECT a = b AS x FROM t) s", "f" },
            .{ "SELECT x FROM (SELECT DISTINCT a = b AS x FROM t LIMIT 1) s", "f" },
            .{ "SELECT a + b FROM t", "3" },
        };
        for (cases) |c| {
            errdefer std.debug.print("{s}\n", .{c[0]});
            try testing.expectEqualStrings(c[1], try shown(&db, &cols, c[0], 0, &buf));
        }
        // The declared type of an expression is its dialect's: a + b of
        // two integers is an integer, as PostgreSQL's operator gives it
        // (the dialect's typing rules, sql/typing.zig).
        var s = try db.prepare("SELECT a = b, a + b FROM t");
        defer s.finalize();
        try testing.expectEqualStrings("boolean", s.columnDecltype(0).?);
        try testing.expectEqualStrings("integer", s.columnDecltype(1).?);
    }
    if (D.mariadb.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mariadb, .column_metadata = true });
        defer db.close();
        var cols: xqlite.display.Columns = .init(gpa);
        defer cols.deinit();
        try db.exec("CREATE TABLE t (b BOOLEAN, d DECIMAL(6,2))");
        try db.exec("INSERT INTO t VALUES (TRUE, 220)");
        try testing.expectEqualStrings("1", try shown(&db, &cols, "SELECT b FROM t", 0, &buf));
        try testing.expectEqualStrings("220.00", try shown(&db, &cols, "SELECT d FROM t", 0, &buf));
        try testing.expectEqualStrings("2.50", try shown(&db, &cols, "SELECT CAST(2.5 AS DECIMAL(6,2))", 0, &buf));
    }
    if (D.oracle.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .oracle, .column_metadata = true });
        defer db.close();
        var cols: xqlite.display.Columns = .init(gpa);
        defer cols.deinit();
        try db.exec("CREATE TABLE t (b BOOLEAN, n NUMBER(6,2))");
        try db.exec("INSERT INTO t VALUES (TRUE, 1.5)");
        try testing.expectEqualStrings("TRUE", try shown(&db, &cols, "SELECT b FROM t", 0, &buf));
        try testing.expectEqualStrings("1.5", try shown(&db, &cols, "SELECT n FROM t", 0, &buf));
    }
    // SQLite's: as stored, and no declared type for an expression.
    var db = try Db.open(gpa, testing.io, ":memory:", .{ .column_metadata = true });
    defer db.close();
    var cols: xqlite.display.Columns = .init(gpa);
    defer cols.deinit();
    try db.exec("CREATE TABLE t (ok BOOLEAN, n NUMERIC(6,2)); INSERT INTO t VALUES (1, 1.5)");
    try testing.expectEqualStrings("1", try shown(&db, &cols, "SELECT ok FROM t", 0, &buf));
    try testing.expectEqualStrings("1.5", try shown(&db, &cols, "SELECT n FROM t", 0, &buf));
    var s = try db.prepare("SELECT 1 = 1");
    defer s.finalize();
    try testing.expectEqual(@as(?[:0]const u8, null), s.columnDecltype(0));
}

/// The declared type of column `i` of `sql` (prepared, not run).
fn expectDecltype(db: *Db, sql: []const u8, i: usize, want: ?[]const u8) !void {
    errdefer std.debug.print("{s}\n", .{sql});
    var s = try db.prepare(sql);
    defer s.finalize();
    if (want) |w| {
        try testing.expectEqualStrings(w, s.columnDecltype(i) orelse return error.TestExpectedEqual);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), s.columnDecltype(i));
    }
}

test "zig api: types of expressions through subqueries, CTEs, views and compounds" {
    if (!xqlite.Dialect.postgres.built()) return;
    var buf: [64]u8 = undefined;
    var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres, .column_metadata = true });
    defer db.close();
    var cols: xqlite.display.Columns = .init(gpa);
    defer cols.deinit();
    try db.exec("CREATE TABLE t (a int, b int, ok boolean, n numeric(6,2))");
    try db.exec("INSERT INTO t VALUES (1, 2, true, 1.5)");
    // (PostgreSQL's frontend keeps the scale of a cast to numeric, not
    // its precision: numeric(38,2).)
    // A view stores SQLite text: a comparison is typed again when the
    // view is compiled into a statement, a cast lowered to SQLite's
    // (CAST(round(2.5, 2) AS NUMERIC)) has lost its target type.
    try db.exec("CREATE VIEW v AS SELECT a = b AS x, 2.5::numeric(6,2) AS y, a < b AND ok AS z FROM t");
    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        // FROM subqueries, flattened or not.
        .{ "SELECT y FROM (SELECT 2.5::numeric(6,2) AS y) s", "2.50", "numeric(38,2)" },
        .{ "SELECT x FROM (SELECT DISTINCT a = b AS x FROM t LIMIT 1) s", "f", "boolean" },
        // CTEs.
        .{ "WITH c AS (SELECT a = b AS x FROM t) SELECT x FROM c", "f", "boolean" },
        .{ "WITH c AS (SELECT 2.5::numeric(6,2) AS y) SELECT y FROM c", "2.50", "numeric(38,2)" },
        .{ "WITH RECURSIVE r(x) AS (SELECT true UNION ALL SELECT NOT x FROM r LIMIT 3) SELECT x FROM r", "t", "boolean" },
        // Scalar subqueries: the type of their column.
        .{ "SELECT (SELECT a = b FROM t)", "f", "boolean" },
        .{ "SELECT (SELECT 2.5::numeric(6,2))", "2.50", "numeric(38,2)" },
        // Views.
        .{ "SELECT x FROM v", "f", "boolean" },
        .{ "SELECT z FROM v", "t", "boolean" },
        .{ "SELECT y FROM v", "2.5", null },
        // A compound is of the common type of its terms (integers of the
        // widest, an integer and a numeric a numeric); of none if they
        // have none (PostgreSQL fails: UNION types boolean and integer
        // cannot be matched), so a boolean with an integer is shown as
        // stored.
        .{ "SELECT a = b FROM t UNION ALL SELECT 2", "0", null },
        .{ "SELECT 2 UNION ALL SELECT a = b FROM t", "2", null },
        .{ "SELECT x FROM (SELECT a = b AS x FROM t UNION ALL SELECT 2) s", "0", null },
        .{ "SELECT a = b FROM t UNION ALL SELECT NULL", "f", "boolean" },
        .{ "SELECT 1 UNION ALL SELECT 2::bigint", "1", "bigint" },
        // A numeric value keeps its own scale in PostgreSQL: the common
        // type of 1 and 2.50 is a numeric of no one scale.
        .{ "SELECT x FROM (SELECT 1 AS x UNION ALL SELECT 2.50) s ORDER BY x LIMIT 1", "1", "numeric" },
        .{ "SELECT (SELECT 1.50 UNION SELECT 2.25 ORDER BY 1 LIMIT 1)", "1.50", "numeric" },
        .{ "VALUES (1), (2.25)", "1", "numeric" },
        // COLLATE keeps the type.
        .{ "SELECT (a = b) COLLATE \"C\" FROM t", "f", "boolean" },
    };
    for (cases) |c| {
        errdefer std.debug.print("{s}\n", .{c[0]});
        try testing.expectEqualStrings(c[1], try shown(&db, &cols, c[0], 0, &buf));
        try expectDecltype(&db, c[0], 0, c[2]);
    }
    // The type is kept with the statement as a Type.
    var s = try db.prepare("SELECT y FROM (SELECT 2.5::numeric(6,2) AS y) s");
    defer s.finalize();
    try testing.expectEqual(xqlite.types.Type{ .logical = .numeric, .precision = 38, .scale = 2 }, (try cols.ofStmt(&s, 0)).?.type);
    // SQLite's dialect types nothing, not even the same view.
    db.setDialect(.sqlite);
    try expectDecltype(&db, "SELECT x FROM v", 0, null);
    try expectDecltype(&db, "SELECT (SELECT 1 = 1)", 0, null);
}

/// A case of typesOfExpressions(): a query, its first column's value as
/// the dialect shows it, and its declared type.
const TypeCase = struct { []const u8, []const u8, ?[]const u8 };

fn expectTypes(d: xqlite.Dialect, ddl: []const u8, cases: []const TypeCase) !void {
    if (!d.built()) return;
    var buf: [64]u8 = undefined;
    var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = d, .column_metadata = true });
    defer db.close();
    var cols: xqlite.display.Columns = .init(gpa);
    defer cols.deinit();
    try db.exec(ddl);
    for (cases) |c| {
        errdefer std.debug.print("{t}: {s}\n", .{ d, c[0] });
        try testing.expectEqualStrings(c[1], try shown(&db, &cols, c[0], 0, &buf));
        try expectDecltype(&db, c[0], 0, c[2]);
    }
}

test "zig api: types of literals, operators and functions in each dialect" {
    // PostgreSQL: integers in the wider type, a numeric of the scale of
    // its values (shown with as many digits), real only with real.
    try expectTypes(.postgres,
        \\CREATE TABLE t (a int, b bigint, s smallint, n numeric(6,2), f float8, r real, x text, ts timestamptz);
        \\INSERT INTO t VALUES (1, 2, 3, 1.5, 0.5, 0.25, 'x', '2024-01-02 03:04:05');
    , &.{
        .{ "SELECT 1", "1", "integer" },
        .{ "SELECT 3000000000", "3000000000", "bigint" },
        .{ "SELECT 1.50", "1.50", "numeric" },
        .{ "SELECT 0.1 + 0.2", "0.3", "numeric" },
        .{ "SELECT 1e3", "1000", "numeric" },
        .{ "SELECT 'abc'", "abc", "text" },
        .{ "SELECT NULL", "NULL", null },
        .{ "SELECT a + a FROM t", "2", "integer" },
        .{ "SELECT a + b FROM t", "3", "bigint" },
        .{ "SELECT s + s FROM t", "6", "smallint" },
        .{ "SELECT a / 2 FROM t", "0", "integer" },
        .{ "SELECT a + '1' FROM t", "2", "integer" },
        .{ "SELECT n + 1 FROM t", "2.50", "numeric" },
        .{ "SELECT n * n FROM t", "2.2500", "numeric" },
        .{ "SELECT 1.50::numeric(6,2) + 1", "2.50", "numeric" },
        .{ "SELECT -n FROM t", "-1.50", "numeric(6,2)" },
        // Division picks its scale per value in PostgreSQL: none known.
        .{ "SELECT n / 3 FROM t", "0.5", "numeric" },
        .{ "SELECT f + a FROM t", "1.5", "double precision" },
        .{ "SELECT r * r FROM t", "0.0625", "real" },
        .{ "SELECT r + f FROM t", "0.75", "double precision" },
        .{ "SELECT 'a' || x FROM t", "ax", "text" },
        .{ "SELECT count(*) FROM t", "1", "bigint" },
        .{ "SELECT sum(a) FROM t", "1", "bigint" },
        .{ "SELECT sum(b) FROM t", "2", "numeric" },
        .{ "SELECT sum(n) FROM t", "1.50", "numeric" },
        .{ "SELECT avg(a) FROM t", "1", "numeric" },
        .{ "SELECT max(n) FROM t", "1.50", "numeric(6,2)" },
        .{ "SELECT length(x) FROM t", "1", "integer" },
        .{ "SELECT upper(x) FROM t", "X", "text" },
        .{ "SELECT round(n, 1) FROM t", "1.5", "numeric" },
        .{ "SELECT round(2.567, 2)", "2.57", "numeric" },
        .{ "SELECT round(2.5)", "3", "numeric" },
        .{ "SELECT abs(n) FROM t", "1.50", "numeric(6,2)" },
        .{ "SELECT coalesce(a, b) FROM t", "1", "bigint" },
        .{ "SELECT CASE WHEN a > 0 THEN n END FROM t", "1.50", "numeric(6,2)" },
        .{ "SELECT CASE WHEN a > 0 THEN 1 ELSE 2.5 END FROM t", "1", "numeric" },
        .{ "SELECT row_number() OVER () FROM t", "1", "bigint" },
        .{ "SELECT (SELECT a + b FROM t)", "3", "bigint" },
        // Dates, timestamps and intervals by their operators' rows.
        .{ "SELECT ts + interval '1 day' FROM t", "2024-01-03 03:04:05+00", "timestamp with time zone" },
        .{ "SELECT ts - ts FROM t", "00:00:00", "interval" },
        .{ "SELECT date '2024-01-31' + 1", "2024-02-01", "date" },
        .{ "SELECT date '2024-03-01' - date '2024-02-01'", "29", "integer" },
        .{ "SELECT date '2024-01-31' + interval '1 month'", "2024-02-29 00:00:00", "timestamp without time zone" },
        .{ "SELECT interval '1 day' * 2", "2 days", "interval" },
    });
    // MariaDB: integer arithmetic in BIGINT, `/` a DECIMAL of 4 more
    // digits, DECIMAL(p,s) shown with its s digits.
    try expectTypes(.mariadb,
        \\CREATE TABLE t (a INT, d DECIMAL(6,2), f DOUBLE, x VARCHAR(5));
        \\INSERT INTO t VALUES (7, 1.5, 0.5, 'x');
    , &.{
        .{ "SELECT 1", "1", "int" },
        .{ "SELECT 1.50", "1.50", "decimal(3,2)" },
        .{ "SELECT 'abc'", "abc", "varchar(3)" },
        .{ "SELECT a + a FROM t", "14", "bigint" },
        .{ "SELECT a / 2 FROM t", "3.5000", "decimal(14,4)" },
        .{ "SELECT 7 / 2", "3.5000", "decimal(14,4)" },
        .{ "SELECT a DIV 2 FROM t", "3", "bigint" },
        .{ "SELECT d + 1 FROM t", "2.50", "decimal(13,2)" },
        .{ "SELECT d * d FROM t", "2.2500", "decimal(12,4)" },
        .{ "SELECT d / 2 FROM t", "0.750000", "decimal(10,6)" },
        .{ "SELECT a + f FROM t", "7.5", "double" },
        .{ "SELECT count(*) FROM t", "1", "bigint" },
        .{ "SELECT avg(a) FROM t", "7.0000", "decimal(14,4)" },
        .{ "SELECT sum(d) FROM t", "1.50", "decimal(28,2)" },
        .{ "SELECT avg(d) FROM t", "1.500000", "decimal(10,6)" },
        .{ "SELECT round(2.567, 2)", "2.57", "decimal(4,2)" },
        .{ "SELECT CHAR_LENGTH(x) FROM t", "1", "int" },
        .{ "SELECT UPPER(x) FROM t", "X", "varchar(5)" },
        .{ "SELECT CONCAT(x, 'yz') FROM t", "xyz", "varchar(7)" },
        .{ "SELECT CASE WHEN a > 0 THEN d ELSE 1 END FROM t", "1.50", "decimal(12,2)" },
    });
    // SQL Server: an int stays an int, decimals by its precision and
    // scale rules.
    try expectTypes(.mssql,
        \\CREATE TABLE t (i INT, b BIGINT, d DECIMAL(5,2), f FLOAT, x VARCHAR(5));
        \\INSERT INTO t VALUES (7, 2, 1.5, 0.5, 'x');
    , &.{
        .{ "SELECT 1", "1", "int" },
        .{ "SELECT 1.50", "1.50", "numeric(3,2)" },
        .{ "SELECT 'abc'", "abc", "varchar(3)" },
        .{ "SELECT i / 2 FROM t", "3", "int" },
        .{ "SELECT i + b FROM t", "9", "bigint" },
        .{ "SELECT 7 / 2.0", "3.500000", "numeric(17,6)" },
        .{ "SELECT d * 2 FROM t", "3.00", "numeric(16,2)" },
        .{ "SELECT d + f FROM t", "2", "float" },
        .{ "SELECT x + 'yz' FROM t", "xyz", "varchar(7)" },
        .{ "SELECT COUNT(*) FROM t", "1", "int" },
        .{ "SELECT AVG(d) FROM t", "1.500000", "numeric(38,6)" },
        .{ "SELECT SUM(d) FROM t", "1.50", "numeric(38,2)" },
        .{ "SELECT LEN(x) FROM t", "1", "int" },
        .{ "SELECT UPPER(x) FROM t", "X", "varchar(5)" },
        .{ "SELECT ISNULL(d, 0) FROM t", "1.50", "decimal(5,2)" },
    });
    // Oracle: NUMBER everywhere (shown without trailing zeros).
    try expectTypes(.oracle,
        \\CREATE TABLE t (n NUMBER(6,2), i NUMBER(5), s VARCHAR2(5), f BINARY_DOUBLE);
        \\INSERT INTO t VALUES (1.5, 7, 'ab', 0.5);
    , &.{
        .{ "SELECT 1 FROM dual", "1", "NUMBER" },
        .{ "SELECT 'abc' FROM dual", "abc", "CHAR(3)" },
        .{ "SELECT n + 1 FROM t", "2.5", "NUMBER" },
        .{ "SELECT i / 2 FROM t", "3.5", "NUMBER" },
        .{ "SELECT n + f FROM t", "2", "BINARY_DOUBLE" },
        .{ "SELECT s || 'c' FROM t", "abc", "VARCHAR2(6)" },
        .{ "SELECT COUNT(*) FROM t", "1", "NUMBER" },
        .{ "SELECT LENGTH(s) FROM t", "2", "NUMBER" },
        .{ "SELECT UPPER(s) FROM t", "AB", "VARCHAR2" },
        .{ "SELECT TO_DATE('2024-01-02', 'YYYY-MM-DD') FROM dual", "2024-01-02 00:00:00", "DATE" },
    });
}

test "zig api: types of parameters" {
    const D = xqlite.Dialect;
    // SQLite's dialect types none.
    {
        var db = try memDb();
        defer db.close();
        try db.exec("CREATE TABLE t (a INTEGER, b TEXT)");
        var s = try db.prepare("SELECT * FROM t WHERE a = ?");
        defer s.finalize();
        try testing.expectEqual(@as(?xqlite.types.Type, null), s.parameterType(1));
    }
    if (D.postgres.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .postgres });
        defer db.close();
        try db.exec("CREATE TABLE t (a int, b text, n numeric(6,2), c bigint, ts timestamptz)");
        const T = xqlite.types.Type;
        const cases = [_]struct { []const u8, []const ?T }{
            .{ "SELECT * FROM t WHERE a = $1 AND $2 = b", &.{ .{ .logical = .int4 }, .{ .logical = .text } } },
            .{ "SELECT $1 + 1", &.{.{ .logical = .int4 }} },
            .{ "SELECT a + $1 FROM t", &.{.{ .logical = .int4 }} },
            .{ "SELECT * FROM t WHERE c BETWEEN $1 AND $2", &.{ .{ .logical = .int8 }, .{ .logical = .int8 } } },
            .{ "SELECT * FROM t WHERE a IN ($1, $2)", &.{ .{ .logical = .int4 }, .{ .logical = .int4 } } },
            .{ "SELECT * FROM t WHERE b IN ($1)", &.{.{ .logical = .text }} },
            .{ "SELECT CASE a WHEN $1 THEN 1 END FROM t", &.{.{ .logical = .int4 }} },
            .{ "INSERT INTO t VALUES ($1, $2, $3, $4)", &.{ .{ .logical = .int4 }, .{ .logical = .text }, .{ .logical = .numeric, .precision = 6, .scale = 2 }, .{ .logical = .int8 } } },
            .{ "INSERT INTO t (c, a) VALUES ($1, $2), ($3, 4)", &.{ .{ .logical = .int8 }, .{ .logical = .int4 }, .{ .logical = .int8 } } },
            .{ "UPDATE t SET b = $1 WHERE a = $2", &.{ .{ .logical = .text }, .{ .logical = .int4 } } },
            // A parameter used twice is of the type of where it is first
            // typed; one nothing types has none.
            .{ "SELECT $1 = a, $1 FROM t", &.{.{ .logical = .int4 }} },
            .{ "SELECT $1, $2 = a FROM t", &.{ null, .{ .logical = .int4 } } },
            // Of the operand of the operator chosen: timestamptz +
            // interval, timestamptz - timestamptz.
            .{ "SELECT ts + $1 FROM t", &.{.{ .logical = .interval }} },
            .{ "SELECT ts - $1 FROM t", &.{.{ .logical = .timestamp_tz }} },
        };
        for (cases) |c| {
            errdefer std.debug.print("{s}\n", .{c[0]});
            var s = try db.prepare(c[0]);
            defer s.finalize();
            try testing.expectEqual(c[1].len, s.parameterCount());
            for (c[1], 1..) |want, i| try testing.expectEqual(want, s.parameterType(i));
        }
        // A parameter compared with a column gives the result its type.
        var s = try db.prepare("SELECT a + $1 FROM t");
        defer s.finalize();
        try testing.expectEqualStrings("integer", s.columnDecltype(0).?);
    }
    if (D.mariadb.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mariadb });
        defer db.close();
        try db.exec("CREATE TABLE t (a INT, d DECIMAL(6,2))");
        var s = try db.prepare("INSERT INTO t VALUES (?, ?)");
        defer s.finalize();
        try testing.expectEqual(xqlite.types.Logical.int4, s.parameterType(1).?.logical);
        try testing.expectEqual(xqlite.types.Type{ .logical = .numeric, .precision = 6, .scale = 2 }, s.parameterType(2).?);
    }
    if (D.mssql.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mssql });
        defer db.close();
        try db.exec("CREATE TABLE t (a INT, x VARCHAR(5))");
        var s = try db.prepare("UPDATE t SET x = ? WHERE a = ?");
        defer s.finalize();
        try testing.expectEqual(xqlite.types.Type{ .logical = .varchar, .length = 5 }, s.parameterType(1).?);
        try testing.expectEqual(xqlite.types.Logical.int4, s.parameterType(2).?.logical);
    }
    if (D.oracle.built()) {
        var db = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .oracle });
        defer db.close();
        try db.exec("CREATE TABLE t (a NUMBER(5), s VARCHAR2(5))");
        var s = try db.prepare("INSERT INTO t VALUES (:1, :2)");
        defer s.finalize();
        try testing.expectEqual(xqlite.types.Logical.int4, s.parameterType(1).?.logical);
        try testing.expectEqual(xqlite.types.Logical.varchar, s.parameterType(2).?.logical);
    }
}

test "zig api: types of expressions of the schema outlive their statements" {
    if (!xqlite.Dialect.postgres.built()) return;
    var mem = MemVfs.init(gpa, testing.io);
    defer mem.deinit();
    const ddl =
        \\CREATE TABLE g (a int, b int GENERATED ALWAYS AS (a * 2) STORED,
        \\  c boolean CHECK (c = (a > 0)), d numeric(6,2) CHECK (d::numeric(4,1) < 100))
    ;
    {
        var w = try Db.open(gpa, testing.io, "types.db", .{ .vfs = .{ .custom = mem.interface() }, .dialect = .postgres });
        defer w.close();
        try w.exec(ddl);
        try w.exec("CREATE INDEX gi ON g ((a < b))");
        try w.exec("INSERT INTO g (a, c, d) VALUES (1, true, 1.5)");
        // Another connection reads the schema, then reads it again after
        // this one changes it.
        var r = try Db.open(gpa, testing.io, "types.db", .{ .vfs = .{ .custom = mem.interface() }, .dialect = .postgres });
        defer r.close();
        try r.exec("INSERT INTO g (a, c, d) VALUES (2, true, 2.5)");
        try w.exec("CREATE TABLE h (x int)");
        try r.exec("INSERT INTO g (a, c, d) VALUES (3, true, 3.5)");
        try testing.expectError(error.Constraint, r.exec("INSERT INTO g (a, c, d) VALUES (4, false, 4.5)"));
        try testing.expectEqual(@as(?i64, 3), try r.one(i64, "SELECT count(*) FROM g WHERE a < b", .{}));
    }
    // Reopened, and attached to a connection of another dialect.
    var db = try Db.open(gpa, testing.io, "types.db", .{ .vfs = .{ .custom = mem.interface() }, .dialect = .postgres });
    defer db.close();
    try db.exec("INSERT INTO g (a, c, d) VALUES (5, true, 5.5)");
    try testing.expectEqual(@as(?i64, 10), try db.one(i64, "SELECT b FROM g WHERE a = 5", .{}));
    if (!xqlite.Dialect.mariadb.built()) return;
    var m = try Db.open(gpa, testing.io, ":memory:", .{ .vfs = .{ .custom = mem.interface() }, .dialect = .mariadb });
    defer m.close();
    try m.exec("ATTACH 'types.db' AS aux");
    try testing.expectError(error.Constraint, m.exec("INSERT INTO aux.g (a, c, d) VALUES (6, FALSE, 6.5)"));
    try m.exec("INSERT INTO aux.g (a, c, d) VALUES (6, TRUE, 6.5)");
    try testing.expectEqual(@as(?i64, 5), try m.one(i64, "SELECT count(*) FROM aux.g WHERE a < b", .{}));
    try m.exec("DETACH aux");
    try m.exec("ATTACH 'types.db' AS aux");
    try testing.expectEqual(@as(?i64, 12), try m.one(i64, "SELECT b FROM aux.g WHERE a = 6", .{}));
}

test "zig api: Diagnostics carry the SQLSTATE and the dialect's number" {
    var diag: xqlite.Diagnostics = .{};
    var db = try Db.open(gpa, testing.io, ":memory:", .{ .diagnostics = &diag });
    defer db.close();
    try testing.expectError(error.Sql, db.exec("SELECT * FROM nope"));
    try testing.expectEqualStrings("42P01", &diag.sqlstate.?);
    // An API error has none.
    try testing.expectError(error.ColumnNotFound, db.oneAlloc(struct { b: i64 }, gpa, "SELECT 1 AS a", .{}));
    try testing.expectEqual(@as(?[5]u8, null), diag.sqlstate);
    if (xqlite.Dialect.mariadb.built()) {
        var my_diag: xqlite.Diagnostics = .{};
        var my = try Db.open(gpa, testing.io, ":memory:", .{ .dialect = .mariadb, .diagnostics = &my_diag });
        defer my.close();
        try testing.expectError(error.Sql, my.exec("SELECT * FROM nope"));
        try testing.expectEqualStrings("42P01", &my_diag.sqlstate.?);
        try testing.expectEqual(@as(?u32, 1146), my_diag.dialect_number);
    }
}

fn interruptAt(db: *Db, n: i64) i64 {
    if (n == 1000) db.interrupt();
    return n;
}

test "zig api: interrupt stops the running statement only" {
    var db = try memDb();
    defer db.close();
    try db.createFunction("interrupt_at", &db, interruptAt, .{});
    try testing.expectError(error.Interrupt, db.exec(
        \\WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 1000000)
        \\SELECT count(interrupt_at(n)) FROM c
    ));
    // The next statement runs.
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT 1", .{}));
}

// ======================================================== virtual tables

/// range(lo, hi): the integers lo..hi as a table-valued function.
const Range = struct {
    pub const schema = "CREATE TABLE x(value INTEGER, square INTEGER, lo HIDDEN, hi HIDDEN)";
    pub const arg_columns = [_]usize{ 2, 3 };

    default_hi: i64,
    opened: *usize,

    pub fn connect(_: std.mem.Allocator, opened: *usize, args: []const []const u8) !Range {
        // range(hi), or with several arguments, as many as there are.
        const hi = switch (args.len) {
            0 => 5,
            1 => try std.fmt.parseInt(i64, args[0], 10),
            else => @as(i64, @intCast(args.len)),
        };
        return .{ .default_hi = hi, .opened = opened };
    }

    pub const Cursor = struct {
        table: *Range,
        i: i64 = 0,
        lo: i64 = 0,
        hi: i64 = 0,

        pub fn open(table: *Range) Cursor {
            table.opened.* += 1;
            return .{ .table = table };
        }

        pub fn filter(c: *Cursor, args: xqlite.FilterArgs) !void {
            c.lo = (try args.get(i64, 0)) orelse 1;
            c.hi = (try args.get(i64, 1)) orelse c.table.default_hi;
            if (c.hi > 1000) return error.RangeTooLarge;
            c.i = c.lo;
        }

        pub fn next(c: *Cursor) void {
            c.i += 1;
        }

        pub fn eof(c: *const Cursor) bool {
            return c.i > c.hi;
        }

        pub fn column(c: *Cursor, i: usize) xqlite.Value {
            return switch (i) {
                0 => .{ .integer = c.i },
                1 => .{ .integer = c.i * c.i },
                2 => .{ .integer = c.lo },
                else => .{ .integer = c.hi },
            };
        }

        pub fn rowid(c: *Cursor) i64 {
            return c.i;
        }
    };
};

test "zig api: virtual tables: typed module, table-valued function, CREATE VIRTUAL TABLE" {
    var db = try memDb();
    defer db.close();
    var opened: usize = 0;
    try db.createModule("range", Range, &opened);

    try testing.expectEqual(@as(?[2]i64, .{ 5, 15 }), try db.one([2]i64, "SELECT count(*), sum(value) FROM range", .{}));
    try testing.expectEqual(@as(?[2]i64, .{ 3, 29 }), try db.one([2]i64, "SELECT count(*), sum(square) FROM range(2, 4)", .{}));
    try testing.expectEqual(@as(?i64, 30), try db.one(i64, "SELECT sum(value) FROM range WHERE lo = 10 AND hi = 20 AND value % 10 = 0", .{}));
    try testing.expectEqual(@as(?i64, 7), try db.one(i64, "SELECT rowid FROM range(7, 7)", .{}));
    try testing.expectError(error.Sql, db.exec("SELECT * FROM range(1, 5000)"));
    try testing.expectEqualStrings("RangeTooLarge", db.lastError().?.message);

    try db.exec("CREATE VIRTUAL TABLE r3 USING range(3)");
    try testing.expectEqual(@as(?i64, 6), try db.one(i64, "SELECT sum(value) FROM r3", .{}));
    // A join that passes the arguments from another table.
    try db.exec("CREATE TABLE bounds(h INTEGER); INSERT INTO bounds VALUES(2), (3)");
    try testing.expectEqual(@as(?i64, 9), try db.one(i64, "SELECT sum(value) FROM bounds, range(1, bounds.h)", .{}));
    try testing.expectError(error.Sql, db.exec("CREATE VIRTUAL TABLE bad USING range(nope)"));
    try testing.expectEqualStrings("InvalidCharacter", db.lastError().?.message);
    try db.exec("DROP TABLE r3");
    // Every module argument reaches connect(), however many.
    try db.exec("CREATE VIRTUAL TABLE r40 USING range(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40)");
    try testing.expectEqual(@as(?i64, 40), try db.one(i64, "SELECT max(value) FROM r40", .{}));
    try testing.expect(opened > 0);
}

// ================================================================= files

test "zig api: file database: unix VFS, reopen, WAL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/api.db", .{tmp.sub_path});

    {
        var db = try Db.open(gpa, testing.io, path, .{ .journal_mode = .wal, .busy_timeout_ms = 100, .foreign_keys = true });
        defer db.close();
        try db.exec(
            \\CREATE TABLE parent(id INTEGER PRIMARY KEY);
            \\CREATE TABLE child(pid REFERENCES parent(id));
        );
        try db.transaction(.immediate, struct {
            fn fill(d: *Db) !void {
                var s = try d.prepare("INSERT INTO parent(id) VALUES(?)");
                defer s.finalize();
                for (1..101) |i| try s.exec(.{i});
            }
        }.fill, .{&db});
        try testing.expectError(error.Constraint, db.execArgs("INSERT INTO child VALUES(?)", .{999}));
        try testing.expectEqual(xqlite.ResultCode.constraint_foreignkey, db.lastError().?.code);
    }
    {
        var db = try Db.open(gpa, testing.io, path, .{ .read_only = true });
        defer db.close();
        try testing.expectEqual(@as(?i64, 5050), try db.one(i64, "SELECT sum(id) FROM parent", .{}));
        const mode = (try db.oneAlloc([]const u8, gpa, "PRAGMA journal_mode", .{})).?;
        defer gpa.free(mode);
        try testing.expectEqualStrings("wal", mode);
    }
    // A missing file without create.
    var path2_buf: [256]u8 = undefined;
    const path2 = try std.fmt.bufPrint(&path2_buf, ".zig-cache/tmp/{s}/none.db", .{tmp.sub_path});
    try testing.expectError(error.CantOpen, Db.open(gpa, testing.io, path2, .{ .create = false }));
}

test "zig api: memory VFS and journal modes" {
    // A named database in the connection's private in-memory file system.
    var db = try Db.open(gpa, testing.io, "app.db", .{ .vfs = .memory, .journal_mode = .wal });
    defer db.close();
    try db.exec("CREATE TABLE t(a); INSERT INTO t VALUES(1)");
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT a FROM t", .{}));
    try db.setJournalMode(.delete);

    var diag: xqlite.Diagnostics = .{};
    try testing.expectError(error.UnsupportedJournalMode, Db.open(gpa, testing.io, ":memory:", .{ .journal_mode = .wal, .diagnostics = &diag }));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "journal_mode=wal refused: the database uses "));
}

test "zig api: allocation failures of the API's own allocator" {
    // The VFS object of a .memory connection.
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, Db.open(failing.allocator(), testing.io, ":memory:", .{ .vfs = .memory }));

    // The record of a function: nothing is registered, nothing leaks.
    var mem = MemVfs.init(gpa, testing.io);
    defer mem.deinit();
    failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var db = try Db.open(failing.allocator(), testing.io, ":memory:", .{ .vfs = .{ .custom = mem.interface() } });
    defer db.close();
    try testing.expectError(error.OutOfMemory, db.createFunction("my_add", {}, add, .{}));
    try testing.expectError(error.OutOfMemory, db.createAggregate("my_sum", Sum, .{}));
    try testing.expectError(error.Sql, db.exec("SELECT my_add(1, 2)"));

    // A Db is a plain value: it can be moved.
    var holder: struct { db: Db } = .{ .db = try memDb() };
    defer holder.db.close();
    try testing.expectEqual(@as(?i64, 1), try holder.db.one(i64, "SELECT 1", .{}));
}

test "zig api: empty text and blobs" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT '', x'', zeroblob(0), CAST('' AS BLOB)");
    defer s.finalize();
    try testing.expect(try s.step());
    try testing.expectEqualStrings("", try s.column([]const u8, 0));
    try testing.expectEqualStrings("", try s.column([]const u8, 1));
    try testing.expectEqualStrings("", try s.column([:0]const u8, 2));
    try testing.expectEqualStrings("", try s.column([]const u8, 3));
    try testing.expectEqualStrings("", (try s.column(xqlite.Blob, 0)).data);
    // Reading a BLOB as text converted it in place (as in C): step again
    // for fresh values.
    s.reset();
    try testing.expect(try s.step());
    try testing.expectEqualStrings("", (try s.column(xqlite.Value, 1)).blob);
    const v = try s.columnAlloc(xqlite.Value, gpa, 3);
    defer xqlite.free(gpa, v);
    try testing.expectEqualStrings("", v.blob);
}

// ============================================================ review fixes

test "zig api: errors: out of memory in the API layer is recorded as NOMEM" {
    var mem = MemVfs.init(gpa, testing.io);
    defer mem.deinit();
    var diag: xqlite.Diagnostics = .{};
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var db = try Db.open(failing.allocator(), testing.io, ":memory:", .{ .vfs = .{ .custom = mem.interface() }, .diagnostics = &diag });
    defer db.close();

    // The record of a function, from the Db's allocator.
    try testing.expectError(error.OutOfMemory, db.createFunction("my_add", {}, add, .{}));
    try testing.expectEqual(@as(?xqlite.Error, error.OutOfMemory), diag.err);
    try testing.expectEqual(xqlite.ResultCode.nomem, diag.code);
    try testing.expectEqualStrings("out of memory", diag.message());
    try testing.expectEqual(@as(?usize, null), diag.offset);
    var e = db.lastError().?;
    try testing.expectEqual(xqlite.ResultCode.nomem, e.code);
    try testing.expectEqualStrings("out of memory", e.message);

    // A copy made with the caller's allocator; a syntax error first, so
    // that its offset is not reported for the NOMEM.
    try testing.expectError(error.Sql, db.exec("SELEC 1"));
    try testing.expectEqual(@as(?usize, 0), diag.offset);
    var s = try db.prepare("SELECT 'some text'");
    defer s.finalize();
    try testing.expect(try s.step());
    var none = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, s.columnAlloc([]const u8, none.allocator(), 0));
    try testing.expectEqual(xqlite.ResultCode.nomem, diag.code);
    try testing.expectEqualStrings("out of memory", diag.message());
    try testing.expectEqual(@as(?usize, null), diag.offset);
    e = db.lastError().?;
    try testing.expectEqual(xqlite.ResultCode.nomem, e.code);
    try testing.expectEqual(@as(?usize, null), e.offset);
}

/// A table name longer than Diagnostics.max_message, so that its "no such
/// table" message would not survive a copy through Diagnostics.
const long_name = "t" ++ repeat('x', 300);

fn repeat(comptime c: u8, comptime n: usize) [n]u8 {
    return @splat(c);
}

fn failLong(db: *Db) xqlite.Error!void {
    try db.exec("SELECT " ++ long_name ++ " FROM acct");
}

const long_message = "no such column: " ++ long_name;

/// The error of failLong(), as the connection reports it right away.
fn expectLongError(db: *const Db, offset: ?usize) !void {
    const e = db.lastError().?;
    try testing.expectEqual(xqlite.ResultCode.@"error", e.code);
    try testing.expectEqualStrings(long_message, e.message);
    try testing.expectEqual(offset, e.offset);
}

test "zig api: errors: finalize, transaction() and Savepoint.rollback() keep the whole error" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE acct(v)");
    comptime std.debug.assert(long_message.len > xqlite.Diagnostics.max_message);
    try testing.expectError(error.Sql, failLong(&db));
    const offset = db.lastError().?.offset;
    try testing.expectEqual(@as(?usize, 7), offset);

    // Stmt.finalize() after the error.
    {
        var s = try db.prepare("SELECT 1");
        defer s.finalize();
        try testing.expectError(error.Sql, failLong(&db));
    }
    try expectLongError(&db, offset);

    // ROLLBACK of transaction().
    try testing.expectError(error.Sql, db.transaction(.deferred, failLong, .{&db}));
    try testing.expect(!db.inTransaction());
    try expectLongError(&db, offset);

    // ROLLBACK TO of a nested transaction() and of a savepoint.
    try db.begin(.deferred);
    try testing.expectError(error.Sql, db.transaction(.deferred, failLong, .{&db}));
    try testing.expect(db.inTransaction());
    try expectLongError(&db, offset);
    var sp = try db.savepoint("sp");
    try testing.expectError(error.Sql, failLong(&db));
    sp.rollback();
    try expectLongError(&db, offset);
    try db.rollback();

    // Without an error to keep, the cleanups report none either.
    try db.exec("SELECT 1");
    sp = try db.savepoint("ok");
    sp.rollback();
    try testing.expectEqual(@as(?xqlite.ErrorInfo, null), db.lastError());
}

test "zig api: next(): the field mapping is cached, across reset, rebinding and schema changes" {
    var db = try memDb();
    defer db.close();
    try db.exec("CREATE TABLE t(a, b); INSERT INTO t VALUES(1, 'one'), (2, 'two')");
    const AB = struct { a: i64, b: []const u8 };
    const BA = struct { b: []const u8, a: i64 };
    var s = try db.prepare("SELECT * FROM t WHERE a >= ? ORDER BY a");
    defer s.finalize();

    try s.bind(.{1});
    var r = (try s.next(AB)).?;
    try testing.expectEqual(@as(i64, 1), r.a);
    try testing.expectEqualStrings("one", r.b);
    // Another struct on the same statement: its own mapping.
    const r2 = (try s.next(BA)).?;
    try testing.expectEqual(@as(i64, 2), r2.a);
    try testing.expectEqualStrings("two", r2.b);
    try testing.expectEqual(@as(?AB, null), try s.next(AB));

    // Rebinding (a reset) keeps the mapping valid.
    try s.bind(.{2});
    r = (try s.next(AB)).?;
    try testing.expectEqual(@as(i64, 2), r.a);
    try testing.expectEqualStrings("two", r.b);
    s.reset();
    var it = s.iterator(AB);
    try testing.expectEqual(@as(i64, 2), (try it.next()).?.a);

    // A schema change recompiles the statement with the columns in
    // another order: the mapping is resolved again.
    s.reset();
    try db.exec("DROP TABLE t; CREATE TABLE t(b, a); INSERT INTO t VALUES('three', 3)");
    try s.bind(.{1});
    r = (try s.next(AB)).?;
    try testing.expectEqual(@as(i64, 3), r.a);
    try testing.expectEqualStrings("three", r.b);
    // ... and a column that is gone is reported.
    s.reset();
    try db.exec("DROP TABLE t; CREATE TABLE t(a, c)");
    try s.bind(.{1});
    try db.exec("INSERT INTO t VALUES(4, 'four')");
    try testing.expectError(error.ColumnNotFound, s.next(AB));
}

test "zig api: bind(): cached parameter mapping, and NULLs after a failure" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT :a, @b, $c");
    defer s.finalize();
    const Abc = struct { a: i64, b: i64, c: i64 };
    const Cba = struct { c: i64, b: i64, a: i64 };
    for (0..3) |i| {
        const n: i64 = @intCast(i);
        try s.bind(Abc{ .a = n, .b = n + 1, .c = n + 2 });
        try testing.expectEqual([3]i64{ n, n + 1, n + 2 }, (try s.next([3]i64)).?);
        try s.bind(Cba{ .c = n + 2, .b = n + 1, .a = n });
        try testing.expectEqual([3]i64{ n, n + 1, n + 2 }, (try s.next([3]i64)).?);
    }
    // A failed bind leaves every parameter NULL, not the earlier values.
    try testing.expectError(error.UnknownParameter, s.bind(.{ .a = 1, .b = 2, .d = 3 }));
    try testing.expectEqual([3]?i64{ null, null, null }, (try s.next([3]?i64)).?);
    try s.bind(.{ 7, 8, 9 });
    try testing.expectError(error.IntegerOverflow, s.bind(.{ 1, 2, @as(u64, std.math.maxInt(u64)) }));
    try testing.expectEqual([3]?i64{ null, null, null }, (try s.next([3]?i64)).?);
    // A tuple rebinds every parameter without clearing.
    try s.bind(.{ 4, 5, 6 });
    try testing.expectEqual([3]i64{ 4, 5, 6 }, (try s.next([3]i64)).?);
}

/// `n` levels of rec() below this one, joined: runs SQL that calls the
/// function itself, from inside the function.
fn rec(db: *Db, arena: std.mem.Allocator, n: i64) ![]const u8 {
    const head = try std.fmt.allocPrint(arena, "<{d}", .{n});
    if (n == 0) return std.fmt.allocPrint(arena, "{s}>", .{head});
    const inner = (try db.oneAlloc([]const u8, arena, "SELECT rec(?)", .{n - 1})).?;
    // The outer arena is intact after the nested call.
    return std.fmt.allocPrint(arena, "{s}{s}>", .{ head, inner });
}

fn shout(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.ascii.allocUpperString(arena, s);
}

test "zig api: functions: the arena of Allocator parameters is reused, and nests" {
    var mem = MemVfs.init(gpa, testing.io);
    defer mem.deinit();
    // Counts the allocations of the API layer.
    var counting = testing.FailingAllocator.init(gpa, .{});
    var db = try Db.open(counting.allocator(), testing.io, ":memory:", .{ .vfs = .{ .custom = mem.interface() } });
    defer db.close();
    try db.createFunction("shout", {}, shout, .{});
    try db.exec("CREATE TABLE t(s); WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<500) INSERT INTO t SELECT 'row' || i FROM r");
    const before = counting.allocations;
    try testing.expectEqual(@as(?i64, 500), try db.one(i64, "SELECT count(*) FROM t WHERE shout(s) = upper(s)", .{}));
    // One buffer for the arena, kept from call to call.
    try testing.expect(counting.allocations - before < 5);

    try db.createFunction("rec", &db, rec, .{});
    const got = (try db.oneAlloc([]const u8, gpa, "SELECT rec(3)", .{})).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("<3<2<1<0>>>>", got);
    // The outer call's arena is free again for the next statement.
    try testing.expectEqual(@as(?i64, 500), try db.one(i64, "SELECT count(*) FROM t WHERE shout(s) = upper(s)", .{}));
}

test "zig api: prepare(): trailing text follows the tokenizer" {
    var db = try memDb();
    defer db.close();
    var s = try db.prepare("SELECT 1; /* closed */ -- line\n ;");
    s.finalize();
    s = try db.prepare("SELECT 1; /* not closed");
    s.finalize();
    // A bare "/*" at the end is not a comment for SQLite's tokenizer.
    try testing.expectError(error.MultipleStatements, db.prepare("SELECT 1; /*"));
    // A long tail, past the stack buffer.
    s = try db.prepare("SELECT 1; --" ++ repeat('-', 1000));
    s.finalize();
}

test "zig api: savepoint names are quoted" {
    var db = try memDb();
    defer db.close();
    var sp = try db.savepoint("a \"quoted\" name" ++ repeat('"', 40));
    try db.exec("CREATE TABLE t(a)");
    try sp.release();
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT count(*) FROM t", .{}));
}

test "zig api: incremental blob I/O" {
    var db = try memDb();
    defer db.close();
    try db.exec(
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, data BLOB, n INT UNIQUE, log INT DEFAULT 0);
        \\INSERT INTO t(id, data, n) VALUES(1, zeroblob(3000), 1), (2, x'0102', 2);
        \\CREATE TRIGGER tr AFTER UPDATE ON t BEGIN UPDATE t SET log = log + 1 WHERE id = 2; END;
    );
    var b = try db.openBlob(null, "t", "data", 1, true);
    try testing.expectEqual(@as(u32, 3000), b.bytes());
    try b.write("xqlite", 2500);
    var buf: [8]u8 = undefined;
    try b.read(&buf, 2498);
    try testing.expectEqualSlices(u8, "\x00\x00xqlite", &buf);
    try testing.expectError(error.Sql, b.read(&buf, 2995));
    // An open blob is a running statement.
    try testing.expectError(error.Busy, db.tryClose());
    try b.reopen(2);
    try testing.expectEqual(@as(u32, 2), b.bytes());
    try b.close();
    // No trigger ran.
    try testing.expectEqual(@as(?i64, 0), try db.one(i64, "SELECT log FROM t WHERE id = 2", .{}));
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT substr(data, 2501, 6) = CAST('xqlite' AS BLOB) FROM t WHERE id = 1", .{}));

    // The blob expires when its row changes.
    var r = try db.openBlob("main", "t", "data", 2, false);
    try testing.expectError(error.ReadOnly, r.write("z", 0));
    try db.exec("UPDATE t SET n = 3 WHERE id = 2");
    try testing.expectError(error.Abort, r.read(buf[0..1], 0));
    try testing.expectEqual(@as(u32, 0), r.bytes());
    try r.close();

    try testing.expectError(error.Sql, db.openBlob(null, "t", "n", 1, true));
    try testing.expectEqualStrings("cannot open indexed column for writing", db.lastError().?.message);
    try testing.expectError(error.Sql, db.openBlob(null, "t", "data", 9, false));
    try testing.expectEqualStrings("no such rowid: 9", db.lastError().?.message);
}

test "zig api: serialize and deserialize" {
    var src = try memDb();
    defer src.close();
    try src.exec("CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3)");
    const image = try src.serialize(testing.allocator, "main");
    defer testing.allocator.free(image);
    try testing.expectEqual(@as(usize, 8192), image.len);
    try testing.expectError(error.NotFound, src.serialize(testing.allocator, "nosuch"));

    var db = try memDb();
    defer db.close();
    try db.deserialize("main", image, false);
    try testing.expectEqual(@as(?i64, 6), try db.one(i64, "SELECT sum(x) FROM t", .{}));
    try db.exec("INSERT INTO t VALUES(4)");
    try testing.expectEqual(@as(?i64, 10), try db.one(i64, "SELECT sum(x) FROM t", .{}));
    try db.exec("ATTACH ':memory:' AS ro");
    try db.deserialize("ro", image, true);
    try testing.expectError(error.ReadOnly, db.exec("INSERT INTO ro.t VALUES(5)"));
    try testing.expectError(error.Sql, db.deserialize("temp", image, false));
}

test "zig api: backup between two connections, and VACUUM" {
    var src = try memDb();
    defer src.close();
    try src.exec(
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b);
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<200)
        \\  INSERT INTO t SELECT i, zeroblob(500) FROM n;
    );
    var dest = try memDb();
    defer dest.close();

    var b = try dest.backup("main", &src, "main");
    try testing.expect(!try b.step(3));
    try testing.expectEqual(b.pageCount() - 3, b.remaining());
    // Neither connection closes while the backup runs.
    try testing.expectError(error.Busy, src.tryClose());
    try testing.expect(try b.step(null));
    try testing.expectEqual(@as(u32, 0), b.remaining());
    try b.finish();
    try testing.expectEqual(@as(?i64, 200), try dest.one(i64, "SELECT count(*) FROM t", .{}));

    try testing.expectError(error.Sql, dest.backup("main", &src, "nosuch"));
    try testing.expectEqualStrings("unknown database nosuch", dest.lastError().?.message);
    try testing.expectError(error.Sql, dest.backup("main", &dest, "main"));
    try testing.expectEqualStrings("source and destination must be distinct", dest.lastError().?.message);

    try dest.exec("DELETE FROM t WHERE a > 10; VACUUM");
    try testing.expectEqual(@as(?i64, 0), try dest.one(i64, "PRAGMA freelist_count", .{}));
    try testing.expectEqual(@as(?i64, 10), try dest.one(i64, "SELECT count(*) FROM t", .{}));
}
