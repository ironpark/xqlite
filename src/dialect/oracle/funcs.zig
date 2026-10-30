//! The functions of the Oracle dialect.
//!
//! The dialect's table (Hooks.functions; in the schema as
//! xq_oracle_<name>) has Oracle's string, number and date functions with
//! Oracle's semantics, in particular the empty-string rule: a string
//! argument that is '' is NULL, and a string result that would be '' is
//! NULL. Numbers become text as Oracle writes them (0.5 is '.5', 2.0 is
//! '2'), and a number result that is integral is an integer.
//!
//!  - lengthc (LENGTH), lengthb, substr, instr, initcap,
//!    lpad, rpad, ltrim, rtrim, trim, replace, translate;
//!  - greatest, least (NULL if an argument is), mod, ceil, floor, power,
//!    sqrt, sign, exp, ln, log, round and trunc (of numbers and dates);
//!  - to_char, to_number, to_date, to_timestamp, add_months,
//!    months_between, last_day, next_day, extract;
//!  - the sequence functions (nextval(), currval() of s.NEXTVAL).
//!
//! LENGTH is lengthc so that SQLite's length() stays unshadowed: the
//! CHECKs of VARCHAR2(n) columns call it, and sqlite3 must run them.
//!
//! The engine functions (Hooks.engine_functions, visible in every
//! dialect):
//!
//!  - xq_ora_coerce(value, type, table, column, flags): the value stored
//!    into a column of declared type `type` (types.format()) by INSERT,
//!    UPDATE and MERGE: '' is NULL, text becomes a number or a date, a
//!    number text, the length and precision checked with Oracle's errors
//!    (flags: 1 NOT NULL);
//!  - xq_ora_cast(value, type): CAST(value AS type);
//!  - xq_ora_autocommit(): 1 when no transaction is open (the implicit
//!    transaction of frontend.zig);
//!  - xq_ora_data_type(), xq_ora_data_length(), xq_ora_data_precision(),
//!    xq_ora_data_scale() of (catalog type, SQLite type): the columns of
//!    USER_TAB_COLUMNS.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const types = @import("types.zig");
const dt = @import("datetime.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const DateTime = dt.DateTime;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("lengthc", 1, det, lengthcFunc),
    dfunc.scalar("lengthb", 1, det, lengthbFunc),
    dfunc.scalar("substr", 2, det, substrFunc),
    dfunc.scalar("substr", 3, det, substrFunc),
    dfunc.scalar("instr", 2, det, instrFunc),
    dfunc.scalar("instr", 3, det, instrFunc),
    dfunc.scalar("instr", 4, det, instrFunc),
    dfunc.scalar("initcap", 1, det, initcapFunc),
    dfunc.scalar("lpad", 2, det, lpadFunc),
    dfunc.scalar("lpad", 3, det, lpadFunc),
    dfunc.scalar("rpad", 2, det, rpadFunc),
    dfunc.scalar("rpad", 3, det, rpadFunc),
    dfunc.scalar("ltrim", 1, det, ltrimFunc),
    dfunc.scalar("ltrim", 2, det, ltrimFunc),
    dfunc.scalar("rtrim", 1, det, rtrimFunc),
    dfunc.scalar("rtrim", 2, det, rtrimFunc),
    dfunc.scalar("trim", 1, det, trimFunc),
    dfunc.scalar("trim", 2, det, trimFunc),
    dfunc.scalar("replace", 2, det, replaceFunc),
    dfunc.scalar("replace", 3, det, replaceFunc),
    dfunc.scalar("translate", 3, det, translateFunc),
    dfunc.scalar("greatest", -1, det, greatestFunc),
    dfunc.scalar("least", -1, det, leastFunc),
    dfunc.scalar("mod", 2, det, modFunc),
    dfunc.scalar("ceil", 1, det, ceilFunc),
    dfunc.scalar("floor", 1, det, floorFunc),
    dfunc.scalar("power", 2, det, powerFunc),
    dfunc.scalar("sqrt", 1, det, sqrtFunc),
    dfunc.scalar("sign", 1, det, signFunc),
    dfunc.scalar("exp", 1, det, expFunc),
    dfunc.scalar("ln", 1, det, lnFunc),
    dfunc.scalar("log", 2, det, logFunc),
    dfunc.scalar("round", 1, det, roundFunc),
    dfunc.scalar("round", 2, det, roundFunc),
    dfunc.scalar("trunc", 1, det, truncFunc),
    dfunc.scalar("trunc", 2, det, truncFunc),
    dfunc.scalar("to_char", 1, det, toCharFunc),
    dfunc.scalar("to_char", 2, det, toCharFunc),
    dfunc.scalar("to_number", 1, det, toNumberFunc),
    dfunc.scalar("to_number", 2, det, toNumberFunc),
    dfunc.scalar("to_date", 1, det, toDateFunc),
    dfunc.scalar("to_date", 2, det, toDateFunc),
    dfunc.scalar("to_timestamp", 1, det, toTimestampFunc),
    dfunc.scalar("to_timestamp", 2, det, toTimestampFunc),
    dfunc.scalar("add_months", 2, det, addMonthsFunc),
    dfunc.scalar("months_between", 2, det, monthsBetweenFunc),
    dfunc.scalar("last_day", 1, det, lastDayFunc),
    dfunc.scalar("next_day", 2, det, nextDayFunc),
    dfunc.scalar("extract", 2, det, extractFunc),
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_ora_coerce", 5, det, coerceFunc),
    dfunc.scalar("xq_ora_cast", 2, det, castFunc),
    dfunc.scalar("xq_ora_autocommit", 0, .{}, autocommitFunc),
    dfunc.scalar("xq_ora_data_type", 2, det, dataTypeFunc),
    dfunc.scalar("xq_ora_data_length", 2, det, dataLengthFunc),
    dfunc.scalar("xq_ora_data_precision", 2, det, dataPrecisionFunc),
    dfunc.scalar("xq_ora_data_scale", 2, det, dataScaleFunc),
};

const isNull = dfunc.isNull;
const gpa = dfunc.gpa;

// ============================================================ values

/// The text Oracle writes for a number: no trailing ".0", no leading zero
/// before the point (0.5 is ".5"), 15 significant digits for reals.
pub fn numberText(buf: []u8, m: *Mem) []const u8 {
    if (api.valueType(m) == vi.SQLITE_INTEGER) return std.fmt.bufPrint(buf, "{d}", .{api.valueInt64(m)}) catch "";
    return realText(buf, api.valueDouble(m));
}

pub fn realText(buf: []u8, x: f64) []const u8 {
    if (std.math.isNan(x)) return "Nan";
    if (std.math.isInf(x)) return if (x > 0) "Inf" else "-Inf";
    if (x == @trunc(x) and @abs(x) < 1e15) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(x))}) catch "";
    // 15 significant digits, as a double holds them, without trailing
    // zeros.
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{e:.14}", .{x}) catch return "";
    // d.dddddddddddddde[-]x
    const e_at = std.mem.indexOfScalar(u8, s, 'e').?;
    const exp = std.fmt.parseInt(i32, s[e_at + 1 ..], 10) catch 0;
    var mant: [20]u8 = undefined;
    var n: usize = 0;
    var neg = false;
    for (s[0..e_at]) |c| {
        if (c == '-') neg = true else if (c != '.') {
            mant[n] = c;
            n += 1;
        }
    }
    while (n > 1 and mant[n - 1] == '0') n -= 1;
    var w: std.Io.Writer = .fixed(buf);
    if (neg) w.writeByte('-') catch {};
    if (exp < -10 or exp >= 20) {
        // 1.5E+25
        w.writeByte(mant[0]) catch {};
        if (n > 1) {
            w.writeByte('.') catch {};
            w.writeAll(mant[1..n]) catch {};
        }
        w.print("E{s}{d:0>2}", .{ if (exp < 0) "-" else "+", @abs(exp) }) catch {};
        return w.buffered();
    }
    if (exp < 0) {
        w.writeByte('.') catch {};
        var k: i32 = -1;
        while (k > exp) : (k -= 1) w.writeByte('0') catch {};
        w.writeAll(mant[0..n]) catch {};
        return w.buffered();
    }
    const int_digits: usize = @intCast(exp + 1);
    for (0..int_digits) |k| w.writeByte(if (k < n) mant[k] else '0') catch {};
    if (n > int_digits) {
        w.writeByte('.') catch {};
        w.writeAll(mant[int_digits..n]) catch {};
    }
    return w.buffered();
}

/// A string argument as Oracle sees it: null for NULL and for '' (the
/// empty string is NULL), numbers as Oracle writes them, a blob as hex.
fn str(ctx: *Context, m: *Mem, buf: []u8) ?[]const u8 {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return null,
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return numberText(buf, m),
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse return null;
            if (b.len == 0) return null;
            // RAW as text is hexadecimal (RAWTOHEX), when it fits.
            if (b.len * 2 <= buf.len) {
                const hex = "0123456789ABCDEF";
                for (b, 0..) |c, i| {
                    buf[2 * i] = hex[c >> 4];
                    buf[2 * i + 1] = hex[c & 15];
                }
                return buf[0 .. b.len * 2];
            }
            return api.valueText(m);
        },
        else => {
            const z = api.valueText(m) orelse {
                api.resultErrorNomem(ctx);
                return null;
            };
            if (z.len == 0) return null;
            return z;
        },
    }
}

/// Make `s` the text result, '' as NULL.
fn resultStr(ctx: *Context, s: []const u8) void {
    if (s.len == 0) return api.resultNull(ctx);
    api.resultText(ctx, s, .transient);
}

fn resultOwnedStr(ctx: *Context, out: *std.ArrayList(u8)) void {
    if (out.items.len == 0) return api.resultNull(ctx);
    dfunc.resultOwned(ctx, out);
}

/// A number result: an integer when it is integral (as Oracle's NUMBER
/// prints), else a real.
pub fn resultNumber(ctx: *Context, x: f64) void {
    if (std.math.isNan(x)) return api.resultError(ctx, "ORA-01426: numeric overflow");
    if (x == @trunc(x) and @abs(x) < 9.007199254740992e15) return api.resultInt64(ctx, @intFromFloat(x));
    api.resultDouble(ctx, x);
}

pub const Num = union(enum) { int: i64, real: f64 };

/// A number argument: integers and reals, text that spells a number
/// (Oracle converts it), NULL for NULL and ''. Fails with ORA-01722.
fn numArg(ctx: *Context, m: *Mem) error{Invalid}!?Num {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return null,
        vi.SQLITE_INTEGER => return .{ .int = api.valueInt64(m) },
        vi.SQLITE_FLOAT => return .{ .real = api.valueDouble(m) },
        else => {
            const z = api.valueText(m) orelse return null;
            return parseNum(z) catch {
                api.resultError(ctx, "ORA-01722: invalid number");
                return error.Invalid;
            };
        },
    }
}

/// The number text `z` spells (spaces around it allowed), null for ''.
pub fn parseNum(z_arg: []const u8) error{Invalid}!?Num {
    const z = std.mem.trim(u8, z_arg, " \t\n\r");
    if (z.len == 0) return null;
    if (std.fmt.parseInt(i64, z, 10)) |v| return .{ .int = v } else |_| {}
    for (z) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E')) return error.Invalid;
    const x = std.fmt.parseFloat(f64, z) catch return error.Invalid;
    return .{ .real = x };
}

fn toF(n: Num) f64 {
    return switch (n) {
        .int => |v| @floatFromInt(v),
        .real => |v| v,
    };
}

fn numArgs(ctx: *Context, argv: []*Mem, out: []f64) error{ Invalid, Null }!void {
    for (argv, 0..) |m, i| {
        const n = (try numArg(ctx, m)) orelse return error.Null;
        out[i] = toF(n);
    }
}

/// A whole-number argument (Oracle truncates fractions).
fn intArg(ctx: *Context, m: *Mem) error{Invalid}!?i64 {
    const n = (try numArg(ctx, m)) orelse return null;
    return switch (n) {
        .int => |v| v,
        .real => |v| if (std.math.isFinite(v)) @intFromFloat(std.math.clamp(@trunc(v), -9.2e18, 9.2e18)) else 0,
    };
}

/// The statement's time (SYSDATE's), as a DateTime.
fn now(ctx: *Context) DateTime {
    const ms = api.stmtCurrentTime(ctx);
    // Julian day * 86400000 -> seconds since 1970.
    const secs = @divFloor(ms - 210866760000000, 1000);
    return DateTime.fromEpochSeconds(@floatFromInt(secs));
}

/// A date argument: text in the dialect's format (or DD-MON-RR); null for
/// NULL, error (ORA-01861) if it is not a date.
fn dateArg(ctx: *Context, m: *Mem) error{Invalid}!?DateTime {
    var buf: [64]u8 = undefined;
    const s = str(ctx, m, &buf) orelse return null;
    return dt.parseDefault(s, now(ctx)) orelse {
        api.resultError(ctx, "ORA-01861: literal does not match format string");
        return error.Invalid;
    };
}

fn resultDate(ctx: *Context, d: DateTime) void {
    var buf: [48]u8 = undefined;
    api.resultText(ctx, dt.writeDate(&buf, d), .transient);
}

fn resultTimestamp(ctx: *Context, d: DateTime, digits: u32) void {
    var buf: [48]u8 = undefined;
    api.resultText(ctx, dt.writeTimestamp(&buf, d, digits), .transient);
}

// =========================================================== strings

const nextChar = dfunc.nextChar;
const charCount = dfunc.charCount;
const charOffset = dfunc.charOffset;

fn lengthcFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [64]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, @intCast(charCount(s)));
}

fn lengthbFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [64]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, @intCast(s.len));
}

/// SUBSTR(s, pos [, len]): characters; a position of 0 is 1, a negative
/// one counts from the end; NULL past the end or for a length below 1.
fn substrFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [64]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    const pos = (intArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    var len: ?i64 = null;
    if (argv.len == 3) {
        len = (intArg(ctx, argv[2]) catch return) orelse return api.resultNull(ctx);
        if (len.? < 1) return api.resultNull(ctx);
    }
    const n: i64 = @intCast(charCount(s));
    var start: i64 = if (pos == 0) 1 else pos;
    if (start < 0) start = n + start + 1;
    if (start < 1 or start > n) return api.resultNull(ctx);
    const from = charOffset(s, @intCast(start - 1));
    const rest = s[from..];
    const take = if (len) |l| charOffset(rest, @intCast(l)) else rest.len;
    resultStr(ctx, rest[0..take]);
}

/// INSTR(s, sub [, pos [, occurrence]]): the character position of the
/// occurrence-th match from pos (backwards from the end if negative), 0
/// if none.
fn instrFunc(ctx: *Context, argv: []*Mem) void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const s = str(ctx, argv[0], &b1) orelse return api.resultNull(ctx);
    const sub = str(ctx, argv[1], &b2) orelse return api.resultNull(ctx);
    var pos: i64 = 1;
    var occ: i64 = 1;
    if (argv.len >= 3) pos = (intArg(ctx, argv[2]) catch return) orelse return api.resultNull(ctx);
    if (argv.len == 4) occ = (intArg(ctx, argv[3]) catch return) orelse return api.resultNull(ctx);
    if (occ <= 0) return api.resultError(ctx, "ORA-01428: argument is out of range");
    if (pos == 0) return api.resultInt64(ctx, 0);
    // Character start offsets.
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa(ctx));
    var i: usize = 0;
    while (i < s.len) : (i = nextChar(s, i)) starts.append(gpa(ctx), i) catch return api.resultErrorNomem(ctx);
    const n: i64 = @intCast(starts.items.len);
    var found: i64 = 0;
    if (pos > 0) {
        var k: i64 = pos - 1;
        while (k < n) : (k += 1) {
            if (std.mem.startsWith(u8, s[starts.items[@intCast(k)]..], sub)) {
                found += 1;
                if (found == occ) return api.resultInt64(ctx, k + 1);
            }
        }
    } else {
        var k: i64 = n + pos;
        while (k >= 0) : (k -= 1) {
            if (std.mem.startsWith(u8, s[starts.items[@intCast(k)]..], sub)) {
                found += 1;
                if (found == occ) return api.resultInt64(ctx, k + 1);
            }
        }
    }
    api.resultInt64(ctx, 0);
}

/// INITCAP: the first letter of each word upper case, the others lower;
/// words are runs of letters and digits.
fn initcapFunc(ctx: *Context, argv: []*Mem) void {
    var buf: [64]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    const out = gpa(ctx).alloc(u8, s.len) catch return api.resultErrorNomem(ctx);
    var in_word = false;
    for (s, out) |c, *o| {
        const alnum = std.ascii.isAlphanumeric(c) or c >= 0x80;
        o.* = if (!alnum) c else if (in_word) std.ascii.toLower(c) else std.ascii.toUpper(c);
        in_word = alnum;
    }
    api.resultText(ctx, out, .dynamic);
}

/// LPAD/RPAD(s, n [, pad]): s cut or padded to n characters; NULL for
/// n < 1 or an empty pad.
fn pad(ctx: *Context, argv: []*Mem, left: bool) void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const s = str(ctx, argv[0], &b1) orelse return api.resultNull(ctx);
    const n_arg = (intArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    const fill = if (argv.len == 3) (str(ctx, argv[2], &b2) orelse return api.resultNull(ctx)) else " ";
    if (n_arg < 1) return api.resultNull(ctx);
    const n: usize = @intCast(@min(n_arg, 1_000_000));
    const have = charCount(s);
    if (have >= n) return resultStr(ctx, s[0..charOffset(s, n)]);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa(ctx));
    if (!left) out.appendSlice(gpa(ctx), s) catch return api.resultErrorNomem(ctx);
    var need = n - have;
    var fi: usize = 0;
    while (need > 0) : (need -= 1) {
        if (fi >= fill.len) fi = 0;
        const start = fi;
        fi = nextChar(fill, fi);
        out.appendSlice(gpa(ctx), fill[start..fi]) catch return api.resultErrorNomem(ctx);
    }
    if (left) out.appendSlice(gpa(ctx), s) catch return api.resultErrorNomem(ctx);
    resultOwnedStr(ctx, &out);
}

fn lpadFunc(ctx: *Context, argv: []*Mem) void {
    pad(ctx, argv, true);
}

fn rpadFunc(ctx: *Context, argv: []*Mem) void {
    pad(ctx, argv, false);
}

fn inSet(set: []const u8, s: []const u8, i: usize) ?usize {
    const end = nextChar(s, i);
    const ch = s[i..end];
    var k: usize = 0;
    while (k < set.len) {
        const e = nextChar(set, k);
        if (std.mem.eql(u8, set[k..e], ch)) return end;
        k = e;
    }
    return null;
}

/// The characters of `s` without those of `set` at the start (`left`)
/// and/or end.
fn trimSet(s: []const u8, set: []const u8, left: bool, right: bool) []const u8 {
    var a: usize = 0;
    if (left) {
        while (a < s.len) {
            a = inSet(set, s, a) orelse break;
        }
    }
    var b = s.len;
    if (right) {
        while (b > a) {
            // The start of the last character before b.
            var k = b - 1;
            while (k > a and s[k] & 0xc0 == 0x80) k -= 1;
            if (inSet(set, s, k) == null) break;
            b = k;
        }
    }
    return s[a..b];
}

fn trimCommon(ctx: *Context, argv: []*Mem, left: bool, right: bool) void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const s = str(ctx, argv[0], &b1) orelse return api.resultNull(ctx);
    const set = if (argv.len == 2) (str(ctx, argv[1], &b2) orelse return api.resultNull(ctx)) else " ";
    resultStr(ctx, trimSet(s, set, left, right));
}

fn ltrimFunc(ctx: *Context, argv: []*Mem) void {
    trimCommon(ctx, argv, true, false);
}

fn rtrimFunc(ctx: *Context, argv: []*Mem) void {
    trimCommon(ctx, argv, false, true);
}

/// trim(s [, c]): TRIM([BOTH] [c FROM] s), c one character.
fn trimFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 2) {
        var b: [64]u8 = undefined;
        const c = str(ctx, argv[1], &b) orelse return api.resultNull(ctx);
        if (charCount(c) != 1) return api.resultError(ctx, "ORA-30001: trim set should have only one character");
    }
    trimCommon(ctx, argv, true, true);
}

/// REPLACE(s, search [, repl]): every search replaced (removed without a
/// repl); s itself for a NULL search.
fn replaceFunc(ctx: *Context, argv: []*Mem) void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    const s = str(ctx, argv[0], &b1) orelse return api.resultNull(ctx);
    const search = str(ctx, argv[1], &b2) orelse return resultStr(ctx, s);
    const repl: []const u8 = if (argv.len == 3) (str(ctx, argv[2], &b3) orelse "") else "";
    const out = std.mem.replaceOwned(u8, gpa(ctx), s, search, repl) catch return api.resultErrorNomem(ctx);
    if (out.len == 0) {
        gpa(ctx).free(out);
        return api.resultNull(ctx);
    }
    api.resultText(ctx, out, .dynamic);
}

/// TRANSLATE(s, from, to): each character of `from` becomes the one at
/// the same place in `to`, or is removed if `to` is shorter.
fn translateFunc(ctx: *Context, argv: []*Mem) void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    const s = str(ctx, argv[0], &b1) orelse return api.resultNull(ctx);
    const from = str(ctx, argv[1], &b2) orelse return api.resultNull(ctx);
    const to = str(ctx, argv[2], &b3) orelse return api.resultNull(ctx);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa(ctx));
    var i: usize = 0;
    while (i < s.len) {
        const e = nextChar(s, i);
        const ch = s[i..e];
        var k: usize = 0;
        var idx: usize = 0;
        var hit: ?usize = null;
        while (k < from.len) : (idx += 1) {
            const fe = nextChar(from, k);
            if (std.mem.eql(u8, from[k..fe], ch)) {
                hit = idx;
                break;
            }
            k = fe;
        }
        if (hit) |h| {
            const t0 = charOffset(to, h);
            if (t0 < to.len) out.appendSlice(gpa(ctx), to[t0..nextChar(to, t0)]) catch return api.resultErrorNomem(ctx);
        } else out.appendSlice(gpa(ctx), ch) catch return api.resultErrorNomem(ctx);
        i = e;
    }
    resultOwnedStr(ctx, &out);
}

// ===================================================== GREATEST, LEAST

/// GREATEST/LEAST: NULL if an argument is; compared as numbers when the
/// first argument is one, else as text.
fn extreme(ctx: *Context, argv: []*Mem, sign_: i32) void {
    for (argv) |m| if (isNull(m)) return api.resultNull(ctx);
    if (argv.len == 0) return api.resultNull(ctx);
    const t0 = api.valueType(argv[0]);
    if (t0 == vi.SQLITE_INTEGER or t0 == vi.SQLITE_FLOAT) {
        var best: f64 = 0;
        var best_m: ?*Mem = null;
        for (argv) |m| {
            const n = (numArg(ctx, m) catch return) orelse return api.resultNull(ctx);
            const x = toF(n);
            if (best_m == null or std.math.sign(x - best) == @as(f64, @floatFromInt(sign_))) {
                best = x;
                best_m = m;
            }
        }
        const bm = best_m.?;
        const bt = api.valueType(bm);
        if (bt == vi.SQLITE_INTEGER or bt == vi.SQLITE_FLOAT) return api.resultValue(ctx, bm);
        return resultNumber(ctx, best);
    }
    var keep: std.ArrayList(u8) = .empty;
    defer keep.deinit(gpa(ctx));
    var have = false;
    const want: std.math.Order = if (sign_ > 0) .gt else .lt;
    for (argv) |m| {
        var buf: [64]u8 = undefined;
        const s = str(ctx, m, &buf) orelse return api.resultNull(ctx);
        if (!have or std.mem.order(u8, s, keep.items) == want) {
            keep.clearRetainingCapacity();
            keep.appendSlice(gpa(ctx), s) catch return api.resultErrorNomem(ctx);
            have = true;
        }
    }
    resultStr(ctx, keep.items);
}

fn greatestFunc(ctx: *Context, argv: []*Mem) void {
    extreme(ctx, argv, 1);
}

fn leastFunc(ctx: *Context, argv: []*Mem) void {
    extreme(ctx, argv, -1);
}

// ============================================================= numbers

/// MOD(m, n): m - n * TRUNC(m / n); m for n = 0.
fn modFunc(ctx: *Context, argv: []*Mem) void {
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const b = (numArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    if (a == .int and b == .int) {
        if (b.int == 0) return api.resultInt64(ctx, a.int);
        if (b.int == -1) return api.resultInt64(ctx, 0);
        return api.resultInt64(ctx, @rem(a.int, b.int));
    }
    const x = toF(a);
    const y = toF(b);
    if (y == 0) return resultNumber(ctx, x);
    resultNumber(ctx, x - y * @trunc(x / y));
}

fn unaryMath(ctx: *Context, argv: []*Mem, comptime f: fn (f64) f64, int_same: bool) void {
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    if (int_same and a == .int) return api.resultInt64(ctx, a.int);
    resultNumber(ctx, f(toF(a)));
}

fn ceilF(x: f64) f64 {
    return @ceil(x);
}
fn floorF(x: f64) f64 {
    return @floor(x);
}
fn expF(x: f64) f64 {
    return @exp(x);
}

fn ceilFunc(ctx: *Context, argv: []*Mem) void {
    unaryMath(ctx, argv, ceilF, true);
}

fn floorFunc(ctx: *Context, argv: []*Mem) void {
    unaryMath(ctx, argv, floorF, true);
}

fn expFunc(ctx: *Context, argv: []*Mem) void {
    unaryMath(ctx, argv, expF, false);
}

fn sqrtFunc(ctx: *Context, argv: []*Mem) void {
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const x = toF(a);
    if (x < 0) return api.resultError(ctx, "ORA-01428: argument is out of range");
    resultNumber(ctx, @sqrt(x));
}

fn lnFunc(ctx: *Context, argv: []*Mem) void {
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const x = toF(a);
    if (x <= 0) return api.resultError(ctx, "ORA-01428: argument is out of range");
    resultNumber(ctx, @log(x));
}

fn logFunc(ctx: *Context, argv: []*Mem) void {
    var v: [2]f64 = undefined;
    numArgs(ctx, argv, &v) catch |err| switch (err) {
        error.Invalid => return,
        error.Null => return api.resultNull(ctx),
    };
    if (v[0] <= 0 or v[0] == 1 or v[1] <= 0) return api.resultError(ctx, "ORA-01428: argument is out of range");
    resultNumber(ctx, @log(v[1]) / @log(v[0]));
}

fn powerFunc(ctx: *Context, argv: []*Mem) void {
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const b = (numArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    if (a == .int and b == .int and b.int >= 0 and b.int < 64) {
        if (std.math.powi(i64, a.int, @intCast(b.int))) |r| return api.resultInt64(ctx, r) else |_| {}
    }
    const x = toF(a);
    const y = toF(b);
    if (x < 0 and y != @trunc(y)) return api.resultError(ctx, "ORA-01428: argument is out of range");
    resultNumber(ctx, std.math.pow(f64, x, y));
}

fn signFunc(ctx: *Context, argv: []*Mem) void {
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const x = toF(a);
    api.resultInt64(ctx, if (x > 0) 1 else if (x < 0) -1 else 0);
}

/// x rounded (half away from zero) or truncated to `d` decimal places.
fn roundTo(x: f64, d: i64, trunc: bool) f64 {
    if (!std.math.isFinite(x) or x == 0) return x;
    // On the shortest decimal text of x, as Oracle's decimal NUMBER
    // would (2.675 is 2.67499999... as a double, and rounds to 2.68).
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e}", .{@abs(x)}) catch return x;
    const e_at = std.mem.indexOfScalar(u8, s, 'e') orelse return x;
    const exp = std.fmt.parseInt(i64, s[e_at + 1 ..], 10) catch return x;
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    for (s[0..e_at]) |c| if (c != '.' and n < digits.len) {
        digits[n] = c;
        n += 1;
    };
    const keep = exp + std.math.clamp(d, -400, 400) + 1;
    if (keep >= @as(i64, @intCast(n))) return x;
    const neg = x < 0;
    var kept: u64 = 0;
    var k: i64 = 0;
    while (k < keep) : (k += 1) kept = kept * 10 + (digits[@intCast(k)] - '0');
    if (!trunc and keep >= 0 and digits[@intCast(keep)] >= '5') kept += 1;
    if (kept == 0) return 0;
    var out: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&out, "{s}{d}e{d}", .{ if (neg) "-" else "", kept, exp - keep + 1 }) catch return x;
    return std.fmt.parseFloat(f64, text) catch x;
}

/// ROUND/TRUNC of a number (to d places), or of a date (to a unit, DD by
/// default) when the argument is a date's text.
fn roundTrunc(ctx: *Context, argv: []*Mem, trunc: bool) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const t0 = api.valueType(argv[0]);
    if (t0 == vi.SQLITE_TEXT) {
        const z = api.valueText(argv[0]) orelse return api.resultErrorNomem(ctx);
        if (dt.parseIso(z)) |d| {
            var unit: []const u8 = "DD";
            var ub: [64]u8 = undefined;
            if (argv.len == 2) unit = str(ctx, argv[1], &ub) orelse return api.resultNull(ctx);
            const r = dt.truncate(d, unit, !trunc) orelse return api.resultError(ctx, "ORA-01898: too many precision specifiers");
            return resultDate(ctx, r);
        }
    }
    const a = (numArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    var places: i64 = 0;
    if (argv.len == 2) places = (intArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    if (a == .int and places >= 0) return api.resultInt64(ctx, a.int);
    resultNumber(ctx, roundTo(toF(a), places, trunc));
}

fn roundFunc(ctx: *Context, argv: []*Mem) void {
    roundTrunc(ctx, argv, false);
}

fn truncFunc(ctx: *Context, argv: []*Mem) void {
    roundTrunc(ctx, argv, true);
}

// ========================================================= TO_CHAR

fn toCharFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    var fb: [256]u8 = undefined;
    const fmt: ?[]const u8 = if (argv.len == 2) (str(ctx, argv[1], &fb) orelse return api.resultNull(ctx)) else null;
    const t0 = api.valueType(argv[0]);
    if (t0 == vi.SQLITE_INTEGER or t0 == vi.SQLITE_FLOAT) {
        var buf: [64]u8 = undefined;
        const f = fmt orelse return resultStr(ctx, numberText(&buf, argv[0]));
        var out: std.Io.Writer.Allocating = .init(gpa(ctx));
        defer out.deinit();
        formatNumber(&out.writer, toF((numArg(ctx, argv[0]) catch return).?), f) catch |err| switch (err) {
            error.WriteFailed => return api.resultErrorNomem(ctx),
            error.BadFormat => return api.resultError(ctx, "ORA-01481: invalid number format model"),
        };
        return resultStr(ctx, out.written());
    }
    var buf: [64]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    const d = dt.parseIso(s) orelse {
        // TO_CHAR of a string is the string; with a number format, the
        // number it spells.
        if (fmt) |f| {
            const n = parseNum(s) catch return api.resultError(ctx, "ORA-01722: invalid number");
            var out: std.Io.Writer.Allocating = .init(gpa(ctx));
            defer out.deinit();
            formatNumber(&out.writer, toF(n.?), f) catch |err| switch (err) {
                error.WriteFailed => return api.resultErrorNomem(ctx),
                error.BadFormat => return api.resultError(ctx, "ORA-01481: invalid number format model"),
            };
            return resultStr(ctx, out.written());
        }
        return resultStr(ctx, s);
    };
    const f = fmt orelse return resultStr(ctx, s);
    var out: std.Io.Writer.Allocating = .init(gpa(ctx));
    defer out.deinit();
    dt.format(&out.writer, d, f) catch |err| switch (err) {
        error.WriteFailed => return api.resultErrorNomem(ctx),
        error.BadFormat => return api.resultError(ctx, "ORA-01821: date format not recognized"),
    };
    resultStr(ctx, out.written());
}

/// TO_CHAR(number, fmt): 9 0 . D , G $ S MI PR FM X; '#'s when the
/// number does not fit.
pub fn formatNumber(w: *std.Io.Writer, x_arg: f64, fmt_arg: []const u8) error{ BadFormat, WriteFailed }!void {
    var fmt = fmt_arg;
    var fm = false;
    if (fmt.len >= 2 and std.ascii.eqlIgnoreCase(fmt[0..2], "FM")) {
        fm = true;
        fmt = fmt[2..];
    }
    var lead_s = false;
    var trail_s = false;
    var mi = false;
    var pr = false;
    var dollar = false;
    if (fmt.len > 0 and (fmt[0] == 'S' or fmt[0] == 's')) {
        lead_s = true;
        fmt = fmt[1..];
    }
    if (fmt.len >= 2 and std.ascii.eqlIgnoreCase(fmt[fmt.len - 2 ..], "MI")) {
        mi = true;
        fmt = fmt[0 .. fmt.len - 2];
    } else if (fmt.len >= 2 and std.ascii.eqlIgnoreCase(fmt[fmt.len - 2 ..], "PR")) {
        pr = true;
        fmt = fmt[0 .. fmt.len - 2];
    } else if (fmt.len > 0 and (fmt[fmt.len - 1] == 'S' or fmt[fmt.len - 1] == 's')) {
        trail_s = true;
        fmt = fmt[0 .. fmt.len - 1];
    }
    // Hexadecimal: X's (and leading 0's).
    if (fmt.len > 0 and (std.mem.indexOfAny(u8, fmt, "xX") != null)) {
        if (x_arg < 0 or x_arg != @trunc(x_arg)) return error.BadFormat;
        var hb: [32]u8 = undefined;
        const upper = std.mem.indexOfScalar(u8, fmt, 'X') != null;
        const h = if (upper) std.fmt.bufPrint(&hb, "{X}", .{@as(u64, @intFromFloat(x_arg))}) catch return error.BadFormat else std.fmt.bufPrint(&hb, "{x}", .{@as(u64, @intFromFloat(x_arg))}) catch return error.BadFormat;
        const width = fmt.len;
        if (h.len > width) {
            for (0..width + 1) |_| try w.writeByte('#');
            return;
        }
        const zero_pad = fmt[0] == '0';
        if (!fm) try w.writeByte(' ');
        var k = h.len;
        while (k < width) : (k += 1) if (zero_pad) try w.writeByte('0') else if (!fm) try w.writeByte(' ');
        try w.writeAll(h);
        return;
    }
    // Integer part (digits and group separators) and fraction.
    var buf_i: [64]u8 = undefined;
    var buf_f: [64]u8 = undefined;
    var int_part: std.ArrayList(u8) = .initBuffer(&buf_i);
    var frac_part: std.ArrayList(u8) = .initBuffer(&buf_f);
    var seen_point = false;
    for (fmt) |c| {
        const u = std.ascii.toUpper(c);
        switch (u) {
            '9', '0' => {
                const list = if (seen_point) &frac_part else &int_part;
                if (list.items.len >= list.capacity) return error.BadFormat;
                list.appendAssumeCapacity(u);
            },
            ',', 'G' => {
                if (seen_point) return error.BadFormat;
                if (int_part.items.len >= int_part.capacity) return error.BadFormat;
                int_part.appendAssumeCapacity(',');
            },
            '.', 'D' => {
                if (seen_point) return error.BadFormat;
                seen_point = true;
            },
            '$' => dollar = true,
            'B', 'V', 'L', 'C', 'U' => return error.BadFormat,
            else => return error.BadFormat,
        }
    }
    const frac_digits = frac_part.items.len;
    const neg = x_arg < 0;
    const x = @abs(roundTo(x_arg, @intCast(frac_digits), false));
    // The digits of x with frac_digits decimals.
    var db: [400]u8 = undefined;
    const digits = std.fmt.bufPrint(&db, "{d:.[1]}", .{ x, frac_digits }) catch return error.BadFormat;
    const dot = std.mem.indexOfScalar(u8, digits, '.');
    var int_digits = if (dot) |d| digits[0..d] else digits;
    const frac = if (dot) |d| digits[d + 1 ..] else "";
    if (std.mem.eql(u8, int_digits, "0")) int_digits = "";
    var slots: usize = 0;
    var first_zero: ?usize = null;
    for (int_part.items) |c| if (c != ',') {
        if (c == '0' and first_zero == null) first_zero = slots;
        slots += 1;
    };
    const width = fmt.len + 1 + @as(usize, if (pr) 1 else 0);
    if (int_digits.len > slots) {
        for (0..width) |_| try w.writeByte('#');
        return;
    }
    var need = int_digits.len;
    if (first_zero) |z| need = @max(need, slots - z);
    // Zero with no decimals prints one 0.
    if (need == 0 and frac_digits == 0 and slots > 0) need = 1;
    var bb: [512]u8 = undefined;
    var body: std.ArrayList(u8) = .initBuffer(&bb);
    var slot: usize = 0;
    var printed = false;
    const pad_digits = need - int_digits.len;
    for (int_part.items) |c| {
        if (c == ',') {
            body.appendAssumeCapacity(if (printed) ',' else ' ');
            continue;
        }
        const k = @as(isize, @intCast(slot)) - @as(isize, @intCast(slots - need));
        if (k < 0) {
            body.appendAssumeCapacity(' ');
        } else {
            const ku: usize = @intCast(k);
            body.appendAssumeCapacity(if (ku < pad_digits) '0' else int_digits[ku - pad_digits]);
            printed = true;
        }
        slot += 1;
    }
    if (seen_point) {
        body.appendAssumeCapacity('.');
        var fr = frac;
        if (fm) {
            // FM drops the trailing zeros of 9 places.
            var keep = fr.len;
            while (keep > 0 and fr[keep - 1] == '0' and frac_part.items[keep - 1] == '9') keep -= 1;
            fr = fr[0..keep];
        }
        body.appendSliceAssumeCapacity(fr);
    }
    // The sign (and $) go right before the first printed character.
    var lead: usize = 0;
    while (lead < body.items.len and body.items[lead] == ' ') lead += 1;
    var ob: [600]u8 = undefined;
    var out: std.ArrayList(u8) = .initBuffer(&ob);
    if (!fm) out.appendNTimesAssumeCapacity(' ', lead);
    if (!(lead_s or trail_s or mi or pr)) {
        if (neg) out.appendAssumeCapacity('-') else if (!fm) out.appendAssumeCapacity(' ');
    } else if (lead_s) {
        out.appendAssumeCapacity(if (neg) '-' else '+');
    } else if (pr) {
        out.appendAssumeCapacity(if (neg) '<' else ' ');
    }
    if (dollar) out.appendAssumeCapacity('$');
    out.appendSliceAssumeCapacity(body.items[lead..]);
    if (trail_s) out.appendAssumeCapacity(if (neg) '-' else '+');
    if (mi) {
        if (neg) out.appendAssumeCapacity('-') else if (!fm) out.appendAssumeCapacity(' ');
    }
    if (pr) {
        if (neg) out.appendAssumeCapacity('>') else if (!fm) out.appendAssumeCapacity(' ');
    }
    try w.writeAll(out.items);
}

/// TO_NUMBER(s [, fmt]): the number s spells, group separators, $ and
/// blanks of a format left out.
fn toNumberFunc(ctx: *Context, argv: []*Mem) void {
    const t0 = api.valueType(argv[0]);
    if (t0 == vi.SQLITE_INTEGER or t0 == vi.SQLITE_FLOAT) return api.resultValue(ctx, argv[0]);
    var buf: [128]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa(ctx));
    var neg = false;
    var hex = false;
    if (argv.len == 2) {
        var fb: [128]u8 = undefined;
        const f = str(ctx, argv[1], &fb) orelse return api.resultNull(ctx);
        hex = std.mem.indexOfAny(u8, f, "xX") != null;
    }
    if (hex) {
        const v = std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 16) catch return api.resultError(ctx, "ORA-01722: invalid number");
        return api.resultInt64(ctx, v);
    }
    const t = std.mem.trim(u8, s, " ");
    for (t, 0..) |c, i| {
        if (c == ',' and argv.len == 2) continue;
        if (c == '$') continue;
        if ((c == '<' and i == 0) or (c == '>' and i == t.len - 1)) {
            neg = true;
            continue;
        }
        if (c == '-' and i == t.len - 1 and t.len > 1) {
            neg = true;
            continue;
        }
        clean.append(gpa(ctx), c) catch return api.resultErrorNomem(ctx);
    }
    const n = (parseNum(clean.items) catch return api.resultError(ctx, "ORA-01722: invalid number")) orelse return api.resultNull(ctx);
    switch (n) {
        .int => |v| api.resultInt64(ctx, if (neg) -v else v),
        .real => |v| resultNumber(ctx, if (neg) -v else v),
    }
}

// ============================================================== dates

fn toDateCommon(ctx: *Context, argv: []*Mem, digits: ?u32) void {
    var buf: [128]u8 = undefined;
    const s = str(ctx, argv[0], &buf) orelse return api.resultNull(ctx);
    const n = now(ctx);
    const d = blk: {
        if (argv.len == 2) {
            var fb: [256]u8 = undefined;
            const f = str(ctx, argv[1], &fb) orelse return api.resultNull(ctx);
            break :blk dt.parse(s, f, n) catch |err| switch (err) {
                error.BadFormat => return api.resultError(ctx, "ORA-01821: date format not recognized"),
                error.NoMatch => return api.resultError(ctx, "ORA-01861: literal does not match format string"),
                error.BadMonth => return api.resultError(ctx, "ORA-01843: not a valid month"),
                error.BadDay => return api.resultError(ctx, "ORA-01847: day of month must be between 1 and last day of month"),
                error.BadHour => return api.resultError(ctx, "ORA-01850: hour must be between 0 and 23"),
                error.BadHour12 => return api.resultError(ctx, "ORA-01849: hour must be between 1 and 12"),
                error.BadMinute => return api.resultError(ctx, "ORA-01851: minutes must be between 0 and 59"),
                error.BadSecond => return api.resultError(ctx, "ORA-01852: seconds must be between 0 and 59"),
            };
        }
        break :blk dt.parseDefault(s, n) orelse return api.resultError(ctx, "ORA-01861: literal does not match format string");
    };
    if (digits) |k| return resultTimestamp(ctx, d, k);
    resultDate(ctx, d);
}

fn toDateFunc(ctx: *Context, argv: []*Mem) void {
    toDateCommon(ctx, argv, null);
}

fn toTimestampFunc(ctx: *Context, argv: []*Mem) void {
    toDateCommon(ctx, argv, 6);
}

/// The fractional digits a date's text has (a TIMESTAMP keeps them).
fn fracDigitsOf(m: *Mem) u32 {
    if (api.valueType(m) != vi.SQLITE_TEXT) return 0;
    const z = api.valueText(m) orelse return 0;
    if (z.len > 20 and z[19] == '.') {
        var n: u32 = 0;
        for (z[20..]) |c| {
            if (!std.ascii.isDigit(c)) break;
            n += 1;
        }
        return n;
    }
    return 0;
}

fn addMonthsFunc(ctx: *Context, argv: []*Mem) void {
    const d = (dateArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const n = (intArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    resultDate(ctx, dt.addMonths(d, n));
}

fn monthsBetweenFunc(ctx: *Context, argv: []*Mem) void {
    const a = (dateArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    const b = (dateArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    resultNumber(ctx, dt.monthsBetween(a, b));
}

fn lastDayFunc(ctx: *Context, argv: []*Mem) void {
    const d = (dateArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    resultDate(ctx, dt.lastDay(d));
}

/// NEXT_DAY(d, 'MONDAY'): the first such day after d (same time).
fn nextDayFunc(ctx: *Context, argv: []*Mem) void {
    const d = (dateArg(ctx, argv[0]) catch return) orelse return api.resultNull(ctx);
    var buf: [64]u8 = undefined;
    const name = std.mem.trim(u8, str(ctx, argv[1], &buf) orelse return api.resultNull(ctx), " ");
    for (dt.day_names, 0..) |dn, k| {
        if ((name.len >= 3 and name.len <= dn.len and std.ascii.eqlIgnoreCase(name, dn[0..name.len]))) {
            const wd: i64 = d.weekday();
            var delta = @mod(@as(i64, @intCast(k)) - wd, 7);
            if (delta == 0) delta = 7;
            return resultDate(ctx, d.withDays(d.days() + delta));
        }
    }
    api.resultError(ctx, "ORA-01846: not a valid day of the week");
}

/// extract(field, d): EXTRACT(field FROM d).
fn extractFunc(ctx: *Context, argv: []*Mem) void {
    var fb: [32]u8 = undefined;
    const field = str(ctx, argv[0], &fb) orelse return api.resultNull(ctx);
    const d = (dateArg(ctx, argv[1]) catch return) orelse return api.resultNull(ctx);
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(field, "YEAR")) return api.resultInt64(ctx, d.year);
    if (eq(field, "MONTH")) return api.resultInt64(ctx, d.month);
    if (eq(field, "DAY")) return api.resultInt64(ctx, d.day);
    if (eq(field, "HOUR")) return api.resultInt64(ctx, d.hour);
    if (eq(field, "MINUTE")) return api.resultInt64(ctx, d.minute);
    if (eq(field, "SECOND")) {
        if (d.nanos == 0) return api.resultInt64(ctx, d.second);
        return api.resultDouble(ctx, @as(f64, @floatFromInt(d.second)) + @as(f64, @floatFromInt(d.nanos)) / 1e9);
    }
    api.resultError(ctx, "ORA-00907: missing right parenthesis");
}

// ===================================================== coerce, cast

pub const coerce_not_null = 1;

const CastError = error{ Failed, Oom };

/// `m` converted to declared type `ty` (types.format() spelling), as the
/// result of `ctx`; `col` names the column for messages (empty for a
/// CAST).
fn convert(ctx: *Context, m: *Mem, ty: types.TypeName, col: []const u8) void {
    const fam = types.family(ty.name) orelse return api.resultValue(ctx, m);
    const vt = api.valueType(m);
    if (vt == vi.SQLITE_NULL) return api.resultNull(ctx);
    switch (fam) {
        .number, .binary_float => {
            var n: Num = undefined;
            switch (vt) {
                vi.SQLITE_INTEGER => n = .{ .int = api.valueInt64(m) },
                vi.SQLITE_FLOAT => n = .{ .real = api.valueDouble(m) },
                vi.SQLITE_BLOB => return api.resultError(ctx, "ORA-00932: inconsistent datatypes: expected NUMBER got BINARY"),
                else => {
                    const z = api.valueText(m) orelse return api.resultErrorNomem(ctx);
                    n = (parseNum(z) catch return api.resultError(ctx, "ORA-01722: invalid number")) orelse return api.resultNull(ctx);
                },
            }
            if (fam == .binary_float) return api.resultDouble(ctx, toF(n));
            const scale = ty.scale orelse (if (ty.precision != null and std.mem.eql(u8, ty.name, "NUMBER")) @as(i64, 0) else null);
            var x = toF(n);
            if (scale) |s| {
                if (!(n == .int and s >= 0)) x = roundTo(x, s, false);
            }
            if (std.mem.eql(u8, ty.name, "NUMBER")) if (types.precisionBound(ty)) |bound| {
                if (@abs(x) >= bound) {
                    if (col.len > 0) return api.resultError(ctx, "ORA-01438: value larger than specified precision allowed for this column");
                    return api.resultError(ctx, "ORA-01438: value larger than specified precision allowed for this column");
                }
            };
            if (n == .int and (scale == null or scale.? >= 0)) return api.resultInt64(ctx, n.int);
            resultNumber(ctx, x);
        },
        .varchar, .char, .clob, .rowid, .interval => {
            var buf: [64]u8 = undefined;
            const s = str(ctx, m, &buf) orelse return api.resultNull(ctx);
            if ((fam == .varchar or fam == .char) and ty.precision != null) {
                const max: usize = @intCast(ty.precision.?);
                const len = if (ty.char_semantics) dfunc.charCount(s) else s.len;
                if (len > max) {
                    if (col.len == 0) return api.resultError(ctx, "ORA-25137: Data value out of range");
                    var mb: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&mb, "ORA-12899: value too large for column {s} (actual: {d}, maximum: {d})", .{ col, len, max }) catch "ORA-12899: value too large for column";
                    return api.resultError(ctx, msg);
                }
                if (fam == .char and len < max) {
                    // CHAR(n) is blank-padded.
                    var out: std.ArrayList(u8) = .empty;
                    out.appendSlice(gpa(ctx), s) catch return api.resultErrorNomem(ctx);
                    out.appendNTimes(gpa(ctx), ' ', max - len) catch return api.resultErrorNomem(ctx);
                    return dfunc.resultOwned(ctx, &out);
                }
            }
            api.resultText(ctx, s, .transient);
        },
        .date, .timestamp => {
            if (vt != vi.SQLITE_TEXT) return api.resultError(ctx, "ORA-00932: inconsistent datatypes: expected DATE got NUMBER");
            const z = api.valueText(m) orelse return api.resultErrorNomem(ctx);
            if (z.len == 0) return api.resultNull(ctx);
            const d = dt.parseDefault(z, now(ctx)) orelse return api.resultError(ctx, "ORA-01861: literal does not match format string");
            if (fam == .date) return resultDate(ctx, d);
            // Six digits whatever the precision (the fraction cut to it),
            // so that timestamps compare as text.
            var t = d;
            const keep = std.math.pow(u32, 10, 9 - types.fractionDigits(ty));
            t.nanos = t.nanos / keep * keep;
            resultTimestamp(ctx, t, 6);
        },
        .blob, .raw => {
            var bytes: []const u8 = undefined;
            var owned: ?[]u8 = null;
            defer if (owned) |o| gpa(ctx).free(o);
            if (vt == vi.SQLITE_BLOB) {
                bytes = api.valueBlob(m) orelse &.{};
            } else if (vt == vi.SQLITE_TEXT) {
                const z = api.valueText(m) orelse return api.resultErrorNomem(ctx);
                if (z.len == 0) return api.resultNull(ctx);
                // Text is hexadecimal (HEXTORAW).
                const n = (z.len + 1) / 2;
                const out = gpa(ctx).alloc(u8, n) catch return api.resultErrorNomem(ctx);
                owned = out;
                var hi = z.len % 2 == 1;
                var k: usize = 0;
                var acc: u8 = 0;
                for (z) |c| {
                    const v = std.fmt.charToDigit(c, 16) catch return api.resultError(ctx, "ORA-01465: invalid hex number");
                    if (hi) {
                        out[k] = acc | v;
                        k += 1;
                        acc = 0;
                    } else acc = v << 4;
                    hi = !hi;
                }
                bytes = out;
            } else return api.resultError(ctx, "ORA-00932: inconsistent datatypes: expected BINARY got NUMBER");
            if (fam == .raw) if (ty.precision) |max| if (bytes.len > max) {
                return api.resultError(ctx, "ORA-12899: value too large for column");
            };
            api.resultBlob(ctx, bytes, .transient);
        },
        .boolean => {
            switch (vt) {
                vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return api.resultInt64(ctx, @intFromBool(api.valueDouble(m) != 0)),
                vi.SQLITE_TEXT => {
                    const z = std.mem.trim(u8, api.valueText(m) orelse return api.resultErrorNomem(ctx), " ");
                    if (z.len == 0) return api.resultNull(ctx);
                    const yes = [_][]const u8{ "TRUE", "T", "YES", "Y", "ON", "1" };
                    const no = [_][]const u8{ "FALSE", "F", "NO", "N", "OFF", "0" };
                    for (yes) |w| if (std.ascii.eqlIgnoreCase(z, w)) return api.resultInt64(ctx, 1);
                    for (no) |w| if (std.ascii.eqlIgnoreCase(z, w)) return api.resultInt64(ctx, 0);
                    return api.resultError(ctx, "ORA-61800: invalid boolean value");
                },
                else => return api.resultError(ctx, "ORA-00932: inconsistent datatypes: expected BOOLEAN got BINARY"),
            }
        },
    }
}

/// xq_ora_coerce(value, type, table, column, flags).
fn coerceFunc(ctx: *Context, argv: []*Mem) void {
    const spelling = api.valueText(argv[1]) orelse return api.resultErrorNomem(ctx);
    const table = api.valueText(argv[2]) orelse "";
    const column = api.valueText(argv[3]) orelse "";
    const flags = api.valueInt64(argv[4]);
    var nb: [256]u8 = undefined;
    const col = std.fmt.bufPrint(&nb, "\"{s}\".\"{s}\"", .{ table, column }) catch column;
    const empty = api.valueType(argv[0]) == vi.SQLITE_TEXT and api.valueBytes(argv[0]) == 0;
    if (flags & coerce_not_null != 0 and (isNull(argv[0]) or empty)) {
        var mb: [300]u8 = undefined;
        const msg = std.fmt.bufPrint(&mb, "ORA-01400: cannot insert NULL into ({s})", .{col}) catch "ORA-01400: cannot insert NULL";
        return api.resultError(ctx, msg);
    }
    const ty = types.parse(spelling) orelse return api.resultValue(ctx, argv[0]);
    convert(ctx, argv[0], ty, col);
}

/// xq_ora_cast(value, type).
fn castFunc(ctx: *Context, argv: []*Mem) void {
    const spelling = api.valueText(argv[1]) orelse return api.resultErrorNomem(ctx);
    const ty = types.parse(spelling) orelse return api.resultValue(ctx, argv[0]);
    convert(ctx, argv[0], ty, "");
}

fn autocommitFunc(ctx: *Context, _: []*Mem) void {
    api.resultInt64(ctx, @intFromBool(api.contextDbHandle(ctx).auto_commit));
}

// ============================================== USER_TAB_COLUMNS helpers

/// The Oracle type of a column: its catalog spelling, else one its
/// SQLite type suggests.
fn columnType(ctx: *Context, argv: []*Mem) ?types.TypeName {
    if (!isNull(argv[0])) {
        const z = api.valueText(argv[0]) orelse return null;
        if (types.parse(z)) |t| return t;
    }
    const z = if (isNull(argv[1])) "" else (api.valueText(argv[1]) orelse "");
    _ = ctx;
    const Aff = int.Aff;
    if (z.len == 0) return .{ .name = "BLOB" };
    return switch (@import("../../sql/build.zig").affinityType(z, null)) {
        Aff.integer => .{ .name = "NUMBER", .scale = 0 },
        Aff.real, Aff.numeric => .{ .name = "NUMBER" },
        Aff.blob => .{ .name = "BLOB" },
        else => .{ .name = "VARCHAR2", .precision = 4000 },
    };
}

fn dataTypeFunc(ctx: *Context, argv: []*Mem) void {
    const ty = columnType(ctx, argv) orelse return api.resultNull(ctx);
    const name = types.dataTypeName(gpa(ctx), ty) catch return api.resultErrorNomem(ctx);
    if (name.ptr == ty.name.ptr) return api.resultText(ctx, name, .transient);
    api.resultText(ctx, name, .dynamic);
}

fn dataLengthFunc(ctx: *Context, argv: []*Mem) void {
    const ty = columnType(ctx, argv) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, types.dataLength(ty));
}

fn dataPrecisionFunc(ctx: *Context, argv: []*Mem) void {
    const ty = columnType(ctx, argv) orelse return api.resultNull(ctx);
    const fam = types.family(ty.name) orelse return api.resultNull(ctx);
    if (fam == .number) {
        if (std.mem.eql(u8, ty.name, "FLOAT")) return api.resultInt64(ctx, ty.precision orelse 126);
        if (ty.precision) |p| return api.resultInt64(ctx, p);
    }
    api.resultNull(ctx);
}

fn dataScaleFunc(ctx: *Context, argv: []*Mem) void {
    const ty = columnType(ctx, argv) orelse return api.resultNull(ctx);
    const fam = types.family(ty.name) orelse return api.resultNull(ctx);
    if (fam == .number and std.mem.eql(u8, ty.name, "NUMBER")) {
        if (ty.scale) |s| return api.resultInt64(ctx, s);
        if (ty.precision != null) return api.resultInt64(ctx, 0);
    }
    if (fam == .timestamp) return api.resultInt64(ctx, types.fractionDigits(ty));
    api.resultNull(ctx);
}

// ================================================================= tests

const testing = std.testing;

fn expectNumberFormat(x: f64, fmt: []const u8, want: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatNumber(&w, x, fmt);
    try testing.expectEqualStrings(want, w.buffered());
}

test "oracle number text and formats" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(".5", realText(&buf, 0.5));
    try testing.expectEqualStrings("-.5", realText(&buf, -0.5));
    try testing.expectEqualStrings("2", realText(&buf, 2.0));
    try testing.expectEqualStrings("1234.5", realText(&buf, 1234.5));
    try testing.expectEqualStrings(".333333333333333", realText(&buf, 1.0 / 3.0));
    try testing.expectEqualStrings("1.5E+25", realText(&buf, 1.5e25));
    try expectNumberFormat(1234.5, "9,999.99", " 1,234.50");
    try expectNumberFormat(12, "000", " 012");
    try expectNumberFormat(3.14159, "FM990.00", "3.14");
    try expectNumberFormat(-5, "999", "  -5");
    try expectNumberFormat(0.5, "9.99", "  .50");
    try expectNumberFormat(0, "9", " 0");
    try expectNumberFormat(12345, "999", "####");
    try expectNumberFormat(255, "XX", " FF");
    try expectNumberFormat(-12.3, "FM999.99MI", "12.3-");
    try expectNumberFormat(42, "$999", "  $42");
    try expectNumberFormat(1.5, "FM9.999", "1.5");
    try testing.expectEqual(@as(f64, 2.68), roundTo(2.675, 2, false));
    try testing.expectEqual(@as(f64, -3), roundTo(-2.5, 0, false));
}
