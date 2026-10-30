//! The status counters of the library (port of the sqlite3_status()
//! half of status.c): the memory in use, the number of allocations, the
//! largest request and the page cache's own allocations, each with a
//! highwater mark.
//!
//! Counting is SQLite's SQLITE_CONFIG_MEMSTATUS, here `enabled`: off by
//! default, so the Zig API pays one predictable branch per allocation;
//! the C ABI turns it on at sqlite3_initialize() as SQLite does, unless
//! the application said SQLITE_CONFIG_MEMSTATUS 0 before. The counters
//! are atomic (C takes mem0.mutex instead). An allocation remembers in
//! its header whether it was counted (malloc.zig), so turning counting
//! on while memory is in use does not drive the counters negative.

const std = @import("std");

/// SQLITE_STATUS_* verbs.
pub const Op = enum(u4) {
    memory_used = 0,
    pagecache_used = 1,
    pagecache_overflow = 2,
    scratch_used = 3,
    scratch_overflow = 4,
    malloc_size = 5,
    parser_stack = 6,
    pagecache_size = 7,
    scratch_size = 8,
    malloc_count = 9,
};

const Counter = struct {
    now: std.atomic.Value(isize) = .init(0),
    mx: std.atomic.Value(isize) = .init(0),
};

/// sqlite3Stat and sqlite3GlobalConfig.bMemstat.
pub var state: struct {
    enabled: bool = false,
    counters: [10]Counter = @splat(.{}),
} = .{};

/// Whether allocations are counted (bMemstat).
pub inline fn enabled() bool {
    return state.enabled;
}

/// SQLITE_CONFIG_MEMSTATUS.
pub fn enable(on: bool) void {
    state.enabled = on;
}

fn raiseMax(c: *Counter, v: isize) void {
    var m = c.mx.load(.monotonic);
    while (v > m) m = c.mx.cmpxchgWeak(m, v, .monotonic, .monotonic) orelse return;
}

/// Port of sqlite3StatusUp().
pub fn up(op: Op, n: isize) void {
    const c = &state.counters[@backingInt(op)];
    const v = c.now.fetchAdd(n, .monotonic) + n;
    raiseMax(c, v);
}

/// Port of sqlite3StatusDown().
pub fn down(op: Op, n: isize) void {
    _ = state.counters[@backingInt(op)].now.fetchSub(n, .monotonic);
}

/// Port of sqlite3StatusHighwater(): raise the highwater mark of `op`
/// (whose value is not tracked, only its largest) to `x`.
pub fn highwater(op: Op, x: isize) void {
    raiseMax(&state.counters[@backingInt(op)], x);
}

/// Port of sqlite3_status64(): the current value and highwater mark of
/// `op`; `reset` restarts the mark at the current value.
pub fn status64(op: Op, current: *i64, hw: *i64, reset: bool) void {
    const c = &state.counters[@backingInt(op)];
    const now = c.now.load(.monotonic);
    current.* = now;
    hw.* = c.mx.load(.monotonic);
    if (reset) c.mx.store(now, .monotonic);
}

test "status: counters and highwater marks" {
    var cur: i64 = 0;
    var hw: i64 = 0;
    const before = state.counters[@backingInt(Op.parser_stack)].now.load(.monotonic);
    up(.parser_stack, 10);
    up(.parser_stack, 5);
    down(.parser_stack, 12);
    status64(.parser_stack, &cur, &hw, true);
    try std.testing.expectEqual(before + 3, cur);
    try std.testing.expect(hw >= before + 15);
    status64(.parser_stack, &cur, &hw, false);
    try std.testing.expectEqual(cur, hw);
    down(.parser_stack, 3);
}
