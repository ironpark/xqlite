//! Crashing an engine on purpose, to test the recovery of the other.
//!
//! - xqlite: `$XQLITE_TEST_CRASH=KIND:N[:torn]` makes `xqlite sql` exit at
//!   once at its N-th write to a file of KIND (db, journal or wal), with
//!   `torn` after writing half of it (src/vfs/crash.zig). `xqlite
//!   crash-write FILE BYTE` instead dies in the middle of a commit.
//! - sqlite3: tools/crashshim.c, built by `zig build tools` (and by `zig
//!   build check`, which passes it with --crashshim) and preloaded
//!   (DYLD_INSERT_LIBRARIES on macOS, LD_PRELOAD elsewhere), exits at the
//!   CRASH_AT-th change (a write, a truncation or an unlink) of a file
//!   whose name ends with CRASH_SUFFIX, before the change.
//!
//!     try crash.requireShim(c);           // skips the check without it
//!     const e = try crash.sqliteEnv(c, "-journal", 3);
//!     _ = try c.run(&.{ c.cfg.sqlite3, "main.db", sql }, .{ .env = e });
//!     const x = try crash.xqEnv(c, .db, 3, .{});
//!     _ = try c.run(&.{ c.cfg.xq, "sql", "main.db", sql }, .{ .env = x });

const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;

const Check = @import("Check.zig");
const Config = @import("Config.zig");

/// The variable that preloads a library.
pub const preload_var = if (builtin.os.tag.isDarwin()) "DYLD_INSERT_LIBRARIES" else "LD_PRELOAD";

pub const FileKind = enum { db, journal, wal };

/// The environment for `xqlite sql` to exit at its n-th write (from 1) to
/// a file of `kind`; `torn` writes half of that write first.
pub fn xqEnv(c: *Check, kind: FileKind, n: u32, opts: struct { torn: bool = false }) !*Environ.Map {
    const spec = try std.fmt.allocPrint(c.arena, "{t}:{d}{s}", .{ kind, n, if (opts.torn) ":torn" else "" });
    return c.env(&.{.{ "XQLITE_TEST_CRASH", spec }});
}

/// The environment for a program (sqlite3) to exit at the `at`-th change
/// (from 1) of a file whose name ends with `suffix`. Call `requireShim`
/// first.
pub fn sqliteEnv(c: *Check, suffix: []const u8, at: u32) !*Environ.Map {
    const n = try std.fmt.allocPrint(c.arena, "{d}", .{at});
    return c.env(&.{
        .{ preload_var, c.cfg.crashshim },
        .{ "CRASH_SUFFIX", suffix },
        .{ "CRASH_AT", n },
    });
}

/// Skips the check (error.Skipped) unless the preload library exists and
/// stops the reference sqlite3 (a system binary may ignore the variable).
pub fn requireShim(c: *Check) !void {
    if (!Config.exists(c.io, c.cfg.crashshim))
        return c.skip("no preload library {s} (zig build tools)", .{c.cfg.crashshim});
    const e = try sqliteEnv(c, "probe.db", 1);
    const r = try c.run(&.{ c.cfg.sqlite3, "probe.db", "CREATE TABLE t(x); SELECT 'alive';" }, .{ .env = e });
    defer c.remove("probe.db") catch {};
    if (std.mem.eql(u8, std.mem.trimEnd(u8, r.stdout, "\n"), "alive") and r.stderr.len == 0)
        return c.skip("{s} does not reach {s}", .{ preload_var, c.cfg.sqlite3 });
}
