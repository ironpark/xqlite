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
//!
//! What a uuid is (its text, its fields, versions 4 and 7, the clock of
//! uuidv7()) is the package pkg/uuid (the import `uuid`); this file is the
//! SQL functions around it: SQLite values, errors, randomness, the time.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const datetime = @import("datetime.zig");
const platform = @import("../../util/platform.zig");
const pkg = @import("uuid");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

pub const len = pkg.len;
pub const Bytes = pkg.Uuid;
pub const text_len = pkg.text_len;

// ========================================================= input, output

/// uuid_in(): the 16 bytes of `z`, or null if PostgreSQL does not read it.
pub const parse = pkg.parse;
/// uuid_out(): the hyphenated lower-case text.
pub const format = pkg.format;
/// The time of a version 1 or 7 uuid, microseconds since 1970.
pub const timestampOf = pkg.timestamp;

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

fn v4Func(ctx: *Context, _: []*Mem) void {
    var r: Bytes = undefined;
    random(ctx, &r);
    const b = pkg.v4(r);
    api.resultBlob(ctx, &b, .transient);
}

const ns_per_ms: i64 = pkg.ns_per_ms;
const ns_per_us: i64 = 1_000;
/// The last time 48 bits of milliseconds hold, in microseconds.
const max_us: i64 = @as(i64, pkg.v7_max_ms) * 1000;

/// The connection's clock for uuidv7(), nanoseconds since 1970 (the
/// connection's state, so the extension's private connection keeps one
/// per sqlite3 connection).
fn ascendingNs(ctx: *Context) i64 {
    const t = platform.now();
    return api.contextDbHandle(ctx).xq.postgres.uuidv7_clock.next(t.sec *% std.time.ns_per_s +% t.nsec);
}

/// generate_uuidv7(): the milliseconds, 12 bits of the fraction `sub_ns`
/// (nanoseconds within the millisecond), random bits.
fn v7(ctx: *Context, ms: u64, sub_ns: u32) Bytes {
    var r: [8]u8 = undefined;
    random(ctx, &r);
    return pkg.v7(ms, sub_ns, r);
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
        return api.resultErrorFields(ctx, .of("22008"), .{ .message = "timestamp out of range for UUID version 7", .detail = "UUID version 7 supports timestamps from 1970-01-01 to approximately year 10889." });
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

fn versionFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const b = arg(ctx, argv[0]) orelse return;
    const v = pkg.version(&b) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, v);
}

fn timestampFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const b = arg(ctx, argv[0]) orelse return;
    const us = timestampOf(&b) orelse return api.resultNull(ctx);
    var buf: datetime.Buf = undefined;
    api.resultText(ctx, datetime.formatTimestamp(us, &buf), .transient);
}
