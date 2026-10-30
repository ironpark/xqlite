//! JSON values as PostgreSQL's json and jsonb types see them, for the
//! functions of jfuncs.zig.
//!
//!  - json is the text as written: parse() checks it as PostgreSQL's
//!    json input does (RFC 8259: no comments, no trailing commas,
//!    `\u0000` allowed), and every Value keeps its `raw` text, so that
//!    `->`, json_each() ... return what was written (whitespace,
//!    duplicate keys, key order).
//!  - jsonb is the value normalized (normalize()): object keys sorted by
//!    length, then bytes, a duplicate key's last value kept, numbers as
//!    numeric_out() spells them (1e2 is 100, 1.50 stays 1.50), written
//!    by writeJsonb() with PostgreSQL's spacing (`{"a": 1, "b": [1, 2]}`)
//!    and by writePretty() as jsonb_pretty() does.
//!
//! Also: jsonb comparison (compare(): Object > Array > Boolean > Number
//! > String > Null, containers by size first), containment (contains(),
//! `@>`), PostgreSQL's text[] literals (parseTextArray(), '{a,b}').

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Invalid: not json; UnicodeEscape: `\u0000`, which jsonb cannot hold.
pub const Error = error{ Invalid, UnicodeEscape, OutOfMemory };

pub const Value = struct {
    v: Kind,
    /// The text of the value as written (json); empty for a value that
    /// was built.
    raw: []const u8 = "",

    pub fn typeName(x: Value) []const u8 {
        return switch (x.v) {
            .null => "null",
            .bool => "boolean",
            .number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    pub fn isScalar(x: Value) bool {
        return x.v != .array and x.v != .object;
    }

    /// The value of key `k` of an object (the last one with that key).
    pub fn get(x: Value, k: []const u8) ?Value {
        if (x.v != .object) return null;
        var found: ?Value = null;
        for (x.v.object) |p| if (std.mem.eql(u8, p.key, k)) {
            found = p.value;
        };
        return found;
    }

    /// Element `i` of an array, from the end if negative.
    pub fn at(x: Value, i: i64) ?Value {
        if (x.v != .array) return null;
        const n: i64 = @intCast(x.v.array.len);
        const k = if (i < 0) n + i else i;
        if (k < 0 or k >= n) return null;
        return x.v.array[@intCast(k)];
    }
};

pub const Kind = union(enum) {
    null,
    bool: bool,
    /// The number as written (json) or as numeric_out() writes it
    /// (normalized).
    number: []const u8,
    /// Decoded.
    string: []const u8,
    array: []Value,
    object: []Pair,
};

pub const Pair = struct {
    key: []const u8,
    value: Value,
};

pub const null_value: Value = .{ .v = .null };

// ================================================================ parsing

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    jsonb: bool,
    depth: u32 = 0,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        };
    }

    fn value(p: *Parser) Error!Value {
        p.ws();
        if (p.i >= p.s.len) return error.Invalid;
        const start = p.i;
        const c = p.s[p.i];
        var v: Kind = undefined;
        switch (c) {
            '{' => {
                p.depth += 1;
                if (p.depth > 6400) return error.Invalid;
                p.i += 1;
                var pairs: std.ArrayList(Pair) = .empty;
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == '}') {
                    p.i += 1;
                } else while (true) {
                    p.ws();
                    if (p.i >= p.s.len or p.s[p.i] != '"') return error.Invalid;
                    const k = try p.string();
                    p.ws();
                    if (p.i >= p.s.len or p.s[p.i] != ':') return error.Invalid;
                    p.i += 1;
                    const x = try p.value();
                    try pairs.append(p.a, .{ .key = k, .value = x });
                    p.ws();
                    if (p.i >= p.s.len) return error.Invalid;
                    if (p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.s[p.i] != '}') return error.Invalid;
                    p.i += 1;
                    break;
                }
                p.depth -= 1;
                v = .{ .object = pairs.items };
            },
            '[' => {
                p.depth += 1;
                if (p.depth > 6400) return error.Invalid;
                p.i += 1;
                var items: std.ArrayList(Value) = .empty;
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == ']') {
                    p.i += 1;
                } else while (true) {
                    try items.append(p.a, try p.value());
                    p.ws();
                    if (p.i >= p.s.len) return error.Invalid;
                    if (p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.s[p.i] != ']') return error.Invalid;
                    p.i += 1;
                    break;
                }
                p.depth -= 1;
                v = .{ .array = items.items };
            },
            '"' => v = .{ .string = try p.string() },
            '-', '0'...'9' => v = .{ .number = try p.number() },
            else => {
                inline for (.{ .{ "true", Kind{ .bool = true } }, .{ "false", Kind{ .bool = false } }, .{ "null", Kind.null } }) |w| {
                    if (std.mem.startsWith(u8, p.s[p.i..], w[0])) {
                        const e = p.i + w[0].len;
                        if (e >= p.s.len or !isWordChar(p.s[e])) {
                            p.i = e;
                            return .{ .v = w[1], .raw = p.s[start..p.i] };
                        }
                    }
                }
                return error.Invalid;
            },
        }
        return .{ .v = v, .raw = p.s[start..p.i] };
    }

    fn number(p: *Parser) Error![]const u8 {
        const s = p.s;
        const start = p.i;
        var i = p.i;
        if (s[i] == '-') i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return error.Invalid;
        if (s[i] == '0') {
            i += 1;
        } else {
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        if (i < s.len and s[i] == '.') {
            i += 1;
            if (i >= s.len or !std.ascii.isDigit(s[i])) return error.Invalid;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            if (i >= s.len or !std.ascii.isDigit(s[i])) return error.Invalid;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        if (i < s.len and isWordChar(s[i])) return error.Invalid;
        p.i = i;
        return s[start..i];
    }

    /// A string at `"`, decoded.
    fn string(p: *Parser) Error![]const u8 {
        const s = p.s;
        p.i += 1;
        const start = p.i;
        var plain = true;
        var i = p.i;
        while (true) : (i += 1) {
            if (i >= s.len) return error.Invalid;
            const c = s[i];
            if (c == '"') break;
            if (c < 0x20) return error.Invalid;
            if (c == '\\') {
                plain = false;
                i += 1;
                if (i >= s.len) return error.Invalid;
            }
        }
        if (plain) {
            p.i = i + 1;
            return s[start..i];
        }
        var out: std.ArrayList(u8) = .empty;
        var k = start;
        while (k < i) {
            const c = s[k];
            if (c != '\\') {
                try out.append(p.a, c);
                k += 1;
                continue;
            }
            k += 1;
            const e = s[k];
            k += 1;
            switch (e) {
                '"', '\\', '/' => try out.append(p.a, e),
                'b' => try out.append(p.a, 8),
                'f' => try out.append(p.a, 12),
                'n' => try out.append(p.a, '\n'),
                'r' => try out.append(p.a, '\r'),
                't' => try out.append(p.a, '\t'),
                'u' => {
                    var cp: u21 = try hex4(s, k);
                    k += 4;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (k + 6 > i or s[k] != '\\' or s[k + 1] != 'u') return error.Invalid;
                        const lo = try hex4(s, k + 2);
                        if (lo < 0xDC00 or lo > 0xDFFF) return error.Invalid;
                        k += 6;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) return error.Invalid;
                    if (cp == 0) {
                        // jsonb cannot hold it; json keeps "\u0000".
                        if (p.jsonb) return error.UnicodeEscape;
                        try out.appendSlice(p.a, "\\u0000");
                        continue;
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.Invalid;
                    try out.appendSlice(p.a, buf[0..n]);
                },
                else => return error.Invalid,
            }
        }
        p.i = i + 1;
        return out.items;
    }
};

fn hex4(s: []const u8, k: usize) Error!u21 {
    if (k + 4 > s.len) return error.Invalid;
    return std.fmt.parseInt(u21, s[k .. k + 4], 16) catch error.Invalid;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Parse `text` as json (`jsonb` false: values keep their text) or as
/// jsonb input (then normalize() the result).
pub fn parse(a: Allocator, text: []const u8, jsonb: bool) Error!Value {
    var p: Parser = .{ .a = a, .s = text, .jsonb = jsonb };
    const v = try p.value();
    p.ws();
    if (p.i != text.len) return error.Invalid;
    return v;
}

/// Parse `text` as jsonb: parsed and normalized.
pub fn parseJsonb(a: Allocator, text: []const u8) Error!Value {
    var v = try parse(a, text, true);
    try normalize(a, &v);
    return v;
}

/// Whether `text` is json: how json_valid() would say it, but by
/// PostgreSQL's rules.
pub fn valid(a: Allocator, text: []const u8) bool {
    _ = parse(a, text, false) catch return false;
    return true;
}

// ========================================================= normalization

fn keyLess(_: void, x: Pair, y: Pair) bool {
    return keyOrder(x.key, y.key) == .lt;
}

/// jsonb's order of keys: shorter first, then by bytes.
pub fn keyOrder(x: []const u8, y: []const u8) std.math.Order {
    if (x.len != y.len) return std.math.order(x.len, y.len);
    return std.mem.order(u8, x, y);
}

/// Make `v` a jsonb value: keys sorted, duplicates removed (the last one
/// stays), numbers normalized; `raw` is dropped.
pub fn normalize(a: Allocator, v: *Value) Error!void {
    v.raw = "";
    switch (v.v) {
        .number => |n| v.v = .{ .number = try numericOut(a, n) },
        .array => |items| for (items) |*x| try normalize(a, x),
        .object => |pairs| {
            for (pairs) |*pp| try normalize(a, &pp.value);
            std.mem.sort(Pair, pairs, {}, keyLess);
            // The sort is stable: of equal keys the last one stays.
            var n: usize = 0;
            for (pairs, 0..) |pp, i| {
                if (i + 1 < pairs.len and std.mem.eql(u8, pairs[i + 1].key, pp.key)) continue;
                pairs[n] = pp;
                n += 1;
            }
            v.v = .{ .object = pairs[0..n] };
        },
        else => {},
    }
}

/// A JSON number as numeric_out() writes it: no exponent, the scale of
/// the input (1.50 is 1.50, 1e2 is 100, 1.5e-3 is 0.0015), no negative
/// zero.
pub fn numericOut(a: Allocator, text: []const u8) Error![]const u8 {
    var s = text;
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var mant_end: usize = 0;
    while (mant_end < s.len and s[mant_end] != 'e' and s[mant_end] != 'E') mant_end += 1;
    var exp: i64 = 0;
    if (mant_end < s.len) exp = std.fmt.parseInt(i64, s[mant_end + 1 ..], 10) catch return error.Invalid;
    const mant = s[0..mant_end];
    const dot = std.mem.indexOfScalar(u8, mant, '.');
    const ip = if (dot) |d| mant[0..d] else mant;
    const fp = if (dot) |d| mant[d + 1 ..] else "";
    if (exp > 100000 or exp < -100000) return error.Invalid;
    // Fast path: already normalized.
    if (exp == 0 and mant_end == s.len and (ip.len <= 1 or ip[0] != '0') and !(neg and allZero(ip) and allZero(fp))) return text;
    const fp_len: i64 = @intCast(fp.len);
    const scale: usize = @intCast(@max(0, fp_len - exp));
    // The digits, the point after `point` of them.
    var digits: std.ArrayList(u8) = .empty;
    try digits.appendSlice(a, ip);
    try digits.appendSlice(a, fp);
    var point: i64 = @as(i64, @intCast(ip.len)) + exp;
    var out: std.ArrayList(u8) = .empty;
    if (point < 0) {
        const pad: usize = @intCast(-point);
        try digits.insertSlice(a, 0, try zeros(a, pad));
        point = 0;
    }
    const pt: usize = @intCast(point);
    if (pt > digits.items.len) try digits.appendSlice(a, try zeros(a, pt - digits.items.len));
    var int_part: []const u8 = digits.items[0..pt];
    while (int_part.len > 1 and int_part[0] == '0') int_part = int_part[1..];
    if (int_part.len == 0) int_part = "0";
    var frac: []const u8 = digits.items[pt..];
    if (frac.len > scale) frac = frac[0..scale];
    if (neg and !(allZero(int_part) and allZero(frac))) try out.append(a, '-');
    try out.appendSlice(a, int_part);
    if (scale > 0) {
        try out.append(a, '.');
        try out.appendSlice(a, frac);
        if (frac.len < scale) try out.appendSlice(a, try zeros(a, scale - frac.len));
    }
    return out.items;
}

fn allZero(s: []const u8) bool {
    for (s) |c| if (c != '0') return false;
    return true;
}

fn zeros(a: Allocator, n: usize) Error![]u8 {
    const z = try a.alloc(u8, n);
    @memset(z, '0');
    return z;
}

// ================================================================ writing

/// A string as PostgreSQL's escape_json() writes it.
pub fn writeString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => {
                // "\u0000" kept by json input stays as written.
                if (std.mem.startsWith(u8, s[i..], "\\u0000")) {
                    try out.appendSlice(a, "\\u0000");
                    i += 5;
                } else try out.appendSlice(a, "\\\\");
            },
            8 => try out.appendSlice(a, "\\b"),
            12 => try out.appendSlice(a, "\\f"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => if (c < 0x20) {
                try out.print(a, "\\u{x:0>4}", .{c});
            } else try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

/// jsonb's output: `{"a": 1, "b": [1, 2]}`.
pub fn writeJsonb(a: Allocator, out: *std.ArrayList(u8), v: Value) Error!void {
    switch (v.v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .number => |n| try out.appendSlice(a, n),
        .string => |s| try writeString(a, out, s),
        .array => |items| {
            try out.append(a, '[');
            for (items, 0..) |x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeJsonb(a, out, x);
            }
            try out.append(a, ']');
        },
        .object => |pairs| {
            try out.append(a, '{');
            for (pairs, 0..) |pp, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeString(a, out, pp.key);
                try out.appendSlice(a, ": ");
                try writeJsonb(a, out, pp.value);
            }
            try out.append(a, '}');
        },
    }
}

/// json's output of a value: its text as written, else as built
/// without spaces (`{"a":1}`, what PostgreSQL's json functions build
/// from json input: json_strip_nulls()).
pub fn writeJson(a: Allocator, out: *std.ArrayList(u8), v: Value) Error!void {
    if (v.raw.len > 0) return out.appendSlice(a, v.raw);
    switch (v.v) {
        .array => |items| {
            try out.append(a, '[');
            for (items, 0..) |x, i| {
                if (i > 0) try out.append(a, ',');
                try writeJson(a, out, x);
            }
            try out.append(a, ']');
        },
        .object => |pairs| {
            try out.append(a, '{');
            for (pairs, 0..) |pp, i| {
                if (i > 0) try out.append(a, ',');
                try writeString(a, out, pp.key);
                try out.append(a, ':');
                try writeJson(a, out, pp.value);
            }
            try out.append(a, '}');
        },
        else => try writeJsonb(a, out, v),
    }
}

/// jsonb_pretty(): four spaces a level, one element a line.
pub fn writePretty(a: Allocator, out: *std.ArrayList(u8), v: Value, level: usize) Error!void {
    // An empty container has its brackets on two lines too.
    switch (v.v) {
        .array => |items| {
            try out.append(a, '[');
            for (items, 0..) |x, i| {
                if (i > 0) try out.append(a, ',');
                try newline(a, out, level + 1);
                try writePretty(a, out, x, level + 1);
            }
            try newline(a, out, level);
            try out.append(a, ']');
        },
        .object => |pairs| {
            try out.append(a, '{');
            for (pairs, 0..) |pp, i| {
                if (i > 0) try out.append(a, ',');
                try newline(a, out, level + 1);
                try writeString(a, out, pp.key);
                try out.appendSlice(a, ": ");
                try writePretty(a, out, pp.value, level + 1);
            }
            try newline(a, out, level);
            try out.append(a, '}');
        },
        else => try writeJsonb(a, out, v),
    }
}

fn newline(a: Allocator, out: *std.ArrayList(u8), level: usize) Error!void {
    try out.append(a, '\n');
    for (0..level) |_| try out.appendSlice(a, "    ");
}

/// The text of `v`: json's (as written) or jsonb's.
pub fn toText(a: Allocator, v: Value, jsonb: bool) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (jsonb) try writeJsonb(a, &out, v) else try writeJson(a, &out, v);
    return out.items;
}

/// What `->>` makes of a value: a string unquoted, null NULL, the rest
/// its text.
pub fn toSqlText(a: Allocator, v: Value, jsonb: bool) Error!?[]const u8 {
    return switch (v.v) {
        .null => null,
        .string => |s| s,
        else => try toText(a, v, jsonb),
    };
}

// ============================================================ comparison

/// Compare two JSON numbers by value.
pub fn numCompare(x: []const u8, y: []const u8) std.math.Order {
    var buf: [2]std.heap.FixedBufferAllocator = undefined;
    var mem: [2][256]u8 = undefined;
    buf[0] = .init(&mem[0]);
    buf[1] = .init(&mem[1]);
    const nx = numericOut(buf[0].allocator(), x) catch x;
    const ny = numericOut(buf[1].allocator(), y) catch y;
    if (nx.len > 200 or ny.len > 200) {
        const fx = std.fmt.parseFloat(f64, x) catch 0;
        const fy = std.fmt.parseFloat(f64, y) catch 0;
        return std.math.order(fx, fy);
    }
    const negx = nx[0] == '-';
    const negy = ny[0] == '-';
    if (negx != negy) return if (negx) .lt else .gt;
    const ax = if (negx) nx[1..] else nx;
    const ay = if (negy) ny[1..] else ny;
    const o = absCompare(ax, ay);
    return if (negx) o.invert() else o;
}

fn absCompare(x: []const u8, y: []const u8) std.math.Order {
    const ix = std.mem.indexOfScalar(u8, x, '.') orelse x.len;
    const iy = std.mem.indexOfScalar(u8, y, '.') orelse y.len;
    if (ix != iy) return std.math.order(ix, iy);
    const o = std.mem.order(u8, x[0..ix], y[0..iy]);
    if (o != .eq) return o;
    const fx = if (ix < x.len) x[ix + 1 ..] else "";
    const fy = if (iy < y.len) y[iy + 1 ..] else "";
    const n = @max(fx.len, fy.len);
    for (0..n) |k| {
        const cx: u8 = if (k < fx.len) fx[k] else '0';
        const cy: u8 = if (k < fy.len) fy[k] else '0';
        if (cx != cy) return std.math.order(cx, cy);
    }
    return .eq;
}

fn rank(v: Value) u8 {
    return switch (v.v) {
        .null => 0,
        .string => 1,
        .number => 2,
        .bool => 3,
        .array => 4,
        .object => 5,
    };
}

/// jsonb's order (jsonb comparison operators, ORDER BY): Object > Array
/// > Boolean > Number > String > Null; containers with more items are
/// greater, else compared item by item (objects key, value, key ...
/// in their sorted order). The values are normalized.
pub fn compare(x: Value, y: Value) std.math.Order {
    const rx = rank(x);
    const ry = rank(y);
    if (rx != ry) return std.math.order(rx, ry);
    switch (x.v) {
        .null => return .eq,
        .bool => |b| return std.math.order(@intFromBool(b), @intFromBool(y.v.bool)),
        .number => |n| return numCompare(n, y.v.number),
        .string => |s| return std.mem.order(u8, s, y.v.string),
        .array => |items| {
            const other = y.v.array;
            if (items.len != other.len) return std.math.order(items.len, other.len);
            for (items, other) |p, q| {
                const o = compare(p, q);
                if (o != .eq) return o;
            }
            return .eq;
        },
        .object => |pairs| {
            const other = y.v.object;
            if (pairs.len != other.len) return std.math.order(pairs.len, other.len);
            for (pairs, other) |p, q| {
                var o = std.mem.order(u8, p.key, q.key);
                if (o != .eq) return o;
                o = compare(p.value, q.value);
                if (o != .eq) return o;
            }
            return .eq;
        },
    }
}

pub fn equal(x: Value, y: Value) bool {
    return compare(x, y) == .eq;
}

/// `x @> y` (normalized values).
pub fn contains(x: Value, y: Value) bool {
    // A top-level array contains a scalar it has as an element.
    if (x.v == .array and y.isScalar()) {
        for (x.v.array) |e| if (e.isScalar() and equal(e, y)) return true;
        return false;
    }
    return deepContains(x, y);
}

fn deepContains(x: Value, y: Value) bool {
    switch (y.v) {
        .object => |pairs| {
            if (x.v != .object) return false;
            for (pairs) |pp| {
                const lv = x.get(pp.key) orelse return false;
                if (pp.value.isScalar()) {
                    if (!lv.isScalar() or !equal(lv, pp.value)) return false;
                } else if (!deepContains(lv, pp.value)) return false;
            }
            return true;
        },
        .array => |items| {
            if (x.v != .array) return false;
            outer: for (items) |e| {
                for (x.v.array) |l| {
                    if (e.isScalar()) {
                        if (l.isScalar() and equal(l, e)) continue :outer;
                    } else if (std.meta.activeTag(l.v) == std.meta.activeTag(e.v) and deepContains(l, e)) continue :outer;
                }
                return false;
            }
            return true;
        },
        else => return x.isScalar() and equal(x, y),
    }
}

/// `x ? k`: a key of an object, a string element of an array, or the
/// string itself.
pub fn exists(x: Value, k: []const u8) bool {
    switch (x.v) {
        .object => return x.get(k) != null,
        .array => |items| {
            for (items) |e| if (e.v == .string and std.mem.eql(u8, e.v.string, k)) return true;
            return false;
        },
        .string => |s| return std.mem.eql(u8, s, k),
        else => return false,
    }
}

// =========================================================== text arrays

/// A PostgreSQL text[] literal ('{a,"b c",NULL}'): its elements, null
/// for NULL. error.Invalid if malformed.
pub fn parseTextArray(a: Allocator, text: []const u8) Error![]?[]const u8 {
    var out: std.ArrayList(?[]const u8) = .empty;
    var i: usize = 0;
    const s = text;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    // [1:2]={...} dimensions are not read.
    if (i >= s.len or s[i] != '{') return error.Invalid;
    i += 1;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i < s.len and s[i] == '}') {
        i += 1;
    } else while (true) {
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len) return error.Invalid;
        if (s[i] == '{') return error.Invalid; // multidimensional
        var elem: std.ArrayList(u8) = .empty;
        var quoted = false;
        if (s[i] == '"') {
            quoted = true;
            i += 1;
            while (true) {
                if (i >= s.len) return error.Invalid;
                if (s[i] == '"') break;
                if (s[i] == '\\') {
                    i += 1;
                    if (i >= s.len) return error.Invalid;
                }
                try elem.append(a, s[i]);
                i += 1;
            }
            i += 1;
            while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        } else {
            while (i < s.len and s[i] != ',' and s[i] != '}') {
                if (s[i] == '"' or s[i] == '{') return error.Invalid;
                if (s[i] == '\\') {
                    i += 1;
                    if (i >= s.len) return error.Invalid;
                }
                try elem.append(a, s[i]);
                i += 1;
            }
            const t = std.mem.trimEnd(u8, elem.items, " \t\r\n");
            elem.items.len = t.len;
            if (elem.items.len == 0) return error.Invalid;
        }
        if (!quoted and std.ascii.eqlIgnoreCase(elem.items, "null")) {
            try out.append(a, null);
        } else try out.append(a, elem.items);
        if (i >= s.len) return error.Invalid;
        if (s[i] == ',') {
            i += 1;
            continue;
        }
        if (s[i] != '}') return error.Invalid;
        i += 1;
        break;
    }
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i != s.len) return error.Invalid;
    return out.items;
}

/// An element of a text[] literal as array_out() writes it: quoted if
/// empty, NULL, or with blanks or `{},"\`.
pub fn writeArrayElem(a: Allocator, out: *std.ArrayList(u8), e: ?[]const u8) Error!void {
    const s = e orelse return out.appendSlice(a, "NULL");
    var quote = s.len == 0 or std.ascii.eqlIgnoreCase(s, "null");
    for (s) |c| if (std.mem.indexOfScalar(u8, "{},\"\\ \t\n\r\x0b\x0c", c) != null) {
        quote = true;
    };
    if (!quote) return out.appendSlice(a, s);
    try out.append(a, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

// ================================================================= tests

fn expectJsonb(input: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseJsonb(a, input);
    try std.testing.expectEqualStrings(want, try toText(a, v, true));
}

test "jsonb normalization" {
    try expectJsonb("{\"b\":1,\"a\":2,\"aa\":[1,2,{}],\"a\":3}", "{\"a\": 3, \"b\": 1, \"aa\": [1, 2, {}]}");
    try expectJsonb(" [ ] ", "[]");
    try expectJsonb("1e2", "100");
    try expectJsonb("1.50", "1.50");
    try expectJsonb("-0", "0");
    try expectJsonb("-0.0", "0.0");
    try expectJsonb("1.5e-3", "0.0015");
    try expectJsonb("12.5E1", "125");
    try expectJsonb("1.25e1", "12.5");
    try expectJsonb("0.000", "0.000");
    try expectJsonb("\"a\\u00e9\\n\\\"\\/\"", "\"a\u{e9}\\n\\\"/\"");
    try expectJsonb("\"\\ud83d\\ude00\"", "\"\u{1f600}\"");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "{", "[1,]", "01", "1.", "tru", "{\"a\" 1}", "\"\\x\"", "\"a\nb\"", "nul", "1 2", "+1", ".5" }) |bad| {
        try std.testing.expectError(error.Invalid, parse(a, bad, false));
    }
    try std.testing.expectError(error.UnicodeEscape, parse(a, "\"\\u0000\"", true));
    _ = try parse(a, "\"\\u0000\"", false);
    // json keeps the text.
    const j = try parse(a, "{\"b\" : [1,  2], \"a\":1}", false);
    try std.testing.expectEqualStrings("[1,  2]", j.get("b").?.raw);
}

test "jsonb comparison and containment" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = struct {
        fn v(al: Allocator, s: []const u8) !Value {
            return parseJsonb(al, s);
        }
    };
    try std.testing.expect(contains(try P.v(a, "{\"a\":1,\"b\":[1,2,3]}"), try P.v(a, "{\"b\":[3,1]}")));
    try std.testing.expect(!contains(try P.v(a, "{\"a\":1}"), try P.v(a, "{\"a\":2}")));
    try std.testing.expect(contains(try P.v(a, "[1,2]"), try P.v(a, "1")));
    try std.testing.expect(!contains(try P.v(a, "1"), try P.v(a, "[1]")));
    try std.testing.expect(!contains(try P.v(a, "[[1,2]]"), try P.v(a, "[1]")));
    try std.testing.expect(contains(try P.v(a, "[1,[2,3]]"), try P.v(a, "[[3]]")));
    try std.testing.expectEqual(std.math.Order.eq, compare(try P.v(a, "1.0"), try P.v(a, "1")));
    try std.testing.expectEqual(std.math.Order.lt, compare(try P.v(a, "\"z\""), try P.v(a, "1")));
    try std.testing.expectEqual(std.math.Order.gt, compare(try P.v(a, "{}"), try P.v(a, "[1,2]")));
    try std.testing.expectEqual(std.math.Order.lt, compare(try P.v(a, "-2.5"), try P.v(a, "-2")));
    try std.testing.expectEqual(std.math.Order.gt, compare(try P.v(a, "10"), try P.v(a, "9.99")));
}

test "text arrays" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseTextArray(a, "{a, \"b c\" ,NULL,\"NULL\",d\\,e}");
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("b c", r[1].?);
    try std.testing.expect(r[2] == null);
    try std.testing.expectEqualStrings("NULL", r[3].?);
    try std.testing.expectEqualStrings("d,e", r[4].?);
    try std.testing.expectEqual(@as(usize, 0), (try parseTextArray(a, "{}")).len);
    try std.testing.expectError(error.Invalid, parseTextArray(a, "a,b"));
}
