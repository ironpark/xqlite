//! Tests of ATTACH and DETACH (attach.zig) and of transactions over
//! several databases (the super-journal of vdbeCommit()).

const std = @import("std");
const testing = std.testing;
const int = @import("sqlite_int.zig");
const main_mod = @import("main.zig");
const prepare = @import("prepare.zig");
const attach = @import("attach.zig");
const legacy = @import("legacy.zig");
const api = @import("../vdbe/api.zig");
const vfs = @import("../vfs/vfs.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const Conn = @import("sql_test.zig").Conn;

const RC = int.RC;
const Vdbe = @import("../vdbe/vdbe_int.zig").Vdbe;

test "attach: ATTACH and DETACH" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a); INSERT INTO t VALUES(1)");
    try c.exec("ATTACH 'aux1.db' AS aux1; ATTACH DATABASE 'aux2.db' AS \"Aux2\"; ATTACH aux3 AS aux3");
    try c.expectRows("SELECT seq, name, file FROM pragma_database_list", "0|main|test.db\n2|aux1|aux1.db\n3|Aux2|aux2.db\n4|aux3|aux3\n");
    try c.exec("CREATE TABLE aux1.t(a); INSERT INTO aux1.t VALUES(2); CREATE TABLE aux2.u(b); CREATE INDEX aux2.i ON u(b)");
    try c.expectRows("SELECT * FROM main.t, aux1.t", "1|2\n");
    // The name of an unqualified table is looked up in main first.
    try c.expectRows("SELECT * FROM t", "1\n");
    try c.expectRows("SELECT type, name, tbl_name, sql FROM aux1.sqlite_schema", "table|t|t|CREATE TABLE t(a)\n");
    try c.expectRows("SELECT name FROM aux1.sqlite_master", "t\n");
    try c.expectRows("SELECT name FROM aux2.sqlite_schema", "u\ni\n");
    try c.expectError("CREATE INDEX aux2.j ON t(a)", "no such table: Aux2.t");
    try c.expectRows("PRAGMA aux1.table_info(t)", "0|a||0|NULL|0\n");
    try c.expectRows("SELECT name FROM pragma_table_info('t', 'aux1')", "a\n");
    try c.expectRows("PRAGMA aux1.integrity_check", "ok\n");
    try c.exec("PRAGMA aux1.user_version = 7");
    try c.expectRows("PRAGMA aux1.user_version; PRAGMA user_version", "7\n0\n");

    try c.expectError("ATTACH 'x.db' AS aux1", "database aux1 is already in use");
    try c.expectError("ATTACH 'x.db' AS MAIN", "database MAIN is already in use");
    try c.expectError("ATTACH 'x.db' AS temp", "database temp is already in use");
    try c.expectError("ATTACH a || b AS c", "no such column: a");
    try c.expectError("DETACH nosuch", "no such database: nosuch");
    try c.expectError("DETACH main", "cannot detach database main");
    // TEMP is a database once its file is open.
    try c.expectError("DETACH temp", "no such database: temp");
    try c.exec("CREATE TEMP TABLE tt(x)");
    try c.expectError("DETACH temp", "cannot detach database temp");
    // The message is cut at 127 bytes.
    const ys: [200]u8 = @splat('y');
    try c.expectError("DETACH x" ++ ys, "no such database: x" ++ ys[0..108]);
    try c.exec("BEGIN; INSERT INTO aux1.t VALUES(3)");
    try c.expectError("DETACH aux1", "database aux1 is locked");
    try c.exec("COMMIT");

    try c.exec("DETACH aux1; DETACH \"aux2\"");
    try c.expectRows("SELECT name FROM pragma_database_list", "main\ntemp\naux3\n");
    try c.expectError("SELECT * FROM aux1.t", "no such table: aux1.t");
    try c.exec("ATTACH 'aux1.db' AS again");
    try c.expectRows("SELECT * FROM again.t", "2\n3\n");
    try c.expectRows("SELECT seq, name FROM pragma_database_list", "0|main\n1|temp\n2|aux3\n3|again\n");
    // ":memory:" and "" are private temporary databases.
    try c.exec("ATTACH ':memory:' AS m; ATTACH '' AS e; CREATE TABLE m.z(q); INSERT INTO m.z VALUES(9)");
    try c.expectRows("SELECT * FROM m.z", "9\n");
    try c.expectRows("SELECT name, file FROM pragma_database_list WHERE seq > 3", "m|\ne|\n");
    try testing.expectEqualStrings("aux1.db", main_mod.dbFilename(c.db, "again").?);
    try testing.expectEqualStrings("", main_mod.dbFilename(c.db, "m").?);
    try testing.expectEqualStrings("test.db", main_mod.dbFilename(c.db, null).?);
    try testing.expect(main_mod.dbFilename(c.db, "nosuch") == null);
    try testing.expectEqual(@as(?bool, false), main_mod.dbReadonly(c.db, "again"));
    try testing.expectEqualStrings("again", main_mod.dbName(c.db, 3).?);
    // Any name will do, however long, quotes and all.
    try c.exec("ATTACH 'aux1.db' AS \"q\"\"uote\"");
    try c.expectRows("SELECT a FROM \"q\"\"uote\".t", "2\n3\n");
    try c.exec("DETACH 'q\"uote'");
    try c.exec("ATTACH 'aux1.db' AS x" ++ ys ++ "; SELECT * FROM x" ++ ys ++ ".t; DETACH x" ++ ys);
    // A NULL name and file are empty strings, which may be attached.
    try c.exec("ATTACH NULL AS NULL");
    try c.expectRows("SELECT quote(name) FROM pragma_database_list WHERE seq = 6", "''\n");
    try c.exec("DETACH ''");
}

test "attach: the limit on attached databases" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    _ = main_mod.limit(c.db, .attached, 2);
    try c.exec("ATTACH 'a.db' AS a; ATTACH 'b.db' AS b");
    try c.expectError("ATTACH 'c.db' AS c", "too many attached databases - max 2");
    try c.exec("DETACH a; ATTACH 'c.db' AS c");
    try c.expectRows("SELECT name FROM pragma_database_list", "main\nb\nc\n");
    // The hard limit is SQLITE_MAX_ATTACHED (10).
    try testing.expectEqual(@as(i32, 2), main_mod.limit(c.db, .attached, 100));
    try testing.expectEqual(@as(i32, 10), main_mod.limit(c.db, .attached, -1));
}

test "attach: a file that cannot be opened or read" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    {
        const f = try c.mem.interface().open("junk.db", .{ .create = true });
        defer f.close();
        const junk: [1024]u8 = @splat('x');
        try f.write(&junk, 0);
    }
    try c.expectError("ATTACH 'junk.db' AS j", "file is not a database");
    main_mod.extendedResultCodes(c.db, true);
    try testing.expectEqual(RC.NOTADB, main_mod.extendedErrcode(c.db));
    try c.expectRows("SELECT name FROM pragma_database_list", "main\n");
    // Without SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE no file is made.
    _ = main_mod.dbConfig(c.db, .enable_attach_create, 0);
    try c.expectError("ATTACH 'new.db' AS n", "unable to open database: new.db");
    try testing.expectEqual(RC.CANTOPEN, main_mod.extendedErrcode(c.db));
    try c.exec("CREATE TABLE t(x)");
    _ = main_mod.dbConfig(c.db, .enable_attach_create, 1);
    try c.exec("ATTACH 'new.db' AS n; CREATE TABLE n.t(x); DETACH n");
    // Without SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE it is read-only.
    _ = main_mod.dbConfig(c.db, .enable_attach_write, 0);
    try c.exec("ATTACH 'new.db' AS n");
    try testing.expectEqual(@as(?bool, true), main_mod.dbReadonly(c.db, "n"));
    try c.expectError("INSERT INTO n.t VALUES(1)", "attempt to write a readonly database");
    try c.expectRows("SELECT count(*) FROM n.t", "0\n");
}

test "attach: URI filenames" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("ATTACH 'file:u.db' AS plain; CREATE TABLE plain.t(x); DETACH plain");
    // Without OpenFlags.uri, "file:u.db" was a file of that name.
    try c.expectRows("SELECT 1", "1\n");
    c.db.open_flags.uri = true;
    try c.exec("ATTACH 'file:u.db?mode=rwc' AS u; CREATE TABLE u.t(x); INSERT INTO u.t VALUES(1); DETACH u");
    try c.exec("ATTACH 'file:u.db?mode=ro' AS ro");
    try c.expectRows("SELECT * FROM ro.t", "1\n");
    try c.expectError("INSERT INTO ro.t VALUES(2)", "attempt to write a readonly database");
    try c.exec("ATTACH 'file:%75.db' AS esc");
    try c.expectRows("SELECT * FROM esc.t", "1\n");
    try c.expectError("ATTACH 'file:none.db?mode=rw' AS n", "unable to open database: file:none.db?mode=rw");
    try c.expectError("ATTACH 'file:u.db?vfs=other' AS n", "no such vfs: other");
    try c.expectError("ATTACH 'file:u.db?mode=x' AS n", "no such access mode: x");
    try c.expectError("ATTACH 'file:u.db?cache=x' AS n", "no such cache mode: x");
    try c.expectError("ATTACH 'file://host/u.db' AS n", "invalid uri authority: host");
    try c.exec("ATTACH 'file:m?mode=memory' AS m; CREATE TABLE m.t(x)");
    try c.expectRows("SELECT name, file FROM pragma_database_list WHERE seq >= 2", "ro|u.db\nesc|u.db\nm|\n");
    // A connection opened read-only may not attach read-write.
    c.db.open_flags.read_only = true;
    c.db.open_flags.create = false;
    try c.expectError("ATTACH 'file:u.db?mode=rw' AS n", "access mode not allowed: rw");
}

/// Prepare `sql` on `c`.
fn prep(c: *Conn, sql: []const u8) !*Vdbe {
    var stmt: ?*Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, sql, &stmt, null));
    return stmt.?;
}

test "attach: an OP_Function context whose out already names its register" {
    // ReleaseFast leaves the `out` of a new function context (undefined)
    // as the allocation held it. A DETACH compiled into the memory of a
    // finalized ATTACH found there the ATTACH's `out`, the same register,
    // and kept its argv: the file name register, NULL, so "no such
    // database: " (~40% of capi_test runs in ReleaseFast). Set up that
    // state on purpose; the first run must still bind the arguments.
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("ATTACH 'a.db' AS a");
    const s = try prep(&c, "DETACH a");
    defer _ = api.finalize(s);
    const op = for (s.ops.items) |*o| {
        if (o.opcode == .Function) break o;
    } else return error.TestUnexpectedResult;
    const ctx = op.p4.funcctx;
    ctx.out = &s.mem[@intCast(op.p3)];
    // Register 1 holds the file name of ATTACH; DETACH leaves it NULL.
    ctx.argv[0] = &s.mem[@intCast(op.p2 - 2)];
    try testing.expectEqual(RC.DONE, api.step(s));
    try c.expectRows("SELECT name FROM pragma_database_list", "main\n");
}

test "attach: DETACH while statements are prepared or running" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(x); INSERT INTO t VALUES(1), (2)");
    try c.exec("ATTACH 'a.db' AS a; CREATE TABLE a.u(y); INSERT INTO a.u VALUES(10), (20)");

    // A statement prepared before the DETACH is compiled again, and
    // finds no table.
    const s = try prep(&c, "SELECT y FROM a.u");
    defer _ = api.finalize(s);
    try testing.expectEqual(RC.ROW, api.step(s));
    _ = api.reset(s);
    try c.exec("DETACH a");
    try testing.expectEqual(RC.ERROR, api.step(s));
    try testing.expectEqualStrings("no such table: a.u", main_mod.errmsg(c.db));
    _ = api.reset(s);
    // ATTACHing the database again makes it work again.
    try c.exec("ATTACH 'a.db' AS a");
    try testing.expectEqual(RC.ROW, api.step(s));
    try testing.expectEqual(@as(i64, 10), api.columnInt64(s, 0));

    // While the statement reads it, the database cannot be detached.
    try c.expectError("DETACH a", "database a is locked");
    // Another database can.
    try c.exec("ATTACH 'b.db' AS b; DETACH b");
    try testing.expectEqual(RC.ROW, api.step(s));
    try testing.expectEqual(@as(i64, 20), api.columnInt64(s, 0));
    try testing.expectEqual(RC.DONE, api.step(s));
    _ = api.reset(s);
    try c.exec("DETACH a");

    // A statement reading main does not keep an attached database busy.
    try c.exec("ATTACH 'a.db' AS a");
    const m = try prep(&c, "SELECT x FROM main.t");
    defer _ = api.finalize(m);
    try testing.expectEqual(RC.ROW, api.step(m));
    try c.exec("DETACH a");
    try testing.expectEqual(RC.ROW, api.step(m));
    try testing.expectEqual(RC.DONE, api.step(m));

    // Nor does one reading a database attached after it, which moves
    // down in db.dbs.
    try c.exec("ATTACH 'a.db' AS a; ATTACH 'b.db' AS b; CREATE TABLE b.w(v); INSERT INTO b.w VALUES(1), (2), (3)");
    const r = try prep(&c, "SELECT v FROM b.w");
    defer _ = api.finalize(r);
    try testing.expectEqual(RC.ROW, api.step(r));
    try c.exec("DETACH a");
    try testing.expectEqual(RC.ROW, api.step(r));
    try testing.expectEqual(RC.ROW, api.step(r));
    try testing.expectEqual(@as(i64, 3), api.columnInt64(r, 0));
    try testing.expectEqual(RC.DONE, api.step(r));
    try testing.expectEqual(RC.ROW, api.step(r));
    try c.expectError("DETACH b", "database b is locked");
    _ = api.reset(r);
    try c.exec("DETACH b");
}

test "attach: TEMP triggers and views on attached tables, and the DbFixer" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(x)");
    try c.exec("ATTACH 'a.db' AS a; CREATE TABLE a.u(y); ATTACH 'b.db' AS b; CREATE TABLE b.log(z)");
    try c.exec("CREATE TEMP TRIGGER tr AFTER INSERT ON a.u BEGIN INSERT INTO b.log VALUES(new.y * 10); END");
    try c.exec("INSERT INTO a.u VALUES(1)");
    try c.expectRows("SELECT * FROM b.log", "10\n");
    try c.exec("CREATE VIEW a.v AS SELECT y FROM u");
    try c.expectRows("SELECT * FROM a.v", "1\n");
    try c.expectError("CREATE VIEW a.v2 AS SELECT * FROM main.t", "view v2 cannot reference objects in database main");
    try c.expectError("CREATE TRIGGER a.tr2 AFTER INSERT ON u BEGIN INSERT INTO main.t VALUES(1); END", "qualified table names are not allowed on INSERT, UPDATE, and DELETE statements within triggers");
    try c.exec("CREATE TRIGGER a.tr3 AFTER INSERT ON u BEGIN INSERT INTO u2 VALUES(new.y); END; CREATE TABLE a.u2(w)");
    try c.exec("INSERT INTO a.u VALUES(2)");
    try c.expectRows("SELECT * FROM a.u2", "2\n");
    try c.expectRows("SELECT * FROM b.log", "10\n20\n");
    // After the DETACH, the TEMP trigger stays, on a table of TEMP
    // itself (which it never fires on, as in sqlite3).
    try c.exec("DETACH a");
    try c.expectRows("SELECT name, tbl_name FROM temp.sqlite_schema", "tr|u\n");
    try c.exec("CREATE TEMP TABLE u(y); INSERT INTO u VALUES(3)");
    try c.exec("ATTACH 'a.db' AS a; INSERT INTO a.u VALUES(4)");
    try c.expectRows("SELECT * FROM b.log", "10\n20\n");
    try c.expectRows("SELECT * FROM a.u2", "2\n4\n");
}

test "attach: the internal ATTACH of VACUUM, and closeDb()" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const saved = c.db.open_flags;
    c.db.open_flags.read_only = false;
    c.db.open_flags.create = true;
    try c.exec("ATTACH '' AS vacuum_db");
    c.db.open_flags = saved;
    const i_db = c.db.dbs.items.len - 1;
    try testing.expectEqualStrings("vacuum_db", c.db.dbs.items[i_db].name);
    try c.exec("CREATE TABLE vacuum_db.t(x); INSERT INTO vacuum_db.t VALUES(1)");
    attach.closeDb(c.db, i_db);
    try testing.expectEqual(@as(usize, 2), c.db.dbs.items.len);
    try c.expectRows("SELECT name FROM pragma_database_list", "main\n");
}

/// A VFS over a MemVfs that loses power at the Nth change to a file (a
/// write, truncation or delete): that change and everything after it
/// fail with IoErr and change nothing, as if the process had died.
const PowerCut = struct {
    gpa: std.mem.Allocator,
    inner: vfs.Vfs,
    at: u32,
    changes: u32 = 0,
    cut: bool = false,

    /// Count a change; true if it must fail.
    fn change(self: *PowerCut) bool {
        if (self.cut) return true;
        self.changes += 1;
        if (self.changes == self.at) self.cut = true;
        return self.cut;
    }

    fn interface(self: *PowerCut) vfs.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: vfs.Vfs.VTable = .{ .open = open, .delete = delete, .access = access, .randomness = randomness, .sleep = sleep };

    fn cast(ptr: *anyopaque) *PowerCut {
        return @ptrCast(@alignCast(ptr));
    }

    fn open(ptr: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) vfs.Error!vfs.File {
        const self = cast(ptr);
        if (self.cut and flags.create) return error.IoErr;
        const inner = try self.inner.open(path, flags);
        const f = try self.gpa.create(File);
        f.* = .{ .owner = self, .inner = inner };
        return .{ .ptr = f, .vtable = &File.vtable };
    }

    fn delete(ptr: *anyopaque, path: []const u8, sync_dir: bool) vfs.Error!void {
        if (cast(ptr).change()) return error.IoErr;
        return cast(ptr).inner.delete(path, sync_dir);
    }

    fn access(ptr: *anyopaque, path: []const u8, mode: vfs.AccessMode) vfs.Error!bool {
        return cast(ptr).inner.access(path, mode);
    }

    fn randomness(ptr: *anyopaque, buf: []u8) void {
        cast(ptr).inner.randomness(buf);
    }

    fn sleep(ptr: *anyopaque, us: u32) u32 {
        return cast(ptr).inner.sleep(us);
    }

    const File = struct {
        owner: *PowerCut,
        inner: vfs.File,

        const vtable: vfs.File.VTable = .{
            .close = close,
            .read = read,
            .write = write,
            .truncate = truncate,
            .sync = sync,
            .fileSize = fileSize,
            .lock = lock,
            .unlock = unlock,
            .checkReservedLock = checkReservedLock,
            .sectorSize = sectorSize,
            .deviceCharacteristics = deviceCharacteristics,
            .isReadOnly = isReadOnly,
        };

        fn of(ptr: *anyopaque) *File {
            return @ptrCast(@alignCast(ptr));
        }
        fn close(ptr: *anyopaque) void {
            const f = of(ptr);
            f.inner.close();
            f.owner.gpa.destroy(f);
        }
        fn read(ptr: *anyopaque, buf: []u8, offset: u64) vfs.Error!usize {
            const i = of(ptr).inner;
            return i.vtable.read(i.ptr, buf, offset);
        }
        fn write(ptr: *anyopaque, buf: []const u8, offset: u64) vfs.Error!void {
            const f = of(ptr);
            if (f.owner.change()) return error.IoErr;
            return f.inner.write(buf, offset);
        }
        fn truncate(ptr: *anyopaque, size: u64) vfs.Error!void {
            if (of(ptr).owner.change()) return error.IoErr;
            return of(ptr).inner.truncate(size);
        }
        fn sync(ptr: *anyopaque, flags: vfs.SyncFlags) vfs.Error!void {
            if (of(ptr).owner.cut) return error.IoErr;
            return of(ptr).inner.sync(flags);
        }
        fn fileSize(ptr: *anyopaque) vfs.Error!u64 {
            return of(ptr).inner.fileSize();
        }
        fn lock(ptr: *anyopaque, level: vfs.LockLevel) vfs.Error!void {
            return of(ptr).inner.lock(level);
        }
        fn unlock(ptr: *anyopaque, level: vfs.LockLevel) vfs.Error!void {
            return of(ptr).inner.unlock(level);
        }
        fn checkReservedLock(ptr: *anyopaque) vfs.Error!bool {
            return of(ptr).inner.checkReservedLock();
        }
        fn sectorSize(ptr: *anyopaque) u32 {
            return of(ptr).inner.sectorSize();
        }
        fn deviceCharacteristics(ptr: *anyopaque) vfs.DeviceCharacteristics {
            return of(ptr).inner.deviceCharacteristics();
        }
        fn isReadOnly(ptr: *anyopaque) bool {
            return of(ptr).inner.isReadOnly();
        }
    };
};

test "attach: a transaction over several databases commits atomically" {
    for ([_][]const u8{ "delete", "persist", "truncate" }) |mode| {
        // Lose power at each change to a file in turn, until the commit
        // gets through. Without a super-journal, a cut between deleting
        // (or zeroing) the two journals leaves main committed and a.db
        // rolled back.
        var at: u32 = 1;
        while (true) : (at += 1) {
            var mem = MemVfs.init(testing.allocator, testing.io);
            defer mem.deinit();
            var setup: Conn = undefined;
            try setup.openOn(&mem);
            var buf: [256]u8 = undefined;
            try setup.exec("ATTACH 'a.db' AS a; CREATE TABLE t(x); INSERT INTO t VALUES(1); CREATE TABLE a.t(x); INSERT INTO a.t VALUES(1)");
            setup.close();

            var pc: PowerCut = .{ .gpa = testing.allocator, .inner = mem.interface(), .at = at };
            var opened: ?*int.Sqlite3 = null;
            try testing.expectEqual(RC.OK, main_mod.open(pc.interface(), "test.db", .{}, &opened));
            // The journal mode is the connection's.
            const sql = try std.fmt.bufPrint(&buf, "ATTACH 'a.db' AS a; PRAGMA journal_mode={s}; BEGIN; UPDATE t SET x = 2; UPDATE a.t SET x = 2; COMMIT", .{mode});
            const rc = legacy.exec(opened.?, sql, null, null, null);
            _ = main_mod.close(opened.?);
            const committed = !pc.cut;
            if (committed) try testing.expectEqual(RC.OK, rc);

            // Another connection recovers the journals: both databases
            // have the old row or both the new one.
            var check: Conn = undefined;
            try check.openOn(&mem);
            defer check.close();
            try check.exec("ATTACH 'a.db' AS a");
            const got = try check.query("SELECT (SELECT x FROM main.t) || (SELECT x FROM a.t)");
            defer testing.allocator.free(got);
            if (committed) {
                try testing.expectEqualStrings("22\n", got);
            } else if (!std.mem.eql(u8, got, "11\n") and !std.mem.eql(u8, got, "22\n")) {
                std.debug.print("journal_mode={s}, power cut at change {d}: {s}", .{ mode, at, got });
                return error.NotAtomic;
            }
            try check.expectRows("PRAGMA integrity_check; PRAGMA a.integrity_check", "ok\nok\n");
            if (committed) {
                // The super-journal was deleted.
                var names = mem.files.keyIterator();
                while (names.next()) |name| try testing.expect(std.mem.indexOf(u8, name.*, "-mj") == null);
                break;
            }
        }
    }
}

/// Whether `xqt gen superjournal` leaves `file` in `state`.
fn fixtureExists(comptime state: []const u8, comptime file: []const u8) bool {
    const have = .{
        .{ "pending", "main.db a.db b.db main.db-journal a.db-journal b.db-journal super" },
        .{ "committed-0", "main.db a.db b.db main.db-journal a.db-journal b.db-journal" },
        .{ "committed-1", "main.db a.db b.db a.db-journal b.db-journal" },
        .{ "committed-2", "main.db a.db b.db b.db-journal" },
    };
    inline for (have) |h| {
        if (comptime std.mem.eql(u8, h[0], state)) {
            var it = std.mem.tokenizeScalar(u8, h[1], ' ');
            while (it.next()) |f| if (std.mem.eql(u8, f, file)) return true;
            return false;
        }
    }
    unreachable;
}

const fixture_files = [_][]const u8{ "main.db", "a.db", "b.db", "main.db-journal", "a.db-journal", "b.db-journal", "super" };

/// The files sqlite3 left when it died during the commit of a transaction
/// over main.db, a.db and b.db, in the order of fixture_files.
fn superJournalState(comptime state: []const u8) [fixture_files.len]?[]const u8 {
    var out: [fixture_files.len]?[]const u8 = @splat(null);
    inline for (fixture_files, 0..) |f, i| {
        if (comptime fixtureExists(state, f)) out[i] = @embedFile("../testdata/superjournal/" ++ state ++ "/" ++ f);
    }
    return out;
}

test "attach: recovery of the super-journal and journals sqlite3 left" {
    const journal = @import("../pager/journal.zig");
    inline for (.{
        // sqlite3 died before deleting the super-journal: all roll back.
        .{ "pending", "oldoldold\n" },
        // It died after deleting it (the commit point), while deleting
        // the journals: none may roll back. `xqt interop attach` found
        // a and b rolled back here in optimized builds, which read the
        // checksum of the super-journal name wrong.
        .{ "committed-0", "newnewnew\n" },
        .{ "committed-1", "newnewnew\n" },
        .{ "committed-2", "newnewnew\n" },
    }) |case| {
        const files = superJournalState(case[0]);
        var mem = MemVfs.init(testing.allocator, testing.io);
        defer mem.deinit();
        const v = mem.interface();
        for (fixture_files[0..6], files[0..6]) |n, content| {
            const bytes = content orelse continue;
            const f = try v.open(n, .{ .create = true });
            defer f.close();
            try f.write(bytes, 0);
        }
        if (files[6]) |super| {
            // The super-journal goes by the name the journals give it.
            const j = files[3].?;
            const tail = j[j.len - journal.super_trailer_len ..][0..journal.super_trailer_len];
            const len = journal.superNameLen(tail, j.len, 4096).?;
            const super_name = j[j.len - journal.super_trailer_len - len ..][0..len];
            const f = try v.open(super_name, .{ .create = true, .kind = .super_journal });
            defer f.close();
            try f.write(super, 0);
        }
        var opened: ?*int.Sqlite3 = null;
        try testing.expectEqual(RC.OK, main_mod.open(v, "main.db", .{}, &opened));
        var c: Conn = .{ .mem = &mem, .own = undefined, .db = opened.? };
        defer _ = main_mod.close(c.db);
        try c.exec("ATTACH 'a.db' AS a; ATTACH 'b.db' AS b");
        c.expectRows("SELECT (SELECT group_concat(DISTINCT b) FROM main.t) || (SELECT group_concat(DISTINCT b) FROM a.t) || (SELECT group_concat(DISTINCT b) FROM b.t)", case[1]) catch |err| {
            std.debug.print("state {s}\n", .{case[0]});
            return err;
        };
        try c.expectRows("PRAGMA integrity_check; PRAGMA a.integrity_check; PRAGMA b.integrity_check", "ok\nok\nok\n");
        // The journals of a committed transaction are finalized.
        if (files[6] == null) for (fixture_files[3..6]) |n| try testing.expect(!try v.access(n, .exists));
    }
}
