//! SQLite's JSONB (SQLite 3.45+: jsonb(), json_valid(x, 8)), the binary
//! JSON the dialects store: reading a blob node by node, its strict
//! validity, its strings and numbers decoded, its text written with
//! PostgreSQL's spacing, and the headers of the nodes a writer emits.
//! Outside the dialect directories, as the value display (api/display.zig)
//! and the wire server read it too.
//!
//! A node is a header and a payload. The header's first byte has the
//! element type in its low four bits and the payload size in its high
//! four: 0-11 the size itself, 12/13/14/15 a size of 1/2/4/8 bytes
//! (big-endian) after it. A container's payload is its children, an
//! object's alternately a key (a text node) and a value.
//!
//! What PostgreSQL's jsonb writes (postgres/json.zig) is one canonical
//! node per value: the smallest header, INT/FLOAT/TEXT/TEXTRAW only,
//! object keys in jsonb's order. What sqlite3 writes may be any valid
//! JSONB (JSON5 numbers, escaped strings, larger headers, keys in any
//! order, duplicate keys): every reader here takes it.

const std = @import("std");
const json_text = @import("json_text.zig");
const Allocator = std.mem.Allocator;

pub const NULL: u8 = 0;
pub const TRUE: u8 = 1;
pub const FALSE: u8 = 2;
/// An integer as RFC 8259 writes it.
pub const INT: u8 = 3;
/// An integer in JSON5's 0x notation.
pub const INT5: u8 = 4;
/// A number with a fraction or an exponent, as RFC 8259 writes it.
pub const FLOAT: u8 = 5;
/// A number with JSON5's extensions (.5, 5., +5, Infinity, NaN).
pub const FLOAT5: u8 = 6;
/// A string with nothing to escape (no `"`, `\`, control character).
pub const TEXT: u8 = 7;
/// A string with RFC 8259's escapes.
pub const TEXTJ: u8 = 8;
/// A string with JSON5's escapes.
pub const TEXT5: u8 = 9;
/// A string as it is, which may need escaping.
pub const TEXTRAW: u8 = 10;
pub const ARRAY: u8 = 11;
pub const OBJECT: u8 = 12;

/// The deepest nesting json_valid(x, 8) accepts (JSON_MAX_DEPTH).
pub const max_depth = 1000;

pub const Node = struct {
    typ: u8,
    /// The size of the header.
    hdr: usize,
    /// The size of the payload.
    len: usize,

    pub fn size(n: Node) usize {
        return n.hdr + n.len;
    }

    pub fn isText(n: Node) bool {
        return n.typ >= TEXT and n.typ <= TEXTRAW;
    }

    pub fn isNumber(n: Node) bool {
        return n.typ >= INT and n.typ <= FLOAT5;
    }

    pub fn isContainer(n: Node) bool {
        return n.typ == ARRAY or n.typ == OBJECT;
    }
};

/// The node whose header is at b[i], null if the header or the payload
/// does not fit in `b` (as jsonbPayloadSize() reads it).
pub fn node(b: []const u8, i: usize) ?Node {
    if (i >= b.len) return null;
    const x = b[i] >> 4;
    var hdr: usize = 1;
    var len: usize = x;
    switch (x) {
        0...11 => {},
        12 => {
            if (i + 1 >= b.len) return null;
            len = b[i + 1];
            hdr = 2;
        },
        13 => {
            if (i + 2 >= b.len) return null;
            len = std.mem.readInt(u16, b[i + 1 ..][0..2], .big);
            hdr = 3;
        },
        14 => {
            if (i + 4 >= b.len) return null;
            len = std.mem.readInt(u32, b[i + 1 ..][0..4], .big);
            hdr = 5;
        },
        else => {
            // SQLite reads no size above 32 bits.
            if (i + 8 >= b.len or b[i + 1] != 0 or b[i + 2] != 0 or b[i + 3] != 0 or b[i + 4] != 0) return null;
            len = std.mem.readInt(u32, b[i + 5 ..][0..4], .big);
            hdr = 9;
        },
    }
    if (i + hdr + len > b.len) return null;
    return .{ .typ = b[i] & 0x0f, .hdr = hdr, .len = len };
}

/// The payload of node `n` at b[i].
pub fn payload(b: []const u8, i: usize, n: Node) []const u8 {
    return b[i + n.hdr ..][0..n.len];
}

/// A child of a container: where its node starts, and the node.
pub const Child = struct {
    at: usize,
    n: Node,

    /// The child's node (header and payload).
    pub fn bytes(c: Child, b: []const u8) []const u8 {
        return b[c.at..][0..c.n.size()];
    }

    pub fn body(c: Child, b: []const u8) []const u8 {
        return payload(b, c.at, c.n);
    }
};

/// The children of a container, in order (of an object: key, value, key
/// ...). Stops at a node that does not fit.
pub const Children = struct {
    b: []const u8,
    i: usize,
    end: usize,

    pub fn next(it: *Children) ?Child {
        if (it.i >= it.end) return null;
        const n = node(it.b[0..it.end], it.i) orelse return null;
        const c: Child = .{ .at = it.i, .n = n };
        it.i += n.size();
        return c;
    }
};

/// The children of container `n` at b[i].
pub fn children(b: []const u8, i: usize, n: Node) Children {
    return .{ .b = b, .i = i + n.hdr, .end = i + n.size() };
}

/// The size of the smallest header of a payload of `len` bytes.
pub fn headerSize(len: usize) usize {
    if (len <= 11) return 1;
    if (len <= 0xff) return 2;
    if (len <= 0xffff) return 3;
    return 5;
}

/// Append the smallest header of a node of type `typ` and a payload of
/// `len` bytes.
pub fn appendHeader(a: Allocator, out: *std.ArrayList(u8), typ: u8, len: usize) Allocator.Error!void {
    if (len <= 11) return out.append(a, @as(u8, @intCast(len << 4)) | typ);
    if (len <= 0xff) return out.appendSlice(a, &.{ 0xc0 | typ, @intCast(len) });
    if (len <= 0xffff) {
        try out.append(a, 0xd0 | typ);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(len), .big);
        return out.appendSlice(a, &buf);
    }
    try out.append(a, 0xe0 | typ);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(len), .big);
    try out.appendSlice(a, &buf);
}

// ============================================================== validity

/// Whether `b` is one JSONB value and nothing more, as json_valid(b, 8)
/// (jsonbValidityCheck()) says: a blob that is the bytes of JSON text
/// is not.
pub fn valid(b: []const u8) bool {
    const n = node(b, 0) orelse return false;
    if (n.size() != b.len) return false;
    return check(b, 0, n, 0);
}

fn check(b: []const u8, i: usize, n: Node, depth: usize) bool {
    if (depth > max_depth) return false;
    const z = payload(b, i, n);
    switch (n.typ) {
        NULL, TRUE, FALSE => return n.size() == 1,
        INT => {
            var s = z;
            if (s.len > 0 and s[0] == '-') s = s[1..];
            if (s.len == 0) return false;
            for (s) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        },
        INT5 => {
            var s = z;
            if (s.len > 0 and s[0] == '-') s = s[1..];
            if (s.len < 3 or s[0] != '0' or (s[1] != 'x' and s[1] != 'X')) return false;
            for (s[2..]) |c| if (!std.ascii.isHex(c)) return false;
            return true;
        },
        FLOAT, FLOAT5 => return checkFloat(z, n.typ == FLOAT),
        TEXT => {
            for (z) |c| if (c < 0x20 or c == '"' or c == '\\') return false;
            return true;
        },
        TEXTJ, TEXT5 => return checkEscaped(z, n.typ == TEXT5),
        TEXTRAW => return true,
        ARRAY, OBJECT => {
            var it = children(b, i, n);
            var k: usize = 0;
            while (it.i < it.end) : (k += 1) {
                const c = it.next() orelse return false;
                if (n.typ == OBJECT and k % 2 == 0 and !c.n.isText()) return false;
                if (!check(b, c.at, c.n, depth + 1)) return false;
            }
            return n.typ == ARRAY or k % 2 == 0;
        },
        else => return false,
    }
}

/// jsonbValidityCheck()'s FLOAT/FLOAT5 (`strict`: FLOAT).
fn checkFloat(z: []const u8, strict: bool) bool {
    if (z.len < 2) return false;
    var j: usize = 0;
    const k = z.len;
    // 0: initial, 1: '.' seen, 2: 'e' seen.
    var seen: u8 = 0;
    if (z[j] == '-') {
        j += 1;
        if (z.len < 3) return false;
    }
    if (z[j] == '.') {
        if (strict) return false;
        if (j + 1 >= k or !std.ascii.isDigit(z[j + 1])) return false;
        j += 2;
        seen = 1;
    } else if (z[j] == '0' and strict) {
        if (j + 3 > k) return false;
        if (z[j + 1] != '.' and z[j + 1] != 'e' and z[j + 1] != 'E') return false;
        j += 1;
    }
    while (j < k) : (j += 1) {
        const c = z[j];
        if (std.ascii.isDigit(c)) continue;
        if (c == '.') {
            if (seen > 0) return false;
            if (strict and (j == k - 1 or !std.ascii.isDigit(z[j + 1]))) return false;
            seen = 1;
            continue;
        }
        if (c == 'e' or c == 'E') {
            if (seen == 2) return false;
            if (j == k - 1) return false;
            if (z[j + 1] == '+' or z[j + 1] == '-') {
                j += 1;
                if (j == k - 1) return false;
            }
            seen = 2;
            continue;
        }
        return false;
    }
    return seen != 0;
}

/// jsonbValidityCheck()'s TEXTJ/TEXT5 (`json5`: TEXT5).
fn checkEscaped(z: []const u8, json5: bool) bool {
    var j: usize = 0;
    while (j < z.len) : (j += 1) {
        const c = z[j];
        if (c >= 0x20 and c != '"' and c != '\\') continue;
        if (c == '"') {
            if (!json5) return false;
            continue;
        }
        if (c < 0x20) {
            if (!json5) return false;
            continue;
        }
        // A backslash.
        if (j + 1 >= z.len) return false;
        const e = z[j + 1];
        if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", e) != null or e == 0) {
            j += 1;
        } else if (e == 'u') {
            if (j + 5 >= z.len) return false;
            for (z[j + 2 .. j + 6]) |h| if (!std.ascii.isHex(h)) return false;
            j += 1;
        } else if (!json5) {
            return false;
        } else {
            const r = unescapeOne(z[j..]);
            if (r.cp == invalid_char) return false;
            j += r.len - 1;
        }
    }
    return true;
}

// ======================================================== strings, numbers

/// unescapeOne()'s code point of an invalid escape.
const invalid_char: u32 = 0x110000;

const Unescaped = struct { cp: u32, len: usize, none: bool = false };

/// The escape at z[0] ('\\'), as jsonUnescapeOneChar() reads it: its code
/// point and length; `none` for a line continuation of nothing.
fn unescapeOne(z: []const u8) Unescaped {
    if (z.len < 2) return .{ .cp = invalid_char, .len = z.len };
    switch (z[1]) {
        'u' => {
            if (z.len < 6) return .{ .cp = invalid_char, .len = z.len };
            const v = hex4(z[2..6]) orelse return .{ .cp = invalid_char, .len = 6 };
            if (v & 0xfc00 == 0xd800 and z.len >= 12 and z[6] == '\\' and z[7] == 'u') {
                if (hex4(z[8..12])) |lo| if (lo & 0xfc00 == 0xdc00) {
                    return .{ .cp = ((v & 0x3ff) << 10) + (lo & 0x3ff) + 0x10000, .len = 12 };
                };
            }
            return .{ .cp = v, .len = 6 };
        },
        'b' => return .{ .cp = 8, .len = 2 },
        'f' => return .{ .cp = 12, .len = 2 },
        'n' => return .{ .cp = '\n', .len = 2 },
        'r' => return .{ .cp = '\r', .len = 2 },
        't' => return .{ .cp = '\t', .len = 2 },
        'v' => return .{ .cp = 0x0b, .len = 2 },
        '0' => return .{ .cp = if (z.len > 2 and std.ascii.isDigit(z[2])) invalid_char else 0, .len = 2 },
        '\'', '"', '/', '\\' => return .{ .cp = z[1], .len = 2 },
        'x' => {
            if (z.len < 4 or !std.ascii.isHex(z[2]) or !std.ascii.isHex(z[3])) return .{ .cp = invalid_char, .len = @min(z.len, 4) };
            return .{ .cp = (hexVal(z[2]) << 4) | hexVal(z[3]), .len = 4 };
        },
        0xe2, '\r', '\n' => {
            // Line continuations: a backslash and a line end.
            var i: usize = 0;
            while (i + 1 < z.len and z[i] == '\\') {
                if (z[i + 1] == '\n') {
                    i += 2;
                } else if (z[i + 1] == '\r') {
                    i += if (i + 2 < z.len and z[i + 2] == '\n') 3 else 2;
                } else if (z[i + 1] == 0xe2 and i + 3 < z.len and z[i + 2] == 0x80 and (z[i + 3] == 0xa8 or z[i + 3] == 0xa9)) {
                    i += 4;
                } else break;
            }
            if (i == 0) return .{ .cp = invalid_char, .len = z.len };
            if (i == z.len) return .{ .cp = 0, .len = i, .none = true };
            if (z[i] == '\\') {
                const r = unescapeOne(z[i..]);
                return .{ .cp = r.cp, .len = i + r.len, .none = r.none };
            }
            const n = std.unicode.utf8ByteSequenceLength(z[i]) catch 1;
            if (i + n > z.len) return .{ .cp = z[i], .len = i + 1 };
            const cp = std.unicode.utf8Decode(z[i..][0..n]) catch z[i];
            return .{ .cp = cp, .len = i + n };
        },
        else => return .{ .cp = invalid_char, .len = 2 },
    }
}

fn hexVal(c: u8) u32 {
    return std.fmt.charToDigit(c, 16) catch 0;
}

fn hex4(z: []const u8) ?u32 {
    return std.fmt.parseInt(u32, z, 16) catch null;
}

/// The string of a text node of type `typ` and payload `z`, decoded:
/// `z` itself for TEXT and TEXTRAW.
pub fn string(a: Allocator, typ: u8, z: []const u8) Allocator.Error![]const u8 {
    if (typ == TEXT or typ == TEXTRAW or std.mem.indexOfScalar(u8, z, '\\') == null) return z;
    var out: std.ArrayList(u8) = try .initCapacity(a, z.len);
    var i: usize = 0;
    while (i < z.len) {
        if (z[i] != '\\') {
            out.appendAssumeCapacity(z[i]);
            i += 1;
            continue;
        }
        const r = unescapeOne(z[i..]);
        i += r.len;
        if (r.none) continue;
        const cp: u21 = if (r.cp >= 0x110000 or (r.cp >= 0xd800 and r.cp <= 0xdfff)) 0xfffd else @intCast(r.cp);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

/// The RFC 8259 text of a number node of type `typ` and payload `z`
/// (`z` itself for INT and FLOAT); null for NaN, which SQLite reads as
/// null. Infinity is 9e999, as SQLite writes it.
pub fn number(a: Allocator, typ: u8, z: []const u8) Allocator.Error!?[]const u8 {
    switch (typ) {
        INT, FLOAT => return z,
        INT5 => {
            const neg = z.len > 0 and z[0] == '-';
            const digits = z[@as(usize, @intFromBool(neg)) + 2 ..];
            // The hex digits as decimal, of any length.
            var dec: std.ArrayList(u8) = .empty; // least significant first
            try dec.append(a, 0);
            for (digits) |h| {
                var carry: u32 = hexVal(h);
                for (dec.items) |*d| {
                    const v = @as(u32, d.*) * 16 + carry;
                    d.* = @intCast(v % 10);
                    carry = v / 10;
                }
                while (carry > 0) {
                    try dec.append(a, @intCast(carry % 10));
                    carry /= 10;
                }
            }
            while (dec.items.len > 1 and dec.items[dec.items.len - 1] == 0) dec.items.len -= 1;
            var out: std.ArrayList(u8) = try .initCapacity(a, dec.items.len + 1);
            if (neg and !(dec.items.len == 1 and dec.items[0] == 0)) out.appendAssumeCapacity('-');
            var k = dec.items.len;
            while (k > 0) {
                k -= 1;
                out.appendAssumeCapacity('0' + dec.items[k]);
            }
            return out.items;
        },
        else => {
            var s = z;
            var neg = false;
            if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
                neg = s[0] == '-';
                s = s[1..];
            }
            if (std.ascii.startsWithIgnoreCase(s, "inf")) return if (neg) "-9e999" else "9e999";
            if (std.ascii.startsWithIgnoreCase(s, "nan")) return null;
            var out: std.ArrayList(u8) = try .initCapacity(a, s.len + 3);
            if (neg) out.appendAssumeCapacity('-');
            if (s.len > 0 and s[0] == '.') out.appendAssumeCapacity('0');
            for (s, 0..) |c, i| {
                out.appendAssumeCapacity(c);
                // "5." and "5.e3": a digit after the point.
                if (c == '.' and (i + 1 == s.len or !std.ascii.isDigit(s[i + 1]))) out.appendAssumeCapacity('0');
            }
            return out.items;
        },
    }
}

// ================================================================ text

/// Append the JSON text of the JSONB value `b` (valid()) with
/// PostgreSQL's jsonb spacing (`{"a": 1, "b": [1, 2]}`): the value as
/// stored, keys in their order. Of a canonical value it is jsonb's
/// output (postgres/json.zig writeJsonb()).
pub fn appendText(a: Allocator, out: *std.ArrayList(u8), b: []const u8) Allocator.Error!void {
    const n = node(b, 0) orelse return;
    try writeNode(a, out, b, 0, n);
}

fn writeNode(a: Allocator, out: *std.ArrayList(u8), b: []const u8, i: usize, n: Node) Allocator.Error!void {
    const z = payload(b, i, n);
    switch (n.typ) {
        NULL => try out.appendSlice(a, "null"),
        TRUE => try out.appendSlice(a, "true"),
        FALSE => try out.appendSlice(a, "false"),
        INT, INT5, FLOAT, FLOAT5 => try out.appendSlice(a, (try number(a, n.typ, z)) orelse "null"),
        TEXT, TEXTJ, TEXT5, TEXTRAW => try json_text.appendQuoted(.{ .keep_u0000 = true }, a, out, try string(a, n.typ, z)),
        ARRAY => {
            try out.append(a, '[');
            var it = children(b, i, n);
            var k: usize = 0;
            while (it.next()) |c| : (k += 1) {
                if (k > 0) try out.appendSlice(a, ", ");
                try writeNode(a, out, b, c.at, c.n);
            }
            try out.append(a, ']');
        },
        OBJECT => {
            try out.append(a, '{');
            var it = children(b, i, n);
            var k: usize = 0;
            while (it.next()) |c| : (k += 1) {
                if (k % 2 == 1) {
                    try out.appendSlice(a, ": ");
                } else if (k > 0) try out.appendSlice(a, ", ");
                try writeNode(a, out, b, c.at, c.n);
            }
            try out.append(a, '}');
        },
        else => {},
    }
}

/// The text of JSONB value `b` (appendText()) in memory of `gpa`, null
/// if `b` is not one.
pub fn text(gpa: Allocator, b: []const u8) Allocator.Error!?[]u8 {
    if (!valid(b)) return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try appendText(arena.allocator(), &out, b);
    return try gpa.dupe(u8, out.items);
}

// ================================================================= tests

test "jsonb: nodes, validity, text" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // {"a":[1,"x"],"b":null} as SQLite's jsonb() writes it.
    const b = "\xac\x17a\x4b\x131\x17x\x17b\x00";
    try t.expect(valid(b));
    try t.expectEqualStrings("{\"a\": [1, \"x\"], \"b\": null}", (try text(a, b)).?);
    // The bytes of JSON text are not JSONB.
    for ([_][]const u8{ "{}", "[1,2]", "\"a\"", "1", "", "\x13", "\x23-", "\x11" }) |bad| try t.expect(!valid(bad));
    // JSON5 and escapes.
    try t.expectEqualStrings("[255, -16, 0.5, 2.0, 9e999, \"a\\n\\u0001\u{e9}\"]", (try text(a, "\xcb\x28" ++ "\x440xff" ++ "\x54-0x10" ++ "\x26.5" ++ "\x262." ++ "\x559e999" ++ "\xc9\x0fa\\n\\x01\\u00e9\\\n")).?);
    // A larger header than needed.
    try t.expectEqualStrings("[true]", (try text(a, "\xcb\x01\x01")).?);
    var out: std.ArrayList(u8) = .empty;
    try appendHeader(a, &out, ARRAY, 300);
    try t.expectEqualSlices(u8, "\xdb\x01\x2c", out.items);
    try t.expectEqual(@as(usize, 3), headerSize(300));
    try t.expectEqual(@as(usize, 1), headerSize(11));
}
