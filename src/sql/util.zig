//! Utilities of the SQL layer (port of parts of util.c): error messages,
//! dequoting and number parsing.

const std = @import("std");
const ctype = @import("../util/ctype.zig");
const int = @import("sqlite_int.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const Token = int.Token;
const EP = int.EP;
const TK = int.TK;
const RC = int.RC;

/// Port of sqlite3ErrorMsg(): record a compile error in `p`. The format
/// uses Zig syntax; messages must still match SQLite's word for word.
pub fn errorMsg(p: *Parse, comptime fmt: []const u8, args: anytype) void {
    errorMsgAt(p, null, fmt, args);
}

/// `errorMsg` for a message that quotes the text at `z` (formatted with
/// %T in the C code): its offset in the statement is recorded for
/// sqlite3_error_offset().
pub fn errorMsgAt(p: *Parse, z: ?[*]const u8, comptime fmt: []const u8, args: anytype) void {
    const db = p.db;
    db.err_byte_offset = -2;
    if (z) |zp| recordErrorByteOffset(p, zp);
    if (db.err_byte_offset < -1) db.err_byte_offset = -1;
    const msg = std.fmt.allocPrintSentinel(p.arena, fmt, args, 0) catch {
        p.n_err += 1;
        p.rc = RC.NOMEM;
        return;
    };
    if (db.suppress_err != 0) return;
    p.n_err += 1;
    p.err_msg = msg;
    p.rc = RC.ERROR;
    p.with = null;
}

/// Port of sqlite3RecordErrorByteOffset(): while a message is formatted,
/// remember where `z` is in the statement, if it points into it.
pub fn recordErrorByteOffset(p: *Parse, z: [*]const u8) void {
    const db = p.db;
    if (db.err_byte_offset != -2) return;
    const start = @intFromPtr(p.tail.ptr);
    const at = @intFromPtr(z);
    if (at < start or at >= start + p.tail.len) return;
    db.err_byte_offset = @intCast(at - start);
}

/// Port of sqlite3Dequote(): remove the quotes from a quoted string or
/// identifier in place (doubled quotes become one, [x] becomes x). No-op
/// if `z` is not quoted. Returns the new length.
pub fn dequote(z: [:0]u8) [:0]u8 {
    if (z.len == 0) return z;
    var quote = z[0];
    if (!ctype.isQuote(quote)) return z;
    if (quote == '[') quote = ']';
    var i: usize = 1;
    var j: usize = 0;
    while (true) : (i += 1) {
        std.debug.assert(z[i] != 0);
        if (z[i] == quote) {
            if (z[i + 1] == quote) {
                z[j] = quote;
                j += 1;
                i += 1;
            } else {
                break;
            }
        } else {
            z[j] = z[i];
            j += 1;
        }
    }
    z[j] = 0;
    return z[0..j :0];
}

/// Port of sqlite3DequoteExpr().
pub fn dequoteExpr(e: *Expr) void {
    const tok = e.u.token.?;
    std.debug.assert(ctype.isQuote(tok[0]));
    e.flags |= if (tok[0] == '"') EP.Quoted | EP.DblQuoted else EP.Quoted;
    e.u.token = dequote(tok);
}

/// Port of sqlite3DequoteNumber(): turn a QNUMBER (digits with '_'
/// separators) into an INTEGER or FLOAT.
pub fn dequoteNumber(p: *Parse, e: *Expr) void {
    std.debug.assert(e.op == TK.QNUMBER);
    const z = e.u.token.?;
    const hex = z[0] == '0' and (z[1] == 'x' or z[1] == 'X');
    e.op = TK.INTEGER;
    var out: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const c = z[i];
        if (c != '_') {
            z[out] = c;
            out += 1;
            if (c == 'e' or c == 'E' or c == '.') e.op = TK.FLOAT;
        } else {
            const ok = if (hex)
                i > 0 and ctype.isXdigit(z[i - 1]) and ctype.isXdigit(z[i + 1])
            else
                i > 0 and ctype.isDigit(z[i - 1]) and ctype.isDigit(z[i + 1]);
            if (!ok) errorMsg(p, "unrecognized token: \"{s}\"", .{std.mem.sliceTo(z, 0)});
        }
        if (c == 0) break;
    }
    e.u.token = z[0 .. out - 1 :0];
    if (hex) e.op = TK.INTEGER;
    // tag-20240227-a: integers that fit in 32 bits use EP_IntValue.
    if (e.op == TK.INTEGER) {
        if (getInt32(e.u.token.?)) |v| {
            e.u = .{ .value = v };
            e.flags |= EP.IntValue;
        }
    }
}

/// Port of sqlite3DequoteToken(): drop the quotes of a token if that
/// needs no copy (no quote characters inside).
pub fn dequoteToken(t: *Token) void {
    if (t.n < 2) return;
    const z = t.z.?;
    if (!ctype.isQuote(z[0])) return;
    for (1..t.n - 1) |i| if (ctype.isQuote(z[i])) return;
    t.n -= 2;
    t.z = z + 1;
}

pub fn hexToInt(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// Port of sqlite3GetInt32(): the value of a decimal or hex integer that
/// fits in 32 bits, ignoring trailing text; null otherwise.
pub fn getInt32(z_arg: []const u8) ?i32 {
    var z = z_arg;
    const at = struct {
        fn f(s: []const u8, i: usize) u8 {
            return if (i < s.len) s[i] else 0;
        }
    }.f;
    var neg = false;
    if (at(z, 0) == '-') {
        neg = true;
        z = z[1..];
    } else if (at(z, 0) == '+') {
        z = z[1..];
    } else if (at(z, 0) == '0' and (at(z, 1) == 'x' or at(z, 1) == 'X') and ctype.isXdigit(at(z, 2))) {
        z = z[2..];
        while (at(z, 0) == '0') z = z[1..];
        var u: u32 = 0;
        var i: usize = 0;
        while (i < 8 and ctype.isXdigit(at(z, i))) : (i += 1) u = u * 16 + hexToInt(z[i]);
        if (u & 0x80000000 == 0 and !ctype.isXdigit(at(z, i))) return @bitCast(u);
        return null;
    }
    if (!ctype.isDigit(at(z, 0))) return null;
    while (at(z, 0) == '0') z = z[1..];
    var v: i64 = 0;
    var i: usize = 0;
    while (i < 11 and ctype.isDigit(at(z, i))) : (i += 1) v = v * 10 + (z[i] - '0');
    if (i > 10) return null;
    if (v - @intFromBool(neg) > 2147483647) return null;
    if (neg) v = -v;
    return @intCast(v);
}

/// Result of `atoi64` (the return codes of sqlite3Atoi64()).
pub const AtoiResult = enum(i8) {
    /// Not even a prefix looks like an integer.
    not_a_number = -1,
    ok = 0,
    /// Non-space text follows the integer.
    excess_text = 1,
    /// Too large for 64 bits.
    overflow = 2,
    /// Exactly 9223372036854775808.
    min_magnitude = 3,
};

fn compare2pow63(z: []const u8) i32 {
    const pow63 = "922337203685477580";
    var c: i32 = 0;
    var i: usize = 0;
    while (c == 0 and i < 18) : (i += 1) c = (@as(i32, z[i]) - pow63[i]) * 10;
    if (c == 0) c = @as(i32, z[18]) - '8';
    return c;
}

/// Port of sqlite3Atoi64() for UTF-8: convert decimal text to an i64.
pub fn atoi64(z_arg: []const u8, out: *i64) AtoiResult {
    var z = z_arg;
    while (z.len > 0 and ctype.isSpace(z[0])) z = z[1..];
    var neg = false;
    if (z.len > 0) {
        if (z[0] == '-') {
            neg = true;
            z = z[1..];
        } else if (z[0] == '+') {
            z = z[1..];
        }
    }
    const start_len = z.len;
    while (z.len > 0 and z[0] == '0') z = z[1..];
    var u: u64 = 0;
    var i: usize = 0;
    while (i < z.len and ctype.isDigit(z[i])) : (i += 1) u = u *% 10 +% (z[i] - '0');
    const largest: u64 = std.math.maxInt(i64);
    if (u > largest) {
        out.* = if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
    } else if (neg) {
        out.* = -@as(i64, @intCast(u));
    } else {
        out.* = @intCast(u);
    }
    var rc: AtoiResult = .ok;
    if (i == 0 and start_len == z.len) {
        rc = .not_a_number;
    } else if (i < z.len) {
        for (z[i..]) |c| {
            if (!ctype.isSpace(c)) {
                rc = .excess_text;
                break;
            }
        }
    }
    if (i < 19) return rc;
    const j: i32 = if (i > 19) 1 else compare2pow63(z);
    if (j < 0) return rc;
    out.* = if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
    if (j > 0) return .overflow;
    return if (neg) rc else .min_magnitude;
}

/// Port of sqlite3DecOrHexToI64(): like `atoi64` but also accepts hex
/// ("0x..."), which is never treated as overflowing into a negative.
pub fn decOrHexToI64(z: [:0]const u8, out: *i64) AtoiResult {
    if (z[0] == '0' and (z[1] == 'x' or z[1] == 'X')) {
        var u: u64 = 0;
        var i: usize = 2;
        while (z[i] == '0') i += 1;
        var k = i;
        while (ctype.isXdigit(z[k])) : (k += 1) u = u *% 16 +% hexToInt(z[k]);
        out.* = @bitCast(u);
        if (k - i > 16) return .overflow;
        if (z[k] != 0) return .excess_text;
        return .ok;
    }
    var n: usize = 0;
    while (std.mem.indexOfScalar(u8, "+- \n\t0123456789", z[n]) != null and z[n] != 0) n += 1;
    if (z[n] != 0) n += 1;
    return atoi64(z[0..n], out);
}

/// Port of sqlite3IsTrueOrFalse(): EP_IsTrue for "true", EP_IsFalse for
/// "false" (any case), else 0.
pub fn isTrueOrFalse(z: []const u8) u32 {
    if (ctype.eqlNoCase(z, "true")) return EP.IsTrue;
    if (ctype.eqlNoCase(z, "false")) return EP.IsFalse;
    return 0;
}

test "util: dequote" {
    var buf = "'it''s'".*;
    try std.testing.expectEqualStrings("it's", dequote(&buf));
    var b2 = "[a b]".*;
    try std.testing.expectEqualStrings("a b", dequote(&b2));
    var b3 = "plain".*;
    try std.testing.expectEqualStrings("plain", dequote(&b3));
}

test "util: integer parsing" {
    try std.testing.expectEqual(@as(?i32, 2147483647), getInt32("2147483647"));
    try std.testing.expectEqual(@as(?i32, null), getInt32("2147483648"));
    try std.testing.expectEqual(@as(?i32, -2147483648), getInt32("-2147483648"));
    try std.testing.expectEqual(@as(?i32, 255), getInt32("0xff"));
    try std.testing.expectEqual(@as(?i32, null), getInt32("0x80000000"));
    var v: i64 = 0;
    try std.testing.expectEqual(AtoiResult.ok, atoi64("9223372036854775807", &v));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), v);
    try std.testing.expectEqual(AtoiResult.min_magnitude, atoi64("9223372036854775808", &v));
    try std.testing.expectEqual(AtoiResult.ok, atoi64("-9223372036854775808", &v));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), v);
    try std.testing.expectEqual(AtoiResult.overflow, atoi64("99999999999999999999", &v));
    try std.testing.expectEqual(AtoiResult.excess_text, atoi64("12x", &v));
    try std.testing.expectEqual(AtoiResult.not_a_number, atoi64("x", &v));
    try std.testing.expectEqual(AtoiResult.ok, decOrHexToI64("0xffffffffffffffff", &v));
    try std.testing.expectEqual(@as(i64, -1), v);
}

/// Port of sqlite3ErrStr(): the English text of a result code.
pub fn errStr(rc: i32) [:0]const u8 {
    const msgs = [_]?[:0]const u8{
        "not an error",
        "SQL logic error",
        null,
        "access permission denied",
        "query aborted",
        "database is locked",
        "database table is locked",
        "out of memory",
        "attempt to write a readonly database",
        "interrupted",
        "disk I/O error",
        "database disk image is malformed",
        "unknown operation",
        "database or disk is full",
        "unable to open database file",
        "locking protocol",
        null,
        "database schema has changed",
        "string or blob too big",
        "constraint failed",
        "datatype mismatch",
        "bad parameter or other API misuse",
        null,
        "authorization denied",
        null,
        "column index out of range",
        "file is not a database",
        "notification message",
        "warning message",
    };
    // SQLITE_ABORT_ROLLBACK = SQLITE_ABORT | (2<<8).
    if (rc == RC.ABORT | (2 << 8)) return "abort due to ROLLBACK";
    if (rc == RC.ROW) return "another row available";
    if (rc == RC.DONE) return "no more rows available";
    const primary: usize = @intCast(rc & 0xff);
    if (primary < msgs.len) if (msgs[primary]) |m| return m;
    return "unknown error";
}

/// Port of sqlite3LogEst(): 10*log2(x), roughly.
pub fn logEst(x_arg: u64) i16 {
    const a = [_]i16{ 0, 2, 3, 5, 6, 7, 8, 9 };
    var y: i16 = 40;
    var x = x_arg;
    if (x < 8) {
        if (x < 2) return 0;
        while (x < 8) {
            y -= 10;
            x <<= 1;
        }
    } else {
        const i: u6 = @intCast(60 - @clz(x));
        y += @as(i16, i) * 10;
        x >>= i;
    }
    return a[@intCast(x & 7)] + y - 10;
}
