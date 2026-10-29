//! SQL functions of the MariaDB dialect (Hooks.functions) that SQLite
//! does not have or defines differently: the operators the parser
//! lowers to calls (xq_div, xq_xor, xq_bitxor, xq_date_add ...), and
//! MariaDB functions (FLOOR, POW, LPAD, DATE_FORMAT, YEAR ...).
//! Dates are MariaDB's text forms ('YYYY-MM-DD', 'YYYY-MM-DD hh:mm:ss');
//! "now" is UTC (@@time_zone is +00:00).

const std = @import("std");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const types = @import("types.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

fn isNull(m: *Mem) bool {
    return api.valueType(m) == vi.SQLITE_NULL;
}

fn anyNull(argv: []*Mem) bool {
    for (argv) |m| if (isNull(m)) return true;
    return false;
}

fn isIntegral(m: *Mem) bool {
    return api.valueNumericType(m) == vi.SQLITE_INTEGER;
}

// ============================================================ operators

/// a DIV b: integer division, truncating; NULL for a zero divisor.
pub fn divFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (isIntegral(argv[0]) and isIntegral(argv[1])) {
        const a = api.valueInt64(argv[0]);
        const b = api.valueInt64(argv[1]);
        if (b == 0) return api.resultNull(ctx);
        if (a == std.math.minInt(i64) and b == -1) return api.resultError(ctx, "BIGINT value is out of range in DIV");
        return api.resultInt64(ctx, @divTrunc(a, b));
    }
    const a = api.valueDouble(argv[0]);
    const b = api.valueDouble(argv[1]);
    if (b == 0) return api.resultNull(ctx);
    const q = @trunc(a / b);
    if (!(q >= -9.2233720368547758e18 and q < 9.2233720368547758e18)) return api.resultError(ctx, "BIGINT value is out of range in DIV");
    api.resultInt64(ctx, @intFromFloat(q));
}

/// a XOR b: NULL if either is NULL, else whether exactly one is true.
pub fn xorFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const a = api.valueDouble(argv[0]) != 0;
    const b = api.valueDouble(argv[1]) != 0;
    api.resultInt64(ctx, @intFromBool(a != b));
}

/// a ^ b: bitwise exclusive or.
pub fn bitxorFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    api.resultInt64(ctx, api.valueInt64(argv[0]) ^ api.valueInt64(argv[1]));
}

// ================================================================ math

fn mathFunc(comptime f: fn (f64) f64) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (isNull(argv[0])) return api.resultNull(ctx);
            const r = f(api.valueDouble(argv[0]));
            if (std.math.isNan(r) or std.math.isInf(r)) return api.resultNull(ctx);
            api.resultDouble(ctx, r);
        }
    }.call;
}

fn sqrt(x: f64) f64 {
    return if (x < 0) std.math.nan(f64) else @sqrt(x);
}
fn exp(x: f64) f64 {
    return @exp(x);
}
fn ln(x: f64) f64 {
    return if (x <= 0) std.math.nan(f64) else @log(x);
}
fn log2(x: f64) f64 {
    return if (x <= 0) std.math.nan(f64) else @log2(x);
}
fn log10(x: f64) f64 {
    return if (x <= 0) std.math.nan(f64) else @log10(x);
}
fn sin(x: f64) f64 {
    return @sin(x);
}
fn cos(x: f64) f64 {
    return @cos(x);
}
fn tan(x: f64) f64 {
    return @tan(x);
}
fn asin(x: f64) f64 {
    return std.math.asin(x);
}
fn acos(x: f64) f64 {
    return std.math.acos(x);
}
fn atan(x: f64) f64 {
    return std.math.atan(x);
}
fn degrees(x: f64) f64 {
    return x * 180.0 / std.math.pi;
}
fn radians(x: f64) f64 {
    return x * std.math.pi / 180.0;
}

pub const sqrtFunc = mathFunc(sqrt);
pub const expFunc = mathFunc(exp);
pub const lnFunc = mathFunc(ln);
pub const log2Func = mathFunc(log2);
pub const log10Func = mathFunc(log10);
pub const sinFunc = mathFunc(sin);
pub const cosFunc = mathFunc(cos);
pub const tanFunc = mathFunc(tan);
pub const asinFunc = mathFunc(asin);
pub const acosFunc = mathFunc(acos);
pub const atanFunc = mathFunc(atan);
pub const degreesFunc = mathFunc(degrees);
pub const radiansFunc = mathFunc(radians);

/// LOG(x) is ln(x); LOG(b, x) is log base b.
pub fn logFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 1) return lnFunc(ctx, argv);
    if (anyNull(argv)) return api.resultNull(ctx);
    const b = api.valueDouble(argv[0]);
    const x = api.valueDouble(argv[1]);
    if (b <= 0 or b == 1 or x <= 0) return api.resultNull(ctx);
    api.resultDouble(ctx, @log(x) / @log(b));
}

pub fn piFunc(ctx: *Context, _: []*Mem) void {
    api.resultDouble(ctx, std.math.pi);
}

/// FLOOR/CEIL: an integer for an integer or a float that fits.
fn roundingFunc(comptime up: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (isNull(argv[0])) return api.resultNull(ctx);
            if (isIntegral(argv[0])) return api.resultInt64(ctx, api.valueInt64(argv[0]));
            const x = api.valueDouble(argv[0]);
            const r = if (up) @ceil(x) else @floor(x);
            if (r >= -9.2233720368547758e18 and r < 9.2233720368547758e18) return api.resultInt64(ctx, @intFromFloat(r));
            api.resultDouble(ctx, r);
        }
    }.call;
}

pub const floorFunc = roundingFunc(false);
pub const ceilFunc = roundingFunc(true);

pub fn powFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const r = std.math.pow(f64, api.valueDouble(argv[0]), api.valueDouble(argv[1]));
    if (std.math.isNan(r) or std.math.isInf(r)) return api.resultError(ctx, "DOUBLE value is out of range in 'pow'");
    api.resultDouble(ctx, r);
}

/// TRUNCATE(x, d): x truncated to d decimals.
pub fn truncateFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const d = api.valueInt64(argv[1]);
    if (isIntegral(argv[0]) and d >= 0) return api.resultInt64(ctx, api.valueInt64(argv[0]));
    const x = api.valueDouble(argv[0]);
    const p = std.math.pow(f64, 10, @floatFromInt(std.math.clamp(d, -30, 30)));
    const r = @trunc(x * p) / p;
    if (d <= 0 and r >= -9.2233720368547758e18 and r < 9.2233720368547758e18) return api.resultInt64(ctx, @intFromFloat(r));
    api.resultDouble(ctx, r);
}

/// RAND([seed]): a float in [0, 1).
pub fn randFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [8]u8 = undefined;
    if (argv.len == 1 and !isNull(argv[0])) {
        var prng: std.Random.DefaultPrng = .init(@bitCast(api.valueInt64(argv[0])));
        return api.resultDouble(ctx, prng.random().float(f64));
    }
    @import("../../sql/func.zig").randomness(api.contextDbHandle(ctx), &buf);
    const v = std.mem.readInt(u64, &buf, .little) >> 11;
    api.resultDouble(ctx, @as(f64, @floatFromInt(v)) / 9007199254740992.0);
}

/// UUID(): a random (version 4) UUID.
pub fn uuidFunc(ctx: *Context, _: []*Mem) void {
    var b: [16]u8 = undefined;
    @import("../../sql/func.zig").randomness(api.contextDbHandle(ctx), &b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) catch unreachable;
    api.resultText(ctx, &out, .transient);
}

// ============================================================== strings

fn text(m: *Mem) []const u8 {
    return api.valueText(m) orelse "";
}

fn utf8Len(z: []const u8) usize {
    var n: usize = 0;
    for (z) |c| {
        if (c & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// Byte offset of character `n` (clamped to the end).
fn utf8Offset(z: []const u8, n: usize) usize {
    var count: usize = 0;
    for (z, 0..) |c, i| {
        if (c & 0xc0 != 0x80) {
            if (count == n) return i;
            count += 1;
        }
    }
    return z.len;
}

fn resultOwned(ctx: *Context, out: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    defer out.deinit(gpa);
    api.resultText(ctx, out.items, .transient);
}

/// LEFT(s, n), RIGHT(s, n).
fn sideFunc(comptime right: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (anyNull(argv)) return api.resultNull(ctx);
            const z = text(argv[0]);
            const n_i = api.valueInt64(argv[1]);
            const n: usize = if (n_i < 0) 0 else @intCast(n_i);
            const len = utf8Len(z);
            if (n >= len) return api.resultText(ctx, z, .transient);
            if (right) return api.resultText(ctx, z[utf8Offset(z, len - n)..], .transient);
            api.resultText(ctx, z[0..utf8Offset(z, n)], .transient);
        }
    }.call;
}

pub const leftFunc = sideFunc(false);
pub const rightFunc = sideFunc(true);

/// REPEAT(s, n).
pub fn repeatFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const gpa = api.contextDbHandle(ctx).gpa;
    const z = text(argv[0]);
    const n = api.valueInt64(argv[1]);
    if (n <= 0 or z.len == 0) return api.resultText(ctx, "", .static);
    if (@as(u64, @intCast(n)) * z.len > 1 << 30) return api.resultErrorTooBig(ctx);
    var out: std.ArrayList(u8) = .empty;
    for (0..@intCast(n)) |_| out.appendSlice(gpa, z) catch return api.resultErrorNomem(ctx);
    resultOwned(ctx, &out, gpa);
}

/// SPACE(n).
pub fn spaceFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const gpa = api.contextDbHandle(ctx).gpa;
    const n = api.valueInt64(argv[0]);
    if (n <= 0) return api.resultText(ctx, "", .static);
    if (n > 1 << 30) return api.resultErrorTooBig(ctx);
    var out: std.ArrayList(u8) = .empty;
    out.appendNTimes(gpa, ' ', @intCast(n)) catch return api.resultErrorNomem(ctx);
    resultOwned(ctx, &out, gpa);
}

/// REVERSE(s), by characters.
pub fn reverseFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const gpa = api.contextDbHandle(ctx).gpa;
    const z = text(argv[0]);
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, z.len) catch return api.resultErrorNomem(ctx);
    var end = z.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and z[start] & 0xc0 == 0x80) start -= 1;
        out.appendSliceAssumeCapacity(z[start..end]);
        end = start;
    }
    resultOwned(ctx, &out, gpa);
}

/// LPAD(s, n, pad), RPAD(s, n, pad).
fn padFunc(comptime right: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (anyNull(argv)) return api.resultNull(ctx);
            const gpa = api.contextDbHandle(ctx).gpa;
            const z = text(argv[0]);
            const n_i = api.valueInt64(argv[1]);
            const pad = if (argv.len > 2) text(argv[2]) else " ";
            if (n_i < 0) return api.resultNull(ctx);
            const n: usize = @intCast(@min(n_i, 1 << 24));
            const len = utf8Len(z);
            if (n <= len) return api.resultText(ctx, z[0..utf8Offset(z, n)], .transient);
            if (pad.len == 0) return api.resultNull(ctx);
            var fill: std.ArrayList(u8) = .empty;
            defer fill.deinit(gpa);
            var k: usize = 0;
            const pad_len = utf8Len(pad);
            while (k < n - len) : (k += 1) {
                const ci = k % pad_len;
                const a = utf8Offset(pad, ci);
                const b = utf8Offset(pad, ci + 1);
                fill.appendSlice(gpa, pad[a..b]) catch return api.resultErrorNomem(ctx);
            }
            var out: std.ArrayList(u8) = .empty;
            if (right) {
                out.appendSlice(gpa, z) catch return api.resultErrorNomem(ctx);
                out.appendSlice(gpa, fill.items) catch return api.resultErrorNomem(ctx);
            } else {
                out.appendSlice(gpa, fill.items) catch return api.resultErrorNomem(ctx);
                out.appendSlice(gpa, z) catch return api.resultErrorNomem(ctx);
            }
            resultOwned(ctx, &out, gpa);
        }
    }.call;
}

pub const lpadFunc = padFunc(false);
pub const rpadFunc = padFunc(true);

/// HEX(x): a number in hexadecimal, a string's bytes in hexadecimal.
pub fn hexFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const gpa = api.contextDbHandle(ctx).gpa;
    const t = api.valueType(argv[0]);
    if (t == vi.SQLITE_INTEGER or t == vi.SQLITE_FLOAT) {
        const v: i64 = if (t == vi.SQLITE_INTEGER) api.valueInt64(argv[0]) else @intFromFloat(std.math.clamp(@round(api.valueDouble(argv[0])), -9.2e18, 9.2e18));
        var buf: [20]u8 = undefined;
        const z = std.fmt.bufPrint(&buf, "{X}", .{@as(u64, @bitCast(v))}) catch unreachable;
        return api.resultText(ctx, z, .transient);
    }
    const z = (if (t == vi.SQLITE_BLOB) api.valueBlob(argv[0]) else api.valueText(argv[0])) orelse "";
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, z.len * 2) catch return api.resultErrorNomem(ctx);
    const digits = "0123456789ABCDEF";
    for (z) |c| {
        out.appendAssumeCapacity(digits[c >> 4]);
        out.appendAssumeCapacity(digits[c & 15]);
    }
    resultOwned(ctx, &out, gpa);
}

/// FORMAT(x, d): '1,234.50'.
pub fn formatFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return api.resultNull(ctx);
    const x = api.valueDouble(argv[0]);
    const d: usize = @intCast(std.math.clamp(api.valueInt64(argv[1]), 0, 30));
    var buf: [400]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ @abs(x), d }) catch return api.resultNull(ctx);
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse raw.len;
    var out: [512]u8 = undefined;
    var n: usize = 0;
    if (x < 0 and !std.mem.allEqual(u8, std.mem.trimStart(u8, raw, "0."), '0')) {
        out[n] = '-';
        n += 1;
    }
    for (raw[0..dot], 0..) |c, i| {
        if (i > 0 and (dot - i) % 3 == 0) {
            out[n] = ',';
            n += 1;
        }
        out[n] = c;
        n += 1;
    }
    @memcpy(out[n..][0 .. raw.len - dot], raw[dot..]);
    n += raw.len - dot;
    api.resultText(ctx, out[0..n], .transient);
}

/// INSERT(s, pos, len, new).
pub fn insertFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const gpa = api.contextDbHandle(ctx).gpa;
    const z = text(argv[0]);
    const pos = api.valueInt64(argv[1]);
    const len = api.valueInt64(argv[2]);
    const new = text(argv[3]);
    const n = utf8Len(z);
    if (pos < 1 or pos > n) return api.resultText(ctx, z, .transient);
    const a = utf8Offset(z, @intCast(pos - 1));
    const b = if (len < 0) z.len else utf8Offset(z, @intCast(@min(@as(i64, @intCast(n)), pos - 1 + len)));
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(gpa, z[0..a]) catch return api.resultErrorNomem(ctx);
    out.appendSlice(gpa, new) catch return api.resultErrorNomem(ctx);
    out.appendSlice(gpa, z[b..]) catch return api.resultErrorNomem(ctx);
    resultOwned(ctx, &out, gpa);
}

/// LOCATE(sub, s, pos): 1-based position of sub in s from pos, 0 if none.
pub fn locateFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const sub = text(argv[0]);
    const z = text(argv[1]);
    const pos = api.valueInt64(argv[2]);
    if (pos < 1) return api.resultInt64(ctx, 0);
    const start = utf8Offset(z, @intCast(pos - 1));
    const i = indexOfIgnoreCasePos(z, start, sub) orelse return api.resultInt64(ctx, 0);
    api.resultInt64(ctx, @intCast(utf8Len(z[0..i]) + 1));
}

fn indexOfIgnoreCasePos(z: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len > z.len) return null;
    var i = start;
    while (i + needle.len <= z.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(z[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// FIND_IN_SET(s, list): 1-based index of s in the comma list, 0 if none.
pub fn findInSetFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const needle = text(argv[0]);
    var it = std.mem.splitScalar(u8, text(argv[1]), ',');
    var i: i64 = 1;
    while (it.next()) |item| : (i += 1) {
        if (std.ascii.eqlIgnoreCase(item, needle)) return api.resultInt64(ctx, i);
    }
    api.resultInt64(ctx, 0);
}

/// FIELD(s, a, b, ...): 1-based index of s among the others, 0 if none.
pub fn fieldFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 2 or isNull(argv[0])) return api.resultInt64(ctx, 0);
    const numeric = isIntegral(argv[0]) or api.valueType(argv[0]) == vi.SQLITE_FLOAT;
    for (argv[1..], 1..) |m, i| {
        if (isNull(m)) continue;
        const same = if (numeric) api.valueDouble(m) == api.valueDouble(argv[0]) else std.ascii.eqlIgnoreCase(text(m), text(argv[0]));
        if (same) return api.resultInt64(ctx, @intCast(i));
    }
    api.resultInt64(ctx, 0);
}

/// ELT(n, a, b, ...): the n-th of the others, NULL if none.
pub fn eltFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 2 or isNull(argv[0])) return api.resultNull(ctx);
    const n = api.valueInt64(argv[0]);
    if (n < 1 or n >= argv.len) return api.resultNull(ctx);
    api.resultValue(ctx, argv[@intCast(n)]);
}

/// BIT_LENGTH(s).
pub fn bitLengthFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    _ = api.valueText(argv[0]);
    api.resultInt64(ctx, @intCast(api.valueBytes(argv[0]) * 8));
}

/// JSON_UNQUOTE(s): the value of a JSON string, else s.
pub fn jsonUnquoteFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = text(argv[0]);
    if (z.len < 2 or z[0] != '"' or z[z.len - 1] != '"') return api.resultText(ctx, z, .transient);
    const gpa = api.contextDbHandle(ctx).gpa;
    const v = std.json.parseFromSlice([]const u8, gpa, z, .{}) catch return api.resultText(ctx, z, .transient);
    defer v.deinit();
    api.resultText(ctx, v.value, .transient);
}

// ================================================================ dates

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(z_in: i64) struct { i64, u32, u32 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ if (m <= 2) y + 1 else y, m, d };
}

/// A date/time argument: parsed, or null (then the result is NULL).
fn dateArg(m: *Mem) ?types.DateTime {
    if (isNull(m)) return null;
    var buf: [32]u8 = undefined;
    const z: []const u8 = switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => std.fmt.bufPrint(&buf, "{d}", .{api.valueInt64(m)}) catch return null,
        else => text(m),
    };
    const dt = types.parseDateTime(z) orelse return null;
    if (dt.month > 12 or dt.day > 31) return null;
    return dt;
}

fn validCalendar(dt: types.DateTime) bool {
    return dt.month >= 1 and dt.day >= 1 and dt.day <= types.daysInMonth(dt.year, dt.month);
}

fn writeDate(w: *std.Io.Writer, y: i64, m: u32, d: u32) void {
    w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(y, 0))), m, d }) catch {};
}

fn writeTime(w: *std.Io.Writer, h: u32, mi: u32, s: u32, micro: u32) void {
    w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ h, mi, s }) catch {};
    if (micro != 0) w.print(".{d:0>6}", .{micro}) catch {};
}

/// xq_cast(x, 'date'|'datetime'|'time'): CAST(x AS DATE) and DATE(x),
/// in MariaDB's formats; NULL if x is not a date.
pub fn castFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const to = text(argv[1]);
    var buf: [48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (std.mem.eql(u8, to, "time")) {
        const tm = types.parseTime(text(argv[0])) orelse return api.resultNull(ctx);
        if (tm.neg) w.writeByte('-') catch {};
        writeTime(&w, tm.hours, tm.minute, tm.second, tm.micro);
        return api.resultText(ctx, w.buffered(), .transient);
    }
    const dt = dateArg(argv[0]) orelse return api.resultNull(ctx);
    writeDate(&w, dt.year, dt.month, dt.day);
    if (std.mem.eql(u8, to, "datetime")) {
        w.writeByte(' ') catch {};
        writeTime(&w, dt.hour, dt.minute, dt.second, dt.micro);
    }
    api.resultText(ctx, w.buffered(), .transient);
}

/// xq_date_add(d, n, 'UNIT'): d + INTERVAL n UNIT. A date stays a date
/// for units of a day or more; month arithmetic clips the day to the
/// month's last.
pub fn dateAddFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv[0..2])) return api.resultNull(ctx);
    var dt = dateArg(argv[0]) orelse return api.resultNull(ctx);
    if (!validCalendar(dt)) return api.resultNull(ctx);
    const unit = text(argv[2]);
    const n_f = api.valueDouble(argv[1]);
    const n: i64 = if (isIntegral(argv[1])) api.valueInt64(argv[1]) else @intFromFloat(std.math.clamp(@round(n_f), -1e15, 1e15));
    const U = struct {
        fn is(u: []const u8, name: []const u8) bool {
            return std.ascii.eqlIgnoreCase(u, name);
        }
    };
    var months: i64 = 0;
    var micros: i64 = 0;
    if (U.is(unit, "YEAR")) {
        months = n * 12;
    } else if (U.is(unit, "QUARTER")) {
        months = n * 3;
    } else if (U.is(unit, "MONTH")) {
        months = n;
    } else if (U.is(unit, "WEEK")) {
        micros = n * 7 * 86400_000000;
    } else if (U.is(unit, "DAY")) {
        micros = n * 86400_000000;
    } else if (U.is(unit, "HOUR")) {
        micros = n * 3600_000000;
    } else if (U.is(unit, "MINUTE")) {
        micros = n * 60_000000;
    } else if (U.is(unit, "SECOND")) {
        micros = if (isIntegral(argv[1])) n * 1000000 else @intFromFloat(n_f * 1e6);
    } else if (U.is(unit, "MICROSECOND")) {
        micros = n;
    } else return api.resultError(ctx, "xqlite: unsupported INTERVAL unit");
    var y: i64 = dt.year;
    var m: i64 = dt.month;
    var d: i64 = dt.day;
    if (months != 0) {
        const total = y * 12 + (m - 1) + months;
        y = @divFloor(total, 12);
        m = @mod(total, 12) + 1;
        if (y < 0 or y > 9999) return api.resultNull(ctx);
        d = @min(d, types.daysInMonth(@intCast(y), @intCast(m)));
    }
    const day_units = months != 0 or (@mod(micros, 86400_000000) == 0);
    var days = daysFromCivil(y, m, d);
    var tod: i64 = (@as(i64, dt.hour) * 3600 + @as(i64, dt.minute) * 60 + dt.second) * 1000000 + dt.micro;
    tod += micros;
    days += @divFloor(tod, 86400_000000);
    tod = @mod(tod, 86400_000000);
    const cy, const cm, const cd = civilFromDays(days);
    if (cy < 0 or cy > 9999) return api.resultNull(ctx);
    var buf: [48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeDate(&w, cy, cm, cd);
    dt.has_time = dt.has_time or !day_units;
    if (dt.has_time) {
        w.writeByte(' ') catch {};
        const secs: u32 = @intCast(@divFloor(tod, 1000000));
        writeTime(&w, secs / 3600, (secs / 60) % 60, secs % 60, @intCast(@mod(tod, 1000000)));
    }
    api.resultText(ctx, w.buffered(), .transient);
}

/// The part of a date: YEAR(d), MONTH(d), DAY(d), HOUR(t) ...
fn partFunc(comptime part: enum { year, month, day, hour, minute, second, microsecond, dayofweek, weekday, dayofyear, quarter, to_days }) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (isNull(argv[0])) return api.resultNull(ctx);
            if (part == .hour or part == .minute or part == .second or part == .microsecond) {
                const z = text(argv[0]);
                const tm = if (std.mem.indexOfScalar(u8, z, '-') != null and z.len >= 10)
                    (if (types.parseDateTime(z)) |dt| types.Time{ .hours = dt.hour, .minute = dt.minute, .second = dt.second, .micro = dt.micro } else null)
                else
                    types.parseTime(z);
                const t = tm orelse return api.resultNull(ctx);
                return api.resultInt64(ctx, switch (part) {
                    .hour => t.hours,
                    .minute => t.minute,
                    .second => t.second,
                    else => t.micro,
                });
            }
            const dt = dateArg(argv[0]) orelse return api.resultNull(ctx);
            const days = daysFromCivil(dt.year, dt.month, dt.day);
            const v: i64 = switch (part) {
                .year => dt.year,
                .month => dt.month,
                .day => dt.day,
                .quarter => (dt.month + 2) / 3,
                // 1970-01-01 was a Thursday; DAYOFWEEK: 1 = Sunday.
                .dayofweek => @mod(days + 4, 7) + 1,
                .weekday => @mod(days + 3, 7),
                .dayofyear => days - daysFromCivil(dt.year, 1, 1) + 1,
                .to_days => days + 719528,
                else => unreachable,
            };
            if (!validCalendar(dt) and part != .year and part != .month and part != .day) return api.resultNull(ctx);
            api.resultInt64(ctx, v);
        }
    }.call;
}

pub const yearFunc = partFunc(.year);
pub const monthFunc = partFunc(.month);
pub const dayFunc = partFunc(.day);
pub const hourFunc = partFunc(.hour);
pub const minuteFunc = partFunc(.minute);
pub const secondFunc = partFunc(.second);
pub const microsecondFunc = partFunc(.microsecond);
pub const dayofweekFunc = partFunc(.dayofweek);
pub const weekdayFunc = partFunc(.weekday);
pub const dayofyearFunc = partFunc(.dayofyear);
pub const quarterFunc = partFunc(.quarter);
pub const toDaysFunc = partFunc(.to_days);

/// xq_extract('UNIT', d): EXTRACT(unit FROM d).
pub fn extractFunc(ctx: *Context, argv: []*Mem) void {
    const unit = text(argv[0]);
    const sub = argv[1..2];
    const map = [_]struct { []const u8, dfunc.StepFn }{
        .{ "YEAR", yearFunc },     .{ "MONTH", monthFunc },   .{ "DAY", dayFunc },         .{ "HOUR", hourFunc },
        .{ "MINUTE", minuteFunc }, .{ "SECOND", secondFunc }, .{ "QUARTER", quarterFunc }, .{ "MICROSECOND", microsecondFunc },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(unit, m[0])) return m[1](ctx, @constCast(sub));
    api.resultError(ctx, "xqlite: unsupported EXTRACT unit");
}

/// DATEDIFF(a, b): days from b to a.
pub fn datediffFunc(ctx: *Context, argv: []*Mem) void {
    const a = dateArg(argv[0]) orelse return api.resultNull(ctx);
    const b = dateArg(argv[1]) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, daysFromCivil(a.year, a.month, a.day) - daysFromCivil(b.year, b.month, b.day));
}

/// xq_timestampdiff('UNIT', a, b): TIMESTAMPDIFF(unit, a, b).
pub fn timestampdiffFunc(ctx: *Context, argv: []*Mem) void {
    const a = dateArg(argv[1]) orelse return api.resultNull(ctx);
    const b = dateArg(argv[2]) orelse return api.resultNull(ctx);
    const unit = text(argv[0]);
    const ua = microOf(a);
    const ub = microOf(b);
    const diff = ub - ua;
    const U = struct {
        fn is(u: []const u8, n: []const u8) bool {
            return std.ascii.eqlIgnoreCase(u, n);
        }
    };
    if (U.is(unit, "MONTH") or U.is(unit, "QUARTER") or U.is(unit, "YEAR")) {
        var months: i64 = (@as(i64, b.year) - a.year) * 12 + @as(i64, b.month) - a.month;
        // A partial month does not count.
        const a_rest = microOf(.{ .year = 2000, .month = 1, .day = a.day, .hour = a.hour, .minute = a.minute, .second = a.second, .micro = a.micro });
        const b_rest = microOf(.{ .year = 2000, .month = 1, .day = b.day, .hour = b.hour, .minute = b.minute, .second = b.second, .micro = b.micro });
        if (months > 0 and b_rest < a_rest) months -= 1;
        if (months < 0 and b_rest > a_rest) months += 1;
        const div: i64 = if (U.is(unit, "MONTH")) 1 else if (U.is(unit, "QUARTER")) 3 else 12;
        return api.resultInt64(ctx, @divTrunc(months, div));
    }
    const per: i64 = if (U.is(unit, "MICROSECOND")) 1 else if (U.is(unit, "SECOND")) 1000000 else if (U.is(unit, "MINUTE")) 60_000000 else if (U.is(unit, "HOUR")) 3600_000000 else if (U.is(unit, "DAY")) 86400_000000 else if (U.is(unit, "WEEK")) 7 * 86400_000000 else return api.resultError(ctx, "xqlite: unsupported TIMESTAMPDIFF unit");
    api.resultInt64(ctx, @divTrunc(diff, per));
}

fn microOf(dt: types.DateTime) i64 {
    return (daysFromCivil(dt.year, dt.month, dt.day) * 86400 + @as(i64, dt.hour) * 3600 + @as(i64, dt.minute) * 60 + dt.second) * 1000000 + dt.micro;
}

/// LAST_DAY(d).
pub fn lastDayFunc(ctx: *Context, argv: []*Mem) void {
    const dt = dateArg(argv[0]) orelse return api.resultNull(ctx);
    if (dt.month < 1) return api.resultNull(ctx);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeDate(&w, dt.year, dt.month, types.daysInMonth(dt.year, dt.month));
    api.resultText(ctx, w.buffered(), .transient);
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const day_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

/// DATE_FORMAT(d, fmt) with MariaDB's specifiers.
pub fn dateFormatFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const z = text(argv[0]);
    const dt = types.parseDateTime(z) orelse blk: {
        const t = types.parseTime(z) orelse return api.resultNull(ctx);
        break :blk types.DateTime{ .hour = t.hours, .minute = t.minute, .second = t.second, .micro = t.micro };
    };
    const fmt = text(argv[1]);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const days = daysFromCivil(dt.year, dt.month, dt.day);
    const wd: usize = @intCast(@mod(days + 3, 7)); // 0 = Monday
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 == fmt.len) {
            w.writeByte(fmt[i]) catch break;
            continue;
        }
        i += 1;
        const h12 = if (dt.hour % 12 == 0) 12 else dt.hour % 12;
        (switch (fmt[i]) {
            'Y' => w.print("{d:0>4}", .{dt.year}),
            'y' => w.print("{d:0>2}", .{dt.year % 100}),
            'm' => w.print("{d:0>2}", .{dt.month}),
            'c' => w.print("{d}", .{dt.month}),
            'd' => w.print("{d:0>2}", .{dt.day}),
            'e' => w.print("{d}", .{dt.day}),
            'H' => w.print("{d:0>2}", .{dt.hour}),
            'k' => w.print("{d}", .{dt.hour}),
            'h', 'I' => w.print("{d:0>2}", .{h12}),
            'l' => w.print("{d}", .{h12}),
            'i' => w.print("{d:0>2}", .{dt.minute}),
            's', 'S' => w.print("{d:0>2}", .{dt.second}),
            'f' => w.print("{d:0>6}", .{dt.micro}),
            'p' => w.writeAll(if (dt.hour < 12) "AM" else "PM"),
            'M' => w.writeAll(if (dt.month >= 1) month_names[dt.month - 1] else ""),
            'b' => w.writeAll(if (dt.month >= 1) month_names[dt.month - 1][0..3] else ""),
            'W' => w.writeAll(day_names[wd]),
            'a' => w.writeAll(day_names[wd][0..3]),
            'w' => w.print("{d}", .{(wd + 1) % 7}),
            'j' => w.print("{d:0>3}", .{days - daysFromCivil(dt.year, 1, 1) + 1}),
            'T' => w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute, dt.second }),
            'r' => w.print("{d:0>2}:{d:0>2}:{d:0>2} {s}", .{ h12, dt.minute, dt.second, if (dt.hour < 12) "AM" else "PM" }),
            'D' => blk: {
                const sfx = if (dt.day % 100 >= 11 and dt.day % 100 <= 13) "th" else switch (dt.day % 10) {
                    1 => "st",
                    2 => "nd",
                    3 => "rd",
                    else => "th",
                };
                break :blk w.print("{d}{s}", .{ dt.day, sfx });
            },
            '%' => w.writeByte('%'),
            else => |c| w.writeByte(c),
        }) catch break;
    }
    api.resultText(ctx, w.buffered(), .transient);
}

// ========================================================== aggregates

const Moments = struct { n: f64 = 0, mean: f64 = 0, m2: f64 = 0 };

/// Welford's running variance.
pub fn varStep(ctx: *Context, argv: []*Mem) void {
    const buf = api.aggregateContext(ctx, @sizeOf(Moments)) orelse return;
    const m: *align(1) Moments = @ptrCast(buf.ptr);
    if (isNull(argv[0])) return;
    const x = api.valueDouble(argv[0]);
    m.n += 1;
    const d = x - m.mean;
    m.mean += d / m.n;
    m.m2 += d * (x - m.mean);
}

fn varFinal(comptime sample: bool, comptime root: bool) dfunc.FinalFn {
    return struct {
        fn call(ctx: *Context) void {
            const buf = api.aggregateContext(ctx, 0) orelse return api.resultNull(ctx);
            if (buf.len < @sizeOf(Moments)) return api.resultNull(ctx);
            const m: *align(1) Moments = @ptrCast(buf.ptr);
            const div = if (sample) m.n - 1 else m.n;
            if (div <= 0) return api.resultNull(ctx);
            const v = m.m2 / div;
            api.resultDouble(ctx, if (root) @sqrt(v) else v);
        }
    }.call;
}

pub const stddevPopFinal = varFinal(false, true);
pub const stddevSampFinal = varFinal(true, true);
pub const varPopFinal = varFinal(false, false);
pub const varSampFinal = varFinal(true, false);

test "runtime: civil dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 19723), daysFromCivil(2024, 1, 1));
    const y, const m, const d = civilFromDays(daysFromCivil(2024, 2, 29));
    try std.testing.expect(y == 2024 and m == 2 and d == 29);
}
