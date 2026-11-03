//! uuid: RFC 9562 UUIDs as 16 bytes, with no dependency but std.
//!
//! - Text: `parse()` reads what PostgreSQL's uuid_in() reads (32 hex
//!   digits of either case, a hyphen allowed after any group of four but
//!   the last, the whole in braces or not, no white space); `format()`
//!   writes the hyphenated lower-case form.
//! - Fields: `version()` and `timestamp()` (versions 1 and 7), both null
//!   unless the variant is RFC 9562's.
//! - New values: `v4()` from 16 random bytes; `v7()` from a Unix time in
//!   milliseconds, the nanoseconds within that millisecond (12 bits of
//!   the fraction, RFC 9562's method 3) and 8 random bytes. `Clock` gives
//!   times that move forward on each call, so the v7 uuids of one clock
//!   are in order (PostgreSQL's get_real_time_ns_ascending()).
//!
//! The bytes are in network order, so comparing them as bytes (memcmp)
//! orders uuids as PostgreSQL's uuid_cmp() does. The caller supplies the
//! randomness and the time: the package reads no clock and no entropy.

const std = @import("std");

pub const len = 16;
/// A uuid: its 16 bytes in network order.
pub const Uuid = [len]u8;
/// The length of `format()`'s text.
pub const text_len = 36;

/// The 16 bytes of `z`, or null if it is not a uuid: 32 hex digits, a
/// hyphen allowed after each group of four but the last, the whole in
/// braces or not; no white space.
pub fn parse(z: []const u8) ?Uuid {
    var out: Uuid = undefined;
    var i: usize = 0;
    const braces = z.len > 0 and z[0] == '{';
    if (braces) i = 1;
    for (0..len) |k| {
        if (i + 2 > z.len) return null;
        const hi = std.fmt.charToDigit(z[i], 16) catch return null;
        const lo = std.fmt.charToDigit(z[i + 1], 16) catch return null;
        out[k] = hi << 4 | lo;
        i += 2;
        if (i < z.len and z[i] == '-' and k % 2 == 1 and k < len - 1) i += 1;
    }
    if (braces) {
        if (i >= z.len or z[i] != '}') return null;
        i += 1;
    }
    if (i != z.len) return null;
    return out;
}

/// xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx in lower case.
pub fn format(u: *const Uuid) [text_len]u8 {
    var out: [text_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{ u[0..4], u[4..6], u[6..8], u[8..10], u[10..16] }) catch unreachable;
    return out;
}

/// RFC 9562's variant: 10 in the high bits of byte 8.
pub fn rfcVariant(u: *const Uuid) bool {
    return u[8] & 0xc0 == 0x80;
}

/// The version (the high 4 bits of byte 6), null unless the variant is
/// RFC 9562's.
pub fn version(u: *const Uuid) ?u4 {
    if (!rfcVariant(u)) return null;
    return @intCast(u[6] >> 4);
}

/// Set the version `v` and RFC 9562's variant.
pub fn setVersion(u: *Uuid, v: u4) void {
    u[6] = (u[6] & 0x0f) | @as(u8, v) << 4;
    u[8] = (u[8] & 0x3f) | 0x80;
}

/// A version 4 uuid of the 16 random bytes `random`.
pub fn v4(random: Uuid) Uuid {
    var u = random;
    setVersion(&u, 4);
    return u;
}

pub const ns_per_ms: u32 = 1_000_000;
/// The last Unix time in milliseconds the 48 bits of a version 7 uuid
/// hold (about the year 10889).
pub const v7_max_ms: u64 = (1 << 48) - 1;

/// A version 7 uuid: the Unix time `ms` in the first 48 bits, 12 bits of
/// the fraction `sub_ns` (nanoseconds within the millisecond, less than
/// ns_per_ms), then the 8 bytes of `random` under the variant bits.
pub fn v7(ms: u64, sub_ns: u32, random: [8]u8) Uuid {
    std.debug.assert(ms <= v7_max_ms and sub_ns < ns_per_ms);
    var u: Uuid = undefined;
    std.mem.writeInt(u48, u[0..6], @intCast(ms), .big);
    const frac: u32 = @intCast(@as(u64, sub_ns) * (1 << 12) / ns_per_ms);
    u[6] = @truncate(frac >> 8);
    u[7] = @truncate(frac);
    u[8..].* = random;
    setVersion(&u, 7);
    return u;
}

/// A clock for v7(): nanoseconds since 1970 that move forward by at least
/// `min_step_ns` on each call, whatever the time given, so that the
/// uuids made from its times are in order.
pub const Clock = struct {
    last_ns: i64 = 0,

    /// 1/4096 ms and a nanosecond: the least step that changes the 12
    /// bits of the fraction.
    pub const min_step_ns: i64 = @divTrunc(ns_per_ms, 1 << 12) + 1;

    /// The time to use for `now_ns` (the time of the system).
    pub fn next(c: *Clock, now_ns: i64) i64 {
        var ns = now_ns;
        if (c.last_ns + min_step_ns >= ns) ns = c.last_ns + min_step_ns;
        c.last_ns = ns;
        return ns;
    }
};

/// Microseconds from the Gregorian epoch (1582-10-15) to 1970-01-01.
const gregorian_us: i64 = 12219292800 * std.time.us_per_s;

/// The time of a version 1 or 7 uuid, microseconds since 1970; null for
/// another.
pub fn timestamp(u: *const Uuid) ?i64 {
    switch (version(u) orelse return null) {
        1 => {
            // 100 ns since 1582: time_low, time_mid, time_hi.
            const t: u64 = @as(u64, std.mem.readInt(u32, u[0..4], .big)) |
                @as(u64, std.mem.readInt(u16, u[4..6], .big)) << 32 |
                @as(u64, std.mem.readInt(u16, u[6..8], .big) & 0x0fff) << 48;
            return @as(i64, @intCast(t / 10)) - gregorian_us;
        },
        7 => return @as(i64, std.mem.readInt(u48, u[0..6], .big)) * 1000,
        else => return null,
    }
}

// ================================================================ tests

const testing = std.testing;

test "uuid: input as PostgreSQL's uuid_in() reads it" {
    const want = parse("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11").?;
    for ([_][]const u8{
        "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11",
        "{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}",
        "a0eebc999c0b4ef8bb6d6bb9bd380a11",
        "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11",
        "{a0eebc999c0b4ef8bb6d6bb9bd380a11}",
        "a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11",
    }) |z| try testing.expectEqual(want, parse(z).?);
    for ([_][]const u8{
        "",
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1",
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11-",
        "a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11-",
        " a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11 ",
        "{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}",
        "a0e-ebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "a0eebc99--9c0b-4ef8-bb6d-6bb9bd380a11",
        "-a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "g0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
        "11111111-1111-1111-1111-111111111111F",
    }) |z| try testing.expect(parse(z) == null);
    try testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", &format(&want));
}

test "uuid: timestamps of RFC 9562's test vectors" {
    // 2022-02-22 19:22:22 UTC.
    const t: i64 = 1645557742 * std.time.us_per_s;
    try testing.expectEqual(t, timestamp(&parse("C232AB00-9414-11EC-B3C8-9F6BDECED846").?).?);
    try testing.expectEqual(t, timestamp(&parse("017F22E2-79B0-7CC3-98C4-DC0C0C07398F").?).?);
    try testing.expectEqual(@as(?i64, null), timestamp(&parse("11111111-1111-1111-1111-111111111111").?));
}

test "uuid: version 4 and 7" {
    const a = v4(@splat(0xff));
    try testing.expectEqual(@as(?u4, 4), version(&a));
    try testing.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", &format(&a));

    // RFC 9562's version 7 example: 2022-02-22 19:22:22.000 UTC.
    const u = v7(1645557742000, 0, .{ 0x98, 0xc4, 0xdc, 0x0c, 0x0c, 0x07, 0x39, 0x8f });
    try testing.expectEqualStrings("017f22e2-79b0-7000-98c4-dc0c0c07398f", &format(&u));
    try testing.expectEqual(@as(?i64, 1645557742000 * 1000), timestamp(&u));
    // The fraction of the millisecond orders uuids of one millisecond.
    const later = v7(1645557742000, ns_per_ms / 2, @splat(0));
    try testing.expectEqual(@as(u8, 0x78), later[6]);
    try testing.expect(std.mem.order(u8, &u, &later) == .lt);
}

test "uuid: the clock moves forward" {
    var c: Clock = .{};
    const a = c.next(1000 * ns_per_ms);
    const b = c.next(1000 * ns_per_ms);
    const d = c.next(999 * ns_per_ms);
    try testing.expect(a < b and b < d);
    try testing.expectEqual(Clock.min_step_ns, b - a);
}
