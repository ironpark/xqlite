//! PostgreSQL's formatting functions (formatting.c) as SQL functions:
//!
//!  - to_char(x, template): of an integer, a real, a double precision or
//!    a numeric by the number templates (numformat.zig), of a timestamp,
//!    timestamptz, date or interval by the date/time templates
//!    (dtformat.zig); NULL for an empty template of a date/time or an
//!    infinite interval, '' for an empty template of a number;
//!  - to_number(text, template): a numeric (numformat.zig);
//!  - to_date(text, template), to_timestamp(text, template): a date and a
//!    timestamptz (dtformat.zig); to_timestamp(double) the timestamptz of
//!    seconds since 1970.
//!
//! The type of to_char()'s first argument decides how it is written,
//! and a timestamp, a timestamptz and a date are the same TEXT here: so
//! overload.zig (overloadCall()) makes a call whose argument has a type
//! xq_pg_to_char(x, template, kind), `kind` a Kind. to_char() itself reads
//! a value by its storage: an integer as a bigint, a REAL as a double, a
//! numeric key as a numeric, an interval BLOB as an interval, text as a
//! timestamp.
//!
//! The template is parsed once per statement (sqlite3_set_auxdata()):
//! the calls of a statement pass the same one.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const dec = @import("../decimal.zig");
const ivl = @import("../interval.zig");
const datetime = @import("datetime.zig");
const numformat = @import("numformat.zig");
const dtformat = @import("dtformat.zig");
const decimal_sql = @import("../decimal_sql.zig");
const util = @import("../../sql/util.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Allocator = std.mem.Allocator;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("to_char", 2, det, toCharFunc),
    dfunc.scalar("to_date", 2, det, dfunc.bind(toDateTimeFunc, .{true})),
    dfunc.scalar("to_number", 2, det, toNumberFunc),
    dfunc.scalar("to_timestamp", 1, det, epochFunc),
    dfunc.scalar("to_timestamp", 2, det, dfunc.bind(toDateTimeFunc, .{false})),
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_to_char", 3, det, toCharFunc),
};

/// The type of a value to_char() (and timezone()) is told: its third
/// argument. The numbers are part of the schema's text: never changed.
pub const Kind = enum(u8) {
    auto = 0,
    int4 = 1,
    int8 = 2,
    float4 = 3,
    float8 = 4,
    numeric = 5,
    timestamp = 6,
    timestamptz = 7,
    date = 8,
    interval = 9,
    time = 10,
    timetz = 11,
    _,

    pub fn of(l: @import("../../sql/types.zig").Logical) Kind {
        return switch (l) {
            .int1, .int2, .int4 => .int4,
            .int8 => .int8,
            .float4 => .float4,
            .float8 => .float8,
            .numeric => .numeric,
            .timestamp => .timestamp,
            .timestamp_tz => .timestamptz,
            .date => .date,
            .interval => .interval,
            .time => .time,
            .time_tz => .timetz,
            else => .auto,
        };
    }

    /// The kind argument `i` of a call says, .auto if there is none.
    pub fn fromArg(argv: []*Mem, i: usize) Kind {
        if (argv.len <= i) return .auto;
        return @fromBackingInt(@intCast(std.math.clamp(api.valueInt64(argv[i]), 0, 255)));
    }
};

/// A call's arena and error.
const Call = struct {
    ctx: *Context,
    arena: std.heap.ArenaAllocator,
    diag: numformat.Diag = .{},

    fn a(c: *Call) Allocator {
        return c.arena.allocator();
    }
};

fn begin(ctx: *Context) Call {
    return .{ .ctx = ctx, .arena = .init(dfunc.gpa(ctx)) };
}

fn report(c: *Call, err: anyerror) void {
    switch (err) {
        error.OutOfMemory => api.resultErrorNomem(c.ctx),
        error.Reported => {},
        else => {
            const d = c.diag;
            const msg = if (d.detail) |detail|
                std.mem.concat(c.a(), u8, &.{ d.msg, util.detail_mark, detail }) catch return api.resultErrorNomem(c.ctx)
            else
                d.msg;
            api.resultErrorState(c.ctx, .{ .sqlstate = d.state }, msg);
        },
    }
}

/// The template argument of the calls.
const template_arg = 1;

/// What a template is of: numbers (numformat.zig) or dates and times
/// (dtformat.zig).
const Which = enum { num, dt };

fn Parsed(comptime which: Which) type {
    return switch (which) {
        .num => numformat.Template,
        .dt => dtformat.Template,
    };
}

/// A template parsed, kept with the statement for the calls after the
/// first: the template's text, and its parse (of that copy) in the
/// arena.
const Cached = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    parsed: union(Which) { num: numformat.Template, dt: dtformat.Template },

    fn destroy(t: *Cached) void {
        const gpa = t.arena.child_allocator;
        t.arena.deinit();
        gpa.destroy(t);
    }
};

/// parse() of template `fmt` in `a`.
fn parse(c: *Call, a: Allocator, fmt: []const u8, comptime which: Which) !Parsed(which) {
    return switch (which) {
        .num => numformat.parse(a, fmt, &c.diag),
        .dt => dtformat.parse(a, fmt),
    };
}

/// Template `fmt` parsed, once per statement.
fn template(c: *Call, fmt: []const u8, comptime which: Which) !Parsed(which) {
    if (api.getAuxdataTyped(c.ctx, template_arg, Cached.destroy)) |t| {
        if (t.parsed == which and std.mem.eql(u8, t.text, fmt)) return @field(t.parsed, @tagName(which));
    }
    const gpa = dfunc.gpa(c.ctx);
    const t = try gpa.create(Cached);
    t.arena = .init(gpa);
    const ta = t.arena.allocator();
    const parsed = blk: {
        t.text = ta.dupe(u8, fmt) catch break :blk error.OutOfMemory;
        break :blk parse(c, ta, t.text, which);
    } catch |err| {
        t.destroy();
        // An error's message is the call's, past the template's arena.
        if (err == error.Failed) return parse(c, c.a(), fmt, which);
        return err;
    };
    t.parsed = @unionInit(@FieldType(Cached, "parsed"), @tagName(which), parsed);
    api.setAuxdataTyped(c.ctx, template_arg, Cached.destroy, t);
    // Outside a statement setAuxdata() has freed it.
    const kept = api.getAuxdataTyped(c.ctx, template_arg, Cached.destroy) orelse return parse(c, c.a(), fmt, which);
    return @field(kept.parsed, @tagName(which));
}

fn toCharFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv[0..2])) return api.resultNull(ctx);
    var c = begin(ctx);
    defer c.arena.deinit();
    toChar(&c, argv[0], argv[1], Kind.fromArg(argv, 2)) catch |err| report(&c, err);
}

fn toChar(c: *Call, m: *Mem, fm: *Mem, kind_in: Kind) !void {
    const fmt = dfunc.text(c.ctx, fm) orelse return error.Reported;
    const a = c.a();
    var kind = kind_in;
    if (kind == .auto) kind = switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => .int8,
        vi.SQLITE_FLOAT => .float8,
        vi.SQLITE_BLOB => blk: {
            const b = api.valueBlob(m) orelse "";
            break :blk if (b.len == ivl.len and ivl.decode(b) != null) .interval else .numeric;
        },
        else => .timestamp,
    };
    switch (kind) {
        .int4, .int8, .float4, .float8, .numeric => {
            if (fmt.len == 0) return api.resultText(c.ctx, "", .static);
            const t = try template(c, fmt, .num);
            const z = switch (kind) {
                .int4, .int8 => blk: {
                    if (api.valueType(m) == vi.SQLITE_FLOAT) {
                        break :blk try numformat.floatToChar(a, t, api.valueDouble(m), false, &c.diag);
                    }
                    break :blk try numformat.intToChar(a, t, api.valueInt64(m), kind == .int8, &c.diag);
                },
                .float4, .float8 => try numformat.floatToChar(a, t, api.valueDouble(m), kind == .float4, &c.diag),
                else => blk: {
                    const d = decimal_sql.numArg(c.ctx, a, m) orelse return error.Reported;
                    break :blk try numformat.numericToChar(a, t, d, &c.diag);
                },
            };
            return api.resultText(c.ctx, z, .transient);
        },
        .interval => {
            const iv = datetime.intervalArg(c.ctx, m) orelse return error.Reported;
            if (fmt.len == 0 or !iv.isFinite()) return api.resultNull(c.ctx);
            const z = try dtformat.intervalToChar(a, iv, try template(c, fmt, .dt), &c.diag);
            return api.resultText(c.ctx, z, .transient);
        },
        .time, .timetz => {
            // A time is the interval of its time of day (time_interval()).
            const raw = dfunc.text(c.ctx, m) orelse return error.Reported;
            const tod = datetime.parseTime(raw) catch return badInput(c, "time without time zone", raw);
            if (fmt.len == 0) return api.resultNull(c.ctx);
            const z = try dtformat.intervalToChar(a, .{ .time = tod }, try template(c, fmt, .dt), &c.diag);
            return api.resultText(c.ctx, z, .transient);
        },
        else => {
            const raw = dfunc.text(c.ctx, m) orelse return error.Reported;
            const tz = kind == .timestamptz or kind == .date;
            const t = datetime.parseTimestamp(raw, tz) catch return badInput(c, "timestamp", raw);
            if (fmt.len == 0) return api.resultNull(c.ctx);
            const z = try dtformat.timestampToChar(a, t, tz, try template(c, fmt, .dt), &c.diag);
            return api.resultText(c.ctx, z, .transient);
        },
    }
}

fn badInput(c: *Call, type_name: []const u8, raw: []const u8) error{Reported} {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type {s}: \"{s}\"", .{ type_name, raw[0..@min(raw.len, 64)] }) catch "invalid input syntax";
    api.resultErrorState(c.ctx, .of("22007"), msg);
    return error.Reported;
}

fn toNumberFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    var c = begin(ctx);
    defer c.arena.deinit();
    toNumber(&c, argv) catch |err| report(&c, err);
}

fn toNumber(c: *Call, argv: []*Mem) !void {
    const in = dfunc.text(c.ctx, argv[0]) orelse return error.Reported;
    const fmt = dfunc.text(c.ctx, argv[1]) orelse return error.Reported;
    if (fmt.len == 0) return api.resultNull(c.ctx);
    const a = c.a();
    const d = try numformat.toNumber(a, try template(c, fmt, .num), in, &c.diag);
    const k = dec.key(a, d, true) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        c.diag.state = "22003".*;
        c.diag.msg = "value overflows numeric format";
        return error.Failed;
    };
    api.resultBlob(c.ctx, k, .transient);
}

fn toDateTimeFunc(ctx: *Context, argv: []*Mem, comptime date: bool) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    var c = begin(ctx);
    defer c.arena.deinit();
    toDateTime(&c, argv, date) catch |err| report(&c, err);
}

fn toDateTime(c: *Call, argv: []*Mem, date: bool) !void {
    const in = dfunc.text(c.ctx, argv[0]) orelse return error.Reported;
    const fmt = dfunc.text(c.ctx, argv[1]) orelse return error.Reported;
    const a = c.a();
    const t = try template(c, fmt, .dt);
    var buf: datetime.Buf = undefined;
    if (date) {
        const d = try dtformat.toDate(a, in, t, &c.diag);
        return api.resultText(c.ctx, datetime.formatDate(d, &buf), .transient);
    }
    const ts = try dtformat.toTimestamp(a, in, t, &c.diag);
    api.resultText(c.ctx, datetime.formatTimestamp(ts, &buf), .transient);
}

/// to_timestamp(double): seconds since 1970-01-01 UTC.
fn epochFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    const v = api.valueDouble(m);
    if (std.math.isNan(v)) return api.resultErrorState(ctx, .of("22008"), "timestamp cannot be NaN");
    if (std.math.isInf(v)) return api.resultText(ctx, if (v > 0) "infinity" else "-infinity", .static);
    const us = @round(v * 1e6);
    var mbuf: [96]u8 = undefined;
    const range = std.fmt.bufPrint(&mbuf, "timestamp out of range: \"{d}\"", .{v}) catch "timestamp out of range";
    if (!(us >= -0x1p63 and us < 0x1p63)) return api.resultErrorState(ctx, .of("22008"), range);
    const t = datetime.checkTimestamp(@intFromFloat(us)) catch return api.resultErrorState(ctx, .of("22008"), range);
    var buf: datetime.Buf = undefined;
    api.resultText(ctx, datetime.formatTimestamp(t, &buf), .transient);
}
