//! PostgreSQL's operators as a table (pg_operator's rows: an operator,
//! its operand types, its result type, its implementation) and how an
//! operator is chosen from the types of its operands (PostgreSQL's
//! operator type resolution, "Type Conversion" in its manual, at the
//! depth these types need):
//!  1. an exact match; a string literal (PostgreSQL's unknown) is first
//!     taken to be of the type of the other operand (date '...' - '...'
//!     is date - date);
//!  2. else the rows each operand's type casts to implicitly (integers
//!     to wider ones, to numeric and to floats; numeric to floats; date
//!     to timestamp(tz); timestamp to timestamptz; time to interval;
//!     strings among themselves), a string literal matching any type;
//!  3. of those, the rows with the most exact matches, then with the
//!     most preferred types (double precision, text, timestamptz,
//!     interval) where a cast is needed; then for a string literal the
//!     rows of one type category at its place (a string type if any row
//!     takes one), of the preferred type if any takes that;
//!  4. one row is the operator; none is "operator does not exist: date
//!     + text" (42883), several "operator is not unique" (42725).
//! The operators are the arithmetic and bit operators of numbers, dates,
//! times, timestamps and intervals, and jsonb's `-` (its other operators
//! and `||` are overload.zig's: `||` is PostgreSQL's polymorphic
//! text || anynonarray). A row's implementation is the engine's own
//! opcode (native: the numbers) or an engine function of the same
//! arguments (datetime.zig's xq_pg_date_pli() ..., jfuncs.zig's
//! xq_pg_jsonb_delete()).
//!
//! overload.zig asks resolve() for every such operator whose operands'
//! types are known or are string literals, parameters or NULL; an
//! operand of no known type (a column of a SQLite table, a function with
//! no type rule) leaves the operator to SQLite as before. A parameter or
//! NULL may match any type but never makes the statement fail.

const std = @import("std");
const types = @import("../../sql/types.zig");
const datetime = @import("datetime.zig");

const Logical = types.Logical;

/// The types of the table's rows.
pub const T = enum {
    int2,
    int4,
    int8,
    numeric,
    float4,
    float8,
    text,
    varchar,
    bpchar,
    boolean,
    bytea,
    date,
    time,
    timestamp,
    timestamptz,
    interval,
    uuid,
    json,
    jsonb,
    text_array,

    /// PostgreSQL's name of the type (format_type()), as its errors say.
    pub fn name(t: T) []const u8 {
        return switch (t) {
            .int2 => "smallint",
            .int4 => "integer",
            .int8 => "bigint",
            .numeric => "numeric",
            .float4 => "real",
            .float8 => "double precision",
            .text => "text",
            .varchar => "character varying",
            .bpchar => "character",
            .boolean => "boolean",
            .bytea => "bytea",
            .date => "date",
            .time => "time without time zone",
            .timestamp => "timestamp without time zone",
            .timestamptz => "timestamp with time zone",
            .interval => "interval",
            .uuid => "uuid",
            .json => "json",
            .jsonb => "jsonb",
            .text_array => "text[]",
        };
    }

    /// The core's type.
    pub fn logical(t: T) Logical {
        return switch (t) {
            .int2 => .int2,
            .int4 => .int4,
            .int8 => .int8,
            .numeric => .numeric,
            .float4 => .float4,
            .float8 => .float8,
            .text => .text,
            .varchar => .varchar,
            .bpchar => .char,
            .boolean => .boolean,
            .bytea => .bytes,
            .date => .date,
            .time => .time,
            .timestamp => .timestamp,
            .timestamptz => .timestamp_tz,
            .interval => .interval,
            .uuid => .uuid,
            .json => .json,
            .jsonb => .jsonb,
            .text_array => .unknown,
        };
    }

    /// The type of the core's `l` (spelled `spelling`), null if the table
    /// has none (time with time zone, a type of no Logical but text[]).
    pub fn of(l: Logical, spelling: ?[]const u8) ?T {
        return switch (l) {
            .int1, .int2 => .int2,
            .int4 => .int4,
            .int8 => .int8,
            .numeric => .numeric,
            .float4 => .float4,
            .float8 => .float8,
            .text => .text,
            .varchar => .varchar,
            .char => .bpchar,
            .boolean => .boolean,
            .bytes => .bytea,
            .date => .date,
            .time => .time,
            .timestamp => .timestamp,
            .timestamp_tz => .timestamptz,
            .interval => .interval,
            .uuid => .uuid,
            .json => .json,
            .jsonb => .jsonb,
            .time_tz => null,
            .unknown => {
                const z = spelling orelse return null;
                const strings = [_][]const u8{ "text[]", "character varying[]", "character[]", "name[]" };
                for (strings) |s| if (std.mem.eql(u8, z, s)) return .text_array;
                return null;
            },
        };
    }

    const Category = enum { numeric, string, datetime, timespan, boolean, user, array };

    fn category(t: T) Category {
        return switch (t) {
            .int2, .int4, .int8, .numeric, .float4, .float8 => .numeric,
            .text, .varchar, .bpchar => .string,
            .date, .time, .timestamp, .timestamptz => .datetime,
            .interval => .timespan,
            .boolean => .boolean,
            .bytea, .uuid, .json, .jsonb => .user,
            .text_array => .array,
        };
    }

    /// The preferred type of its category.
    fn preferred(t: T) bool {
        return switch (t) {
            .float8, .text, .timestamptz, .interval, .boolean => true,
            else => false,
        };
    }

    /// Whether a value of `from` casts implicitly to `to` (pg_cast's
    /// implicit casts among these types).
    fn castsTo(from: T, to: T) bool {
        if (from == to) return true;
        return switch (from) {
            .int2 => switch (to) {
                .int4, .int8, .numeric, .float4, .float8 => true,
                else => false,
            },
            .int4 => switch (to) {
                .int8, .numeric, .float4, .float8 => true,
                else => false,
            },
            .int8 => switch (to) {
                .numeric, .float4, .float8 => true,
                else => false,
            },
            .numeric => to == .float4 or to == .float8,
            .float4 => to == .float8,
            .text, .varchar, .bpchar => to.category() == .string,
            .date => to == .timestamp or to == .timestamptz,
            .timestamp => to == .timestamptz,
            .time => to == .interval,
            else => false,
        };
    }
};

pub const Op = enum {
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    bit_and,
    bit_or,
    shl,
    shr,

    pub fn text(o: Op) []const u8 {
        return switch (o) {
            .add => "+",
            .sub, .neg => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .bit_and => "&",
            .bit_or => "|",
            .shl => "<<",
            .shr => ">>",
        };
    }

    fn unary(o: Op) bool {
        return o == .neg;
    }
};

pub const Entry = struct {
    op: Op,
    /// The operand types: one for a prefix operator.
    args: []const T,
    result: T,
    /// The engine function of the same arguments; null for the engine's
    /// own operator.
    func: ?[:0]const u8 = null,
};

fn native(op: Op, args: []const T, result: T) Entry {
    return .{ .op = op, .args = args, .result = result };
}

fn func(op: Op, args: []const T, result: T, comptime o: datetime.Op) Entry {
    return .{ .op = op, .args = args, .result = result, .func = o.name() };
}

/// The table.
pub const entries = blk: {
    @setEvalBranchQuota(20000);
    var list: []const Entry = &.{};
    const ints = [_]T{ .int2, .int4, .int8 };
    // + - * / of integers: every pair, in the wider type.
    for ([_]Op{ .add, .sub, .mul, .div }) |op| {
        for (ints, 0..) |a, i| for (ints, 0..) |b, j| {
            list = list ++ [_]Entry{native(op, &.{ a, b }, ints[@max(i, j)])};
        };
        list = list ++ [_]Entry{
            native(op, &.{ .numeric, .numeric }, .numeric),
            native(op, &.{ .float4, .float4 }, .float4),
            native(op, &.{ .float8, .float8 }, .float8),
            native(op, &.{ .float4, .float8 }, .float8),
            native(op, &.{ .float8, .float4 }, .float8),
        };
    }
    // % of the same type (no float's).
    for ([_]T{ .int2, .int4, .int8, .numeric }) |a| list = list ++ [_]Entry{native(.mod, &.{ a, a }, a)};
    for ([_]T{ .int2, .int4, .int8, .numeric, .float4, .float8 }) |a| list = list ++ [_]Entry{native(.neg, &.{a}, a)};
    for (ints) |a| list = list ++ [_]Entry{
        native(.bit_and, &.{ a, a }, a),
        native(.bit_or, &.{ a, a }, a),
        native(.shl, &.{ a, .int4 }, a),
        native(.shr, &.{ a, .int4 }, a),
    };
    list = list ++ [_]Entry{
        // Dates.
        func(.add, &.{ .date, .int4 }, .date, .date_pli),
        func(.add, &.{ .int4, .date }, .date, .integer_pl_date),
        func(.sub, &.{ .date, .int4 }, .date, .date_mii),
        func(.sub, &.{ .date, .date }, .int4, .date_mi),
        func(.add, &.{ .date, .interval }, .timestamp, .date_pl_interval),
        func(.add, &.{ .interval, .date }, .timestamp, .interval_pl_date),
        func(.sub, &.{ .date, .interval }, .timestamp, .date_mi_interval),
        func(.add, &.{ .date, .time }, .timestamp, .datetime_pl),
        func(.add, &.{ .time, .date }, .timestamp, .timedate_pl),
        // Timestamps.
        func(.add, &.{ .timestamp, .interval }, .timestamp, .timestamp_pl_interval),
        func(.add, &.{ .interval, .timestamp }, .timestamp, .interval_pl_timestamp),
        func(.sub, &.{ .timestamp, .interval }, .timestamp, .timestamp_mi_interval),
        func(.sub, &.{ .timestamp, .timestamp }, .interval, .timestamp_mi),
        func(.add, &.{ .timestamptz, .interval }, .timestamptz, .timestamptz_pl_interval),
        func(.add, &.{ .interval, .timestamptz }, .timestamptz, .interval_pl_timestamptz),
        func(.sub, &.{ .timestamptz, .interval }, .timestamptz, .timestamptz_mi_interval),
        func(.sub, &.{ .timestamptz, .timestamptz }, .interval, .timestamptz_mi),
        // Times.
        func(.add, &.{ .time, .interval }, .time, .time_pl_interval),
        func(.add, &.{ .interval, .time }, .time, .interval_pl_time),
        func(.sub, &.{ .time, .interval }, .time, .time_mi_interval),
        func(.sub, &.{ .time, .time }, .interval, .time_mi_time),
        // Intervals.
        func(.add, &.{ .interval, .interval }, .interval, .interval_pl),
        func(.sub, &.{ .interval, .interval }, .interval, .interval_mi),
        func(.neg, &.{.interval}, .interval, .interval_um),
        func(.mul, &.{ .interval, .float8 }, .interval, .interval_mul),
        func(.mul, &.{ .float8, .interval }, .interval, .mul_d_interval),
        func(.div, &.{ .interval, .float8 }, .interval, .interval_div),
        // jsonb (jfuncs.zig).
        .{ .op = .sub, .args = &.{ .jsonb, .text }, .result = .jsonb, .func = "xq_pg_jsonb_delete" },
        .{ .op = .sub, .args = &.{ .jsonb, .int4 }, .result = .jsonb, .func = "xq_pg_jsonb_delete" },
        .{ .op = .sub, .args = &.{ .jsonb, .text_array }, .result = .jsonb, .func = "xq_pg_jsonb_delete_keys" },
    };
    break :blk list[0..list.len].*;
};

/// What an operand is to resolve().
pub const Arg = union(enum) {
    /// Of a type of the table.
    known: T,
    /// A string literal (PostgreSQL's unknown).
    literal,
    /// A parameter or NULL: as a literal, but no error.
    loose,

    fn typeName(a: Arg) []const u8 {
        return switch (a) {
            .known => |t| t.name(),
            .literal, .loose => "unknown",
        };
    }
};

pub const Resolution = union(enum) {
    entry: *const Entry,
    not_exist,
    not_unique,
};

/// The row of operator `op` for operands `args` (one for a prefix
/// operator), by PostgreSQL's rules (the file's comment).
pub fn resolve(op: Op, args: []const Arg) Resolution {
    std.debug.assert(args.len == @as(usize, if (op.unary()) 1 else 2));
    // The rows of the operator.
    var cand: [entries.len]u16 = undefined;
    var n: usize = 0;
    for (&entries, 0..) |*e, i| if (e.op == op) {
        cand[n] = @intCast(i);
        n += 1;
    };
    // 1. An exact match; an unknown operand of the type of the other.
    var want: [2]?T = .{ null, null };
    var known: ?T = null;
    for (args) |a| if (a == .known) {
        known = a.known;
    };
    for (args, 0..) |a, i| want[i] = switch (a) {
        .known => |t| t,
        else => if (args.len == 2) known else null,
    };
    for (cand[0..n]) |ci| {
        const e = &entries[ci];
        for (e.args, 0..) |t, i| {
            if (want[i] != t) break;
        } else return .{ .entry = e };
    }
    // 2. The rows the operands cast to.
    var m: usize = 0;
    for (cand[0..n]) |ci| {
        const e = &entries[ci];
        for (e.args, args) |t, a| switch (a) {
            .known => |k| if (!k.castsTo(t)) break,
            else => {},
        } else {
            cand[m] = ci;
            m += 1;
        }
    }
    n = m;
    if (n == 0) return .not_exist;
    // 3. The most exact matches, then the most preferred types.
    inline for (.{ false, true }) |pref| {
        var best: usize = 0;
        for (cand[0..n]) |ci| best = @max(best, score(&entries[ci], args, pref));
        m = 0;
        for (cand[0..n]) |ci| if (score(&entries[ci], args, pref) == best) {
            cand[m] = ci;
            m += 1;
        };
        n = m;
    }
    if (n == 1) return .{ .entry = &entries[cand[0]] };
    // The category at the place of each unknown operand.
    for (args, 0..) |a, i| {
        if (a == .known) continue;
        var cat: ?T.Category = null;
        var conflict = false;
        var any_pref = false;
        for (cand[0..n]) |ci| {
            const t = entries[ci].args[i];
            if (cat == null) {
                cat = t.category();
            } else if (cat.? != t.category()) {
                if (t.category() == .string) {
                    cat = .string;
                } else if (cat.? != .string) {
                    conflict = true;
                }
            }
        }
        if (conflict and cat.? != .string) return .not_unique;
        for (cand[0..n]) |ci| {
            const t = entries[ci].args[i];
            if (t.category() == cat.? and t.preferred()) any_pref = true;
        }
        m = 0;
        for (cand[0..n]) |ci| {
            const t = entries[ci].args[i];
            if (t.category() != cat.? or (any_pref and !t.preferred())) continue;
            cand[m] = ci;
            m += 1;
        }
        n = m;
    }
    if (n == 1) return .{ .entry = &entries[cand[0]] };
    return if (n == 0) .not_exist else .not_unique;
}

/// The places of `e` that `args` match exactly (and, with `pref`, where
/// a cast is to a preferred type).
fn score(e: *const Entry, args: []const Arg, pref: bool) usize {
    var s: usize = 0;
    for (e.args, args) |t, a| switch (a) {
        .known => |k| {
            if (k == t or (pref and t.preferred())) s += 1;
        },
        else => {},
    };
    return s;
}

/// Whether `name` (lower case) is the function of a row: the function an
/// operator was made a call of.
pub fn isFunction(name: []const u8) bool {
    return functions.has(name);
}

/// The result type of the row whose function is `name` (lower case), if
/// one is: the type of that call in the text of a view.
pub fn functionResult(name: []const u8) ?T {
    return functions.get(name);
}

const KV = struct { []const u8, T };

const functions = blk: {
    @setEvalBranchQuota(20000);
    var kvs: []const KV = &.{};
    for (entries) |e| if (e.func) |f| {
        // jsonb's two rows of one function.
        for (kvs) |kv| {
            if (std.mem.eql(u8, kv[0], f)) break;
        } else kvs = kvs ++ &[_]KV{.{ f, e.result }};
    };
    break :blk std.StaticStringMap(T).initComptime(kvs);
};

/// The message of a resolution that failed: "operator does not exist:
/// date + text", "operator is not unique: date + unknown".
pub fn message(r: Resolution, op: Op, args: []const Arg, buf: []u8) []const u8 {
    const what = if (r == .not_unique) "operator is not unique" else "operator does not exist";
    if (args.len == 1) return std.fmt.bufPrint(buf, "{s}: {s} {s}", .{ what, op.text(), args[0].typeName() }) catch what;
    return std.fmt.bufPrint(buf, "{s}: {s} {s} {s}", .{ what, args[0].typeName(), op.text(), args[1].typeName() }) catch what;
}

// ================================================================ tests

const testing = std.testing;

fn expectRow(op: Op, args: []const Arg, result: T, f: ?[]const u8) !void {
    const r = resolve(op, args);
    switch (r) {
        .entry => |e| {
            try testing.expectEqual(result, e.result);
            if (f) |name| try testing.expectEqualStrings(name, e.func.?) else try testing.expect(e.func == null);
        },
        else => {
            var buf: [128]u8 = undefined;
            std.debug.print("{s}\n", .{message(r, op, args, &buf)});
            return error.TestUnexpectedResult;
        },
    }
}

test "operators resolve as PostgreSQL's" {
    const k = struct {
        fn of(t: T) Arg {
            return .{ .known = t };
        }
    }.of;
    try expectRow(.add, &.{ k(.int4), k(.int4) }, .int4, null);
    try expectRow(.add, &.{ k(.int2), k(.int8) }, .int8, null);
    try expectRow(.add, &.{ k(.int4), k(.numeric) }, .numeric, null);
    try expectRow(.add, &.{ k(.int4), k(.float8) }, .float8, null);
    try expectRow(.add, &.{ k(.float4), k(.int4) }, .float8, null);
    try expectRow(.add, &.{ k(.float4), k(.float4) }, .float4, null);
    try expectRow(.add, &.{ k(.numeric), k(.float4) }, .float8, null);
    try expectRow(.mod, &.{ k(.int2), k(.int4) }, .int4, null);
    try expectRow(.add, &.{ k(.int4), .literal }, .int4, null);
    try expectRow(.neg, &.{k(.int2)}, .int2, null);
    try expectRow(.add, &.{ k(.date), k(.int4) }, .date, "xq_pg_date_pli");
    try expectRow(.add, &.{ k(.int2), k(.date) }, .date, "xq_pg_integer_pl_date");
    try expectRow(.sub, &.{ k(.date), .literal }, .int4, "xq_pg_date_mi");
    try expectRow(.sub, &.{ k(.date), k(.timestamp) }, .interval, "xq_pg_timestamp_mi");
    try expectRow(.sub, &.{ k(.timestamptz), k(.date) }, .interval, "xq_pg_timestamptz_mi");
    try expectRow(.add, &.{ k(.timestamptz), .literal }, .timestamptz, "xq_pg_timestamptz_pl_interval");
    try expectRow(.add, &.{ k(.timestamp), .literal }, .timestamp, "xq_pg_timestamp_pl_interval");
    try expectRow(.mul, &.{ k(.interval), k(.int4) }, .interval, "xq_pg_interval_mul");
    try expectRow(.mul, &.{ k(.numeric), k(.interval) }, .interval, "xq_pg_mul_d_interval");
    try expectRow(.neg, &.{k(.interval)}, .interval, "xq_pg_interval_um");
    try expectRow(.add, &.{ k(.time), k(.interval) }, .time, "xq_pg_time_pl_interval");
    try expectRow(.sub, &.{ k(.jsonb), .literal }, .jsonb, "xq_pg_jsonb_delete");
    try expectRow(.sub, &.{ k(.jsonb), k(.text_array) }, .jsonb, "xq_pg_jsonb_delete_keys");
    try testing.expectEqual(Resolution.not_exist, resolve(.add, &.{ k(.date), k(.text) }));
    try testing.expectEqual(Resolution.not_exist, resolve(.add, &.{ k(.timestamp), k(.int4) }));
    try testing.expectEqual(Resolution.not_exist, resolve(.add, &.{ k(.date), k(.int8) }));
    try testing.expectEqual(Resolution.not_exist, resolve(.mod, &.{ k(.float8), k(.int4) }));
    try testing.expectEqual(Resolution.not_exist, resolve(.add, &.{ k(.boolean), k(.int4) }));
    try testing.expectEqual(Resolution.not_exist, resolve(.neg, &.{k(.text)}));
    try testing.expectEqual(Resolution.not_unique, resolve(.add, &.{ k(.date), .literal }));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("operator does not exist: date + text", message(.not_exist, .add, &.{ k(.date), k(.text) }, &buf));
    try testing.expectEqualStrings("operator is not unique: date + unknown", message(.not_unique, .add, &.{ k(.date), .literal }, &buf));
    try testing.expectEqualStrings("operator does not exist: - text", message(.not_exist, .neg, &.{k(.text)}, &buf));
    try testing.expectEqual(T.date, functionResult("xq_pg_date_pli").?);
    try testing.expectEqual(T.jsonb, functionResult("xq_pg_jsonb_delete").?);
}
