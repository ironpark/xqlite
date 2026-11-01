//! The functions of the PostgreSQL dialect (Hooks.functions), besides
//! version() and the sequence functions of frontend.zig. They shadow
//! SQLite's built-ins of the same name (random(), floor() ...).
//!
//!  - greatest(...), least(...): NULLs are skipped (SQLite's max()/min()
//!    of several arguments are NULL if one is);
//!  - left, right, repeat, reverse, lpad, rpad, split_part,
//!    starts_with;
//!  - random() in [0, 1), gen_random_uuid();
//!  - floor, ceil/ceiling, sqrt, power/pow, exp, ln, log, mod, trunc,
//!    sign, pi;
//!  - current_user(), current_database() (current_schema() is session.zig's).
//!
//! The engine functions (Hooks.engine_functions, visible in every
//! dialect, as the IR writes them into the schema):
//!
//!  - xq_like(pattern, s [, escape]) / xq_ilike(): the IR's Like of
//!    PostgreSQL's LIKE and ILIKE: case-sensitive (xq_ilike: ASCII
//!    case-insensitive), `\` the default escape, '' for none;
//!  - xq_pg_bool(x): the cast to boolean ('t', 'yes', 'on', 1 ... are
//!    1); xq_pg_int2(x), xq_pg_int4(x), xq_pg_int8(x): the casts to
//!    smallint, integer and bigint (a real rounds, text is read as an
//!    integer, out of range is an error); xq_pg_data_type(), xq_pg_udt_name(), xq_pg_char_max(),
//!    xq_pg_num_precision(), xq_pg_num_scale() of (catalog type, SQLite
//!    type): the columns of information_schema.columns.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("greatest", -1, det, greatestFunc),
    dfunc.scalar("least", -1, det, leastFunc),
    dfunc.scalar("left", 2, det, leftFunc),
    dfunc.scalar("right", 2, det, rightFunc),
    dfunc.scalar("repeat", 2, det, repeatFunc),
    dfunc.scalar("reverse", 1, det, reverseFunc),
    dfunc.scalar("lpad", 2, det, lpadFunc),
    dfunc.scalar("lpad", 3, det, lpadFunc),
    dfunc.scalar("rpad", 2, det, rpadFunc),
    dfunc.scalar("rpad", 3, det, rpadFunc),
    dfunc.scalar("split_part", 3, det, splitPartFunc),
    dfunc.scalar("starts_with", 2, det, startsWithFunc),
    dfunc.scalar("random", 0, .{}, randomFunc),
    dfunc.scalar("gen_random_uuid", 0, .{}, uuidFunc),
    dfunc.scalar("floor", 1, det, floorFunc),
    dfunc.scalar("ceil", 1, det, ceilFunc),
    dfunc.scalar("ceiling", 1, det, ceilFunc),
    dfunc.scalar("sqrt", 1, det, sqrtFunc),
    dfunc.scalar("power", 2, det, powerFunc),
    dfunc.scalar("pow", 2, det, powerFunc),
    dfunc.scalar("exp", 1, det, expFunc),
    dfunc.scalar("ln", 1, det, lnFunc),
    dfunc.scalar("log", 1, det, logFunc),
    dfunc.scalar("log", 2, det, logFunc),
    dfunc.scalar("mod", 2, det, modFunc),
    dfunc.scalar("trunc", 1, det, truncFunc),
    dfunc.scalar("trunc", 2, det, truncFunc),
    dfunc.scalar("sign", 1, det, signFunc),
    dfunc.scalar("pi", 0, det, piFunc),
    dfunc.scalar("current_user", 0, det, currentUserFunc),
    dfunc.scalar("current_database", 0, det, currentDatabaseFunc),
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_like", 2, det, likeFunc),
    dfunc.scalar("xq_like", 3, det, likeFunc),
    dfunc.scalar("xq_ilike", 2, det, ilikeFunc),
    dfunc.scalar("xq_ilike", 3, det, ilikeFunc),
    dfunc.scalar("xq_pg_bool", 1, det, boolFunc),
    dfunc.scalar("xq_pg_int2", 1, det, dfunc.bind(intFunc, .{IntType.smallint})),
    dfunc.scalar("xq_pg_int4", 1, det, dfunc.bind(intFunc, .{IntType.integer})),
    dfunc.scalar("xq_pg_int8", 1, det, dfunc.bind(intFunc, .{IntType.bigint})),
    dfunc.scalar("xq_pg_data_type", 2, det, dataTypeFunc),
    dfunc.scalar("xq_pg_udt_name", 2, det, udtNameFunc),
    dfunc.scalar("xq_pg_char_max", 2, det, charMaxFunc),
    dfunc.scalar("xq_pg_num_precision", 2, det, numPrecisionFunc),
    dfunc.scalar("xq_pg_num_scale", 2, det, numScaleFunc),
};

const isNull = dfunc.isNull;
const anyNull = dfunc.anyNull;
const text = dfunc.text;
const gpa = dfunc.gpa;
const isInt = dfunc.isIntegral;
const cpCount = dfunc.charCount;
const cpOffset = dfunc.charOffset;

// ================================================================= LIKE

const likeFunc = dfunc.bind(like, .{false});
const ilikeFunc = dfunc.bind(like, .{true});

fn like(ctx: *Context, argv: []*Mem, fold: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const pat = text(ctx, argv[0]) orelse return;
    const s = text(ctx, argv[1]) orelse return;
    var esc: ?u21 = '\\';
    if (argv.len == 3) {
        const e = text(ctx, argv[2]) orelse return;
        if (e.len == 0) {
            esc = null;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(e[0]) catch 1;
            if (n != e.len) return api.resultErrorState(ctx, .of("22025"), "invalid escape string");
            esc = std.unicode.utf8Decode(e) catch e[0];
        }
    }
    const r = likeMatch(pat, s, esc, fold) catch return api.resultErrorState(ctx, .of("22025"), "LIKE pattern must not end with escape character");
    api.resultInt64(ctx, @intFromBool(r));
}

fn nextCp(s: []const u8, i: *usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[i.*]) catch 1;
    const end = @min(s.len, i.* + n);
    const cp = std.unicode.utf8Decode(s[i.*..end]) catch s[i.*];
    i.* = end;
    return cp;
}

fn foldCp(c: u21, fold: bool) u21 {
    if (fold and c < 128) return std.ascii.toLower(@intCast(c));
    return c;
}

/// PostgreSQL's LIKE: `_` one character, `%` any run, `esc` quotes the
/// next character.
pub fn likeMatch(pat: []const u8, s: []const u8, esc: ?u21, fold: bool) error{TrailingEscape}!bool {
    var pi: usize = 0;
    var si: usize = 0;
    // Backtracking point: the pattern after the last %, and where in s.
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (true) {
        if (pi < pat.len) {
            var pj = pi;
            const pc = nextCp(pat, &pj);
            if (pc == '%') {
                star_p = pj;
                star_s = si;
                pi = pj;
                continue;
            }
            if (si < s.len) {
                var sj = si;
                const sc = nextCp(s, &sj);
                var matched = false;
                if (pc == '_') {
                    matched = true;
                } else if (esc != null and pc == esc.?) {
                    if (pj >= pat.len) return error.TrailingEscape;
                    var pk = pj;
                    const lit = nextCp(pat, &pk);
                    if (foldCp(lit, fold) == foldCp(sc, fold)) {
                        matched = true;
                        pj = pk;
                    }
                } else if (foldCp(pc, fold) == foldCp(sc, fold)) {
                    matched = true;
                }
                if (matched) {
                    pi = pj;
                    si = sj;
                    continue;
                }
            } else if (esc != null and pc == esc.? and pj >= pat.len) {
                return error.TrailingEscape;
            }
        } else if (si >= s.len) {
            return true;
        }
        // Mismatch: let the last % take one more character.
        const sp = star_p orelse return false;
        if (star_s >= s.len) return false;
        _ = nextCp(s, &star_s);
        pi = sp;
        si = star_s;
    }
}

// ====================================================== greatest, least

const greatestFunc = dfunc.bind(extreme, .{1});
const leastFunc = dfunc.bind(extreme, .{-1});

fn extreme(ctx: *Context, argv: []*Mem, sign_: i32) void {
    const serial = @import("../../vdbe/serial.zig");
    var best: ?*Mem = null;
    for (argv) |m| {
        if (isNull(m)) continue;
        if (best == null or std.math.sign(serial.memCompare(m, best.?, null)) == sign_) best = m;
    }
    if (best) |b| api.resultValue(ctx, b) else api.resultNull(ctx);
}

// ============================================================== strings

fn leftFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    const n = api.valueInt64(argv[1]);
    const total: i64 = @intCast(cpCount(s));
    const keep: i64 = if (n >= 0) @min(n, total) else @max(0, total + n);
    api.resultText(ctx, s[0..cpOffset(s, @intCast(keep))], .transient);
}

fn rightFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    const n = api.valueInt64(argv[1]);
    const total: i64 = @intCast(cpCount(s));
    const skip: i64 = if (n >= 0) @max(0, total - n) else @min(total, 0 -| n);
    api.resultText(ctx, s[cpOffset(s, @intCast(skip))..], .transient);
}

fn repeatFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    const n = api.valueInt64(argv[1]);
    if (n <= 0 or s.len == 0) return api.resultText(ctx, "", .static);
    const total = std.math.mul(usize, s.len, @intCast(n)) catch return api.resultErrorTooBig(ctx);
    if (total > 1_000_000_000) return api.resultErrorTooBig(ctx);
    const out = gpa(ctx).alloc(u8, total) catch return api.resultErrorNomem(ctx);
    var i: usize = 0;
    while (i < total) : (i += s.len) @memcpy(out[i..][0..s.len], s);
    api.resultText(ctx, out, .dynamic);
}

fn reverseFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    if (s.len == 0) return api.resultText(ctx, "", .static);
    const out = gpa(ctx).alloc(u8, s.len) catch return api.resultErrorNomem(ctx);
    var i: usize = 0;
    var o: usize = s.len;
    while (i < s.len) {
        const start = i;
        i = dfunc.nextChar(s, i);
        o -= i - start;
        @memcpy(out[o..][0 .. i - start], s[start..i]);
    }
    api.resultText(ctx, out, .dynamic);
}

fn pad(ctx: *Context, argv: []*Mem, left_side: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    const n_arg = api.valueInt64(argv[1]);
    const fill = if (argv.len == 3) (text(ctx, argv[2]) orelse return) else " ";
    const n: usize = @intCast(@max(0, @min(n_arg, 10_000_000)));
    const have = cpCount(s);
    if (have >= n) return api.resultText(ctx, s[0..cpOffset(s, n)], .transient);
    if (fill.len == 0) return api.resultText(ctx, s, .transient);
    var out: std.ArrayList(u8) = .empty;
    // Empty once resultOwned() has it.
    defer out.deinit(gpa(ctx));
    if (!left_side) out.appendSlice(gpa(ctx), s) catch return api.resultErrorNomem(ctx);
    var need = n - have;
    var fi: usize = 0;
    while (need > 0) : (need -= 1) {
        if (fi >= fill.len) fi = 0;
        const start = fi;
        fi = dfunc.nextChar(fill, fi);
        out.appendSlice(gpa(ctx), fill[start..fi]) catch return api.resultErrorNomem(ctx);
    }
    if (left_side) out.appendSlice(gpa(ctx), s) catch return api.resultErrorNomem(ctx);
    dfunc.resultOwned(ctx, &out);
}

const lpadFunc = dfunc.bind(pad, .{true});
const rpadFunc = dfunc.bind(pad, .{false});

fn splitPartFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    const d = text(ctx, argv[1]) orelse return;
    const n = api.valueInt64(argv[2]);
    if (n == 0) return api.resultErrorState(ctx, .of("22023"), "field position must not be zero");
    if (d.len == 0) {
        return api.resultText(ctx, if (n == 1 or n == -1) s else "", .transient);
    }
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa(ctx));
    var it = std.mem.splitSequence(u8, s, d);
    while (it.next()) |part| parts.append(gpa(ctx), part) catch return api.resultErrorNomem(ctx);
    const len: i64 = @intCast(parts.items.len);
    const idx: i64 = if (n > 0) n - 1 else len + n;
    if (idx < 0 or idx >= len) return api.resultText(ctx, "", .static);
    api.resultText(ctx, parts.items[@intCast(idx)], .transient);
}

fn startsWithFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const s = text(ctx, argv[0]) orelse return;
    const p = text(ctx, argv[1]) orelse return;
    api.resultInt64(ctx, @intFromBool(std.mem.startsWith(u8, s, p)));
}

// ============================================================= random

fn randomFunc(ctx: *Context, _: []*Mem) void {
    api.resultDouble(ctx, dfunc.randomUnit(ctx));
}

fn uuidFunc(ctx: *Context, _: []*Mem) void {
    const out = dfunc.uuidV4(ctx);
    api.resultText(ctx, &out, .transient);
}

// =============================================================== math

fn floorFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (isInt(argv[0])) return api.resultInt64(ctx, api.valueInt64(argv[0]));
    api.resultDouble(ctx, @floor(api.valueDouble(argv[0])));
}

fn ceilFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (isInt(argv[0])) return api.resultInt64(ctx, api.valueInt64(argv[0]));
    api.resultDouble(ctx, @ceil(api.valueDouble(argv[0])));
}

fn truncFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const x = api.valueDouble(argv[0]);
    if (argv.len == 1) {
        if (isInt(argv[0])) return api.resultInt64(ctx, api.valueInt64(argv[0]));
        return api.resultDouble(ctx, @trunc(x));
    }
    const n: f64 = @floatFromInt(@max(-300, @min(300, api.valueInt64(argv[1]))));
    const scale = std.math.pow(f64, 10, n);
    api.resultDouble(ctx, @trunc(x * scale) / scale);
}

fn sqrtFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const x = api.valueDouble(argv[0]);
    if (x < 0) return api.resultErrorState(ctx, .of("2201F"), "cannot take square root of a negative number");
    api.resultDouble(ctx, @sqrt(x));
}

fn powerFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const x = api.valueDouble(argv[0]);
    const y = api.valueDouble(argv[1]);
    if (x == 0 and y < 0) return api.resultErrorState(ctx, .of("2201F"), "zero raised to a negative power is undefined");
    if (x < 0 and @floor(y) != y) return api.resultErrorState(ctx, .of("2201F"), "a negative number raised to a non-integer power yields a complex result");
    api.resultDouble(ctx, std.math.pow(f64, x, y));
}

fn expFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    api.resultDouble(ctx, @exp(api.valueDouble(argv[0])));
}

fn checkLog(ctx: *Context, x: f64) bool {
    if (x == 0) {
        api.resultErrorState(ctx, .of("2201E"), "cannot take logarithm of zero");
        return false;
    }
    if (x < 0) {
        api.resultErrorState(ctx, .of("2201E"), "cannot take logarithm of a negative number");
        return false;
    }
    return true;
}

fn lnFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const x = api.valueDouble(argv[0]);
    if (!checkLog(ctx, x)) return;
    api.resultDouble(ctx, @log(x));
}

/// log(x) is base 10; log(b, x) base b.
fn logFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const x = api.valueDouble(argv[argv.len - 1]);
    if (!checkLog(ctx, x)) return;
    if (argv.len == 1) return api.resultDouble(ctx, @log10(x));
    const b = api.valueDouble(argv[0]);
    if (!checkLog(ctx, b)) return;
    if (b == 1) return api.resultErrorState(ctx, .of("22012"), "division by zero");
    api.resultDouble(ctx, @log(x) / @log(b));
}

fn modFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (isInt(argv[0]) and isInt(argv[1])) {
        const b = api.valueInt64(argv[1]);
        if (b == 0) return api.resultErrorState(ctx, .of("22012"), "division by zero");
        if (b == -1) return api.resultInt64(ctx, 0);
        return api.resultInt64(ctx, @rem(api.valueInt64(argv[0]), b));
    }
    const b = api.valueDouble(argv[1]);
    if (b == 0) return api.resultErrorState(ctx, .of("22012"), "division by zero");
    api.resultDouble(ctx, @rem(api.valueDouble(argv[0]), b));
}

fn signFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (isInt(argv[0])) return api.resultInt64(ctx, std.math.sign(api.valueInt64(argv[0])));
    api.resultDouble(ctx, std.math.sign(api.valueDouble(argv[0])));
}

fn piFunc(ctx: *Context, _: []*Mem) void {
    api.resultDouble(ctx, std.math.pi);
}

// ============================================================= session

fn currentUserFunc(ctx: *Context, _: []*Mem) void {
    api.resultText(ctx, "postgres", .static);
}

fn currentDatabaseFunc(ctx: *Context, _: []*Mem) void {
    api.resultText(ctx, "main", .static);
}

// ============================================================== casts

/// The cast to boolean: NULL stays NULL, a number is true unless 0, a
/// string is one of PostgreSQL's spellings (or a prefix of one).
fn boolFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return api.resultNull(ctx),
        vi.SQLITE_INTEGER => return api.resultInt64(ctx, @intFromBool(api.valueInt64(m) != 0)),
        vi.SQLITE_FLOAT => return api.resultErrorState(ctx, .of("42846"), "cannot cast type double precision to boolean"),
        else => {},
    }
    const raw = text(ctx, m) orelse return;
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (parseBool(s)) |b| return api.resultInt64(ctx, @intFromBool(b));
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type boolean: \"{s}\"", .{raw[0..@min(raw.len, 64)]}) catch "invalid input syntax for type boolean";
    api.resultErrorState(ctx, .of("22P02"), msg);
}

pub const IntType = enum(u8) {
    smallint = 16,
    integer = 32,
    bigint = 64,

    fn holds(t: IntType, v: i64) bool {
        const bits: u6 = @intCast(@backingInt(t) - 1);
        if (t == .bigint) return true;
        const lim = @as(i64, 1) << bits;
        return v >= -lim and v < lim;
    }
};

/// xq_pg_int2(), xq_pg_int4(), xq_pg_int8(): the cast to an integer type
/// (PostgreSQL rounds a fraction half away from zero; SQLite's CAST
/// truncates).
fn intFunc(ctx: *Context, argv: []*Mem, comptime t: IntType) void {
    const m = argv[0];
    const range_msg = @tagName(t) ++ " out of range";
    const v: i64 = switch (api.valueType(m)) {
        vi.SQLITE_NULL => return api.resultNull(ctx),
        vi.SQLITE_INTEGER => api.valueInt64(m),
        vi.SQLITE_FLOAT => blk: {
            const r = @round(api.valueDouble(m));
            if (!(r >= -0x1p63 and r < 0x1p63)) return api.resultErrorState(ctx, .of("22003"), range_msg);
            break :blk @intFromFloat(r);
        },
        vi.SQLITE_BLOB => return api.resultErrorState(ctx, .of("42846"), "cannot cast type bytea to " ++ @tagName(t)),
        else => blk: {
            const raw = text(ctx, m) orelse return;
            const s = std.mem.trim(u8, raw, " \t\r\n");
            break :blk std.fmt.parseInt(i64, s, 10) catch |err| switch (err) {
                error.Overflow => return api.resultErrorState(ctx, .of("22003"), range_msg),
                error.InvalidCharacter => {
                    var buf: [128]u8 = undefined;
                    const what = "invalid input syntax for type " ++ @tagName(t);
                    const msg = std.fmt.bufPrint(&buf, what ++ ": \"{s}\"", .{raw[0..@min(raw.len, 64)]}) catch what;
                    return api.resultErrorState(ctx, .of("22P02"), msg);
                },
            };
        },
    };
    if (!t.holds(v)) return api.resultErrorState(ctx, .of("22003"), range_msg);
    api.resultInt64(ctx, v);
}

// ============================================================== stores

/// What a value stored into a boolean column goes through
/// (typing.Rules.store, coded by INSERT and UPDATE): a string is read as
/// PostgreSQL reads a boolean's input ('t', 'yes', 'on', '1' ..., case
/// and the spaces around ignored); other values are stored as they are
/// (the column's check takes 0 and 1).
pub const store_boolean = dfunc.scalar("xq_pg_store_boolean", 1, det, storeBooleanFunc);

/// What a value stored into a numeric column goes through: a string is
/// the number it spells ('1.50' is 1.5, '3' is 3), as numeric_in()
/// reads it; other values are stored as they are.
pub const store_numeric = dfunc.scalar("xq_pg_store_numeric", 1, det, storeNumericFunc);

fn storeBooleanFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (api.valueType(m) != vi.SQLITE_TEXT) return api.resultValue(ctx, m);
    const raw = text(ctx, m) orelse return;
    if (parseBool(std.mem.trim(u8, raw, " \t\r\n\x0b\x0c"))) |b| return api.resultInt64(ctx, @intFromBool(b));
    invalidInput(ctx, "boolean", raw);
}

fn storeNumericFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (api.valueType(m) != vi.SQLITE_TEXT) return api.resultValue(ctx, m);
    const raw = text(ctx, m) orelse return;
    const s = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
    if (!isNumericInput(s)) return invalidInput(ctx, "numeric", raw);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
        if (std.fmt.parseInt(i64, s, 10)) |v| return api.resultInt64(ctx, v) else |_| {}
    }
    const r = std.fmt.parseFloat(f64, s) catch return invalidInput(ctx, "numeric", raw);
    api.resultDouble(ctx, r);
}

/// Whether `s` is a number as numeric_in() reads one: a sign, digits
/// with or without a point, an exponent. (NaN and Infinity, which
/// PostgreSQL also reads, have no SQLite value to store.)
fn isNumericInput(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return false;
    }
    return i == s.len;
}

/// PostgreSQL's `invalid input syntax for type <t>: "<text>"` (22P02).
fn invalidInput(ctx: *Context, comptime t: []const u8, raw: []const u8) void {
    var buf: [128]u8 = undefined;
    const what = "invalid input syntax for type " ++ t;
    const msg = std.fmt.bufPrint(&buf, what ++ ": \"{s}\"", .{raw[0..@min(raw.len, 64)]}) catch what;
    api.resultErrorState(ctx, .of("22P02"), msg);
}

pub fn parseBool(s: []const u8) ?bool {
    if (s.len == 0) return null;
    const words = [_]struct { []const u8, bool, usize }{
        // word, value, shortest accepted prefix
        .{ "true", true, 1 }, .{ "false", false, 1 }, .{ "yes", true, 1 }, .{ "no", false, 1 },
        .{ "on", true, 2 },   .{ "off", false, 2 },   .{ "1", true, 1 },   .{ "0", false, 1 },
    };
    for (words) |w| {
        if (s.len >= w[2] and s.len <= w[0].len and std.ascii.eqlIgnoreCase(s, w[0][0..s.len])) return w[1];
    }
    return null;
}

// ================================================== information_schema

/// A declared type split into its name and modifiers: "numeric(10,2)"
/// is "numeric" and "10,2"; "timestamp(3) without time zone" is
/// "timestamp without time zone" and "3".
const Decl = struct {
    base: []const u8,
    mods: []const u8,
    buf: [64]u8 = undefined,
};

fn splitDecl(decl: []const u8, out: *Decl) void {
    const lp = std.mem.indexOfScalar(u8, decl, '(') orelse {
        out.base = decl;
        out.mods = "";
        return;
    };
    const rp = std.mem.indexOfScalarPos(u8, decl, lp, ')') orelse {
        out.base = decl;
        out.mods = "";
        return;
    };
    out.mods = decl[lp + 1 .. rp];
    const rest = decl[rp + 1 ..];
    const head = std.mem.trimEnd(u8, decl[0..lp], " ");
    if (rest.len > 0 and head.len + rest.len <= out.buf.len) {
        @memcpy(out.buf[0..head.len], head);
        @memcpy(out.buf[head.len..][0..rest.len], rest);
        out.base = out.buf[0 .. head.len + rest.len];
    } else {
        out.base = head;
    }
}

/// The PostgreSQL name of a declared type that is not one (a column
/// of a table the SQLite dialect created).
fn sqliteToPg(base: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "integer", "bigint" }, .{ "int", "bigint" },      .{ "text", "text" }, .{ "real", "double precision" },
        .{ "blob", "bytea" },     .{ "numeric", "numeric" }, .{ "", "text" },     .{ "any", "text" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], base)) return m[1];
    return base;
}

/// The declared type of (pg_type, sqlite_type): the PostgreSQL type the
/// catalog records, else the SQLite type mapped to PostgreSQL's names.
fn declArg(ctx: *Context, argv: []*Mem, d: *Decl) bool {
    if (!isNull(argv[0])) {
        const s = text(ctx, argv[0]) orelse return false;
        splitDecl(s, d);
        return true;
    }
    const s = if (isNull(argv[1])) "" else (text(ctx, argv[1]) orelse return false);
    splitDecl(s, d);
    d.base = sqliteToPg(d.base);
    return true;
}

fn dataTypeFunc(ctx: *Context, argv: []*Mem) void {
    var d: Decl = undefined;
    if (!declArg(ctx, argv, &d)) return;
    var lower: [64]u8 = undefined;
    if (d.base.len <= lower.len) {
        api.resultText(ctx, std.ascii.lowerString(&lower, d.base), .transient);
    } else api.resultText(ctx, d.base, .transient);
}

fn udtNameFunc(ctx: *Context, argv: []*Mem) void {
    var d: Decl = undefined;
    if (!declArg(ctx, argv, &d)) return;
    api.resultText(ctx, @import("types.zig").internalName(d.base), .transient);
}

fn firstMod(d: *const Decl, i: usize) ?i64 {
    var it = std.mem.splitScalar(u8, d.mods, ',');
    var k: usize = 0;
    while (it.next()) |m| : (k += 1) {
        if (k == i) return std.fmt.parseInt(i64, std.mem.trim(u8, m, " "), 10) catch null;
    }
    return null;
}

fn charMaxFunc(ctx: *Context, argv: []*Mem) void {
    var d: Decl = undefined;
    if (!declArg(ctx, argv, &d)) return;
    if (std.mem.eql(u8, d.base, "character varying") or std.mem.eql(u8, d.base, "character")) {
        if (firstMod(&d, 0)) |n| return api.resultInt64(ctx, n);
    }
    api.resultNull(ctx);
}

fn numPrecisionFunc(ctx: *Context, argv: []*Mem) void {
    var d: Decl = undefined;
    if (!declArg(ctx, argv, &d)) return;
    const base = d.base;
    const fixed = [_]struct { []const u8, i64 }{
        .{ "smallint", 16 }, .{ "integer", 32 }, .{ "bigint", 64 }, .{ "real", 24 }, .{ "double precision", 53 },
    };
    for (fixed) |f| if (std.mem.eql(u8, f[0], base)) return api.resultInt64(ctx, f[1]);
    if (std.mem.eql(u8, base, "numeric")) if (firstMod(&d, 0)) |n| return api.resultInt64(ctx, n);
    api.resultNull(ctx);
}

fn numScaleFunc(ctx: *Context, argv: []*Mem) void {
    var d: Decl = undefined;
    if (!declArg(ctx, argv, &d)) return;
    const base = d.base;
    if (std.mem.eql(u8, base, "smallint") or std.mem.eql(u8, base, "integer") or std.mem.eql(u8, base, "bigint")) return api.resultInt64(ctx, 0);
    if (std.mem.eql(u8, base, "numeric") and d.mods.len > 0) return api.resultInt64(ctx, firstMod(&d, 1) orelse 0);
    api.resultNull(ctx);
}

// ================================================================ tests

test "pg like matching" {
    const t = std.testing;
    try t.expect(try likeMatch("a%", "abc", '\\', false));
    try t.expect(!try likeMatch("A%", "abc", '\\', false));
    try t.expect(try likeMatch("A%", "abc", '\\', true));
    try t.expect(try likeMatch("_b_", "abc", '\\', false));
    try t.expect(try likeMatch("%c", "abc", '\\', false));
    try t.expect(try likeMatch("%b%", "abc", '\\', false));
    try t.expect(!try likeMatch("%d%", "abc", '\\', false));
    try t.expect(try likeMatch("a\\%", "a%", '\\', false));
    try t.expect(!try likeMatch("a\\%", "ab", '\\', false));
    try t.expect(try likeMatch("a!_", "a_", '!', false));
    try t.expect(try likeMatch("é_", "éx", null, false));
    try t.expect(try likeMatch("%", "", '\\', false));
    try t.expect(try likeMatch("%a%a", "banana", '\\', false));
    try t.expectError(error.TrailingEscape, likeMatch("a\\", "a", '\\', false));
    try t.expectEqual(@as(?bool, true), parseBool("TRUE"));
    try t.expectEqual(@as(?bool, false), parseBool("of"));
    try t.expectEqual(@as(?bool, null), parseBool("o"));
}
