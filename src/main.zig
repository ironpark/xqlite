const std = @import("std");
const Io = std.Io;

const xqlite = @import("xqlite");
const shell = @import("shell.zig");
const slt = @import("slt.zig");
const fuzzcheck = @import("fuzzcheck.zig");
const Header = xqlite.btree.header.Header;
const Btree = xqlite.btree.Btree;
const Cursor = xqlite.btree.Cursor;
const record = xqlite.record;
const Value = record.Value;

const usage =
    \\usage: xqlite <command> [args]
    \\
    \\commands:
    \\  dbinfo <file>             print the database file header
    \\  recover <file>            open the database, rolling back a hot journal
    \\  crash-write <file> <byte> overwrite every page, then exit after commit
    \\                            phase one, leaving a hot journal (testing aid)
    \\  check <file>              run the b-tree integrity check on every table
    \\                            and index listed in the schema
    \\  bt-fill <file> <n> [av]   create table t and index t_b with n rows, then
    \\                            delete every 7th row; av sets the auto-vacuum
    \\                            mode of a new file: none, full or incremental
    \\                            (testing aid)
    \\  bt-churn <file>           delete, update and insert rows of t and t_b
    \\                            (testing aid, see `xqt interop btree`)
    \\  bt-vacuum <file>          run an incremental vacuum to completion
    \\  sql [file] [sql...]       a sqlite3-compatible shell: run SQL and
    \\                            dot-commands on the database (in memory if
    \\                            no file), else read them from standard input
    \\  slt [options] script...   run sqllogictest scripts (xqlite slt for help)
    \\  fuzzcheck [options] db... run SQLite's fuzz corpora (test/fuzzdata*.db)
    \\                            and report crashes and leaks (xqlite fuzzcheck
    \\                            for help)
    \\
    \\environment:
    \\  XQLITE_TEST_CRASH=F:N[:torn]  sql: exit at once at the Nth write to a file
    \\                            of kind F (wal, db or journal); with torn,
    \\                            only half of that write is done (a testing
    \\                            aid, see `xqt interop wal`)
    \\
;

/// A crash during `fuzzcheck` names the fuzz case it happened in.
pub const panic = std.debug.FullPanic(fuzzcheck.panic);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    // sqlite3_config(SQLITE_CONFIG_MALLOC): safe builds take the memory of
    // the library from the leak-checking allocator of main(); fast builds
    // keep the default, the C library's malloc() (as mem1.c).
    if (std.debug.runtime_safety) xqlite.malloc.configMalloc(init.gpa);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len == 3 and std.mem.eql(u8, args[1], "dbinfo")) {
        try dbinfo(arena, io, args[2], out);
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "recover")) {
        try recover(arena, io, args[2], out);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "crash-write")) {
        const fill = try std.fmt.parseInt(u8, args[3], 0);
        try crashWrite(arena, io, args[2], fill);
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "check")) {
        try check(arena, io, args[2], out);
    } else if ((args.len == 4 or args.len == 5) and std.mem.eql(u8, args[1], "bt-fill")) {
        const av = if (args.len == 5)
            std.meta.stringToEnum(xqlite.btree.AutoVacuum, args[4]) orelse return error.BadAutoVacuumMode
        else
            .none;
        try btFill(arena, io, args[2], try std.fmt.parseInt(u32, args[3], 10), av);
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "bt-churn")) {
        try btChurn(arena, io, args[2]);
    } else if (args.len >= 2 and std.mem.eql(u8, args[1], "sql")) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
        var unix = xqlite.UnixVfs.init(init.gpa, io);
        // $XQLITE_TEST_CRASH: crash at a chosen write (see usage).
        var crash: xqlite.crash_vfs.CrashVfs = undefined;
        var v = unix.interface();
        if (std.c.getenv("XQLITE_TEST_CRASH")) |z| {
            const spec = xqlite.crash_vfs.Spec.parse(std.mem.span(z)) orelse {
                std.debug.print("bad XQLITE_TEST_CRASH: {s}\n{s}", .{ z, usage });
                std.process.exit(2);
            };
            crash = .init(init.gpa, v, spec);
            v = crash.interface();
        }
        const code = try shell.run(
            init.gpa,
            io,
            v,
            if (args.len > 2) args[2] else null,
            if (args.len > 3) args[3..] else &.{},
            out,
            &stderr_file_writer.interface,
        );
        if (code != 0) {
            out.flush() catch {};
            std.process.exit(code);
        }
    } else if (args.len >= 2 and std.mem.eql(u8, args[1], "slt")) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
        const code = try slt.run(init.gpa, io, args[2..], out, &stderr_file_writer.interface);
        if (code != 0) {
            out.flush() catch {};
            std.process.exit(code);
        }
    } else if (args.len >= 2 and std.mem.eql(u8, args[1], "fuzzcheck")) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
        const code = try fuzzcheck.run(init.gpa, io, args[2..], out, &stderr_file_writer.interface);
        if (code != 0) {
            out.flush() catch {};
            std.process.exit(code);
        }
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "bt-vacuum")) {
        try btVacuum(arena, io, args[2]);
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
}

fn dbinfo(gpa: std.mem.Allocator, io: Io, path: []const u8, out: *Io.Writer) !void {
    var unix = xqlite.UnixVfs.init(gpa, io);
    const vfs = unix.interface();
    const file = try vfs.open(path, .{ .read_write = false });
    defer file.close();

    try file.lock(.shared);

    var buf: [xqlite.btree.header.size]u8 = undefined;
    try file.read(&buf, 0);
    const h = try Header.parse(&buf);
    const file_size = try file.fileSize();

    const fields = .{
        .{ "page size", h.page_size },
        .{ "write format", @backingInt(h.write_version) },
        .{ "read format", @backingInt(h.read_version) },
        .{ "reserved bytes", h.reserved_space },
        .{ "file change counter", h.file_change_counter },
        .{ "database page count", h.database_size },
        .{ "freelist page count", h.freelist_count },
        .{ "schema cookie", h.schema_cookie },
        .{ "schema format", h.schema_format },
        .{ "default cache size", h.default_cache_size },
        .{ "autovacuum top root", h.largest_root_page },
        .{ "incremental vacuum", h.incremental_vacuum },
        .{ "text encoding", @backingInt(h.text_encoding) },
        .{ "user version", h.user_version },
        .{ "application id", h.application_id },
        .{ "software version", h.sqlite_version },
    };
    inline for (fields) |f| try out.print("{s:<20} {d}\n", .{ f[0], f[1] });
    try out.print("{s:<20} {d}\n", .{ "file size", file_size });
}

/// Takes a read lock, which rolls back any hot journal, then adopts the page
/// size from the (recovered) header. For the pager-level commands; `Btree`
/// does this itself.
fn lockAndAdoptHeader(p: *xqlite.pager.Pager) !void {
    try p.sharedLock();
    var buf: [xqlite.btree.header.size]u8 = undefined;
    try p.readFileHeader(&buf);
    const h = try Header.parse(&buf);
    try p.setPageSize(h.page_size, h.reserved_space);
}

fn recover(gpa: std.mem.Allocator, io: Io, path: []const u8, out: *Io.Writer) !void {
    var unix = xqlite.UnixVfs.init(gpa, io);
    const v = unix.interface();
    const p = try xqlite.pager.Pager.open(gpa, v, path, .{ .create = false });
    defer p.close(.{});

    const had_journal = try v.access(p.journal_path, .exists);
    try lockAndAdoptHeader(p);
    const p1 = try p.get(1, .{});
    defer p.unrefPageOne(p1);
    try out.print("pages {d}, page size {d}, journal {s}\n", .{
        p.pageCount(),
        p.page_size,
        if (!had_journal) "absent" else if (try v.access(p.journal_path, .exists)) "kept" else "rolled back",
    });
}

fn crashWrite(gpa: std.mem.Allocator, io: Io, path: []const u8, fill: u8) !void {
    var unix = xqlite.UnixVfs.init(gpa, io);
    const p = try xqlite.pager.Pager.open(gpa, unix.interface(), path, .{ .create = false });
    try lockAndAdoptHeader(p);
    const p1 = try p.get(1, .{});
    try p.begin(false);
    try p.write(p1);
    @memset(p1.data, fill);
    var pgno: xqlite.pager.Pgno = 2;
    while (pgno <= p.pageCount()) : (pgno += 1) {
        if (p.isLockPage(pgno)) continue;
        const pg = try p.get(pgno, .{});
        defer p.unref(pg);
        try p.write(pg);
        @memset(pg.data, fill);
    }
    try p.commitPhaseOne(false);
    // Simulated power loss: no phase two, no unlock. The OS drops the locks.
    std.process.exit(0);
}

// ============================================================= b-tree tools

fn openBtree(gpa: std.mem.Allocator, io: Io, path: []const u8, opts: xqlite.btree.Options) !*Btree {
    const unix = try gpa.create(xqlite.UnixVfs);
    unix.* = .init(gpa, io);
    return Btree.open(gpa, unix.interface(), path, opts);
}

/// Root pages of the schema objects, by name.
fn schemaRoots(gpa: std.mem.Allocator, bt: *Btree) !std.StringArrayHashMapUnmanaged(xqlite.btree.Pgno) {
    var roots: std.StringArrayHashMapUnmanaged(xqlite.btree.Pgno) = .empty;
    var cur: Cursor = undefined;
    try bt.cursor(&cur, 1, .{});
    defer cur.close();
    var ok = try cur.first();
    while (ok) : (ok = try cur.next()) {
        var v: [5]Value = undefined;
        // Kept for the name strings, which point into it.
        _ = try readRecord(gpa, &cur, &v);
        if (v[3] == .int and v[3].int > 0) try roots.put(gpa, v[1].text, @intCast(v[3].int));
    }
    return roots;
}

fn check(gpa: std.mem.Allocator, io: Io, path: []const u8, out: *Io.Writer) !void {
    const bt = try openBtree(gpa, io, path, .{});
    defer bt.close(.{});
    try bt.beginTrans(.read, 0);
    defer bt.commit() catch {};
    var roots = try schemaRoots(gpa, bt);
    const list = try std.mem.concat(gpa, xqlite.btree.Pgno, &.{ &.{1}, roots.values() });
    const report = try bt.integrityCheck(gpa, list, 100);
    try out.print("{s}\n", .{if (report.n_err == 0) "ok" else report.message});
}

/// Decodes the current entry into `out`. The values point into the
/// returned buffer.
fn readRecord(gpa: std.mem.Allocator, cur: *Cursor, out: []Value) ![]u8 {
    const data = try gpa.alloc(u8, cur.payloadSize());
    errdefer gpa.free(data);
    try cur.payload(0, data);
    if (try record.decode(data, out) != out.len) return error.Corrupt;
    return data;
}

// The demo schema shared with `xqt interop btree`, which builds the same
// content with SQL to compare against.
const SchemaObject = struct { type: []const u8, name: []const u8, sql: []const u8 };
const demo_objects = [_]SchemaObject{
    .{ .type = "table", .name = "t", .sql = "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB)" },
    .{ .type = "index", .name = "t_b", .sql = "CREATE INDEX t_b ON t(b)" },
};
const demo_key_info: record.KeyInfo = .{ .gpa = std.heap.smp_allocator, .sort_orders = &.{ .asc, .asc } };

/// printf('v-%d', (i*7919)%n)
fn demoB(buf: []u8, i: u64, n: u64) []const u8 {
    return std.fmt.bufPrint(buf, "v-{d}", .{(i * 7919) % n}) catch unreachable;
}

/// cast(printf('%.*c', len, ch) AS BLOB)
fn demoC(buf: []u8, len: usize, ch: u8) []const u8 {
    @memset(buf[0..len], ch);
    return buf[0..len];
}

/// Inserts a table row (with `rowid`) or an index key (without).
fn insertRecord(cur: *Cursor, rowid: ?i64, values: []const Value) !void {
    var buf: [16384]u8 = undefined;
    const rec = record.encodeBuf(values, &buf);
    try cur.insert(if (rowid) |r| .{ .rowid = r, .data = rec } else .{ .key = rec }, .{});
}

/// Deletes row `rowid` of t and its t_b entry. The table cursor is left so
/// that next() continues the scan.
fn deleteRow(gpa: std.mem.Allocator, tc: *Cursor, ic: *Cursor, rowid: i64) !void {
    if (try tc.tableMoveto(rowid, false) != .eq) return error.Corrupt;
    var v: [3]Value = undefined;
    const data = try readRecord(gpa, tc, &v);
    defer gpa.free(data);
    const search: record.UnpackedRecord = .{ .info = &demo_key_info, .values = &.{ v[1], .{ .int = rowid } } };
    if (try ic.indexMoveto(search.indexKey()) != .eq) return error.Corrupt;
    try ic.delete(.{});
    try tc.delete(.{ .save_position = true });
}

fn btFill(gpa: std.mem.Allocator, io: Io, path: []const u8, n: u32, av: xqlite.btree.AutoVacuum) !void {
    const bt = try openBtree(gpa, io, path, .{ .auto_vacuum = av });
    defer bt.close(.{});
    try bt.beginTrans(.write, 0);
    errdefer bt.rollback(null, false) catch {};

    const t_root = try bt.createTable(.intkey);
    const i_root = try bt.createTable(.blobkey);
    {
        var sc: Cursor = undefined;
        try bt.cursor(&sc, 1, .{ .write = true });
        defer sc.close();
        for (demo_objects, [_]xqlite.btree.Pgno{ t_root, i_root }, 1..) |obj, root, rowid| {
            try insertRecord(&sc, @intCast(rowid), &.{
                .{ .text = obj.type }, .{ .text = obj.name }, .{ .text = "t" }, .{ .int = root }, .{ .text = obj.sql },
            });
        }
    }
    // What SQLite sets when creating the first table.
    try bt.updateMeta(.schema_version, 1);
    try bt.updateMeta(.file_format, 4);
    try bt.updateMeta(.text_encoding, 1);

    {
        var tc: Cursor = undefined;
        try bt.cursor(&tc, t_root, .{ .write = true });
        defer tc.close();
        var ic: Cursor = undefined;
        try bt.cursor(&ic, i_root, .{ .write = true, .key_info = demo_key_info.btreeKeyInfo() });
        defer ic.close();

        var b_buf: [32]u8 = undefined;
        var c_buf: [4096]u8 = undefined;
        for (1..n + 1) |i| {
            const b = demoB(&b_buf, i, n);
            const c = demoC(&c_buf, if (i % 50 == 0) 3000 else i % 20 + 1, 'p');
            try insertRecord(&tc, @intCast(i), &.{ .null, .{ .text = b }, .{ .blob = c } });
            try insertRecord(&ic, null, &.{ .{ .text = b }, .{ .int = @intCast(i) } });
        }
        var i: i64 = 7;
        while (i <= n) : (i += 7) try deleteRow(gpa, &tc, &ic, i);
    }
    try bt.commit();
}

fn btChurn(gpa: std.mem.Allocator, io: Io, path: []const u8) !void {
    const bt = try openBtree(gpa, io, path, .{});
    defer bt.close(.{});
    try bt.beginTrans(.write, 0);
    errdefer bt.rollback(null, false) catch {};
    var roots = try schemaRoots(gpa, bt);
    const t_root = roots.get("t") orelse return error.NoTable;
    const i_root = roots.get("t_b") orelse return error.NoIndex;

    {
        var tc: Cursor = undefined;
        try bt.cursor(&tc, t_root, .{ .write = true });
        defer tc.close();
        var ic: Cursor = undefined;
        try bt.cursor(&ic, i_root, .{ .write = true, .key_info = demo_key_info.btreeKeyInfo() });
        defer ic.close();

        // DELETE FROM t WHERE a%3=0
        var ok = try tc.first();
        while (ok) {
            const a = tc.integerKey();
            if (@mod(a, 3) == 0) try deleteRow(gpa, &tc, &ic, a);
            ok = try tc.next();
        }

        // UPDATE t SET c=cast(printf('%.*c', 1500+a, 'u') AS BLOB)
        //   WHERE a%3=1 AND a<200
        var c_buf: [4096]u8 = undefined;
        var a: i64 = 1;
        while (a < 200) : (a += 3) {
            if (try tc.tableMoveto(a, false) != .eq) continue;
            var v: [3]Value = undefined;
            const data = try readRecord(gpa, &tc, &v);
            defer gpa.free(data);
            try insertRecord(&tc, a, &.{ .null, v[1], .{ .blob = demoC(&c_buf, @intCast(1500 + a), 'u') } });
        }

        // INSERT INTO t VALUES(100000+k, 'new-'||k, ...) for k in 1..500
        var b_buf: [32]u8 = undefined;
        for (1..501) |k| {
            const b = std.fmt.bufPrint(&b_buf, "new-{d}", .{k}) catch unreachable;
            const c = demoC(&c_buf, if (k % 10 == 0) 2500 else k % 30 + 1, 'n');
            const rowid: i64 = @intCast(100000 + k);
            try insertRecord(&tc, rowid, &.{ .null, .{ .text = b }, .{ .blob = c } });
            try insertRecord(&ic, null, &.{ .{ .text = b }, .{ .int = rowid } });
        }
    }
    try bt.commit();
}

fn btVacuum(gpa: std.mem.Allocator, io: Io, path: []const u8) !void {
    const bt = try openBtree(gpa, io, path, .{});
    defer bt.close(.{});
    try bt.beginTrans(.write, 0);
    errdefer bt.rollback(null, false) catch {};
    while (try bt.incrVacuum()) {}
    try bt.commit();
}

test {
    _ = shell;
    _ = slt;
    _ = fuzzcheck;
    _ = @import("qrf.zig");
}
