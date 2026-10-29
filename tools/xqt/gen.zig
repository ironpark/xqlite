//! `xqt gen NAME [ARGS]`: regenerates test data. A generator (gen/*.zig)
//! declares
//!
//!     pub const name = "superjournal";   // xqt gen superjournal
//!     pub const usage = "...";           // its lines of xqt help gen
//!     pub fn run(gpa, io, cfg, out, args) !u8
//!
//! and is listed in `generators` below.

const std = @import("std");
const xqt = @import("xqt");

pub const generators = .{
    @import("gen/superjournal.zig"),
};

pub const usage = blk: {
    var text: []const u8 = "usage: xqt gen NAME [ARGS]\n\n";
    for (generators) |g| text = text ++ g.usage;
    break :blk text;
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, cfg: *const xqt.Config, out: *std.Io.Writer, args: []const []const u8) !u8 {
    if (args.len > 0) {
        inline for (generators) |g| {
            if (std.mem.eql(u8, args[0], g.name)) return g.run(gpa, io, cfg, out, args[1..]);
        }
    }
    try out.writeAll(usage);
    return 2;
}

test {
    inline for (generators) |g| _ = g;
}
