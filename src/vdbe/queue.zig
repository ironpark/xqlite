//! The queue of a recursive CTE without ORDER BY (OP_OpenQueue,
//! OP_QueuePush, OP_QueuePop): records go in at the tail and come out at
//! the head, first in, first out. Not in C, where the queue is an
//! ephemeral table read with OP_Rewind, OP_RowData and OP_Delete and
//! written with OP_NewRowid and OP_Insert (generateWithRecursiveQuery()).
//! The order is the same, that of the rowids C gives: the order the rows
//! were pushed in.
//!
//! The records are kept back to back in chunks, each record after its
//! length (a native u32). The chunk at the tail is being filled; when it is
//! full it joins the list of chunks to read, and the list is read from its
//! first chunk, whose space goes back to the allocator (or is kept as
//! `spare` for the next chunk) once read. When only the tail chunk is left
//! and all of it has been read, it is filled again from its start, so that
//! a queue that never holds many rows at once (the usual counter or walk)
//! keeps one chunk.
//!
//! Memory is bounded as the ephemeral table of C is by its page cache:
//! once the chunks in memory take `limit` bytes (the size at which a
//! sorter writes a PMA, from cache_size, sorter.maxMemory()), full tail
//! chunks are appended to a temporary file instead, and read back one at a
//! time when the chunks in memory before them have been read. With PRAGMA
//! temp_store=MEMORY there is no limit, as C's ephemeral table then lives
//! in memory too.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const int = @import("../sql/sqlite_int.zig");
const sorter = @import("sorter.zig");
const vfs = @import("xqlite_vfs").vfs;

const Allocator = std.mem.Allocator;
const Mem = vi.Mem;

pub const Error = vfs.Error;

/// The size of a chunk, unless a record needs more.
const chunk_size: usize = 32 * 1024;

/// The bytes before each record: its length.
const len_size = @sizeOf(u32);

/// A run of records in memory.
const Chunk = struct {
    /// The next chunk of the list to read.
    next: ?*Chunk = null,
    /// Bytes used from the start of `buf`.
    len: usize = 0,
    /// Bytes read from the start of `buf` (off <= len).
    off: usize = 0,
    buf: []u8,

    fn unread(c: *const Chunk) bool {
        return c.off < c.len;
    }
};

pub const Queue = struct {
    gpa: Allocator,
    db: *int.Sqlite3,
    /// Full chunks to read, oldest first: all older than those of the
    /// file, which are all older than `tail`.
    first: ?*Chunk = null,
    last: ?*Chunk = null,
    /// The chunk being filled; read once `first` and the file are empty.
    tail: ?*Chunk = null,
    /// A chunk of chunk_size bytes kept for the next one needed.
    spare: ?*Chunk = null,
    /// The size of the buffers of `first`..`last` and `tail`.
    in_memory: usize = 0,
    /// Above this many bytes in memory, full chunks go to the file; 0: no
    /// limit.
    limit: usize,
    /// The temporary file of the chunks between `last` and `tail`, each a
    /// u32 length and the bytes; read from `file_read`, written at
    /// `file_end`.
    file: ?vfs.File = null,
    file_read: u64 = 0,
    file_end: u64 = 0,

    /// A new empty queue.
    pub fn init(db: *int.Sqlite3) Error!*Queue {
        const q = try db.gpa.create(Queue);
        q.* = .{ .gpa = db.gpa, .db = db, .limit = @intCast(sorter.maxMemory(db)) };
        return q;
    }

    /// Free the queue and its chunks, and close its file.
    pub fn deinit(q: *Queue) void {
        q.clear();
        if (q.spare) |c| q.freeChunk(c);
        if (q.file) |f| f.close();
        q.gpa.destroy(q);
    }

    /// Empty the queue (OP_OpenQueue on an open queue). The spare chunk
    /// and the file are kept.
    pub fn clear(q: *Queue) void {
        var it = q.first;
        while (it) |c| {
            it = c.next;
            q.recycle(c);
        }
        q.first = null;
        q.last = null;
        if (q.tail) |c| q.recycle(c);
        q.tail = null;
        q.file_read = 0;
        q.file_end = 0;
        std.debug.assert(q.in_memory == 0);
    }

    /// Append `record` at the tail.
    pub fn push(q: *Queue, record: []const u8) Error!void {
        const need = len_size + record.len;
        const t = if (q.tail) |t| if (t.buf.len - t.len >= need) t else try q.retireTail(need) else try q.retireTail(need);
        std.mem.writeInt(u32, t.buf[t.len..][0..len_size], @intCast(record.len), .native);
        @memcpy(t.buf[t.len + len_size ..][0..record.len], record);
        t.len += need;
    }

    /// Move the record at the head into `out`, as a BLOB. Returns false if
    /// the queue is empty.
    pub fn pop(q: *Queue, out: *Mem) Error!bool {
        while (q.first) |c| {
            if (c.unread()) return take(c, out);
            q.first = c.next;
            if (q.first == null) q.last = null;
            q.recycle(c);
        }
        if (q.file_read < q.file_end) {
            const c = try q.load();
            return take(c, out);
        }
        const t = q.tail orelse return false;
        if (!t.unread()) return false;
        const ok = try take(t, out);
        // All read: fill it again from its start.
        if (!t.unread()) {
            t.len = 0;
            t.off = 0;
        }
        return ok;
    }

    /// Copy the record at the read position of `c` into `out`.
    fn take(c: *Chunk, out: *Mem) Error!bool {
        std.debug.assert(c.unread());
        const n: usize = std.mem.readInt(u32, c.buf[c.off..][0..len_size], .native);
        const record = c.buf[c.off + len_size ..][0..n];
        try mem.clearAndResize(out, n);
        @memcpy(out.z.?[0..n], record);
        out.n = @intCast(n);
        out.setTypeFlag(.{ .Blob = true });
        c.off += len_size + n;
        return true;
    }

    /// Make room for `need` bytes: put the tail chunk, if any, where it
    /// is read from (the list, or the file), and return the new tail.
    fn retireTail(q: *Queue, need: usize) Error!*Chunk {
        if (q.tail) |t| {
            if (!t.unread()) {
                // Nothing in it to keep: it is empty or all read.
                t.len = 0;
                t.off = 0;
                if (t.buf.len >= need) return t;
            } else if (q.file_read == q.file_end and (q.limit == 0 or q.in_memory < q.limit)) {
                // In memory, after the list.
                if (q.last) |l| l.next = t else q.first = t;
                q.last = t;
                q.tail = null;
            } else {
                // To the file, after the chunks already there (or because
                // there are some: the order must hold).
                try q.spill(t);
                t.len = 0;
                t.off = 0;
                if (t.buf.len >= need) return t;
            }
            if (q.tail) |old| {
                q.recycle(old);
                q.tail = null;
            }
        }
        const c = try q.newChunk(need);
        q.tail = c;
        return c;
    }

    /// Append the unread part of `c` to the file.
    fn spill(q: *Queue, c: *Chunk) Error!void {
        const f = q.file orelse blk: {
            const f = try sorter.openTempFile(q.db);
            q.file = f;
            break :blk f;
        };
        const data = c.buf[c.off..c.len];
        var hdr: [len_size]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(data.len), .native);
        try f.write(&hdr, q.file_end);
        try f.write(data, q.file_end + len_size);
        q.file_end += len_size + data.len;
        if (@import("builtin").is_test) q.db.n_queue_spilled += 1;
    }

    /// Read the next chunk of the file into the list, which is empty.
    fn load(q: *Queue) Error!*Chunk {
        std.debug.assert(q.first == null and q.file_read < q.file_end);
        const f = q.file.?;
        var hdr: [len_size]u8 = undefined;
        try f.read(&hdr, q.file_read);
        const n: usize = std.mem.readInt(u32, &hdr, .native);
        const c = try q.newChunk(n);
        errdefer q.recycle(c);
        try f.read(c.buf[0..n], q.file_read + len_size);
        c.len = n;
        q.file_read += len_size + n;
        // Read to its end: the file is written again from its start.
        if (q.file_read == q.file_end) {
            q.file_read = 0;
            q.file_end = 0;
        }
        q.first = c;
        q.last = c;
        return c;
    }

    /// An empty chunk of at least `need` bytes, counted in `in_memory`.
    fn newChunk(q: *Queue, need: usize) Error!*Chunk {
        const size = @max(chunk_size, need);
        if (q.spare) |c| if (c.buf.len >= size) {
            q.spare = null;
            q.in_memory += c.buf.len;
            return c;
        };
        const c = try q.gpa.create(Chunk);
        errdefer q.gpa.destroy(c);
        c.* = .{ .buf = try q.gpa.alloc(u8, size) };
        q.in_memory += size;
        return c;
    }

    /// Give back a chunk taken out of the queue: kept as the spare if it
    /// has the usual size and there is none, else freed.
    fn recycle(q: *Queue, c: *Chunk) void {
        q.in_memory -= c.buf.len;
        if (q.spare == null and c.buf.len == chunk_size) {
            c.* = .{ .buf = c.buf };
            q.spare = c;
        } else {
            q.freeChunk(c);
        }
    }

    fn freeChunk(q: *Queue, c: *Chunk) void {
        q.gpa.free(c.buf);
        q.gpa.destroy(c);
    }
};

// ================================================================== tests

const testing = std.testing;
const Conn = @import("../sql/sql_test.zig").Conn;

/// Run `sql` with a small cache, so that big queues spill, then with
/// temp_store=MEMORY, where they do not: the rows must be the same.
/// Returns the number of chunks spilled.
fn expectSameSpilled(c: *Conn, sql: []const u8, expected: []const u8) !u64 {
    try c.exec("PRAGMA temp_store=0");
    const before = c.db.n_queue_spilled;
    const spilled = try c.query(sql);
    defer testing.allocator.free(spilled);
    const n = c.db.n_queue_spilled - before;
    try c.exec("PRAGMA temp_store=2");
    const in_memory = try c.query(sql);
    defer testing.allocator.free(in_memory);
    try c.exec("PRAGMA temp_store=0");
    try testing.expectEqual(before + n, c.db.n_queue_spilled);
    try testing.expectEqualStrings(in_memory, spilled);
    try testing.expectEqualStrings(expected, spilled);
    return n;
}

test "queue: rows come out in the order they went in" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows(
        \\WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<5)
        \\SELECT group_concat(x) FROM c
    , "1,2,3,4,5\n");
    // Breadth first: each row adds two.
    try c.expectRows(
        \\WITH RECURSIVE t(n, d) AS (SELECT 1, 0 UNION ALL SELECT n*2+k, d+1 FROM t, (SELECT 0 AS k UNION ALL SELECT 1) WHERE d<3)
        \\SELECT group_concat(n, ' ') FROM t
    , "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15\n");
    // UNION: the rows already seen are not queued again.
    try c.expectRows(
        \\WITH RECURSIVE r(x) AS (SELECT 1 UNION SELECT (x*3)%7 FROM r)
        \\SELECT group_concat(x) FROM r
    , "1,3,2,6,4,5\n");
    // Records bigger than a chunk, and types that must survive.
    try c.expectRows(
        \\WITH RECURSIVE b(i, v) AS (SELECT 0, NULL UNION ALL
        \\  SELECT i+1, CASE i%4 WHEN 0 THEN zeroblob(100000) WHEN 1 THEN 1.5 WHEN 2 THEN 'x' ELSE 7 END FROM b WHERE i<12)
        \\SELECT group_concat(i || typeof(v) || ifnull(length(v), ''), ' ') FROM b
    , "0null 1blob100000 2real3 3text1 4integer1 5blob100000 6real3 7text1 8integer1 9blob100000 10real3 11text1 12integer1\n");
    // LIMIT stops with rows left; the queue is opened again (cleared) for
    // each run of the correlated subquery.
    try c.expectRows(
        \\SELECT (WITH RECURSIVE c(x) AS (SELECT n UNION ALL SELECT x+1 FROM c) SELECT sum(x) FROM (SELECT x FROM c LIMIT 3))
        \\FROM (SELECT 1 AS n UNION ALL SELECT 10 UNION ALL SELECT 100)
    , "6\n33\n303\n");
}

test "queue: a big frontier spills to a file" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // 512-byte pages: the queue spills past 250 pages in memory.
    try c.exec("PRAGMA page_size=512; PRAGMA cache_size=10");
    try c.exec("CREATE TABLE t(x)");
    // A frontier of 2^17 rows of ~60 bytes, in memory at once.
    try testing.expect(try expectSameSpilled(&c,
        \\WITH RECURSIVE t(n, d, pad) AS (SELECT 1, 0, printf('%050d', 0) UNION ALL
        \\  SELECT n*2+k, d+1, printf('%050d', n*2+k) FROM t, (SELECT 0 AS k UNION ALL SELECT 1) WHERE d<17)
        \\SELECT count(*), sum(n), sum(n*(n%7)), min(pad), max(pad) FROM t
    , "262143|34359607296|103079084031|00000000000000000000000000000000000000000000000000|00000000000000000000000000000000000000000000262143\n") > 0);
    // The order of the rows, and a queue filled and emptied several
    // times over the spill.
    try testing.expect(try expectSameSpilled(&c,
        \\WITH RECURSIVE t(n, d, pad) AS (SELECT 1, 0, zeroblob(40) UNION ALL
        \\  SELECT n*2+k, d+1, zeroblob(40) FROM t, (SELECT 0 AS k UNION ALL SELECT 1) WHERE d<15)
        \\SELECT count(*), sum(n = rn) FROM (SELECT n, row_number() OVER () AS rn FROM t)
    , "65535|65535\n") > 0);
}
