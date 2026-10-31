//! SQL functions of the MariaDB dialect (Hooks.functions) that SQLite
//! does not have or defines differently: the operators the parser
//! lowers to calls (xq_div, xq_xor, xq_bitxor, xq_date_add ...), and
//! MariaDB functions (POW, LPAD, DATE_FORMAT, YEAR ...; those SQL Server
//! shares, FLOOR, LEFT ..., are in ../shared_funcs.zig).
//! Dates are MariaDB's text forms ('YYYY-MM-DD', 'YYYY-MM-DD hh:mm:ss');
//! "now" is UTC (@@time_zone is +00:00).

const std = @import("std");
const calendar = @import("../calendar.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const types = @import("types.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

const isNull = dfunc.isNull;
const anyNull = dfunc.anyNull;
const isIntegral = dfunc.isIntegral;
const text = dfunc.text;
const utf8Len = dfunc.charCount;
const utf8Offset = dfunc.charOffset;

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

pub fn powFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const r = std.math.pow(f64, api.valueDouble(argv[0]), api.valueDouble(argv[1]));
    if (std.math.isNan(r) or std.math.isInf(r)) return api.resultError(ctx, "DOUBLE value is out of range in 'pow'");
    api.resultDouble(ctx, r);
}

/// RAND([seed]): a float in [0, 1).
pub fn randFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 1 and !isNull(argv[0])) {
        var prng: std.Random.DefaultPrng = .init(@bitCast(api.valueInt64(argv[0])));
        return api.resultDouble(ctx, prng.random().float(f64));
    }
    api.resultDouble(ctx, dfunc.randomUnit(ctx));
}

/// UUID(): a random (version 4) UUID.
pub fn uuidFunc(ctx: *Context, _: []*Mem) void {
    const out = dfunc.uuidV4(ctx);
    api.resultText(ctx, &out, .transient);
}

// ============================================================== strings

/// LPAD(s, n, pad), RPAD(s, n, pad).
fn padFunc(comptime right: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (anyNull(argv)) return api.resultNull(ctx);
            const gpa = api.contextDbHandle(ctx).gpa;
            const z = text(ctx, argv[0]) orelse return;
            const n_i = api.valueInt64(argv[1]);
            const pad = if (argv.len > 2) (text(ctx, argv[2]) orelse return) else " ";
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
            dfunc.resultOwned(ctx, &out);
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
    dfunc.resultOwned(ctx, &out);
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
    const z = text(ctx, argv[0]) orelse return;
    const pos = api.valueInt64(argv[1]);
    const len = api.valueInt64(argv[2]);
    const new = text(ctx, argv[3]) orelse return;
    const n = utf8Len(z);
    if (pos < 1 or pos > n) return api.resultText(ctx, z, .transient);
    const a = utf8Offset(z, @intCast(pos - 1));
    const b = if (len < 0) z.len else utf8Offset(z, @intCast(@min(@as(i64, @intCast(n)), pos - 1 + len)));
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(gpa, z[0..a]) catch return api.resultErrorNomem(ctx);
    out.appendSlice(gpa, new) catch return api.resultErrorNomem(ctx);
    out.appendSlice(gpa, z[b..]) catch return api.resultErrorNomem(ctx);
    dfunc.resultOwned(ctx, &out);
}

/// LOCATE(sub, s, pos): 1-based position of sub in s from pos, 0 if none.
pub fn locateFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const sub = text(ctx, argv[0]) orelse return;
    const z = text(ctx, argv[1]) orelse return;
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
    const needle = text(ctx, argv[0]) orelse return;
    const list = text(ctx, argv[1]) orelse return;
    var it = std.mem.splitScalar(u8, list, ',');
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
        const same = if (numeric) api.valueDouble(m) == api.valueDouble(argv[0]) else std.ascii.eqlIgnoreCase(text(ctx, m) orelse return, text(ctx, argv[0]) orelse return);
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

// ================================================================ dates

pub const daysFromCivil = calendar.daysFromCivil;
pub const civilFromDays = calendar.civilFromDays;

/// A date/time argument: parsed, or null (then the result is NULL).
fn dateArg(m: *Mem) ?types.DateTime {
    if (isNull(m)) return null;
    var buf: [32]u8 = undefined;
    const z: []const u8 = switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => std.fmt.bufPrint(&buf, "{d}", .{api.valueInt64(m)}) catch return null,
        else => api.valueText(m) orelse return null,
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
    const to = text(ctx, argv[1]) orelse return;
    var buf: [48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (std.mem.eql(u8, to, "time")) {
        const tm = types.parseTime(text(ctx, argv[0]) orelse return) orelse return api.resultNull(ctx);
        if (tm.neg) w.writeByte('-') catch {};
        writeTime(&w, tm.hours, tm.minute, tm.second, tm.micro);
        return api.resultText(ctx, w.buffered(), .transient);
    }
    const dt = dateArg(argv[0]) orelse return api.resultNull(ctx);
    const zero = dt.year == 0 and dt.month == 0 and dt.day == 0;
    if (!zero and !validCalendar(dt)) return api.resultNull(ctx);
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
    const unit = text(ctx, argv[2]) orelse return;
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
                const z = text(ctx, argv[0]) orelse return;
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
    const unit = text(ctx, argv[0]) orelse return;
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
    const unit = text(ctx, argv[0]) orelse return;
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

/// DAYNAME(d), MONTHNAME(d).
fn nameFunc(comptime month: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            const dt = dateArg(argv[0]) orelse return api.resultNull(ctx);
            if (!validCalendar(dt)) return api.resultNull(ctx);
            if (month) return api.resultText(ctx, month_names[dt.month - 1], .static);
            const wd: usize = @intCast(@mod(daysFromCivil(dt.year, dt.month, dt.day) + 3, 7));
            api.resultText(ctx, day_names[wd], .static);
        }
    }.call;
}

pub const daynameFunc = nameFunc(false);
pub const monthnameFunc = nameFunc(true);

/// STR_TO_DATE(s, fmt): the date (or datetime, or time) `s` written in
/// DATE_FORMAT's format; NULL if it does not match.
pub fn strToDateFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const z = text(ctx, argv[0]) orelse return;
    const fmt = text(ctx, argv[1]) orelse return;
    var dt: types.DateTime = .{};
    var has_date = false;
    var has_time = false;
    var pm: ?bool = null;
    var i: usize = 0;
    var f: usize = 0;
    const Num = struct {
        fn read(s: []const u8, pos: *usize, max: usize) ?u32 {
            var v: u32 = 0;
            const start = pos.*;
            while (pos.* < s.len and pos.* - start < max and std.ascii.isDigit(s[pos.*])) : (pos.* += 1) v = v * 10 + (s[pos.*] - '0');
            return if (pos.* == start) null else v;
        }
    };
    while (f < fmt.len) : (f += 1) {
        if (fmt[f] != '%' or f + 1 == fmt.len) {
            if (i >= z.len or z[i] != fmt[f]) return api.resultNull(ctx);
            i += 1;
            continue;
        }
        f += 1;
        switch (fmt[f]) {
            'Y' => {
                dt.year = Num.read(z, &i, 4) orelse return api.resultNull(ctx);
                has_date = true;
            },
            'y' => {
                const y = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                dt.year = if (y < 70) 2000 + y else 1900 + y;
                has_date = true;
            },
            'm', 'c' => {
                dt.month = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                has_date = true;
            },
            'd', 'e' => {
                dt.day = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                has_date = true;
            },
            'H', 'k', 'h', 'I', 'l' => {
                dt.hour = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                has_time = true;
            },
            'i' => {
                dt.minute = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                has_time = true;
            },
            's', 'S' => {
                dt.second = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                has_time = true;
            },
            'f' => {
                const start = i;
                var v = Num.read(z, &i, 6) orelse return api.resultNull(ctx);
                var digits = i - start;
                while (digits < 6) : (digits += 1) v *= 10;
                dt.micro = v;
                has_time = true;
            },
            'p' => {
                if (i + 2 > z.len) return api.resultNull(ctx);
                pm = std.ascii.eqlIgnoreCase(z[i .. i + 2], "PM");
                i += 2;
            },
            'M', 'b' => {
                for (month_names, 1..) |m, k| {
                    const n = if (fmt[f] == 'b') m[0..3] else m;
                    if (i + n.len <= z.len and std.ascii.eqlIgnoreCase(z[i .. i + n.len], n)) {
                        dt.month = @intCast(k);
                        i += n.len;
                        break;
                    }
                } else return api.resultNull(ctx);
                has_date = true;
            },
            'T' => {
                dt.hour = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                if (i >= z.len or z[i] != ':') return api.resultNull(ctx);
                i += 1;
                dt.minute = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                if (i >= z.len or z[i] != ':') return api.resultNull(ctx);
                i += 1;
                dt.second = Num.read(z, &i, 2) orelse return api.resultNull(ctx);
                has_time = true;
            },
            '%' => {
                if (i >= z.len or z[i] != '%') return api.resultNull(ctx);
                i += 1;
            },
            else => return api.resultNull(ctx),
        }
    }
    if (pm) |is_pm| {
        if (dt.hour == 12) dt.hour = 0;
        if (is_pm) dt.hour += 12;
    }
    if (dt.month > 12 or dt.day > 31 or dt.hour > 23 or dt.minute > 59 or dt.second > 59) return api.resultNull(ctx);
    if (has_date and dt.month != 0 and dt.day != 0 and !validCalendar(dt)) return api.resultNull(ctx);
    var buf: [48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (has_date) writeDate(&w, dt.year, dt.month, dt.day);
    if (has_time) {
        if (has_date) w.writeByte(' ') catch {};
        writeTime(&w, dt.hour, dt.minute, dt.second, dt.micro);
    }
    if (!has_date and !has_time) return api.resultNull(ctx);
    api.resultText(ctx, w.buffered(), .transient);
}

/// DATE_FORMAT(d, fmt) with MariaDB's specifiers.
pub fn dateFormatFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const z = text(ctx, argv[0]) orelse return;
    const dt = types.parseDateTime(z) orelse blk: {
        const t = types.parseTime(z) orelse return api.resultNull(ctx);
        break :blk types.DateTime{ .hour = t.hours, .minute = t.minute, .second = t.second, .micro = t.micro };
    };
    const fmt = text(ctx, argv[1]) orelse return;
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
    const m = dfunc.aggState(Moments, ctx, true) orelse return;
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
            const m = dfunc.aggState(Moments, ctx, false) orelse return api.resultNull(ctx);
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
