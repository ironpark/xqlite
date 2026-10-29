//! The 100-byte database file header at the start of page 1.
//! See https://www.sqlite.org/fileformat2.html#the_database_header and the
//! page-1 validation in lockBtree() (btree.c).

const std = @import("std");

pub const size = 100;
pub const magic = "SQLite format 3\x00";

pub const min_page_size = 512;
pub const max_page_size = 65536;
pub const default_page_size = 4096;

/// Max embedded, min embedded and leaf payload fractions (offsets 21-23).
/// Fixed since 3.6.0.
const payload_fractions = [3]u8{ 64, 32, 32 };

pub const TextEncoding = enum(u32) {
    utf8 = 1,
    utf16le = 2,
    utf16be = 3,
    _,
};

/// File format versions at offsets 18/19.
pub const FormatVersion = enum(u8) {
    legacy = 1,
    wal = 2,
    _,

    pub fn known(v: FormatVersion) bool {
        return @intFromEnum(v) <= @intFromEnum(FormatVersion.wal);
    }
};

/// Byte offsets of the header fields that are read or written in place on
/// page 1.
pub const offset = struct {
    pub const write_version = 18;
    pub const read_version = 19;
    pub const reserved_space = 20;
    pub const file_change_counter = 24;
    pub const database_size = 28;
    pub const first_freelist_trunk = 32;
    pub const freelist_count = 36;
    /// The meta values (btree.Meta), 4 bytes each, starting with the
    /// freelist count.
    pub const meta = 36;
    pub const largest_root_page = 52;
    pub const incremental_vacuum = 64;
    pub const version_valid_for = 92;
};

/// Big-endian u32 fields of `Header` and their byte offsets.
const u32_fields = .{
    .{ "file_change_counter", offset.file_change_counter },
    .{ "database_size", offset.database_size },
    .{ "first_freelist_trunk", offset.first_freelist_trunk },
    .{ "freelist_count", offset.freelist_count },
    .{ "schema_cookie", 40 },
    .{ "schema_format", 44 },
    .{ "default_cache_size", 48 },
    .{ "largest_root_page", offset.largest_root_page },
    .{ "user_version", 60 },
    .{ "incremental_vacuum", offset.incremental_vacuum },
    .{ "application_id", 68 },
    .{ "version_valid_for", offset.version_valid_for },
    .{ "sqlite_version", 96 },
};

pub const Header = struct {
    page_size: u32 = default_page_size,
    write_version: FormatVersion = .legacy,
    read_version: FormatVersion = .legacy,
    /// Bytes reserved at the end of each page for extensions.
    reserved_space: u8 = 0,
    file_change_counter: u32 = 0,
    /// Size of the database in pages. Only trustworthy when
    /// `version_valid_for == file_change_counter`; see `inHeaderSizeValid`.
    database_size: u32 = 0,
    first_freelist_trunk: u32 = 0,
    freelist_count: u32 = 0,
    schema_cookie: u32 = 0,
    /// 1 to 4. Newly created databases use 4.
    schema_format: u32 = 4,
    default_cache_size: u32 = 0,
    /// Page number of the largest root b-tree page in auto/incremental
    /// vacuum mode, otherwise 0.
    largest_root_page: u32 = 0,
    text_encoding: TextEncoding = .utf8,
    user_version: u32 = 0,
    incremental_vacuum: u32 = 0,
    application_id: u32 = 0,
    version_valid_for: u32 = 0,
    /// SQLITE_VERSION_NUMBER of the library that last wrote the file.
    sqlite_version: u32 = 0,

    pub const ParseError = error{
        /// Not an SQLite database (SQLITE_NOTADB).
        NotADatabase,
    };

    /// Decodes and validates a header. Port of the checks in lockBtree().
    pub fn parse(bytes: *const [size]u8) ParseError!Header {
        if (!std.mem.eql(u8, bytes[0..16], magic)) return error.NotADatabase;
        // Readers must refuse files whose read version they do not know. An
        // unknown write version only makes the file read-only; see `readOnly`.
        const read_version: FormatVersion = @enumFromInt(bytes[19]);
        if (!read_version.known()) return error.NotADatabase;
        if (!std.mem.eql(u8, bytes[21..24], &payload_fractions)) return error.NotADatabase;

        const page_size = pageSize(bytes) orelse return error.NotADatabase;
        if (page_size - bytes[20] < 480) return error.NotADatabase;

        var h: Header = .{
            .page_size = page_size,
            .write_version = @enumFromInt(bytes[18]),
            .read_version = read_version,
            .reserved_space = bytes[20],
            .text_encoding = @enumFromInt(get4(bytes, 56)),
        };
        inline for (u32_fields) |f| @field(h, f[0]) = get4(bytes, f[1]);
        return h;
    }

    pub fn write(h: Header, out: *[size]u8) void {
        std.debug.assert(std.math.isPowerOfTwo(h.page_size));
        std.debug.assert(h.page_size >= min_page_size and h.page_size <= max_page_size);
        @memcpy(out[0..16], magic);
        const ps: u16 = if (h.page_size == max_page_size) 1 else @intCast(h.page_size);
        std.mem.writeInt(u16, out[16..18], ps, .big);
        out[18] = @intFromEnum(h.write_version);
        out[19] = @intFromEnum(h.read_version);
        out[20] = h.reserved_space;
        out[21..24].* = payload_fractions;
        put4(out, 56, @intFromEnum(h.text_encoding));
        @memset(out[72..92], 0);
        inline for (u32_fields) |f| put4(out, f[1], @field(h, f[0]));
    }

    /// Bytes per page available to b-tree content.
    pub fn usableSize(h: Header) u32 {
        return h.page_size - h.reserved_space;
    }

    /// Writers newer than us may have used features we do not understand.
    pub fn readOnly(h: Header) bool {
        return !h.write_version.known();
    }

    /// The in-header database size is only valid if the file was last written
    /// by SQLite 3.7.0 or later, which keeps `version_valid_for` in sync.
    /// Otherwise the size must be derived from the file length.
    pub fn inHeaderSizeValid(h: Header) bool {
        return h.database_size != 0 and h.version_valid_for == h.file_change_counter;
    }

    pub fn autoVacuum(h: Header) bool {
        return h.largest_root_page != 0;
    }

    pub fn incrementalVacuum(h: Header) bool {
        return h.incremental_vacuum != 0;
    }
};

/// The page size stored at offset 16, or null if it is not a legal size.
pub fn pageSize(bytes: *const [size]u8) ?u32 {
    // The value 1 means 65536; this decodes both forms in one step.
    const page_size: u32 = (@as(u32, bytes[16]) << 8) | (@as(u32, bytes[17]) << 16);
    return if (validPageSize(page_size)) page_size else null;
}

/// A power of two from 512 to 65536.
pub fn validPageSize(page_size: u32) bool {
    return page_size >= min_page_size and page_size <= max_page_size and std.math.isPowerOfTwo(page_size);
}

fn get4(b: *const [size]u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

fn put4(b: *[size]u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .big);
}

const testing = std.testing;

test "header round trip" {
    var buf: [size]u8 = undefined;
    inline for (.{ 512, 4096, 65536 }) |ps| {
        const h: Header = .{
            .page_size = ps,
            .reserved_space = 8,
            .file_change_counter = 7,
            .database_size = 3,
            .version_valid_for = 7,
            .user_version = 0xdeadbeef,
            .text_encoding = .utf16le,
            .sqlite_version = 3054001,
        };
        h.write(&buf);
        const p = try Header.parse(&buf);
        try testing.expectEqual(h, p);
        try testing.expectEqual(@as(u32, ps - 8), p.usableSize());
        try testing.expect(p.inHeaderSizeValid());
    }
}

test "header rejects bad input" {
    var buf: [size]u8 = undefined;
    const good: Header = .{};
    good.write(&buf);
    _ = try Header.parse(&buf);

    var b = buf;
    b[0] = 's';
    try testing.expectError(error.NotADatabase, Header.parse(&b));

    b = buf;
    std.mem.writeInt(u16, b[16..18], 1000, .big);
    try testing.expectError(error.NotADatabase, Header.parse(&b));

    b = buf;
    std.mem.writeInt(u16, b[16..18], 256, .big);
    try testing.expectError(error.NotADatabase, Header.parse(&b));

    b = buf;
    b[19] = 3;
    try testing.expectError(error.NotADatabase, Header.parse(&b));

    b = buf;
    b[18] = 3;
    try testing.expect((try Header.parse(&b)).readOnly());

    b = buf;
    b[22] = 33;
    try testing.expectError(error.NotADatabase, Header.parse(&b));

    b = buf;
    std.mem.writeInt(u16, b[16..18], 512, .big);
    b[20] = 33; // usable size 479 < 480
    try testing.expectError(error.NotADatabase, Header.parse(&b));
}
