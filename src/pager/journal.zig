//! Rollback journal file format (the on-disk parts of pager.c).
//!
//! A journal is one or more segments, each a header padded to the sector
//! size followed by page records:
//!
//!     header (sector_size bytes)
//!         8 bytes  magic
//!         4 bytes  nRec: records in this segment, or 0xffffffff for "the
//!                  rest of the file" (written when syncs are skipped)
//!         4 bytes  checksum initializer
//!         4 bytes  database size in pages before the transaction
//!         4 bytes  sector size used by the writer
//!         4 bytes  page size
//!         zero padding
//!     record (page_size + 8 bytes)
//!         4 bytes  page number
//!         N bytes  original page content
//!         4 bytes  checksum
//!
//! A multi-database commit appends a super-journal trailer (see
//! `readSuperName`). Everything here must stay byte-compatible with SQLite.

const std = @import("std");

pub const magic = [8]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };
pub const max_sector_size = 0x10000;
/// Bytes of the header that carry data; the rest of the sector is padding.
pub const header_len = 28;
/// The magic plus nRec, rewritten in place once the records are synced.
pub const nrec_len = 12;

pub const Header = struct {
    n_rec: u32,
    cksum_init: u32,
    db_size: u32,
    sector_size: u32,
    page_size: u32,

    pub fn encode(h: Header, out: *[header_len]u8, with_magic: bool) void {
        if (with_magic) out[0..8].* = magic else @memset(out[0..8], 0);
        std.mem.writeInt(u32, out[8..12], h.n_rec, .big);
        std.mem.writeInt(u32, out[12..16], h.cksum_init, .big);
        std.mem.writeInt(u32, out[16..20], h.db_size, .big);
        std.mem.writeInt(u32, out[20..24], h.sector_size, .big);
        std.mem.writeInt(u32, out[24..28], h.page_size, .big);
    }

    /// Decodes the fields after the magic. The caller checks the magic.
    pub fn decode(b: *const [header_len]u8) Header {
        return .{
            .n_rec = std.mem.readInt(u32, b[8..12], .big),
            .cksum_init = std.mem.readInt(u32, b[12..16], .big),
            .db_size = std.mem.readInt(u32, b[16..20], .big),
            .sector_size = std.mem.readInt(u32, b[20..24], .big),
            .page_size = std.mem.readInt(u32, b[24..28], .big),
        };
    }

    /// Whether the size fields are plausible. Garbage here means the header
    /// was never synced. A zero page size (SQLite before 3.5.8) must be
    /// replaced by the caller before checking.
    pub fn sizesValid(h: Header) bool {
        return h.page_size >= 512 and h.page_size <= 65536 and std.math.isPowerOfTwo(h.page_size) and
            h.sector_size >= 32 and h.sector_size <= max_sector_size and std.math.isPowerOfTwo(h.sector_size);
    }
};

pub fn nrecBytes(n_rec: u32) [nrec_len]u8 {
    var b: [nrec_len]u8 = undefined;
    b[0..8].* = magic;
    std.mem.writeInt(u32, b[8..12], n_rec, .big);
    return b;
}

pub fn recordSize(page_size: u32) u32 {
    return page_size + 8;
}

/// Encodes a record into `buf` (recordSize bytes).
pub fn encodeRecord(buf: []u8, pgno: u32, page: []const u8, cksum_init: u32) void {
    std.debug.assert(buf.len == recordSize(@intCast(page.len)));
    std.mem.writeInt(u32, buf[0..4], pgno, .big);
    @memcpy(buf[4..][0..page.len], page);
    std.mem.writeInt(u32, buf[buf.len - 4 ..][0..4], checksum(cksum_init, page), .big);
}

pub const Record = struct {
    pgno: u32,
    page: []const u8,
    cksum: u32,
};

pub fn decodeRecord(buf: []const u8) Record {
    return .{
        .pgno = std.mem.readInt(u32, buf[0..4], .big),
        .page = buf[4 .. buf.len - 4],
        .cksum = std.mem.readInt(u32, buf[buf.len - 4 ..][0..4], .big),
    };
}

/// Port of pager_cksum(): the initializer plus every 200th byte counted
/// down from the end of the page. Weak, but it catches the likely damage of
/// a torn write: one end of the record changed.
pub fn checksum(init: u32, page: []const u8) u32 {
    var cksum = init;
    var i: i64 = @as(i64, @intCast(page.len)) - 200;
    while (i > 0) : (i -= 200) cksum +%= page[@intCast(i)];
    return cksum;
}

/// Port of journalHdrOffset(): the sector boundary at or after `off`.
pub fn headerOffset(off: u64, sector_size: u32) u64 {
    if (off == 0) return 0;
    return ((off - 1) / sector_size + 1) * sector_size;
}

/// Size of the super-journal trailer that follows the name.
pub const super_trailer_len = 16;

/// Port of the parsing half of readSuperJournal(). `tail` is the last 16
/// bytes of the journal; returns the name length if they describe a
/// trailer, after which `superNameValid` checks the name itself.
///
///     4 bytes  lock page number
///     N bytes  super-journal name
///     4 bytes  N
///     4 bytes  checksum: sum of the name's bytes as signed chars
///     8 bytes  magic
pub fn superNameLen(tail: *const [super_trailer_len]u8, journal_size: u64, max_len: usize) ?u32 {
    const len = std.mem.readInt(u32, tail[0..4], .big);
    if (len == 0 or len >= max_len or len > journal_size - super_trailer_len) return null;
    if (!std.mem.eql(u8, tail[8..16], &magic)) return null;
    return len;
}

pub fn superNameValid(tail: *const [super_trailer_len]u8, name: []const u8) bool {
    var cksum = std.mem.readInt(u32, tail[4..8], .big);
    for (name) |c| cksum -%= @bitCast(@as(i32, @as(i8, @bitCast(c))));
    return cksum == 0 and isSuperName(name);
}

/// Port of pagerIsSuperJrnlName(): "<db>-mjXXXXXX9XX" with hex digits.
/// Limits what a crafted journal can make us delete.
pub fn isSuperName(name: []const u8) bool {
    if (name.len < 12) return false;
    if (!std.mem.eql(u8, name[name.len - 12 ..][0..3], "-mj")) return false;
    if (name[name.len - 3] != '9') return false;
    for (name[name.len - 9 ..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

const testing = std.testing;

test "journal: header round trip and validation" {
    const h: Header = .{ .n_rec = 3, .cksum_init = 0xdeadbeef, .db_size = 7, .sector_size = 512, .page_size = 4096 };
    var b: [header_len]u8 = undefined;
    h.encode(&b, true);
    try testing.expectEqualSlices(u8, &magic, b[0..8]);
    try testing.expectEqual(h, Header.decode(&b));
    try testing.expect(h.sizesValid());
    var bad = h;
    bad.page_size = 1000;
    try testing.expect(!bad.sizesValid());
    h.encode(&b, false);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), b[0..8]);
}

test "journal: record and checksum" {
    var page: [1024]u8 = @splat(0);
    page[24] = 1; // 1024-1000
    page[224] = 2;
    page[824] = 3;
    page[0] = 99; // never sampled
    try testing.expectEqual(@as(u32, 10 + 6), checksum(10, &page));

    var rec: [1032]u8 = undefined;
    encodeRecord(&rec, 5, &page, 10);
    const r = decodeRecord(&rec);
    try testing.expectEqual(@as(u32, 5), r.pgno);
    try testing.expectEqualSlices(u8, &page, r.page);
    try testing.expectEqual(checksum(10, &page), r.cksum);
}

test "journal: header offsets and super-journal names" {
    try testing.expectEqual(@as(u64, 0), headerOffset(0, 512));
    try testing.expectEqual(@as(u64, 512), headerOffset(100, 512));
    try testing.expectEqual(@as(u64, 512), headerOffset(512, 512));
    try testing.expectEqual(@as(u64, 2048), headerOffset(2000, 512));

    try testing.expect(isSuperName("/tmp/a.db-mj0123AB9FF"));
    try testing.expect(!isSuperName("/tmp/a.db-journal"));
    try testing.expect(!isSuperName("/tmp/a.db-mj0123AB8FF"));
}
