//! SQLite's locale-independent character classes (sqlite3CtypeMap and the
//! sqlite3Isxxx macros).

/// Bits: 0x01 space, 0x02 alpha, 0x04 digit, 0x08 hex digit, 0x20 lower
/// case (toupper subtracts it), 0x40 identifier character that is not
/// alphanumeric ($, _ and every non-ASCII byte), 0x80 quote.
pub const map = blk: {
    var m: [256]u8 = @splat(0);
    for ("\t\n\x0b\x0c\r ") |c| m[c] = 0x01;
    for ('0'..'9' + 1) |c| m[c] = 0x0c;
    for ('A'..'Z' + 1) |c| m[c] = 0x02;
    for ('a'..'z' + 1) |c| m[c] = 0x22;
    for ("ABCDEF") |c| m[c] = 0x0a;
    for ("abcdef") |c| m[c] = 0x2a;
    m['$'] = 0x40;
    m['_'] = 0x40;
    for ("\"'[`") |c| m[c] = 0x80;
    for (0x80..0x100) |c| m[c] = 0x40;
    break :blk m;
};

pub fn isSpace(c: u8) bool {
    return map[c] & 0x01 != 0;
}

pub fn isAlnum(c: u8) bool {
    return map[c] & 0x06 != 0;
}

pub fn isAlpha(c: u8) bool {
    return map[c] & 0x02 != 0;
}

pub fn isDigit(c: u8) bool {
    return map[c] & 0x04 != 0;
}

pub fn isXdigit(c: u8) bool {
    return map[c] & 0x08 != 0;
}

pub fn isQuote(c: u8) bool {
    return map[c] & 0x80 != 0;
}

/// IdChar(): a character that may appear in an unquoted identifier.
pub fn isIdChar(c: u8) bool {
    return map[c] & 0x46 != 0;
}

pub fn toUpper(c: u8) u8 {
    return c & ~(map[c] & 0x20);
}

/// sqlite3UpperToLower for the first 256 entries.
pub fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Port of sqlite3StrICmp(), on slices.
pub fn strICmp(a: []const u8, b: []const u8) i32 {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const d = @as(i32, toLower(x)) - toLower(y);
        if (d != 0) return d;
    }
    return @as(i32, @intCast(a.len)) - @as(i32, @intCast(b.len));
}

/// Port of sqlite3StrNICmp(): compares the first `n` bytes of `a` and `b`
/// ignoring ASCII case, stopping early at a NUL in `a`. Both slices must
/// hold at least `n` bytes, except that a slice may end at its NUL.
pub fn strNICmp(a: []const u8, b: []const u8, n: usize) i32 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = if (i < a.len) a[i] else 0;
        const y = if (i < b.len) b[i] else 0;
        if (x == 0 or toLower(x) != toLower(y)) return @as(i32, toLower(x)) - toLower(y);
    }
    return 0;
}

pub fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (toLower(x) != toLower(y)) return false;
    return true;
}
