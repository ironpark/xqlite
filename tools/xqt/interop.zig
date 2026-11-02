//! `xqt interop [NAME...]`: cross-checks against sqlite3, every module or
//! the ones named. A module (interop/*.zig) declares
//!
//!     pub const name = "sql";            // xqt interop sql
//!     pub const about = "...";           // one line for xqt list
//!     pub fn register(s: *xqt.Suite) !void { try s.add("...", check, .{}); }
//!
//! and is listed in `modules` below; its checks run in parallel with those
//! of every other module. A module that checks a dialect also declares
//!
//!     pub const dialect = "mariadb";     // a -Ddialects name
//!
//! and is left out when the xqlite under test is built without it.

const std = @import("std");
const xqt = @import("xqt");
const xqlite_config = @import("xqlite_config");

pub const modules = .{
    @import("interop/sql.zig"),
    @import("interop/hot_journal.zig"),
    @import("interop/btree.zig"),
    @import("interop/savepoint.zig"),
    @import("interop/pragma.zig"),
    @import("interop/shell.zig"),
    @import("interop/wal.zig"),
    @import("interop/attach.zig"),
    @import("interop/vacuum.zig"),
    @import("interop/analyze.zig"),
    @import("interop/pg.zig"),
    @import("interop/mariadb.zig"),
    @import("interop/mssql.zig"),
    @import("interop/oracle.zig"),
};

pub const usage =
    \\usage: xqt interop [NAME...]   (no NAME: all; xqt list names them)
    \\
;

pub fn run(gpa: std.mem.Allocator, io: std.Io, cfg: *const xqt.Config, out: *std.Io.Writer, args: []const []const u8) !u8 {
    for (args) |a| {
        if (a.len > 0 and a[0] == '-') return usageError(out);
        if (!known(a)) {
            try out.print("xqt interop: no module {s}\n", .{a});
            try list(out);
            return 2;
        }
    }
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "interop" });
    defer suite.deinit();
    inline for (modules) |m| {
        if (comptime !built(m)) {
            if (contains(args, m.name)) try out.print("xqt interop: {s}: xqlite is built without the {s} dialect\n", .{ m.name, m.dialect });
        } else if (args.len == 0 or contains(args, m.name)) {
            suite.prefix = m.name ++ ": ";
            try m.register(&suite);
        }
    }
    suite.prefix = "";
    suite.run();
    try suite.summary();
    return @intFromBool(suite.failed() > 0);
}

/// Whether the xqlite under test has the dialect `m` checks (true for a
/// module that checks none).
fn built(comptime m: type) bool {
    if (!@hasDecl(m, "dialect")) return true;
    return @field(xqlite_config, "dialect_" ++ m.dialect);
}

/// One line per module, for `xqt list`.
pub fn list(out: *std.Io.Writer) !void {
    inline for (modules) |m| try out.print("  {s:<14} {s}\n", .{ m.name, m.about });
}

fn known(name: []const u8) bool {
    inline for (modules) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn usageError(out: *std.Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}
