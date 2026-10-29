//! Helpers for the seeded fuzzers (src/fuzz_tests.zig), after TigerBeetle's
//! testing/fuzz.zig: seeds that may be commit hashes, and swarm testing,
//! where each run turns some operations off and skews the rest, so that
//! rare interleavings come up more often than with uniform choices.

const std = @import("std");

/// Parse a seed: a decimal number, or a 40-digit commit hash (so CI can
/// fuzz a new seed for each commit and still be reproducible).
pub fn parseSeed(s: []const u8) ?u64 {
    if (s.len == 40) {
        const hash = std.fmt.parseUnsigned(u160, s, 16) catch return null;
        return @truncate(hash);
    }
    return std.fmt.parseUnsigned(u64, s, 10) catch null;
}

/// Weights for the values of `E`, for `chooseWeighted`: random, with some
/// values off. At least one value keeps a weight.
pub fn randomEnumWeights(rand: std.Random, comptime E: type) std.enums.EnumArray(E, u32) {
    var weights: std.enums.EnumArray(E, u32) = .initFill(0);
    var any = false;
    while (!any) {
        for (std.enums.values(E)) |e| {
            const w: u32 = if (rand.boolean()) rand.intRangeAtMost(u32, 1, 100) else 0;
            weights.set(e, w);
            if (w > 0) any = true;
        }
    }
    return weights;
}

/// A value of `E` drawn by `weights`, which must not all be zero.
pub fn chooseWeighted(rand: std.Random, comptime E: type, weights: std.enums.EnumArray(E, u32)) E {
    var total: u64 = 0;
    for (weights.values) |w| total += w;
    std.debug.assert(total > 0);
    var pick = rand.uintLessThan(u64, total);
    for (std.enums.values(E)) |e| {
        if (pick < weights.get(e)) return e;
        pick -= weights.get(e);
    }
    unreachable;
}

test parseSeed {
    try std.testing.expectEqual(@as(?u64, 42), parseSeed("42"));
    try std.testing.expectEqual(@as(?u64, 0x89abcdef01234567), parseSeed("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expectEqual(@as(?u64, null), parseSeed("x"));
}

test chooseWeighted {
    const E = enum { a, b, c };
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    var weights: std.enums.EnumArray(E, u32) = .initFill(0);
    weights.set(.b, 5);
    for (0..100) |_| try std.testing.expectEqual(E.b, chooseWeighted(rand, E, weights));
    for (0..100) |_| {
        const w = randomEnumWeights(rand, E);
        try std.testing.expect(w.get(.a) + w.get(.b) + w.get(.c) > 0);
    }
}
