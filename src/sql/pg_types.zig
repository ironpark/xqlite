//! PostgreSQL's type OIDs and type modifiers of each `types.Logical`:
//! what the wire server describes a column or parameter with, and what
//! the PostgreSQL dialect's catalog (pg_attribute.atttypid, atttypmod,
//! format_type()) shows. Outside the dialect directories, as the wire
//! server has it with any set of dialects (-Ddialects).

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;

pub const Oid = u32;

/// PostgreSQL's type OIDs (pg_type.dat).
pub const oid = struct {
    pub const @"bool": Oid = 16;
    pub const bytea: Oid = 17;
    pub const name: Oid = 19;
    pub const int8: Oid = 20;
    pub const int2: Oid = 21;
    pub const int4: Oid = 23;
    pub const text: Oid = 25;
    pub const oid: Oid = 26;
    pub const json: Oid = 114;
    pub const float4: Oid = 700;
    pub const float8: Oid = 701;
    pub const unknown: Oid = 705;
    pub const bpchar: Oid = 1042;
    pub const varchar: Oid = 1043;
    pub const date: Oid = 1082;
    pub const time: Oid = 1083;
    pub const timestamp: Oid = 1114;
    pub const timestamptz: Oid = 1184;
    pub const interval: Oid = 1186;
    pub const timetz: Oid = 1266;
    pub const numeric: Oid = 1700;
    pub const uuid: Oid = 2950;
    pub const jsonb: Oid = 3802;
};

/// The array type of each element type (pg_type.typarray), and back.
const arrays = [_]struct { Oid, Oid }{
    .{ oid.bool, 1000 },        .{ oid.bytea, 1001 },    .{ oid.name, 1003 },    .{ oid.int2, 1005 },
    .{ oid.int4, 1007 },        .{ oid.text, 1009 },     .{ oid.varchar, 1015 }, .{ oid.bpchar, 1014 },
    .{ oid.int8, 1016 },        .{ oid.float4, 1021 },   .{ oid.float8, 1022 },  .{ oid.oid, 1028 },
    .{ oid.json, 199 },         .{ oid.date, 1182 },     .{ oid.time, 1183 },    .{ oid.timestamp, 1115 },
    .{ oid.timestamptz, 1185 }, .{ oid.interval, 1187 }, .{ oid.timetz, 1270 },  .{ oid.numeric, 1231 },
    .{ oid.uuid, 2951 },        .{ oid.jsonb, 3807 },
};

/// The array type of element type `o`, null if it has none here.
pub fn arrayOf(o: Oid) ?Oid {
    for (arrays) |x| if (x[0] == o) return x[1];
    return null;
}

/// The element type of array type `o`, null if `o` is no array type.
pub fn elementOf(o: Oid) ?Oid {
    for (arrays) |x| if (x[1] == o) return x[0];
    return null;
}

/// The OID a column or parameter of type `t` is described with. A type
/// not known is text, as PostgreSQL resolves an unknown literal.
pub fn ofType(t: Type) Oid {
    return switch (t.logical) {
        .unknown, .text => oid.text,
        .boolean => oid.bool,
        .int1, .int2 => oid.int2,
        .int4 => oid.int4,
        .int8 => oid.int8,
        .float4 => oid.float4,
        .float8 => oid.float8,
        .numeric => oid.numeric,
        .varchar => oid.varchar,
        .char => oid.bpchar,
        .bytes => oid.bytea,
        .date => oid.date,
        .time => oid.time,
        .time_tz => oid.timetz,
        .timestamp => oid.timestamp,
        .timestamp_tz => oid.timestamptz,
        .interval => oid.interval,
        .uuid => oid.uuid,
        .json => oid.json,
        .jsonb => oid.jsonb,
        .array => arrayOf(ofType(t.elementType())) orelse 1009,
    };
}

/// The type of a parameter the client gave OID `o`, for reading its value
/// (null: not one of ours, read as text).
pub fn typeOf(o: Oid) ?Type {
    if (elementOf(o)) |e| return if (typeOf(e)) |t| t.arrayOf() else .{ .logical = .array };
    return .{ .logical = switch (o) {
        oid.bool => .boolean,
        oid.int2 => .int2,
        oid.int4, oid.oid => .int4,
        oid.int8 => .int8,
        oid.float4 => .float4,
        oid.float8 => .float8,
        oid.numeric => .numeric,
        oid.text, oid.name, oid.unknown => .text,
        oid.varchar => .varchar,
        oid.bpchar => .char,
        oid.bytea => .bytes,
        oid.date => .date,
        oid.time => .time,
        oid.timetz => .time_tz,
        oid.timestamp => .timestamp,
        oid.timestamptz => .timestamp_tz,
        oid.interval => .interval,
        oid.uuid => .uuid,
        oid.json => .json,
        oid.jsonb => .jsonb,
        else => return null,
    } };
}

/// pg_type.typlen: the size of a fixed-size type, -1 for the others.
pub fn typeLen(o: Oid) i16 {
    return switch (o) {
        oid.bool => 1,
        oid.int2 => 2,
        oid.int4, oid.float4, oid.date, oid.oid => 4,
        oid.int8, oid.float8, oid.time, oid.timestamp, oid.timestamptz => 8,
        oid.timetz => 12,
        oid.interval, oid.uuid => 16,
        oid.name => 64,
        else => -1,
    };
}

/// The type modifier (atttypmod): a varchar(n)'s n + 4, a numeric(p,s)'s
/// (p << 16 | s) + 4, a time's or timestamp's fractional digits; -1 for
/// none.
pub fn typeMod(t: Type) i32 {
    if (t.logical == .array) return typeMod(t.elementType());
    return switch (t.logical) {
        .varchar, .char => if (t.length) |n| if (n < std.math.maxInt(i32) - 4) @as(i32, @intCast(n)) + 4 else -1 else -1,
        .numeric => if (t.precision) |p| ((@as(i32, p) << 16) | (t.scale orelse 0)) + 4 else -1,
        .time, .time_tz, .timestamp, .timestamp_tz => if (t.scale) |s| s else -1,
        else => -1,
    };
}
