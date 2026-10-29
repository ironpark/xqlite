//! A work pool: independent jobs spread over threads.

const std = @import("std");

/// Calls `func(ctx, i)` for every i in 0..n, on up to `jobs` threads, and
/// returns when all calls have. Jobs start in order of i, so put the
/// longest first. `func` must be safe to run concurrently with itself.
pub fn forEach(jobs: usize, n: usize, ctx: anytype, comptime func: fn (@TypeOf(ctx), usize) void) void {
    const Ctx = @TypeOf(ctx);
    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        n: usize,
        ctx: Ctx,

        fn work(s: *@This()) void {
            while (true) {
                const i = s.next.fetchAdd(1, .monotonic);
                if (i >= s.n) return;
                func(s.ctx, i);
            }
        }
    };
    var shared: Shared = .{ .n = n, .ctx = ctx };
    var threads: [256]std.Thread = undefined;
    const want = @min(@max(jobs, 1), n, threads.len);
    var started: usize = 0;
    // This thread is one of the workers.
    while (started + 1 < want) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, Shared.work, .{&shared}) catch break;
    }
    shared.work();
    for (threads[0..started]) |t| t.join();
}

test forEach {
    var hits: [100]std.atomic.Value(u32) = @splat(.init(0));
    forEach(8, hits.len, &hits, struct {
        fn f(h: *[100]std.atomic.Value(u32), i: usize) void {
            _ = h[i].fetchAdd(1, .monotonic);
        }
    }.f);
    for (&hits) |*h| try std.testing.expectEqual(1, h.load(.monotonic));
}
