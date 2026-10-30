//! The seeded fuzzers, after TigerBeetle's fuzz_tests.zig. Each one is a
//! function of a seed and a number of events, deterministic for a seed, so
//! that a failure can be replayed:
//!
//!   zig build fuzz -Doptimize=ReleaseSafe -- NAME [SEED] [--events N]
//!
//! Without a seed a random one is used; the seed is printed first either
//! way. A 40-digit commit hash is accepted as a seed. `zig build test` runs
//! every fuzzer with a fixed seed and few events (smoke mode), so they
//! cannot rot.

const std = @import("std");
const fuzz = @import("xqlite_base").fuzz;
const btree_fuzz = @import("xqlite_storage").btree_fuzz;
const ir_fuzz = @import("ir/fuzz.zig");

const Fuzzer = struct {
    name: []const u8,
    run: *const fn (gpa: std.mem.Allocator, io: std.Io, seed: u64, events_max: u32) anyerror!void,
    /// Events of a default run, and of a smoke run.
    events: u32,
    smoke_events: u32,
};

const fuzzers = [_]Fuzzer{
    .{ .name = "btree_model", .run = btree_fuzz.model, .events = 50_000, .smoke_events = 2_000 },
    .{ .name = "btree_corrupt", .run = btree_fuzz.corrupt, .events = 5_000, .smoke_events = 100 },
    .{ .name = "ir_roundtrip", .run = ir_fuzz.roundtrip, .events = 2_000, .smoke_events = 30 },
};

const usage =
    \\usage: zig build fuzz -- NAME [SEED] [--events N]
    \\       zig build fuzz -- smoke
    \\
    \\fuzzers:
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usageExit();
    if (std.mem.eql(u8, args[1], "smoke")) {
        for (fuzzers) |f| try runOne(init.gpa, init.io, f, smoke_seed, f.smoke_events);
        return;
    }
    const f = for (fuzzers) |f| {
        if (std.mem.eql(u8, f.name, args[1])) break f;
    } else return usageExit();

    var seed: ?u64 = null;
    var events = f.events;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--events") and i + 1 < args.len) {
            i += 1;
            events = std.fmt.parseUnsigned(u32, args[i], 10) catch return usageExit();
        } else {
            seed = fuzz.parseSeed(args[i]) orelse return usageExit();
        }
    }
    const s = seed orelse blk: {
        var b: [8]u8 = undefined;
        init.io.random(&b);
        break :blk std.mem.readInt(u64, &b, .little);
    };
    try runOne(init.gpa, init.io, f, s, events);
}

fn runOne(gpa: std.mem.Allocator, io: std.Io, f: Fuzzer, seed: u64, events: u32) !void {
    std.debug.print("fuzz {s} seed={d} events={d}\n", .{ f.name, seed, events });
    try f.run(gpa, io, seed, events);
}

fn usageExit() noreturn {
    std.debug.print("{s}", .{usage});
    for (fuzzers) |f| std.debug.print("  {s}\n", .{f.name});
    std.process.exit(2);
}

const smoke_seed = 42;

test "fuzzers: smoke" {
    for (fuzzers) |f| try f.run(std.testing.allocator, std.testing.io, smoke_seed, f.smoke_events);
}

test {
    _ = fuzz;
    _ = ir_fuzz;
}
