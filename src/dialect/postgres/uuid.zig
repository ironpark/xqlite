//! PostgreSQL's uuid: a value of 16 bytes, stored as a BLOB of them, so
//! that SQLite's order of blobs (memcmp) is PostgreSQL's order of uuids
//! (uuid_cmp() compares the bytes): indexes, ORDER BY, range scans,
//! PRIMARY KEY, UNIQUE and foreign keys work on the values as they are.
//! A column of a table made before (declared uuid, stored as TEXT) keeps
//! its 36-character text: types.zig, typing.zig's store() and
//! overload.zig choose the form by the column's storage.
//!
//! The engine functions (visible in every dialect, as the schema text
//! calls them; their meaning is fixed, docs/extension.md):
//!  - xq_pg_uuid(x): the cast to uuid, and what a value stored into a
//!    uuid column goes through: text read as uuid_in() reads it (32 hex
//!    digits of either case, a hyphen allowed after any group of four, in
//!    braces or not; else `invalid input syntax for type uuid: "x"`,
//!    22P02), a uuid's 16 bytes as they are; NULL is NULL;
//!  - xq_pg_uuid_text(x): uuid_out(): the hyphenated lower-case text of
//!    a uuid (its 16 bytes, or a text uuid_in() reads); the cast to text,
//!    `||`, and the store of a text uuid column.
//!
//! PostgreSQL 18's functions (the dialect's, Hooks.functions):
//!  - uuidv4(), and gen_random_uuid() (the parser's name for it): a
//!    random uuid of version 4;
//!  - uuidv7([shift interval]): a uuid of version 7, the Unix time in
//!    milliseconds in its first 48 bits, then 12 bits of the fraction of
//!    the millisecond (RFC 9562's method 3), then random bits. The time
//!    is a clock that moves forward on each call of the connection by at
//!    least 1/4096 ms (PostgreSQL's get_real_time_ns_ascending(), per
//!    session), so a connection's uuids are in order; the shift is added
//!    as timestamptz + interval adds it, and a time before 1970 or after
//!    the 48 bits is an error;
//!  - uuid_extract_version(u): bits 4-7 of byte 6, NULL unless the
//!    variant is RFC 9562's (bits 10 of byte 8);
//!  - uuid_extract_timestamp(u): the time of a version 1 or 7 uuid as a
//!    timestamptz, else NULL.
//! gen_random_uuid() of the table (xq_postgres_gen_random_uuid() in the
//! schema of an older database) keeps its meaning: the text of a uuid.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const datetime = @import("datetime.zig");
const platform = @import("../../util/platform.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

pub const len = 16;
pub const Bytes = [len]u8;
pub const text_len = 36;

// ========================================================= input, output

/// uuid_in(): the 16 bytes of `z`, or null if PostgreSQL does not read
/// it: 32 hex digits, a hyphen allowed after each group of four but the
/// last, the whole in braces or not; no white space.
pub fn parse(z: []const u8) ?Bytes {
    var out: Bytes = undefined;
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

/// uuid_out(): xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx in lower case.
pub fn format(b: *const Bytes) [text_len]u8 {
    var out: [text_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) catch unreachable;
    return out;
}

/// The bytes of a SQLite value that is a uuid: 16 bytes, or a text
/// uuid_in() reads (a uuid column of an older table).
pub fn ofValue(m: *Mem) ?Bytes {
    switch (api.valueType(m)) {
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse return null;
            if (b.len != len) return null;
            return b[0..len].*;
        },
        vi.SQLITE_TEXT => return parse(api.valueText(m) orelse return null),
        else => return null,
    }
}

/// The bytes of argument `m` (not NULL) of a function of uuids, or the
/// error of what it is not set and null.
fn arg(ctx: *Context, m: *Mem) ?Bytes {
    if (ofValue(m)) |b| return b;
    switch (api.valueType(m)) {
        vi.SQLITE_TEXT => {
            const z = api.valueText(m) orelse {
                api.resultErrorNomem(ctx);
                return null;
            };
            invalid(ctx, z);
        },
        vi.SQLITE_BLOB => api.resultErrorState(ctx, .of("42846"), "cannot cast type bytea to uuid"),
        vi.SQLITE_INTEGER => api.resultErrorState(ctx, .of("42846"), "cannot cast type integer to uuid"),
        else => api.resultErrorState(ctx, .of("42846"), "cannot cast type double precision to uuid"),
    }
    return null;
}

fn invalid(ctx: *Context, z: []const u8) void {
    const shown = z[0..@min(z.len, 256)];
    var buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type uuid: \"{s}\"", .{shown}) catch "invalid input syntax for type uuid";
    api.resultErrorState(ctx, .of("22P02"), msg);
}

// ====================================================== engine functions

const det: dfunc.Options = .{ .deterministic = true };

/// The store function of a uuid column (typing.zig).
pub const store_def = dfunc.scalar("xq_pg_uuid", 1, det, uuidFunc);
/// The store function of a uuid column stored as TEXT.
pub const store_text_def = dfunc.scalar("xq_pg_uuid_text", 1, det, uuidTextFunc);
pub const store = &store_def;
pub const store_text = &store_text_def;

pub const engine_functions = [_]int.FuncDef{ store_def, store_text_def };

fn uuidFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const b = arg(ctx, argv[0]) orelse return;
    api.resultBlob(ctx, &b, .transient);
}

fn uuidTextFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const b = arg(ctx, argv[0]) orelse return;
    const z = format(&b);
    api.resultText(ctx, &z, .transient);
}

// ===================================================== dialect functions

pub const functions = [_]int.FuncDef{
    dfunc.scalar("uuidv4", 0, .{}, v4Func),
    dfunc.scalar("uuidv7", 0, .{}, v7Func),
    dfunc.scalar("uuidv7", 1, .{}, v7Func),
    dfunc.scalar("uuid_extract_version", 1, det, versionFunc),
    dfunc.scalar("uuid_extract_timestamp", 1, det, timestampFunc),
};

fn random(ctx: *Context, b: []u8) void {
    @import("../../sql/func/func.zig").randomness(api.contextDbHandle(ctx), b);
}

/// Set the version (4 bits of byte 6) and RFC 9562's variant (10 in
/// byte 8).
fn setVersion(b: *Bytes, v: u8) void {
    b[6] = (b[6] & 0x0f) | v << 4;
    b[8] = (b[8] & 0x3f) | 0x80;
}

fn v4Func(ctx: *Context, _: []*Mem) void {
    var b: Bytes = undefined;
    random(ctx, &b);
    setVersion(&b, 4);
    api.resultBlob(ctx, &b, .transient);
}

const ns_per_ms: i64 = 1_000_000;
const ns_per_us: i64 = 1_000;
/// 1/4096 ms and a nanosecond: the least step that changes the 12 bits
/// of the fraction (SUBMS_MINIMAL_STEP_NS).
const min_step_ns: i64 = @divTrunc(ns_per_ms, 1 << 12) + 1;
/// The last time 48 bits of milliseconds hold, in microseconds.
const max_us: i64 = ((1 << 48) - 1) * 1000;

/// The connection's clock for uuidv7(), nanoseconds since 1970: now,
/// but at least min_step_ns after the time it last gave (the
/// connection's state, so the extension's private connection keeps one
/// per sqlite3 connection).
fn ascendingNs(ctx: *Context) i64 {
    const t = platform.now();
    var ns = t.sec *% std.time.ns_per_s +% t.nsec;
    const st = &api.contextDbHandle(ctx).xq.postgres;
    if (st.uuidv7_ns + min_step_ns >= ns) ns = st.uuidv7_ns + min_step_ns;
    st.uuidv7_ns = ns;
    return ns;
}

/// generate_uuidv7(): the milliseconds, 12 bits of the fraction `sub_ns`
/// (nanoseconds within the millisecond), random bits.
fn v7(ctx: *Context, ms: u64, sub_ns: u32) Bytes {
    var b: Bytes = undefined;
    std.mem.writeInt(u48, b[0..6], @truncate(ms), .big);
    const frac: u32 = @intCast(@as(u64, sub_ns) * (1 << 12) / @as(u64, ns_per_ms));
    b[6] = @truncate(frac >> 8);
    b[7] = @truncate(frac);
    random(ctx, b[8..]);
    setVersion(&b, 7);
    return b;
}

fn v7Func(ctx: *Context, argv: []*Mem) void {
    const ns = ascendingNs(ctx);
    if (argv.len == 0) {
        const b = v7(ctx, @intCast(@divTrunc(ns, ns_per_ms)), @intCast(@mod(ns, ns_per_ms)));
        return api.resultBlob(ctx, &b, .transient);
    }
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const shift = intervalArg(ctx, argv[0]) orelse return;
    // timestamptz + interval, in microseconds (as PostgreSQL computes it).
    const us = datetime.addInterval(@divTrunc(ns, ns_per_us), shift) catch std.math.minInt(i64);
    if (us < 0 or us > max_us) {
        return api.resultErrorState(ctx, .of("22008"), "timestamp out of range for UUID version 7");
    }
    const b = v7(ctx, @intCast(@divTrunc(us, 1000)), @intCast(@mod(us, 1000) * ns_per_us + @mod(ns, ns_per_us)));
    api.resultBlob(ctx, &b, .transient);
}

/// The shift of uuidv7(shift): the interval argument in either form (an
/// interval column's BLOB, an older one's text, a string), read by
/// datetime.zig, to which what an interval value is belongs.
fn intervalArg(ctx: *Context, m: *Mem) ?datetime.Interval {
    return datetime.intervalArg(ctx, m);
}

/// RFC 9562's variant (10 in the high bits of byte 8).
fn rfcVariant(b: *const Bytes) bool {
    return b[8] & 0xc0 == 0x80;
}

fn versionFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const b = arg(ctx, argv[0]) orelse return;
    if (!rfcVariant(&b)) return api.resultNull(ctx);
    api.resultInt64(ctx, b[6] >> 4);
}

/// Microseconds from the Gregorian epoch (1582-10-15) to 1970-01-01.
const gregorian_us: i64 = 12219292800 * std.time.us_per_s;

fn timestampFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const b = arg(ctx, argv[0]) orelse return;
    const us = timestampOf(&b) orelse return api.resultNull(ctx);
    var buf: datetime.Buf = undefined;
    api.resultText(ctx, datetime.formatTimestamp(us, &buf), .transient);
}

/// The time of a version 1 or 7 uuid, microseconds since 1970; null for
/// another.
pub fn timestampOf(b: *const Bytes) ?i64 {
    if (!rfcVariant(b)) return null;
    switch (b[6] >> 4) {
        1 => {
            // 100 ns since 1582: time_low, time_mid, time_hi.
            const t: u64 = @as(u64, std.mem.readInt(u32, b[0..4], .big)) |
                @as(u64, std.mem.readInt(u16, b[4..6], .big)) << 32 |
                @as(u64, std.mem.readInt(u16, b[6..8], .big) & 0x0fff) << 48;
            return @as(i64, @intCast(t / 10)) - gregorian_us;
        },
        7 => return @as(i64, std.mem.readInt(u48, b[0..6], .big)) * 1000,
        else => return null,
    }
}

// ================================================================ tests

const testing = std.testing;

test "pg: uuid input as uuid_in() reads it" {
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

test "pg: uuid timestamps of RFC 9562's test vectors" {
    // 2022-02-22 19:22:22 UTC.
    const t: i64 = 1645557742 * std.time.us_per_s;
    try testing.expectEqual(t, timestampOf(&parse("C232AB00-9414-11EC-B3C8-9F6BDECED846").?).?);
    try testing.expectEqual(t, timestampOf(&parse("017F22E2-79B0-7CC3-98C4-DC0C0C07398F").?).?);
    try testing.expectEqual(@as(?i64, null), timestampOf(&parse("11111111-1111-1111-1111-111111111111").?));
}
