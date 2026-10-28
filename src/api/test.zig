//! Tests of the Zig API. Every test is leak-checked twice over: the API's
//! own allocations go to std.testing.allocator (the `gpa` of Db.open()),
//! and so does the engine's memory in test builds (malloc.zig).

const std = @import("std");
const xqlite = @import("../xqlite.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;

const testing = std.testing;
const gpa = testing.allocator;
const Db = xqlite.Db;

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

// ======================================================== virtual tables

/// range(lo, hi): the integers lo..hi as a table-valued function.
const Range = struct {
    pub const schema = "CREATE TABLE x(value INTEGER, square INTEGER, lo HIDDEN, hi HIDDEN)";
    pub const arg_columns = [_]usize{ 2, 3 };

    default_hi: i64,
    opened: *usize,

    pub fn connect(_: std.mem.Allocator, opened: *usize, args: []const []const u8) !Range {
        const hi = if (args.len > 0) try std.fmt.parseInt(i64, args[0], 10) else 5;
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
