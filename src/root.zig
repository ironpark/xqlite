//! xqlite: an embedded SQL database ported from SQLite to Zig.
//!
//! Layers are ported bottom-up; see README.md for the roadmap.

const std = @import("std");

pub const varint = @import("util/varint.zig");

pub const vfs = @import("vfs/vfs.zig");
pub const MemVfs = @import("vfs/mem.zig").MemVfs;
pub const UnixVfs = @import("vfs/unix.zig").UnixVfs;

pub const pager = @import("pager/pager.zig");
pub const pcache = @import("pager/pcache.zig");

pub const btree = @import("btree/btree.zig");

pub const record = @import("vdbe/record.zig");

pub const tokenize = @import("parse/tokenize.zig");
pub const sql_util = @import("sql/util.zig");
pub const numeric = @import("sql/numeric.zig");
pub const printf = @import("sql/printf.zig");

pub const vdbe = struct {
    pub const mem = @import("vdbe/mem.zig");
    pub const aux = @import("vdbe/aux.zig");
    pub const serial = @import("vdbe/serial.zig");
};

// Analyze every declaration of the SQL layer, which is not yet reachable
// from a public entry point.
test {
    inline for (.{
        @import("vdbe/mem.zig"),   @import("vdbe/aux.zig"),   @import("vdbe/serial.zig"),
        @import("vdbe/vdbe_int.zig"), @import("sql/expr.zig"), @import("sql/build.zig"),
        @import("sql/select.zig"), @import("sql/window.zig"), @import("sql/main.zig"),
        @import("sql/util.zig"),   @import("sql/walker.zig"), @import("sql/trigger.zig"),
        @import("parse/parser.zig"), @import("vdbe/exec.zig"), @import("vdbe/sorter.zig"),
        @import("vdbe/rowset.zig"), @import("vdbe/api.zig"),
    }) |file| std.testing.refAllDecls(file);
}

/// The SQLite release this port tracks (SQLITE_VERSION_NUMBER). Keep in sync
/// with SQLITE_VERSION in tools/fetch-sqlite.sh.
pub const sqlite_version_number = 3054001;

test {
    std.testing.refAllDecls(@This());
}

test "read header of a database written by sqlite3" {
    const bytes = @embedFile("testdata/basic.db");
    const h = try btree.header.Header.parse(bytes[0..btree.header.size]);
    try std.testing.expectEqual(@as(u32, 1024), h.page_size);
    try std.testing.expectEqual(@as(u32, 42), h.user_version);
    try std.testing.expectEqual(@as(u32, 1481724236), h.application_id);
    try std.testing.expectEqual(btree.header.TextEncoding.utf8, h.text_encoding);
    try std.testing.expectEqual(@as(u32, 4), h.schema_format);
    try std.testing.expect(h.inHeaderSizeValid());
    try std.testing.expectEqual(@as(u32, bytes.len / 1024), h.database_size);
}
