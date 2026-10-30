//! Where corruption was found (SQLITE_CORRUPT_BKPT, SQLITE_CORRUPT_PAGE).
//! Every place in the storage layer that finds the file damaged returns
//! `corrupt(@src())`, or `corruptPage(pgno, @src())` when it knows the
//! page, rather than a bare error.Corrupt: the error is the same, but the
//! hook, if set, learns the source line and the page. The engine sets it
//! to report through sqlite3_log() as SQLite does; the fuzzers, to tell
//! which check fired.

const std = @import("std");

pub const Location = struct {
    src: std.builtin.SourceLocation,
    /// The damaged page; 0 if unknown.
    pgno: u32 = 0,
};

/// Called with the location of every corruption found. Set it once,
/// before opening databases: it is read without synchronization.
pub var hook: ?*const fn (Location) void = null;

/// Every database is valid (SQLITE_TESTCTRL_NEVER_CORRUPT, the inverse of
/// SQLite's CORRUPT_DB): in builds with runtime safety it turns on the
/// consistency checks that a corrupt file could fail, which SQLite's
/// SQLITE_DEBUG builds guard with CORRUPT_DB. On in test builds, whose
/// tests and fuzzers of corrupt files turn it off; the model fuzzer turns
/// it on.
pub var never_corrupt: bool = @import("builtin").is_test;

/// Whether to run those checks. Comptime false without runtime safety,
/// so that they cost nothing in release builds.
pub inline fn checking() bool {
    return std.debug.runtime_safety and never_corrupt;
}

pub fn corrupt(src: std.builtin.SourceLocation) error{Corrupt} {
    return corruptPage(0, src);
}

pub fn corruptPage(pgno: u32, src: std.builtin.SourceLocation) error{Corrupt} {
    @branchHint(.cold);
    if (hook) |h| h(.{ .src = src, .pgno = pgno });
    return error.Corrupt;
}

/// "database corruption at line N of [btree.zig]" with the page, if
/// known: the message SQLite logs (SQLITE_CORRUPT), with the file name
/// in place of the source id.
pub fn format(loc: Location, buf: []u8) []const u8 {
    const base = std.fs.path.basename(loc.src.file);
    return (if (loc.pgno != 0)
        std.fmt.bufPrint(buf, "database corruption page {d} at line {d} of [{s}]", .{ loc.pgno, loc.src.line, base })
    else
        std.fmt.bufPrint(buf, "database corruption at line {d} of [{s}]", .{ loc.src.line, base })) catch "database corruption";
}

test "corrupt calls the hook with the location" {
    const S = struct {
        var last: ?Location = null;
        fn record(loc: Location) void {
            last = loc;
        }
    };
    hook = S.record;
    defer hook = null;
    try std.testing.expectError(error.Corrupt, @as(error{Corrupt}!void, corruptPage(7, @src())));
    const loc = S.last.?;
    try std.testing.expectEqual(@as(u32, 7), loc.pgno);
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, format(loc, &buf), "database corruption page 7 at line "));
    try std.testing.expect(std.mem.endsWith(u8, format(loc, &buf), "of [corrupt.zig]"));
}
