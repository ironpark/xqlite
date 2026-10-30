//! The functions of the T-SQL dialect: the engine functions its trees
//! lower to (xq_tsql_*, visible in every dialect, so that the schema may
//! keep them), the functions of its table (SQL Server's names) and the
//! session's (variables, identity, transactions, MERGE).
//!
//! Conversion (xq_tsql_cast(), xq_tsql_try_cast(), xq_tsql_store()):
//! SQL Server's rules for the types of types.zig, with its messages.
//! CAST truncates a string to the type's length, an assignment (store)
//! fails instead ("String or binary data would be truncated."), unless
//! only spaces are cut; TRY_CAST gives NULL where CAST fails. Dates and
//! times are text in SQL Server's own format: date 'YYYY-MM-DD',
//! datetime 'YYYY-MM-DD hh:mm:ss.fff' (in 1/300 s), datetime2(n)
//! 'YYYY-MM-DD hh:mm:ss.fffffff' with n digits, time(n), smalldatetime
//! (minutes), datetimeoffset(n) with '+hh:mm'.

const std = @import("std");
const calendar = @import("../calendar.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const catalog = @import("../../catalog/catalog.zig");
const types = @import("types.zig");
const maria = @import("../mariadb/runtime.zig");

const sequence = catalog.sequence;
const Context = dfunc.Context;
const Mem = dfunc.Mem;
const isNull = dfunc.isNull;
const anyNull = dfunc.anyNull;
const text = dfunc.text;

fn fail(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [400]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    api.resultError(ctx, msg);
}

/// At most 60 bytes of a value for a message.
fn clip(z: []const u8) []const u8 {
    return z[0..@min(z.len, 60)];
}

// ============================================================ conversion

pub const Mode = enum(u8) { cast, try_cast, store };

fn modeOf(ctx: *Context) Mode {
    const p = api.userData(ctx) orelse return .cast;
    return @fromBackingInt(@intCast(@as(u8, @truncate(@intFromPtr(p)))));
}

pub const user_cast: ?*anyopaque = @ptrFromInt(@as(usize, @backingInt(Mode.cast)) + 0x100);
pub const user_try: ?*anyopaque = @ptrFromInt(@as(usize, @backingInt(Mode.try_cast)) + 0x100);
pub const user_store: ?*anyopaque = @ptrFromInt(@as(usize, @backingInt(Mode.store)) + 0x100);

/// xq_tsql_cast(x, 'type') and friends (the mode is the user data). The
/// type of xq_tsql_store() may be followed by "|table|column", for the
/// messages.
pub fn convertFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const arg = text(ctx, argv[1]) orelse return;
    var it = std.mem.splitScalar(u8, arg, '|');
    const tz = it.next().?;
    const where: Where = .{ .table = it.next() orelse "", .column = it.next() orelse "" };
    const t = types.parseText(tz) orelse return fail(ctx, "Type {s} is not a defined system type.", .{tz});
    convertAt(ctx, argv[0], t, modeOf(ctx), where);
}

/// The column a value is stored into (for messages).
pub const Where = struct { table: []const u8 = "", column: []const u8 = "" };

fn truncated(ctx: *Context, w: Where, cut: []const u8) void {
    if (w.table.len == 0) return fail(ctx, "String or binary data would be truncated.", .{});
    fail(ctx, "String or binary data would be truncated in table '{s}', column '{s}'. Truncated value: '{s}'.", .{ w.table, w.column, clip(cut) });
}

/// A conversion failure: an error, or NULL for TRY_CAST.
fn bad(ctx: *Context, mode: Mode, comptime fmt: []const u8, args: anytype) void {
    if (mode == .try_cast) return api.resultNull(ctx);
    fail(ctx, fmt, args);
}

/// The SQL Server name of the type of a value, for messages.
fn sourceName(m: *Mem) []const u8 {
    return switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => "int",
        vi.SQLITE_FLOAT => "float",
        vi.SQLITE_BLOB => "varbinary",
        else => "varchar",
    };
}

pub fn convert(ctx: *Context, m: *Mem, t: types.Type, mode: Mode) void {
    convertAt(ctx, m, t, mode, .{});
}

fn convertAt(ctx: *Context, m: *Mem, t: types.Type, mode: Mode, where: Where) void {
    if (t.isInteger()) return toInteger(ctx, m, t, mode);
    if (t.isNumber()) return toReal(ctx, m, t, mode);
    if (t.isChar()) return toChars(ctx, m, t, mode, where);
    if (t.isBinary()) return toBinary(ctx, m, t, mode, where);
    if (t.isTemporal()) return toTemporal(ctx, m, t, mode);
    if (t.base == .uniqueidentifier) return toGuid(ctx, m, mode);
    api.resultValue(ctx, m);
}

/// An integer parsed as SQL Server reads one from a string: spaces, a
/// sign, digits ('' is 0).
fn parseIntText(z_in: []const u8) ?i128 {
    const z = std.mem.trim(u8, z_in, " \t\r\n");
    if (z.len == 0) return 0;
    var i: usize = 0;
    var neg = false;
    if (z[0] == '+' or z[0] == '-') {
        neg = z[0] == '-';
        i = 1;
    }
    if (i == z.len) return null;
    var v: i128 = 0;
    for (z[i..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(i64) + 1) return v; // overflowed: caller checks
    }
    return if (neg) -v else v;
}

/// A decimal number as SQL Server reads one from a string (no exponent
/// unless `exponent`).
fn parseDecText(z_in: []const u8, exponent: bool) ?f64 {
    const z = std.mem.trim(u8, z_in, " \t\r\n");
    if (z.len == 0) return if (exponent) 0 else null;
    var any_digit = false;
    for (z, 0..) |c, i| {
        if (std.ascii.isDigit(c)) {
            any_digit = true;
            continue;
        }
        if (c == '.') continue;
        if ((c == '+' or c == '-') and (i == 0 or (exponent and (z[i - 1] == 'e' or z[i - 1] == 'E')))) continue;
        if (exponent and (c == 'e' or c == 'E')) continue;
        return null;
    }
    if (!any_digit) return null;
    return std.fmt.parseFloat(f64, z) catch null;
}

fn roundHalfAway(x: f64, scale: i64) f64 {
    const p = std.math.pow(f64, 10, @floatFromInt(std.math.clamp(scale, -30, 30)));
    const y = x * p;
    // Absorb binary noise (1.005 * 100 = 100.49999...).
    const r = if (y >= 0) @floor(y + 0.5 + 1e-9) else -@floor(-y + 0.5 + 1e-9);
    return r / p;
}

fn toInteger(ctx: *Context, m: *Mem, t: types.Type, mode: Mode) void {
    const tname = @tagName(t.base);
    if (t.base == .bit) return toBit(ctx, m, mode);
    const exact = t.base == .decimal or t.base == .numeric;
    var v: i128 = undefined;
    switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => v = api.valueInt64(m),
        vi.SQLITE_FLOAT => {
            const f = api.valueDouble(m);
            const r = if (exact) roundHalfAway(f, 0) else @trunc(f);
            if (!(r > -1.8e19 and r < 1.8e19)) return bad(ctx, mode, "Arithmetic overflow error converting float to data type {s}.", .{tname});
            v = @intFromFloat(r);
        },
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse &.{};
            var x: u64 = 0;
            for (b[b.len -| 8..]) |c| x = (x << 8) | c;
            v = @as(i64, @bitCast(x));
        },
        else => {
            const z = text(ctx, m) orelse return;
            if (parseIntText(z)) |x| {
                v = x;
            } else if (exact) {
                const f = parseDecText(z, false) orelse return bad(ctx, mode, "Error converting data type varchar to numeric.", .{});
                v = @intFromFloat(std.math.clamp(roundHalfAway(f, 0), -1.7e19, 1.7e19));
            } else return bad(ctx, mode, "Conversion failed when converting the varchar value '{s}' to data type {s}.", .{ clip(z), tname });
            const lo, const hi = limits(t);
            if (v < lo or v > hi) {
                if (exact) return bad(ctx, mode, "Arithmetic overflow error converting varchar to data type numeric.", .{});
                return bad(ctx, mode, "The conversion of the varchar value '{s}' overflowed an {s} column.", .{ clip(z), tname });
            }
            return api.resultInt64(ctx, @intCast(v));
        },
    }
    const lo, const hi = limits(t);
    if (v < lo or v > hi) {
        if (exact) return bad(ctx, mode, "Arithmetic overflow error converting {s} to data type numeric.", .{sourceName(m)});
        if (api.valueType(m) == vi.SQLITE_INTEGER) return bad(ctx, mode, "Arithmetic overflow error for data type {s}, value = {d}.", .{ tname, v });
        return bad(ctx, mode, "Arithmetic overflow error converting expression to data type {s}.", .{tname});
    }
    api.resultInt64(ctx, @intCast(v));
}

fn limits(t: types.Type) struct { i128, i128 } {
    if (t.range()) |r| return .{ r[0], r[1] };
    if (t.base == .decimal or t.base == .numeric) {
        const lim = std.math.pow(i128, 10, @intCast(t.precision())) - 1;
        return .{ -lim, lim };
    }
    return .{ std.math.minInt(i64), std.math.maxInt(i64) };
}

fn toBit(ctx: *Context, m: *Mem, mode: Mode) void {
    switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => api.resultInt64(ctx, @intFromBool(api.valueInt64(m) != 0)),
        vi.SQLITE_FLOAT => api.resultInt64(ctx, @intFromBool(api.valueDouble(m) != 0)),
        else => {
            const z = std.mem.trim(u8, text(ctx, m) orelse return, " ");
            if (std.ascii.eqlIgnoreCase(z, "true")) return api.resultInt64(ctx, 1);
            if (std.ascii.eqlIgnoreCase(z, "false")) return api.resultInt64(ctx, 0);
            const f = parseDecText(z, true) orelse return bad(ctx, mode, "Conversion failed when converting the varchar value '{s}' to data type bit.", .{clip(z)});
            api.resultInt64(ctx, @intFromBool(f != 0));
        },
    }
}

fn toReal(ctx: *Context, m: *Mem, t: types.Type, mode: Mode) void {
    const exact = t.isExactNumeric();
    var f: f64 = undefined;
    switch (api.valueType(m)) {
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => f = api.valueDouble(m),
        vi.SQLITE_BLOB => return bad(ctx, mode, "Explicit conversion from data type varbinary to {s} is not allowed.", .{@tagName(t.base)}),
        else => {
            const z = text(ctx, m) orelse return;
            var zz = std.mem.trim(u8, z, " ");
            if ((t.base == .money or t.base == .smallmoney) and zz.len > 0 and zz[0] == '$') zz = zz[1..];
            f = parseDecText(zz, !exact) orelse {
                if (exact) return bad(ctx, mode, "Error converting data type varchar to numeric.", .{});
                return bad(ctx, mode, "Error converting data type varchar to float.", .{});
            };
        },
    }
    if (exact) {
        f = roundHalfAway(f, t.scaleOf());
        const lim = std.math.pow(f64, 10, @floatFromInt(t.precision() - t.scaleOf()));
        if (@abs(f) >= lim) return bad(ctx, mode, "Arithmetic overflow error converting {s} to data type numeric.", .{sourceName(m)});
    }
    api.resultDouble(ctx, f);
}

fn toChars(ctx: *Context, m: *Mem, t: types.Type, mode: Mode, where: Where) void {
    const z: []const u8 = switch (api.valueType(m)) {
        vi.SQLITE_BLOB => api.valueBlob(m) orelse "",
        else => text(ctx, m) orelse return,
    };
    const n = t.maxLength() orelse return api.resultText(ctx, z, .transient);
    const len = dfunc.charCount(z);
    if (len <= n) return api.resultText(ctx, z, .transient);
    const cut = dfunc.charOffset(z, @intCast(n));
    if (mode == .store and std.mem.trim(u8, z[cut..], " ").len != 0) return truncated(ctx, where, z[0..cut]);
    api.resultText(ctx, z[0..cut], .transient);
}

fn toBinary(ctx: *Context, m: *Mem, t: types.Type, mode: Mode, where: Where) void {
    var buf: [8]u8 = undefined;
    const b: []const u8 = switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => blk: {
            const v = api.valueInt64(m);
            std.mem.writeInt(i64, &buf, v, .big);
            break :blk if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) buf[4..] else buf[0..];
        },
        vi.SQLITE_BLOB => api.valueBlob(m) orelse "",
        else => text(ctx, m) orelse return,
    };
    const n = t.maxLength() orelse return api.resultBlob(ctx, b, .transient);
    if (b.len > n) {
        if (mode == .store) return truncated(ctx, where, "");
        return api.resultBlob(ctx, b[0..@intCast(n)], .transient);
    }
    if (t.base == .binary and b.len < n) {
        // binary(n) is padded with zero bytes.
        const out = dfunc.gpa(ctx).alloc(u8, @intCast(n)) catch return api.resultErrorNomem(ctx);
        @memcpy(out[0..b.len], b);
        @memset(out[b.len..], 0);
        return api.resultBlob(ctx, out, .dynamic);
    }
    api.resultBlob(ctx, b, .transient);
}

fn toGuid(ctx: *Context, m: *Mem, mode: Mode) void {
    const z = std.mem.trim(u8, text(ctx, m) orelse return, " ");
    var g = z;
    if (g.len == 38 and g[0] == '{' and g[37] == '}') g = g[1..37];
    var out: [36]u8 = undefined;
    const ok = g.len == 36 and for (g, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash) {
            if (c != '-') break false;
        } else if (!std.ascii.isHex(c)) break false;
        out[i] = std.ascii.toUpper(c);
    } else true;
    if (!ok) return bad(ctx, mode, "Conversion failed when converting from a character string to uniqueidentifier.", .{});
    api.resultText(ctx, &out, .transient);
}

// ======================================================= dates and times

/// A point in time: days since 1970-01-01, seconds of the day, the
/// fraction in 100 ns units, a time zone offset in minutes; and the shape
/// of the text it was read from.
pub const Moment = struct {
    days: i64 = daysFrom1900,
    secs: u32 = 0,
    frac: u32 = 0,
    off: ?i16 = null,
    has_date: bool = true,
    has_time: bool = false,
    frac_digits: u8 = 0,
    t_sep: bool = false,

    pub const daysFrom1900: i64 = -25567;

    fn ymd(mo: Moment) struct { i64, u32, u32 } {
        return calendar.civilFromDays(mo.days);
    }

    /// Normalize after arithmetic on secs/frac (given as wide values).
    fn fromParts(days: i64, secs: i64, frac: i64) Moment {
        var d = days;
        var s = secs;
        var f = frac;
        s += @divFloor(f, 10_000_000);
        f = @mod(f, 10_000_000);
        d += @divFloor(s, 86400);
        s = @mod(s, 86400);
        return .{ .days = d, .secs = @intCast(s), .frac = @intCast(f) };
    }

    /// 100 ns ticks since 1970.
    fn ticks(mo: Moment) i128 {
        return (@as(i128, mo.days) * 86400 + mo.secs) * 10_000_000 + mo.frac;
    }

    fn fromTicks(t: i128) Moment {
        const per_day: i128 = 86400 * 10_000_000;
        const days = @divFloor(t, per_day);
        const rest = t - days * per_day;
        return .{ .days = @intCast(days), .secs = @intCast(@divFloor(rest, 10_000_000)), .frac = @intCast(@mod(rest, 10_000_000)) };
    }
};

fn digits(z: []const u8, i: *usize, max: usize) ?u32 {
    const start = i.*;
    var v: u32 = 0;
    while (i.* < z.len and i.* - start < max and std.ascii.isDigit(z[i.*])) : (i.* += 1) v = v * 10 + (z[i.*] - '0');
    if (i.* == start) return null;
    return v;
}

/// The date and time formats SQL Server reads (us_english, mdy):
/// 'YYYY-MM-DD', 'YYYY/MM/DD', 'YYYYMMDD', 'MM/DD/YYYY', each with an
/// optional time 'hh:mm[:ss[.fffffff]] [AM|PM]' after a space or T, a
/// time alone (on 1900-01-01), and an offset 'Z' or '+hh:mm'.
pub fn parseMoment(z_in: []const u8) ?Moment {
    const z = std.mem.trim(u8, z_in, " \t\r\n");
    var mo: Moment = .{};
    var i: usize = 0;
    const has_date = std.mem.indexOfAny(u8, z, "-/.") != null and (std.mem.indexOfScalar(u8, z, ':') == null or std.mem.indexOfAny(u8, z, "-/.").? < std.mem.indexOfScalar(u8, z, ':').?) or
        (z.len >= 8 and std.ascii.isDigit(z[0]) and (z.len == 8 or z[8] == ' ' or z[8] == 'T'));
    if (has_date) {
        const a = digits(z, &i, 8) orelse return null;
        var y: u32 = 0;
        var mon: u32 = 0;
        var d: u32 = 0;
        if (i == 8) {
            y = a / 10000;
            mon = (a / 100) % 100;
            d = a % 100;
        } else {
            if (i >= z.len) return null;
            const sep = z[i];
            if (sep != '-' and sep != '/' and sep != '.') return null;
            i += 1;
            const b = digits(z, &i, 4) orelse return null;
            if (i >= z.len or z[i] != sep) return null;
            i += 1;
            const c = digits(z, &i, 4) orelse return null;
            if (a > 31) {
                y = a;
                mon = b;
                d = c;
            } else {
                // mdy
                mon = a;
                d = b;
                y = if (c < 100) (if (c < 50) 2000 + c else 1900 + c) else c;
            }
        }
        if (y < 1 or y > 9999 or mon < 1 or mon > 12 or d < 1 or d > daysInMonth(y, mon)) return null;
        mo.days = calendar.daysFromCivil(y, mon, d);
        if (i < z.len and (z[i] == 'T' or z[i] == ' ')) {
            mo.t_sep = z[i] == 'T';
            while (i < z.len and (z[i] == ' ' or z[i] == 'T')) i += 1;
        }
    } else mo.has_date = false;
    if (i < z.len and std.ascii.isDigit(z[i])) {
        const h = digits(z, &i, 2) orelse return null;
        if (i >= z.len or z[i] != ':') return null;
        i += 1;
        const mi = digits(z, &i, 2) orelse return null;
        var sec: u32 = 0;
        if (i < z.len and z[i] == ':') {
            i += 1;
            sec = digits(z, &i, 2) orelse return null;
            if (i < z.len and z[i] == '.') {
                i += 1;
                var scale: u32 = 1_000_000;
                var nd: u8 = 0;
                while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) {
                    if (nd < 7) mo.frac += (z[i] - '0') * scale;
                    scale /= 10;
                    nd += 1;
                }
                mo.frac_digits = @min(nd, 7);
            }
        }
        var hour = h;
        while (i < z.len and z[i] == ' ') i += 1;
        if (i + 1 < z.len and (z[i + 1] == 'M' or z[i + 1] == 'm') and (z[i] == 'A' or z[i] == 'a' or z[i] == 'P' or z[i] == 'p')) {
            if (hour == 0 or hour > 12) return null;
            const pm = z[i] == 'P' or z[i] == 'p';
            if (hour == 12) hour = 0;
            if (pm) hour += 12;
            i += 2;
        }
        if (hour > 23 or mi > 59 or sec > 59) return null;
        mo.secs = hour * 3600 + mi * 60 + sec;
        mo.has_time = true;
    }
    while (i < z.len and z[i] == ' ') i += 1;
    if (i < z.len) {
        if (z[i] == 'Z' or z[i] == 'z') {
            mo.off = 0;
            i += 1;
        } else if (z[i] == '+' or z[i] == '-') {
            const neg = z[i] == '-';
            i += 1;
            const oh = digits(z, &i, 2) orelse return null;
            if (i >= z.len or z[i] != ':') return null;
            i += 1;
            const om = digits(z, &i, 2) orelse return null;
            if (oh > 14 or om > 59) return null;
            const v: i16 = @intCast(oh * 60 + om);
            mo.off = if (neg) -v else v;
        }
    }
    if (i != z.len) return null;
    if (!mo.has_date and !mo.has_time) return null;
    return mo;
}

fn daysInMonth(y: u32, m: u32) u32 {
    return calendar.daysInMonth(y, m);
}

/// A value as a moment (text, or days since 1900-01-01 for a number).
fn momentOf(m: *Mem) ?Moment {
    switch (api.valueType(m)) {
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => {
            const f = api.valueDouble(m);
            if (!(f > -700000 and f < 3000000)) return null;
            var mo = Moment.fromTicks(@as(i128, Moment.daysFrom1900) * 86400 * 10_000_000 + @as(i128, @intFromFloat(@round(f * 86400.0 * 1000.0))) * 10_000);
            mo.has_time = true;
            mo.frac_digits = 3;
            return mo;
        },
        vi.SQLITE_TEXT => return parseMoment(api.valueText(m) orelse return null),
        else => return null,
    }
}

/// Round the fraction to `n` digits (carrying into the seconds).
fn roundFrac(mo: Moment, n: u8) Moment {
    const unit: u32 = std.math.pow(u32, 10, 7 - n);
    const f = (mo.frac + unit / 2) / unit * unit;
    var r = Moment.fromParts(mo.days, mo.secs, f);
    r.off = mo.off;
    return r;
}

/// datetime's rounding to 1/300 s: .000, .003, .007.
fn datetimeMillis(mo: Moment) struct { Moment, u32 } {
    var ticks300 = (@as(u64, mo.frac) * 300 + 5_000_000) / 10_000_000;
    var secs: i64 = mo.secs;
    if (ticks300 == 300) {
        ticks300 = 0;
        secs += 1;
    }
    const r = Moment.fromParts(mo.days, secs, 0);
    return .{ r, @intCast((ticks300 * 1000 + 150) / 300) };
}

fn writeDate(w: *std.Io.Writer, days: i64) void {
    const y, const m, const d = calendar.civilFromDays(days);
    w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(y, 0))), m, d }) catch {};
}

fn writeClock(w: *std.Io.Writer, secs: u32) void {
    w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, (secs / 60) % 60, secs % 60 }) catch {};
}

fn writeFrac(w: *std.Io.Writer, frac: u32, n: u8) void {
    if (n == 0) return;
    var buf: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>7}", .{frac}) catch {};
    w.writeByte('.') catch {};
    w.writeAll(buf[0..n]) catch {};
}

fn writeOffset(w: *std.Io.Writer, off: i16) void {
    const a: u16 = @abs(off);
    w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), a / 60, a % 60 }) catch {};
}

/// The text of `mo` as a value of type `t`; null if out of its range.
fn formatAs(w: *std.Io.Writer, mo_in: Moment, t: types.Type) bool {
    var mo = mo_in;
    switch (t.base) {
        .date => {
            const y, _, _ = mo.ymd();
            if (y < 1 or y > 9999) return false;
            writeDate(w, mo.days);
        },
        .datetime => {
            mo, const ms = datetimeMillis(mo);
            const y, _, _ = mo.ymd();
            if (y < 1753 or y > 9999) return false;
            writeDate(w, mo.days);
            w.writeByte(' ') catch {};
            writeClock(w, mo.secs);
            w.print(".{d:0>3}", .{ms}) catch {};
        },
        .smalldatetime => {
            // Rounded to the minute (29.998 s and up rounds up).
            var secs: i64 = mo.secs;
            const sec_part = @mod(secs, 60);
            secs -= sec_part;
            if (sec_part * 1000 + mo.frac / 10_000 >= 29_999) secs += 60;
            mo = Moment.fromParts(mo.days, secs, 0);
            const y, _, _ = mo.ymd();
            if (y < 1900 or y > 2079) return false;
            writeDate(w, mo.days);
            w.writeByte(' ') catch {};
            writeClock(w, mo.secs);
        },
        .datetime2, .datetimeoffset => {
            const n = t.fracDigits();
            const off = mo.off;
            mo = roundFrac(mo, n);
            mo.off = off;
            const y, _, _ = mo.ymd();
            if (y < 1 or y > 9999) return false;
            writeDate(w, mo.days);
            w.writeByte(' ') catch {};
            writeClock(w, mo.secs);
            writeFrac(w, mo.frac, n);
            if (t.base == .datetimeoffset) {
                w.writeByte(' ') catch {};
                writeOffset(w, mo.off orelse 0);
            }
        },
        .time => {
            const n = t.fracDigits();
            mo = roundFrac(mo, n);
            writeClock(w, mo.secs);
            writeFrac(w, mo.frac, n);
        },
        else => return false,
    }
    return true;
}

fn toTemporal(ctx: *Context, m: *Mem, t: types.Type, mode: Mode) void {
    if (api.valueType(m) == vi.SQLITE_BLOB) return bad(ctx, mode, "Explicit conversion from data type varbinary to {s} is not allowed.", .{@tagName(t.base)});
    if (t.base == .date and api.valueType(m) != vi.SQLITE_TEXT) return bad(ctx, mode, "Explicit conversion from data type {s} to date is not allowed.", .{sourceName(m)});
    const mo = momentOf(m) orelse return bad(ctx, mode, "Conversion failed when converting date and/or time from character string.", .{});
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (!formatAs(&w, mo, t)) {
        return bad(ctx, mode, "The conversion of a {s} data type to a {s} data type resulted in an out-of-range value.", .{ sourceName(m), @tagName(t.base) });
    }
    api.resultText(ctx, w.buffered(), .transient);
}

/// The text of `mo` in the shape it was read in (a date, a datetime with
/// so many fraction digits, an offset), for DATEADD.
fn formatShape(w: *std.Io.Writer, mo: Moment, upgrade: bool) void {
    if (!mo.has_time and !upgrade) return writeDate(w, mo.days);
    if (mo.has_date or upgrade) {
        writeDate(w, mo.days);
        w.writeByte(if (mo.t_sep) 'T' else ' ') catch {};
    }
    writeClock(w, mo.secs);
    writeFrac(w, mo.frac, if (!mo.has_time) 3 else mo.frac_digits);
    if (mo.off) |off| {
        w.writeByte(' ') catch {};
        writeOffset(w, off);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The dateparts, by the names the parser normalizes them to (DATEADD's
/// `yy` arrives as `year`). Each function handles all of them in a
/// switch, so that a new one cannot be forgotten in one of them.
const Part = enum {
    year,
    quarter,
    month,
    dayofyear,
    day,
    week,
    weekday,
    hour,
    minute,
    second,
    millisecond,
    microsecond,
    nanosecond,
    tzoffset,
    iso_week,
};

/// The datepart argument: its text (for error messages) and the part, if
/// it is one.
fn partArg(ctx: *Context, m: *Mem) ?struct { []const u8, ?Part } {
    const name = text(ctx, m) orelse return null;
    return .{ name, std.meta.stringToEnum(Part, name) };
}

/// dateadd(part, n, d)
pub fn dateaddFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const name, const part_or = partArg(ctx, argv[0]) orelse return;
    var mo = momentOf(argv[2]) orelse return fail(ctx, "Conversion failed when converting date and/or time from character string.", .{});
    const n: i64 = @intFromFloat(std.math.clamp(@trunc(api.valueDouble(argv[1])), -1e15, 1e15));
    const unsupported = "The datepart {s} is not supported by date function dateadd.";
    const part = part_or orelse return fail(ctx, unsupported, .{name});
    var upgrade = false;
    if (part == .year or part == .quarter or part == .month) {
        const months = switch (part) {
            .year => n * 12,
            .quarter => n * 3,
            else => n,
        };
        const y, const mon, const d = mo.ymd();
        const total = y * 12 + (mon - 1) + months;
        const ny = @divFloor(total, 12);
        const nm: u32 = @intCast(@mod(total, 12) + 1);
        if (ny < 1 or ny > 9999) return fail(ctx, "Adding a value to a 'datetime' column caused an overflow.", .{});
        const nd = @min(d, daysInMonth(@intCast(ny), nm));
        mo.days = calendar.daysFromCivil(ny, nm, nd);
    } else {
        const unit: i128 = switch (part) {
            .day, .dayofyear, .weekday => 86400 * 10_000_000,
            .week => 7 * 86400 * 10_000_000,
            .hour => 3600 * 10_000_000,
            .minute => 60 * 10_000_000,
            .second => 10_000_000,
            .millisecond => 10_000,
            .microsecond => 10,
            .nanosecond => 0,
            .tzoffset, .iso_week => return fail(ctx, unsupported, .{name}),
            .year, .quarter, .month => unreachable,
        };
        if (unit == 0 and @mod(n, 100) != 0) {} // below 100 ns: nothing.
        const add: i128 = if (unit == 0) @divTrunc(n, 100) else n * unit;
        const r = Moment.fromTicks(mo.ticks() + add);
        const y, _, _ = r.ymd();
        if (y < 1 or y > 9999) return fail(ctx, "Adding a value to a 'datetime' column caused an overflow.", .{});
        upgrade = !mo.has_time and unit < 86400 * 10_000_000;
        mo.days = r.days;
        mo.secs = r.secs;
        mo.frac = r.frac;
        if (upgrade) mo.frac_digits = 3;
        if (unit < 10_000_000 and mo.frac_digits < 3 and mo.frac != 0) mo.frac_digits = if (unit < 10_000) 7 else 3;
    }
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    formatShape(&w, mo, upgrade);
    api.resultText(ctx, w.buffered(), .transient);
}

/// The Sunday-based week number since 1970 (1970-01-04 was a Sunday).
fn weekIndex(days: i64) i64 {
    return @divFloor(days - 3, 7);
}

/// datediff(part, a, b): the boundaries of `part` crossed from a to b.
pub fn datediffFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const name, const part_or = partArg(ctx, argv[0]) orelse return;
    const a = momentOf(argv[1]) orelse return fail(ctx, "Conversion failed when converting date and/or time from character string.", .{});
    const b = momentOf(argv[2]) orelse return fail(ctx, "Conversion failed when converting date and/or time from character string.", .{});
    const unsupported = "The datepart {s} is not supported by date function datediff.";
    const part = part_or orelse return fail(ctx, unsupported, .{name});
    const ya, const ma, _ = a.ymd();
    const yb, const mb, _ = b.ymd();
    const r: i128 = switch (part) {
        .year => yb - ya,
        .quarter => (yb * 4 + @divFloor(mb - 1, 3)) - (ya * 4 + @divFloor(ma - 1, 3)),
        .month => (yb * 12 + mb) - (ya * 12 + ma),
        .day, .dayofyear, .weekday => b.days - a.days,
        .week => weekIndex(b.days) - weekIndex(a.days),
        .hour => (@as(i128, b.days) * 24 + b.secs / 3600) - (@as(i128, a.days) * 24 + a.secs / 3600),
        .minute => (@as(i128, b.days) * 1440 + b.secs / 60) - (@as(i128, a.days) * 1440 + a.secs / 60),
        .second => (@as(i128, b.days) * 86400 + b.secs) - (@as(i128, a.days) * 86400 + a.secs),
        .millisecond => @divFloor(b.ticks(), 10_000) - @divFloor(a.ticks(), 10_000),
        .microsecond => @divFloor(b.ticks(), 10) - @divFloor(a.ticks(), 10),
        .nanosecond => (b.ticks() - a.ticks()) * 100,
        .tzoffset, .iso_week => return fail(ctx, unsupported, .{name}),
    };
    if (r > std.math.maxInt(i64) or r < std.math.minInt(i64)) return fail(ctx, "The datediff function resulted in an overflow.", .{});
    api.resultInt64(ctx, @intCast(r));
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// Day of the week, 0 for Sunday.
fn dow(days: i64) u32 {
    return @intCast(@mod(days + 4, 7));
}

fn datepartValue(part: Part, mo: Moment) i64 {
    const y, const m, const d = mo.ymd();
    const jan1 = calendar.daysFromCivil(y, 1, 1);
    const doy = mo.days - jan1 + 1;
    return switch (part) {
        .year => y,
        .quarter => @divFloor(m - 1, 3) + 1,
        .month => m,
        .dayofyear => doy,
        .day => d,
        .week => @divFloor(doy - 1 + dow(jan1), 7) + 1,
        .weekday => dow(mo.days) + 1,
        .hour => mo.secs / 3600,
        .minute => (mo.secs / 60) % 60,
        .second => mo.secs % 60,
        .millisecond => mo.frac / 10_000,
        .microsecond => mo.frac / 10,
        .nanosecond => @as(i64, mo.frac) * 100,
        .tzoffset => mo.off orelse 0,
        .iso_week => blk: {
            // The week (Monday-based) that holds the Thursday of this one.
            const wd: i64 = @mod(mo.days + 3, 7); // 0 = Monday
            const thursday = mo.days - wd + 3;
            const ty, _, _ = calendar.civilFromDays(thursday);
            break :blk @divFloor(thursday - calendar.daysFromCivil(ty, 1, 1), 7) + 1;
        },
    };
}

/// datepart(part, d)
pub fn datepartFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const name, const part = partArg(ctx, argv[0]) orelse return;
    const mo = momentOf(argv[1]) orelse return fail(ctx, "Conversion failed when converting date and/or time from character string.", .{});
    const p = part orelse return fail(ctx, "The datepart {s} is not supported by date function datepart.", .{name});
    api.resultInt64(ctx, datepartValue(p, mo));
}

/// datename(part, d): the month's and the weekday's names, else the
/// number as text.
pub fn datenameFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const name, const part = partArg(ctx, argv[0]) orelse return;
    const mo = momentOf(argv[1]) orelse return fail(ctx, "Conversion failed when converting date and/or time from character string.", .{});
    const p = part orelse return fail(ctx, "The datepart {s} is not supported by date function datename.", .{name});
    switch (p) {
        .month => {
            _, const m, _ = mo.ymd();
            return api.resultText(ctx, month_names[m - 1], .static);
        },
        .weekday => return api.resultText(ctx, day_names[dow(mo.days)], .static),
        else => {},
    }
    const v = datepartValue(p, mo);
    var buf: [24]u8 = undefined;
    api.resultText(ctx, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "", .transient);
}

/// eomonth(d [, months]): the last day of the month.
pub fn eomonthFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const mo = momentOf(argv[0]) orelse return fail(ctx, "Conversion failed when converting date and/or time from character string.", .{});
    const add: i64 = if (argv.len > 1) api.valueInt64(argv[1]) else 0;
    const y, const m, _ = mo.ymd();
    const total = y * 12 + (m - 1) + add;
    const ny = @divFloor(total, 12);
    const nm: u32 = @intCast(@mod(total, 12) + 1);
    if (ny < 1 or ny > 9999) return fail(ctx, "Adding a value to a 'date' column caused an overflow.", .{});
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeDate(&w, calendar.daysFromCivil(ny, nm, daysInMonth(@intCast(ny), nm)));
    api.resultText(ctx, w.buffered(), .transient);
}

/// datefromparts(y, m, d)
pub fn datefrompartsFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const y = api.valueInt64(argv[0]);
    const m = api.valueInt64(argv[1]);
    const d = api.valueInt64(argv[2]);
    if (y < 1 or y > 9999 or m < 1 or m > 12 or d < 1 or d > daysInMonth(@intCast(y), @intCast(m))) {
        return fail(ctx, "Cannot construct data type date, some of the arguments have values which are not valid.", .{});
    }
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeDate(&w, calendar.daysFromCivil(y, m, d));
    api.resultText(ctx, w.buffered(), .transient);
}

/// isdate(x): 1 if x reads as a date/time.
pub fn isdateFunc(ctx: *Context, argv: []*Mem) void {
    if (api.valueType(argv[0]) != vi.SQLITE_TEXT) return api.resultInt64(ctx, 0);
    const mo = parseMoment(api.valueText(argv[0]) orelse "") orelse return api.resultInt64(ctx, 0);
    const y, _, _ = mo.ymd();
    api.resultInt64(ctx, @intFromBool(y >= 1753 and mo.off == null));
}

/// isnumeric(x): 1 if x reads as a number.
pub fn isnumericFunc(ctx: *Context, argv: []*Mem) void {
    switch (api.valueType(argv[0])) {
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return api.resultInt64(ctx, 1),
        vi.SQLITE_TEXT => {
            var z = std.mem.trim(u8, api.valueText(argv[0]) orelse "", " ");
            if (z.len > 0 and (z[0] == '$' or z[0] == '+' or z[0] == '-')) z = z[1..];
            if (z.len == 0) return api.resultInt64(ctx, 0);
            api.resultInt64(ctx, @intFromBool(parseDecText(z, true) != null));
        },
        else => api.resultInt64(ctx, 0),
    }
}

// ============================================================ operators

const Num = union(enum) { int: i64, float: f64 };

fn numOf(ctx: *Context, m: *Mem) ?Num {
    switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => return .{ .int = api.valueInt64(m) },
        vi.SQLITE_FLOAT => return .{ .float = api.valueDouble(m) },
        else => {
            const z = text(ctx, m) orelse return null;
            if (parseIntText(z)) |v| if (v >= std.math.minInt(i64) and v <= std.math.maxInt(i64)) return .{ .int = @intCast(v) };
            if (parseDecText(z, true)) |f| return .{ .float = f };
            fail(ctx, "Conversion failed when converting the varchar value '{s}' to data type int.", .{clip(z)});
            return null;
        },
    }
}

/// xq_tsql_add(a, b): `+` of operands whose types the parser did not
/// know: strings (TEXT and TEXT) concatenate, binary strings too, else
/// the numbers add (a string converted as SQL Server converts it).
pub fn addFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const ta = api.valueType(argv[0]);
    const tb = api.valueType(argv[1]);
    if ((ta == vi.SQLITE_TEXT and tb == vi.SQLITE_TEXT) or (ta == vi.SQLITE_BLOB and tb == vi.SQLITE_BLOB)) {
        const gpa = dfunc.gpa(ctx);
        const a: []const u8 = if (ta == vi.SQLITE_BLOB) api.valueBlob(argv[0]) orelse "" else text(ctx, argv[0]) orelse return;
        const b: []const u8 = if (tb == vi.SQLITE_BLOB) api.valueBlob(argv[1]) orelse "" else text(ctx, argv[1]) orelse return;
        const out = std.mem.concat(gpa, u8, &.{ a, b }) catch return api.resultErrorNomem(ctx);
        if (ta == vi.SQLITE_BLOB) return api.resultBlob(ctx, out, .dynamic);
        return api.resultText(ctx, out, .dynamic);
    }
    const x = numOf(ctx, argv[0]) orelse return;
    const y = numOf(ctx, argv[1]) orelse return;
    if (x == .int and y == .int) {
        const r, const o = @addWithOverflow(x.int, y.int);
        if (o == 0) return api.resultInt64(ctx, r);
        return fail(ctx, "Arithmetic overflow error converting expression to data type bigint.", .{});
    }
    const fx: f64 = switch (x) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
    };
    const fy: f64 = switch (y) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
    };
    api.resultDouble(ctx, fx + fy);
}

/// The next code point of `z` at `i.*` (a byte of invalid UTF-8 alone),
/// folded to lower case if ASCII.
fn nextFolded(z: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(z[i.*]) catch 1;
    if (len > 1 and i.* + len <= z.len) {
        if (std.unicode.utf8Decode(z[i.* .. i.* + len])) |c| {
            i.* += len;
            return c;
        } else |_| {}
    }
    const c = z[i.*];
    i.* += 1;
    return std.ascii.toLower(c);
}

/// LIKE with SQL Server's patterns: % _ [abc] [a-z] [^abc], case folded
/// (ASCII), `esc` the escape character (0 for none).
pub fn likeMatch(pat: []const u8, str: []const u8, esc: u21) bool {
    var p: usize = 0;
    var s: usize = 0;
    // Backtracking point of the last %.
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (true) {
        if (p < pat.len) {
            var pp = p;
            const c = nextFolded(pat, &pp);
            if (c == '%' and c != esc) {
                star_p = pp;
                star_s = s;
                p = pp;
                continue;
            }
            if (s < str.len) {
                var ss = s;
                const sc = nextFolded(str, &ss);
                var matched = false;
                var np = pp;
                if (esc != 0 and c == esc and pp < pat.len) {
                    var q = pp;
                    const lit = nextFolded(pat, &q);
                    matched = lit == sc;
                    np = q;
                } else if (c == '_') {
                    matched = true;
                } else if (c == '[') {
                    if (classMatch(pat, pp, sc)) |end| {
                        matched = end.ok;
                        np = end.next;
                    } else matched = c == sc;
                } else matched = c == sc;
                if (matched) {
                    p = np;
                    s = ss;
                    continue;
                }
            }
        } else if (s == str.len) return true;
        // Mismatch: let the last % take one more character.
        const sp = star_p orelse return false;
        if (star_s >= str.len) return false;
        _ = nextFolded(str, &star_s);
        p = sp;
        s = star_s;
    }
}

const ClassEnd = struct { ok: bool, next: usize };

/// A [...] class starting after `[` at `i`: whether `c` is in it, and the
/// offset after `]`; null if there is no `]`.
fn classMatch(pat: []const u8, i_in: usize, c: u21) ?ClassEnd {
    var i = i_in;
    var neg = false;
    if (i < pat.len and pat[i] == '^') {
        neg = true;
        i += 1;
    }
    var ok = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) return .{ .ok = ok != neg, .next = i + 1 };
        first = false;
        const lo = nextFolded(pat, &i);
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            i += 1;
            const hi = nextFolded(pat, &i);
            if (c >= lo and c <= hi) ok = true;
        } else if (c == lo) ok = true;
    }
    return null;
}

/// xq_tsql_like(x, pattern [, escape]).
pub fn likeFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const x = text(ctx, argv[0]) orelse return;
    const pat = text(ctx, argv[1]) orelse return;
    var esc: u21 = 0;
    if (argv.len > 2) {
        const e = text(ctx, argv[2]) orelse return;
        if (dfunc.charCount(e) != 1) return fail(ctx, "The invalid escape character \"{s}\" was specified in a LIKE predicate.", .{clip(e)});
        var i: usize = 0;
        esc = nextFolded(e, &i);
    }
    api.resultInt64(ctx, @intFromBool(likeMatch(pat, x, esc)));
}

/// xq_tsql_newid(): a random UUID, upper case.
pub fn newidFunc(ctx: *Context, _: []*Mem) void {
    var out = dfunc.uuidV4(ctx);
    for (&out) |*c| c.* = std.ascii.toUpper(c.*);
    api.resultText(ctx, &out, .transient);
}

/// Zeroed by aggregateContext().
const Avg = struct { sum_i: i128, sum_f: f64, n: i64, has_float: bool };

/// xq_tsql_avg(x): AVG of SQL Server: of integers, an integer (the
/// quotient truncated), else a float.
pub fn avgStep(ctx: *Context, argv: []*Mem) void {
    const buf = api.aggregateContext(ctx, @sizeOf(Avg)) orelse return;
    const a: *align(1) Avg = @ptrCast(buf.ptr);
    if (isNull(argv[0])) return;
    switch (api.valueType(argv[0])) {
        vi.SQLITE_INTEGER => {
            const v = api.valueInt64(argv[0]);
            a.sum_i += v;
            a.sum_f += @floatFromInt(v);
        },
        else => {
            a.has_float = true;
            a.sum_f += api.valueDouble(argv[0]);
        },
    }
    a.n += 1;
}

pub fn avgFinal(ctx: *Context) void {
    const buf = api.aggregateContext(ctx, 0) orelse return api.resultNull(ctx);
    if (buf.len < @sizeOf(Avg)) return api.resultNull(ctx);
    const a: *align(1) Avg = @ptrCast(buf.ptr);
    if (a.n == 0) return api.resultNull(ctx);
    if (!a.has_float) return api.resultInt64(ctx, @intCast(@divTrunc(a.sum_i, a.n)));
    api.resultDouble(ctx, a.sum_f / @as(f64, @floatFromInt(a.n)));
}

// ============================================================== strings

/// The byte offset in `hay` of the first case-folded occurrence of
/// `needle` from byte `from`.
fn indexFolded(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// charindex(sub, s [, start]): the position (in characters, from 1) of
/// sub in s, case-insensitively (the default collation), 0 if none.
pub fn charindexFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv[0..2])) return api.resultNull(ctx);
    const sub = text(ctx, argv[0]) orelse return;
    const z = text(ctx, argv[1]) orelse return;
    var start: i64 = if (argv.len > 2 and !isNull(argv[2])) api.valueInt64(argv[2]) else 1;
    if (start < 1) start = 1;
    const from = dfunc.charOffset(z, @intCast(start - 1));
    const at = indexFolded(z, sub, from) orelse return api.resultInt64(ctx, 0);
    api.resultInt64(ctx, @intCast(dfunc.charCount(z[0..at]) + 1));
}

/// replace(s, from, to): case-insensitively (the default collation).
pub fn replaceFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const z = text(ctx, argv[0]) orelse return;
    const from = text(ctx, argv[1]) orelse return;
    const to = text(ctx, argv[2]) orelse return;
    if (from.len == 0) return api.resultText(ctx, z, .transient);
    const gpa = dfunc.gpa(ctx);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (indexFolded(z, from, i)) |at| {
        out.appendSlice(gpa, z[i..at]) catch return api.resultErrorNomem(ctx);
        out.appendSlice(gpa, to) catch return api.resultErrorNomem(ctx);
        i = at + from.len;
    }
    out.appendSlice(gpa, z[i..]) catch return api.resultErrorNomem(ctx);
    dfunc.resultOwned(ctx, &out);
}

/// stuff(s, start, len, new): NULL if start is outside s.
pub fn stuffFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv[0..3])) return api.resultNull(ctx);
    const z = text(ctx, argv[0]) orelse return;
    const start = api.valueInt64(argv[1]);
    const len = api.valueInt64(argv[2]);
    const n: i64 = @intCast(dfunc.charCount(z));
    if (start < 1 or start > n or len < 0) return api.resultNull(ctx);
    const ins = if (isNull(argv[3])) "" else text(ctx, argv[3]) orelse return;
    const a = dfunc.charOffset(z, @intCast(start - 1));
    const b = dfunc.charOffset(z, @intCast(@min(start - 1 + len, n)));
    const out = std.mem.concat(dfunc.gpa(ctx), u8, &.{ z[0..a], ins, z[b..] }) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out, .dynamic);
}

/// power(x, y): an integer for integers (as SQL Server returns x's type).
pub fn powerFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (dfunc.isIntegral(argv[0]) and dfunc.isIntegral(argv[1])) {
        const b = api.valueInt64(argv[0]);
        const e = api.valueInt64(argv[1]);
        if (e >= 0) {
            var r: i64 = 1;
            var k: i64 = 0;
            while (k < e) : (k += 1) {
                const x, const o = @mulWithOverflow(r, b);
                if (o != 0) return fail(ctx, "Arithmetic overflow error converting expression to data type int.", .{});
                r = x;
            }
            return api.resultInt64(ctx, r);
        }
        return api.resultInt64(ctx, 0);
    }
    const r = std.math.pow(f64, api.valueDouble(argv[0]), api.valueDouble(argv[1]));
    if (std.math.isNan(r)) return fail(ctx, "An invalid floating point operation occurred.", .{});
    api.resultDouble(ctx, r);
}

// ======================================================= types (catalog)

/// typeinfo(declared type, field): what INFORMATION_SCHEMA.COLUMNS and
/// sys.columns show of a type: 'name', 'length', 'max_length',
/// 'precision', 'scale', 'datetime_precision'.
pub fn typeinfoFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const decl = text(ctx, argv[0]) orelse return;
    const field = text(ctx, argv[1]) orelse return;
    const t = types.parseText(decl) orelse {
        if (eq(field, "name")) {
            const paren = std.mem.indexOfScalar(u8, decl, '(') orelse decl.len;
            return api.resultText(ctx, decl[0..paren], .transient);
        }
        return api.resultNull(ctx);
    };
    if (eq(field, "name")) return api.resultText(ctx, @tagName(t.base), .static);
    const v: ?i64 = if (eq(field, "length")) switch (t.base) {
        .text => 2147483647,
        .ntext => 1073741823,
        .image => 2147483647,
        else => if (t.isChar() or t.isBinary()) (if ((t.len orelse 1) == types.max_len) -1 else t.len orelse 1) else null,
    } else if (eq(field, "max_length")) switch (t.base) {
        .bigint, .float, .datetime, .money, .datetime2 => 8,
        .int, .real, .smalldatetime, .smallmoney => 4,
        .smallint => 2,
        .tinyint, .bit => 1,
        .date => 3,
        .time => 5,
        .datetimeoffset => 10,
        .uniqueidentifier => 16,
        .decimal, .numeric => if (t.precision() <= 9) 5 else if (t.precision() <= 19) 9 else if (t.precision() <= 28) 13 else 17,
        .text, .ntext, .image => 16,
        .nchar, .nvarchar => if ((t.len orelse 1) == types.max_len) -1 else 2 * (t.len orelse 1),
        else => if ((t.len orelse 1) == types.max_len) -1 else t.len orelse 1,
    } else if (eq(field, "precision")) switch (t.base) {
        .bigint => 19,
        .int => 10,
        .smallint => 5,
        .tinyint => 3,
        .decimal, .numeric, .money, .smallmoney => t.precision(),
        .float => 53,
        .real => 24,
        else => null,
    } else if (eq(field, "scale")) switch (t.base) {
        .bigint, .int, .smallint, .tinyint => 0,
        .decimal, .numeric, .money, .smallmoney => t.scaleOf(),
        else => null,
    } else if (eq(field, "datetime_precision")) (if (t.isTemporal()) t.fracDigits() else null) else null;
    const x = v orelse return api.resultNull(ctx);
    api.resultInt64(ctx, x);
}

// ============================================================== session

fn state(ctx: *Context) *@import("state.zig").State {
    return &api.contextDbHandle(ctx).xq.mssql;
}

/// xq_tsql_getvar(name)
pub fn getvarFunc(ctx: *Context, argv: []*Mem) void {
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const v = state(ctx).get(name) orelse return api.resultNull(ctx);
    const m = v.value orelse return api.resultNull(ctx);
    api.resultValue(ctx, m);
}

/// xq_tsql_setvar(name, value)
pub fn setvarFunc(ctx: *Context, argv: []*Mem) void {
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    state(ctx).assign(name, argv[1]) catch |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Undeclared => return fail(ctx, "Must declare the scalar variable \"@{s}\".", .{name}),
    };
    api.resultNull(ctx);
}

/// xq_tsql_declare(name, type, value)
pub fn declareFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const ty = api.valueText(argv[1]) orelse return api.resultNull(ctx);
    const st = &db.xq.mssql;
    st.declare(db.gpa, name, ty) catch return api.resultErrorNomem(ctx);
    st.assign(name, argv[2]) catch return api.resultErrorNomem(ctx);
    api.resultNull(ctx);
}

/// xq_tsql_identity_insert('schema.table', on)
pub fn identityInsertFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const key = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const on = api.valueInt64(argv[1]) != 0;
    const st = &db.xq.mssql;
    if (on) {
        if (st.identity_insert) |cur| if (!std.mem.eql(u8, cur, key)) {
            return fail(ctx, "IDENTITY_INSERT is already ON for table '{s}'. Cannot perform SET operation for table '{s}'.", .{ cur, key });
        };
        @TypeOf(st.*).setText(db.gpa, &st.identity_insert, key) catch return api.resultErrorNomem(ctx);
    } else if (st.identity_insert) |cur| if (std.mem.eql(u8, cur, key)) {
        @TypeOf(st.*).setText(db.gpa, &st.identity_insert, null) catch {};
    };
    api.resultNull(ctx);
}

/// nextval(seq) of the IR's identity columns: the next value, which is
/// the last identity value (SCOPE_IDENTITY(), @@IDENTITY).
pub fn nextvalFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const v = sequence.nextval(db, catalog.main_schema, name) catch |err| {
        if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
        return api.resultError(ctx, @import("../../sql/main.zig").errmsg(db));
    };
    db.xq.mssql.last_identity = v;
    api.resultInt64(ctx, v);
}

/// xq_tsql_identity_seen(seq, v): an explicit value for an identity
/// column (IDENTITY_INSERT ON): the identity moves on past it.
pub fn identitySeenFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[1])) return api.resultNull(ctx);
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const v = api.valueInt64(argv[1]);
    if (sequence.exists(db, catalog.main_schema)) {
        const past = blk: {
            var q = catalog.Query.init(db, "SELECT last_value, is_called, increment FROM main.xq_sequence WHERE name=?1") catch return api.resultError(ctx, "xq_sequence");
            defer q.deinit();
            q.bindText(1, name) catch return api.resultErrorNomem(ctx);
            if (!(q.step() catch false)) break :blk false;
            const last = api.columnInt64(q.v, 0);
            const called = api.columnInt64(q.v, 1) != 0;
            const inc = api.columnInt64(q.v, 2);
            break :blk if (inc > 0) (if (called) v > last else v >= last) else (if (called) v < last else v <= last);
        };
        if (past) _ = sequence.setval(db, catalog.main_schema, name, v, true) catch |err| {
            if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
            return api.resultError(ctx, @import("../../sql/main.zig").errmsg(db));
        };
    }
    db.xq.mssql.last_identity = v;
    api.resultValue(ctx, argv[1]);
}

/// scope_identity(), @@IDENTITY: the identity value last inserted.
pub fn scopeIdentityFunc(ctx: *Context, _: []*Mem) void {
    const v = state(ctx).last_identity orelse return api.resultNull(ctx);
    api.resultInt64(ctx, v);
}

/// ident_current('[schema.]table'): the identity value of the table last
/// handed out (its seed if none).
pub fn identCurrentFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const arg: []const u8 = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    // [db.][schema.]table: a table of a schema of CREATE SCHEMA is
    // "schema.table" (catalog/schema.zig).
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, arg, '.');
    while (it.next()) |part| {
        if (n == parts.len) return api.resultNull(ctx);
        parts[n] = std.mem.trim(u8, part, "[]\"");
        n += 1;
    }
    var buf: [256]u8 = undefined;
    var name: []const u8 = parts[n - 1];
    if (n >= 2 and parts[n - 2].len > 0 and !std.ascii.eqlIgnoreCase(parts[n - 2], "dbo") and
        !(n == 2 and (std.ascii.eqlIgnoreCase(parts[0], "tempdb") or std.ascii.eqlIgnoreCase(parts[0], "main"))))
    {
        name = std.fmt.bufPrint(&buf, "{s}.{s}", .{ parts[n - 2], name }) catch return api.resultNull(ctx);
    }
    const schema: []const u8 = if (name.len > 0 and name[0] == '#') "temp" else "main";
    if (!catalog.exists(db, schema) or !sequence.exists(db, catalog.main_schema)) return api.resultNull(ctx);
    var q = catalog.Query.initFmt(db, "SELECT s.last_value FROM %Q.xq_catalog c JOIN main.xq_sequence s ON s.name = c.value WHERE c.tbl = ?1 COLLATE NOCASE AND c.key = 'identity'", &.{.{ .str = schema }}) catch return api.resultNull(ctx);
    defer q.deinit();
    q.bindText(1, name) catch return api.resultErrorNomem(ctx);
    if (!(q.step() catch false)) return api.resultNull(ctx);
    api.resultInt64(ctx, api.columnInt64(q.v, 0));
}

/// xq_tsql_trancount(): @@TRANCOUNT.
pub fn trancountFunc(ctx: *Context, _: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (db.auto_commit) return api.resultInt64(ctx, 0);
    api.resultInt64(ctx, 1 + @as(i64, db.xq.mssql.tran_nest));
}

/// xq_tsql_tran(op, name): 0 BEGIN of a transaction (named), 1 a nested
/// BEGIN, 2 a nested COMMIT, 3 the end of the transaction.
pub fn tranFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const st = &db.xq.mssql;
    const State = @TypeOf(st.*);
    switch (api.valueInt64(argv[0])) {
        0 => {
            st.tran_nest = 0;
            var lower: [128]u8 = undefined;
            const name: ?[]const u8 = if (api.valueText(argv[1])) |z| std.ascii.lowerString(&lower, z[0..@min(z.len, lower.len)]) else null;
            State.setText(db.gpa, &st.tran_name, name) catch return api.resultErrorNomem(ctx);
        },
        1 => st.tran_nest += 1,
        2 => st.tran_nest -|= 1,
        else => {
            st.tran_nest = 0;
            State.setText(db.gpa, &st.tran_name, null) catch {};
        },
    }
    api.resultNull(ctx);
}

/// xq_tsql_merge(op, key) of MERGE (dml.zig): 0 forget the marks, 1 mark
/// a source row, 2 whether one is marked, 3 and 4 the same of target rows.
pub fn mergeFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const st = &db.xq.mssql;
    const op = api.valueInt64(argv[0]);
    const key = api.valueInt64(argv[1]);
    switch (op) {
        0 => {
            st.merge_src.clearRetainingCapacity();
            st.merge_tgt.clearRetainingCapacity();
            api.resultNull(ctx);
        },
        1, 3 => {
            const set = if (op == 1) &st.merge_src else &st.merge_tgt;
            set.put(db.gpa, key, {}) catch return api.resultErrorNomem(ctx);
            api.resultInt64(ctx, 1);
        },
        else => {
            const set = if (op == 2) &st.merge_src else &st.merge_tgt;
            api.resultInt64(ctx, @intFromBool(set.contains(key)));
        },
    }
}

test "runtime: dates" {
    const m = parseMoment("2024-02-29 13:45:01.1234567").?;
    try std.testing.expect(m.has_date and m.has_time and m.frac == 1234567 and m.frac_digits == 7);
    try std.testing.expect(parseMoment("2023-02-29") == null);
    const us = parseMoment("12/31/2024 1:02 PM").?;
    try std.testing.expectEqual(@as(u32, 13 * 3600 + 120), us.secs);
    try std.testing.expect(parseMoment("20240102").?.has_date);
    const t = parseMoment("10:00").?;
    try std.testing.expect(!t.has_date and t.has_time);
    const z = parseMoment("2024-01-01T00:00:00+05:30").?;
    try std.testing.expectEqual(@as(?i16, 330), z.off);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expect(formatAs(&w, parseMoment("2024-01-01 00:00:00.002").?, .{ .base = .datetime }));
    try std.testing.expectEqualStrings("2024-01-01 00:00:00.003", w.buffered());
}

test "runtime: LIKE patterns" {
    try std.testing.expect(likeMatch("a%", "ABC", 0));
    try std.testing.expect(likeMatch("[a-c]_d", "bxd", 0));
    try std.testing.expect(!likeMatch("[^a-c]%", "abc", 0));
    try std.testing.expect(likeMatch("%[%]%", "50%", 0));
    try std.testing.expect(likeMatch("a!%b", "a%b", '!'));
    try std.testing.expect(!likeMatch("a!%b", "axb", '!'));
    try std.testing.expect(likeMatch("%", "", 0));
    try std.testing.expect(!likeMatch("_", "", 0));
}
