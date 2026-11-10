//! The in-memory rollback journal (port of memjournal.c).
//!
//! A `MemJournal` is a `vfs.File` that keeps its content in a list of
//! fixed-size chunks on the heap. It journals transactions of
//! `:memory:` databases and of journal_mode=MEMORY, where it is never
//! written to disk (`openMemory`, sqlite3MemJournalOpen()). It also
//! buffers journals that are not needed for power-loss recovery, the
//! journals of temporary databases (`open` with a spill size,
//! sqlite3JournalOpen()): once one grows past the spill size its
//! content is copied to a real file of the VFS, which serves every
//! later call.
//!
//! An in-memory journal is only ever appended to, except that its
//! first chunk (the header) may be overwritten, and a write before the
//! end first truncates there, as in C.

const std = @import("std");
const vfs = @import("xqlite_vfs").vfs;

const Allocator = std.mem.Allocator;
const Error = vfs.Error;

/// MEMJOURNAL_DFLT_FILECHUNKSIZE less the chunk header, as C sizes the
/// chunks of a journal that never spills.
const default_chunk_size: u32 = 1024 - @sizeOf(?*Chunk);

/// FileChunk: the content follows the header in the same allocation.
const Chunk = struct {
    next: ?*Chunk,

    fn bytes(c: *Chunk, n: u32) []u8 {
        const base: [*]u8 = @ptrCast(c);
        return base[@sizeOf(Chunk)..][0..n];
    }
};

/// FilePoint: a cursor into the journal.
const FilePoint = struct {
    offset: u64 = 0,
    chunk: ?*Chunk = null,
};

pub const MemJournal = struct {
    gpa: Allocator,
    /// Bytes per chunk (nChunkSize).
    chunk_size: u32,
    /// Bytes held before spilling to a real file; negative never
    /// (nSpill).
    spill: i64,
    first: ?*Chunk = null,
    /// The end of the file (endpoint).
    end: FilePoint = .{},
    /// Where the last read ended (readpoint).
    read_point: FilePoint = .{},
    /// For spilling: the VFS, the name (null: an anonymous temporary
    /// file) and how to open the file.
    vfs: ?vfs.Vfs = null,
    name: ?[]const u8 = null,
    flags: vfs.OpenFlags = .{},
    /// The real file, once spilled; every call goes to it.
    real: ?vfs.File = null,

    const vtable = &vfs.FileImpl(MemJournal).vtable;

    /// Port of sqlite3MemJournalOpen(): a journal kept in memory for
    /// good.
    pub fn openMemory(gpa: Allocator) Allocator.Error!vfs.File {
        return create(gpa, -1, null, null, .{});
    }

    /// Port of sqlite3JournalOpen(): a journal named `name` (null: an
    /// anonymous temporary file) opened with `flags` on `v`. With a
    /// `spill` of 0 the file is opened at once; with a positive one the
    /// content stays in memory until it would grow past `spill` bytes.
    pub fn open(gpa: Allocator, v: vfs.Vfs, name: ?[]const u8, flags: vfs.OpenFlags, spill: i64) Error!vfs.File {
        if (spill == 0) return v.open(name, flags);
        return create(gpa, spill, v, name, flags);
    }

    fn create(gpa: Allocator, spill: i64, v: ?vfs.Vfs, name: ?[]const u8, flags: vfs.OpenFlags) Allocator.Error!vfs.File {
        const p = try gpa.create(MemJournal);
        p.* = .{
            .gpa = gpa,
            .chunk_size = if (spill > 0) @intCast(spill) else default_chunk_size,
            .spill = spill,
            .vfs = v,
            .name = name,
            .flags = flags,
        };
        return .{ .ptr = p, .vtable = vtable };
    }

    /// Port of sqlite3JournalIsInMemory(): whether `f` is a journal whose
    /// content is (still) in memory.
    pub fn isInMemory(f: vfs.File) bool {
        if (f.vtable != vtable) return false;
        const p: *MemJournal = @ptrCast(@alignCast(f.ptr));
        return p.real == null;
    }

    fn chunkAlloc(p: *MemJournal) Allocator.Error!*Chunk {
        const block = try p.gpa.alignedAlloc(u8, .of(Chunk), @sizeOf(Chunk) + p.chunk_size);
        const c: *Chunk = @ptrCast(block.ptr);
        c.next = null;
        return c;
    }

    /// Port of memjrnlFreeChunks().
    fn freeChunks(p: *MemJournal, first: ?*Chunk) void {
        var it = first;
        while (it) |c| {
            it = c.next;
            const base: [*]align(@alignOf(Chunk)) u8 = @ptrCast(c);
            p.gpa.free(base[0 .. @sizeOf(Chunk) + p.chunk_size]);
        }
    }

    pub fn close(p: *MemJournal) void {
        if (p.real) |r| r.close();
        p.freeChunks(p.first);
        p.gpa.destroy(p);
    }

    /// Port of memjrnlRead(): a read past the end reads nothing
    /// (SQLITE_IOERR_SHORT_READ; File.read zero-fills the buffer).
    pub fn read(p: *MemJournal, buf: []u8, offset: u64) Error!usize {
        if (p.real) |r| {
            r.read(buf, offset) catch |err| switch (err) {
                error.ShortRead => return 0,
                else => return err,
            };
            return buf.len;
        }
        if (buf.len + offset > p.end.offset) return 0;
        if (buf.len == 0) return 0;
        var chunk: ?*Chunk = undefined;
        if (p.read_point.offset != offset or offset == 0) {
            var off: u64 = 0;
            var it = p.first.?;
            while (off + p.chunk_size <= offset) : (it = it.next.?) off += p.chunk_size;
            chunk = it;
        } else {
            chunk = p.read_point.chunk.?;
        }
        var in_chunk: u32 = @intCast(offset % p.chunk_size);
        var out: []u8 = buf;
        var n_read: i64 = @intCast(buf.len);
        while (true) {
            const space = p.chunk_size - in_chunk;
            const n = @min(out.len, space);
            @memcpy(out[0..n], chunk.?.bytes(p.chunk_size)[in_chunk..][0..n]);
            out = out[n..];
            n_read -= space;
            in_chunk = 0;
            if (n_read < 0) break;
            chunk = chunk.?.next;
            if (chunk == null or n_read == 0) break;
        }
        // The read point is the chunk where the read ended.
        p.read_point = .{ .offset = if (chunk != null) offset + buf.len else 0, .chunk = chunk };
        return buf.len;
    }

    /// Port of memjrnlCreateFile(): copy the content to the real file.
    /// On failure the journal stays in memory.
    fn createFile(p: *MemJournal) Error!void {
        const real = try p.vfs.?.open(p.name, p.flags);
        errdefer real.close();
        var off: u64 = 0;
        var it = p.first;
        while (it) |c| : (it = c.next) {
            const n: u64 = @min(p.chunk_size, p.end.offset - off);
            try real.write(c.bytes(p.chunk_size)[0..@intCast(n)], off);
            off += n;
        }
        p.freeChunks(p.first);
        p.first = null;
        p.end = .{};
        p.read_point = .{};
        p.real = real;
    }

    /// Port of memjrnlWrite().
    pub fn write(p: *MemJournal, buf: []const u8, offset: u64) Error!void {
        if (p.real) |r| return r.write(buf, offset);
        if (p.spill > 0 and buf.len + offset > @as(u64, @intCast(p.spill))) {
            try p.createFile();
            return p.real.?.write(buf, offset);
        }
        // Only appends, and rewrites of the header in the first chunk.
        std.debug.assert(offset <= p.end.offset);
        if (offset > 0 and offset != p.end.offset) try p.truncate(offset);
        if (offset == 0 and p.first != null) {
            std.debug.assert(p.chunk_size > buf.len);
            @memcpy(p.first.?.bytes(p.chunk_size)[0..buf.len], buf);
            return;
        }
        var src = buf;
        while (src.len > 0) {
            var chunk = p.end.chunk;
            const in_chunk: u32 = @intCast(p.end.offset % p.chunk_size);
            const n = @min(src.len, p.chunk_size - in_chunk);
            if (in_chunk == 0) {
                // A new chunk extends the file (SQLITE_IOERR_NOMEM if
                // it cannot be had).
                const new = p.chunkAlloc() catch return error.OutOfMemory;
                if (chunk) |c| c.next = new else p.first = new;
                chunk = new;
                p.end.chunk = new;
            }
            @memcpy(chunk.?.bytes(p.chunk_size)[in_chunk..][0..n], src[0..n]);
            src = src[n..];
            p.end.offset += n;
        }
    }

    /// Port of memjrnlTruncate(): only shrinks.
    pub fn truncate(p: *MemJournal, size: u64) Error!void {
        if (p.real) |r| return r.truncate(size);
        if (size >= p.end.offset) return;
        var keep: ?*Chunk = null;
        if (size == 0) {
            p.freeChunks(p.first);
            p.first = null;
        } else {
            var off: u64 = p.chunk_size;
            var it = p.first.?;
            while (off < size) : (it = it.next.?) off += p.chunk_size;
            p.freeChunks(it.next);
            it.next = null;
            keep = it;
        }
        p.end = .{ .offset = size, .chunk = keep };
        p.read_point = .{};
    }

    /// Port of memjrnlSync(): nothing to do in memory.
    pub fn sync(p: *MemJournal, flags: vfs.SyncFlags) Error!void {
        if (p.real) |r| return r.sync(flags);
    }

    pub fn fileSize(p: *MemJournal) Error!u64 {
        if (p.real) |r| return r.fileSize();
        return p.end.offset;
    }

    // C leaves the methods below null; a journal is never locked.

    pub fn lock(p: *MemJournal, level: vfs.LockLevel) Error!void {
        if (p.real) |r| return r.lock(level);
    }

    pub fn unlock(p: *MemJournal, level: vfs.LockLevel) Error!void {
        if (p.real) |r| return r.unlock(level);
    }

    pub fn checkReservedLock(p: *MemJournal) Error!bool {
        if (p.real) |r| return r.checkReservedLock();
        return false;
    }

    pub fn sectorSize(p: *MemJournal) u32 {
        if (p.real) |r| return r.sectorSize();
        return vfs.default_sector_size;
    }

    pub fn deviceCharacteristics(p: *MemJournal) vfs.DeviceCharacteristics {
        if (p.real) |r| return r.deviceCharacteristics();
        return .{};
    }

    pub fn isReadOnly(p: *MemJournal) bool {
        if (p.real) |r| return r.isReadOnly();
        return false;
    }
};

const testing = std.testing;

test "memory journal: append, rewrite the header, read across chunks, truncate" {
    const f = try MemJournal.openMemory(testing.allocator);
    defer f.close();
    try testing.expect(MemJournal.isInMemory(f));
    var data: [3000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7);
    try f.write(data[0..28], 0);
    try f.write(data[28..], 28);
    try testing.expectEqual(@as(u64, 3000), try f.fileSize());
    try f.write("ABCD", 0);
    @memcpy(data[0..4], "ABCD");
    var buf: [3000]u8 = undefined;
    try f.read(&buf, 0);
    try testing.expectEqualSlices(u8, "ABCD", buf[0..4]);
    try testing.expectEqualSlices(u8, data[4..], buf[4..]);
    // Sequential reads use the read point.
    var off: u64 = 0;
    while (off + 512 <= 3000) : (off += 512) {
        try f.read(buf[0..512], off);
        try testing.expectEqualSlices(u8, data[@intCast(off)..][0..512], buf[0..512]);
    }
    try testing.expectError(error.ShortRead, f.read(buf[0..10], 2995));
    // A write before the end truncates there first.
    try f.write("xyz", 1500);
    try testing.expectEqual(@as(u64, 1503), try f.fileSize());
    try f.read(buf[0..3], 1500);
    try testing.expectEqualSlices(u8, "xyz", buf[0..3]);
    try f.truncate(0);
    try testing.expectEqual(@as(u64, 0), try f.fileSize());
}

test "spilling journal: copies its content to a file of the VFS" {
    const mem = @import("xqlite_vfs").mem;
    var mv = mem.MemVfs.init(testing.allocator, testing.io);
    defer mv.deinit();
    const f = try MemJournal.open(testing.allocator, mv.interface(), null, .{ .kind = .temp_journal }, 1024);
    defer f.close();
    var data: [2000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 13);
    try f.write(data[0..1000], 0);
    try testing.expect(MemJournal.isInMemory(f));
    try f.write(data[1000..], 1000);
    try testing.expect(!MemJournal.isInMemory(f));
    var buf: [2000]u8 = undefined;
    try f.read(&buf, 0);
    try testing.expectEqualSlices(u8, &data, &buf);
}
