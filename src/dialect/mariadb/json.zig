//! MariaDB's JSON functions (JSON_EXTRACT, JSON_OBJECT, JSON_SET ...),
//! as MariaDB 11 computes and prints them. They are functions of the
//! dialect's table (frontend.zig), so the schema keeps them as
//! xq_mariadb_json_*(...); JSON_VALID is SQLite's json_valid(), which
//! agrees with MariaDB's (the CHECK of a JSON column, which sqlite3 can
//! run). The helpers the parser adds are engine functions (xq_maria_json_*).
//!
//! JSON text is parsed into a Node tree that keeps the source text of
//! each value (`raw`): MariaDB prints numbers and strings as written
//! (1.50, "é"), and some functions return a value's source text
//! as is (JSON_QUERY, a JSON argument of JSON_OBJECT/JSON_ARRAY).
//!
//! Output formats:
//!  - standard (JSON_EXTRACT, JSON_SET, JSON_OBJECT, JSON_LOOSE ...):
//!    `{"a": 1, "b": [1, 2]}`;
//!  - compact (JSON_COMPACT, JSON_ARRAYAGG's separators): no spaces;
//!  - detailed (JSON_DETAILED/JSON_PRETTY): one value per line;
//!  - normalized (JSON_NORMALIZE, JSON_EQUALS): keys sorted, numbers as
//!    1.5E0.
//!
//! Which values are JSON: a result of a function that returns JSON
//! carries SQLite's JSON subtype ('J', as json_object()'s does), and a
//! JSON argument is used as JSON (embedded, not quoted as a string). The
//! parser marks the other values MariaDB takes as JSON: a JSON column
//! (xq_maria_json_col()) and a boolean expression (xq_maria_json_bool(),
//! true/false). A subtype does not survive a table, a subquery that is
//! materialized or a sort, where MariaDB would still know the type.
//!
//! Paths: `$`, `.key`, `."key"`, `.*`, `[n]`, `[last]`, `[last-n]`,
//! `[-n]`, `[n to m]`, `[*]`, `**`, after an optional `lax`/`strict`. A
//! value that is not an array is an array of one for `[0]`/`[last]`.
//! Errors in a document or a path make the result NULL (MariaDB's
//! warning is not recorded).

const std = @import("std");
const json_text = @import("../json_text.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Context = dfunc.Context;
const Mem = dfunc.Mem;
const isNull = dfunc.isNull;

/// The subtype of JSON text (SQLite's JSON_SUBTYPE, ASCII "J").
pub const subtype: u32 = 'J';

// ================================================================ values

pub const Kind = enum { object, array, string, number, true_, false_, null_ };

pub const Node = struct {
    kind: Kind,
    /// The text of the value: as written for a parsed value (strings with
    /// their quotes and escapes), the JSON text of a scalar made here, ""
    /// for an array or object made here.
    raw: []const u8 = "",
    items: []Node = &.{},
    members: []Member = &.{},

    pub fn isContainer(n: *const Node) bool {
        return n.kind == .object or n.kind == .array;
    }
};

pub const Member = struct {
    /// The key as written between the quotes (escapes kept).
    key: []const u8,
    value: Node,
};

const null_node: Node = .{ .kind = .null_, .raw = "null" };

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub const ParseError = error{ Invalid, OutOfMemory };

const max_depth = 512;

const JsonParser = struct {
    a: Allocator,
    z: []const u8,
    i: usize = 0,
    depth: u32 = 0,

    fn ws(p: *JsonParser) void {
        while (p.i < p.z.len and isWs(p.z[p.i])) p.i += 1;
    }

    fn at(p: *const JsonParser, c: u8) bool {
        return p.i < p.z.len and p.z[p.i] == c;
    }

    fn value(p: *JsonParser) ParseError!Node {
        p.ws();
        if (p.i >= p.z.len) return error.Invalid;
        const start = p.i;
        switch (p.z[p.i]) {
            '{' => {
                p.depth += 1;
                if (p.depth > max_depth) return error.Invalid;
                p.i += 1;
                var ms: std.ArrayList(Member) = .empty;
                p.ws();
                if (p.at('}')) {
                    p.i += 1;
                } else while (true) {
                    p.ws();
                    if (!p.at('"')) return error.Invalid;
                    const k = try p.string();
                    p.ws();
                    if (!p.at(':')) return error.Invalid;
                    p.i += 1;
                    const v = try p.value();
                    try ms.append(p.a, .{ .key = k[1 .. k.len - 1], .value = v });
                    p.ws();
                    if (p.at(',')) {
                        p.i += 1;
                        continue;
                    }
                    if (p.at('}')) {
                        p.i += 1;
                        break;
                    }
                    return error.Invalid;
                }
                p.depth -= 1;
                return .{ .kind = .object, .raw = p.z[start..p.i], .members = ms.items };
            },
            '[' => {
                p.depth += 1;
                if (p.depth > max_depth) return error.Invalid;
                p.i += 1;
                var items: std.ArrayList(Node) = .empty;
                p.ws();
                if (p.at(']')) {
                    p.i += 1;
                } else while (true) {
                    try items.append(p.a, try p.value());
                    p.ws();
                    if (p.at(',')) {
                        p.i += 1;
                        continue;
                    }
                    if (p.at(']')) {
                        p.i += 1;
                        break;
                    }
                    return error.Invalid;
                }
                p.depth -= 1;
                return .{ .kind = .array, .raw = p.z[start..p.i], .items = items.items };
            },
            '"' => return .{ .kind = .string, .raw = try p.string() },
            't' => return p.literal("true", .true_),
            'f' => return p.literal("false", .false_),
            'n' => return p.literal("null", .null_),
            else => return p.number(),
        }
    }

    fn literal(p: *JsonParser, comptime word: []const u8, kind: Kind) ParseError!Node {
        if (!std.mem.startsWith(u8, p.z[p.i..], word)) return error.Invalid;
        p.i += word.len;
        return .{ .kind = kind, .raw = p.z[p.i - word.len .. p.i] };
    }

    /// A string at the opening quote: its text with the quotes.
    fn string(p: *JsonParser) ParseError![]const u8 {
        const start = p.i;
        p.i += 1;
        while (p.i < p.z.len) {
            const c = p.z[p.i];
            if (c == '"') {
                p.i += 1;
                return p.z[start..p.i];
            }
            if (c < 0x20) return error.Invalid;
            if (c == '\\') {
                p.i += 1;
                if (p.i >= p.z.len) return error.Invalid;
                switch (p.z[p.i]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => p.i += 1,
                    'u' => {
                        if (p.i + 4 >= p.z.len) return error.Invalid;
                        for (p.z[p.i + 1 .. p.i + 5]) |h| if (!std.ascii.isHex(h)) return error.Invalid;
                        p.i += 5;
                    },
                    else => return error.Invalid,
                }
                continue;
            }
            p.i += 1;
        }
        return error.Invalid;
    }

    fn number(p: *JsonParser) ParseError!Node {
        const start = p.i;
        if (p.at('-')) p.i += 1;
        if (p.at('0')) {
            p.i += 1;
        } else {
            const d = p.i;
            while (p.i < p.z.len and std.ascii.isDigit(p.z[p.i])) p.i += 1;
            if (p.i == d) return error.Invalid;
        }
        if (p.at('.')) {
            p.i += 1;
            const d = p.i;
            while (p.i < p.z.len and std.ascii.isDigit(p.z[p.i])) p.i += 1;
            if (p.i == d) return error.Invalid;
        }
        if (p.at('e') or p.at('E')) {
            p.i += 1;
            if (p.at('+') or p.at('-')) p.i += 1;
            const d = p.i;
            while (p.i < p.z.len and std.ascii.isDigit(p.z[p.i])) p.i += 1;
            if (p.i == d) return error.Invalid;
        }
        return .{ .kind = .number, .raw = p.z[start..p.i] };
    }
};

/// Parse JSON text (RFC 8259; spaces around it allowed).
pub fn parse(a: Allocator, z: []const u8) ParseError!Node {
    var pos: usize = 0;
    return parseAt(a, z, &pos);
}

/// parse(); `pos` is where it stopped (the error's offset).
pub fn parseAt(a: Allocator, z: []const u8, pos: *usize) ParseError!Node {
    var p: JsonParser = .{ .a = a, .z = z };
    defer pos.* = p.i;
    const v = try p.value();
    p.ws();
    if (p.i != z.len) return error.Invalid;
    return v;
}

/// The value of a string's text between the quotes (escapes decoded;
/// an unknown escape is the character).
pub fn unescape(a: Allocator, inner: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c != '\\' or i + 1 >= inner.len) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        const e = inner[i + 1];
        i += 2;
        switch (e) {
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            'u' => {
                const cp1 = hex4(inner, i) orelse {
                    try out.append(a, 'u');
                    continue;
                };
                i += 4;
                var cp: u21 = cp1;
                if (cp1 >= 0xd800 and cp1 < 0xdc00 and i + 1 < inner.len and inner[i] == '\\' and inner[i + 1] == 'u') {
                    if (hex4(inner, i + 2)) |cp2| if (cp2 >= 0xdc00 and cp2 < 0xe000) {
                        cp = 0x10000 + ((@as(u21, cp1) - 0xd800) << 10) + (cp2 - 0xdc00);
                        i += 6;
                    };
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch {
                    try out.appendSlice(a, "\xef\xbf\xbd");
                    continue;
                };
                try out.appendSlice(a, buf[0..n]);
            },
            else => try out.append(a, e),
        }
    }
    return out.items;
}

fn hex4(z: []const u8, i: usize) ?u16 {
    if (i + 4 > z.len) return null;
    return std.fmt.parseInt(u16, z[i .. i + 4], 16) catch null;
}

/// The value of a string node.
pub fn stringValue(a: Allocator, n: *const Node) Allocator.Error![]const u8 {
    return unescape(a, n.raw[1 .. n.raw.len - 1]);
}

/// Append `s` as the text of a JSON string, without the quotes.
pub fn appendEscaped(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try json_text.appendEscaped(.{}, a, out, s);
}

/// Append `s` as a JSON string.
pub fn appendQuoted(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    try appendEscaped(a, out, s);
    try out.append(a, '"');
}

fn keyEql(a: Allocator, raw: []const u8, key: []const u8) Allocator.Error!bool {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return std.mem.eql(u8, raw, key);
    return std.mem.eql(u8, try unescape(a, raw), key);
}

fn keysEql(a: Allocator, x: []const u8, y: []const u8) Allocator.Error!bool {
    if (std.mem.eql(u8, x, y)) return true;
    return std.mem.eql(u8, try unescape(a, x), try unescape(a, y));
}

/// A string node of `s`.
pub fn stringNode(a: Allocator, s: []const u8) Allocator.Error!Node {
    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(a, &out, s);
    return .{ .kind = .string, .raw = out.items };
}

// ================================================================ numbers

/// A REAL as MariaDB prints a DOUBLE in JSON: the shortest digits, an
/// integral value without a fraction, an exponent from 1e15.
pub fn appendDouble(a: Allocator, out: *std.ArrayList(u8), x: f64) Allocator.Error!void {
    if (!std.math.isFinite(x)) return out.appendSlice(a, "null");
    if (x == 0) return out.append(a, '0');
    if (x == @trunc(x) and @abs(x) < 1e15) return out.print(a, "{d}", .{@as(i64, @intFromFloat(x))});
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e}", .{x}) catch return out.appendSlice(a, "null");
    var i: usize = 0;
    const neg = s[0] == '-';
    if (neg) i = 1;
    const e_at = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
    var ds: [32]u8 = undefined;
    var nd: usize = 0;
    for (s[i..e_at]) |c| if (c != '.') {
        ds[nd] = c;
        nd += 1;
    };
    while (nd > 1 and ds[nd - 1] == '0') nd -= 1;
    const exp: i32 = if (e_at < s.len) std.fmt.parseInt(i32, s[e_at + 1 ..], 10) catch 0 else 0;
    if (neg) try out.append(a, '-');
    if (exp >= 15 or exp < -15) {
        try out.append(a, ds[0]);
        if (nd > 1) {
            try out.append(a, '.');
            try out.appendSlice(a, ds[1..nd]);
        }
        try out.print(a, "e{d}", .{exp});
        return;
    }
    if (exp >= 0) {
        const int_len: usize = @intCast(exp + 1);
        var k: usize = 0;
        while (k < int_len) : (k += 1) try out.append(a, if (k < nd) ds[k] else '0');
        if (nd > int_len) {
            try out.append(a, '.');
            try out.appendSlice(a, ds[int_len..nd]);
        }
    } else {
        try out.appendSlice(a, "0.");
        var k: i32 = -1;
        while (k > exp) : (k -= 1) try out.append(a, '0');
        try out.appendSlice(a, ds[0..nd]);
    }
}

/// A JSON number as JSON_NORMALIZE prints it: d.dddE[-]n (the decimal
/// digits as written).
fn appendNormalizedNumber(a: Allocator, out: *std.ArrayList(u8), raw: []const u8) Allocator.Error!void {
    var i: usize = 0;
    const neg = raw.len > 0 and raw[0] == '-';
    if (neg) i = 1;
    var dl: std.ArrayList(u8) = .empty;
    var point: i64 = 0;
    var seen_point = false;
    while (i < raw.len and (std.ascii.isDigit(raw[i]) or raw[i] == '.')) : (i += 1) {
        if (raw[i] == '.') {
            seen_point = true;
            continue;
        }
        try dl.append(a, raw[i]);
        if (!seen_point) point += 1;
    }
    var exp: i64 = 0;
    if (i < raw.len and (raw[i] == 'e' or raw[i] == 'E')) exp = std.fmt.parseInt(i64, raw[i + 1 ..], 10) catch 0;
    // Leading zeros.
    var d = dl.items;
    while (d.len > 0 and d[0] == '0') {
        d = d[1..];
        point -= 1;
    }
    while (d.len > 0 and d[d.len - 1] == '0') d = d[0 .. d.len - 1];
    if (d.len == 0) return out.appendSlice(a, "0.0E0");
    if (neg) try out.append(a, '-');
    try out.append(a, d[0]);
    try out.append(a, '.');
    try out.appendSlice(a, if (d.len > 1) d[1..] else "0");
    try out.print(a, "E{d}", .{point - 1 + exp});
}

// ================================================================ output

pub const Format = enum { standard, compact };

/// Append node `n` in format `f`.
pub fn write(a: Allocator, out: *std.ArrayList(u8), n: *const Node, f: Format) Allocator.Error!void {
    switch (n.kind) {
        .array => {
            try out.append(a, '[');
            for (n.items, 0..) |*it, i| {
                if (i > 0) try out.appendSlice(a, if (f == .standard) ", " else ",");
                try write(a, out, it, f);
            }
            try out.append(a, ']');
        },
        .object => {
            try out.append(a, '{');
            for (n.members, 0..) |*m, i| {
                if (i > 0) try out.appendSlice(a, if (f == .standard) ", " else ",");
                try out.append(a, '"');
                try out.appendSlice(a, m.key);
                try out.appendSlice(a, if (f == .standard) "\": " else "\":");
                try write(a, out, &m.value, f);
            }
            try out.append(a, '}');
        },
        else => try out.appendSlice(a, n.raw),
    }
}

pub fn toText(a: Allocator, n: *const Node, f: Format) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try write(a, &out, n, f);
    return out.items;
}

fn indent(a: Allocator, out: *std.ArrayList(u8), level: usize, tab: usize) Allocator.Error!void {
    try out.appendNTimes(a, ' ', level * tab);
}

/// JSON_DETAILED's format: a value per line, an array or object that is
/// a member's value on the line after the key.
fn writeDetailed(a: Allocator, out: *std.ArrayList(u8), n: *const Node, level: usize, tab: usize) Allocator.Error!void {
    switch (n.kind) {
        .array => {
            if (n.items.len == 0) return out.appendSlice(a, "[]");
            try out.append(a, '[');
            for (n.items, 0..) |*it, i| {
                if (i > 0) try out.append(a, ',');
                try out.append(a, '\n');
                try indent(a, out, level + 1, tab);
                try writeDetailed(a, out, it, level + 1, tab);
            }
            try out.append(a, '\n');
            try indent(a, out, level, tab);
            try out.append(a, ']');
        },
        .object => {
            try out.append(a, '{');
            for (n.members, 0..) |*m, i| {
                if (i > 0) try out.append(a, ',');
                try out.append(a, '\n');
                try indent(a, out, level + 1, tab);
                try out.append(a, '"');
                try out.appendSlice(a, m.key);
                try out.appendSlice(a, "\": ");
                if (m.value.isContainer()) {
                    try out.append(a, '\n');
                    try indent(a, out, level + 1, tab);
                }
                try writeDetailed(a, out, &m.value, level + 1, tab);
            }
            try out.append(a, '\n');
            try indent(a, out, level, tab);
            try out.append(a, '}');
        },
        else => try out.appendSlice(a, n.raw),
    }
}

/// JSON_NORMALIZE's format: compact, keys sorted, numbers normalized.
fn writeNormalized(a: Allocator, out: *std.ArrayList(u8), n: *const Node) Allocator.Error!void {
    switch (n.kind) {
        .array => {
            try out.append(a, '[');
            for (n.items, 0..) |*it, i| {
                if (i > 0) try out.append(a, ',');
                try writeNormalized(a, out, it);
            }
            try out.append(a, ']');
        },
        .object => {
            const ms = try a.dupe(Member, n.members);
            std.sort.insertion(Member, ms, {}, struct {
                fn lt(_: void, x: Member, y: Member) bool {
                    return std.mem.order(u8, x.key, y.key) == .lt;
                }
            }.lt);
            try out.append(a, '{');
            for (ms, 0..) |*m, i| {
                if (i > 0) try out.append(a, ',');
                try out.append(a, '"');
                try out.appendSlice(a, m.key);
                try out.appendSlice(a, "\":");
                try writeNormalized(a, out, &m.value);
            }
            try out.append(a, '}');
        },
        .number => try appendNormalizedNumber(a, out, n.raw),
        else => try out.appendSlice(a, n.raw),
    }
}

fn normalized(a: Allocator, n: *const Node) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeNormalized(a, &out, n);
    return out.items;
}

// ================================================================ paths

pub const Idx = struct {
    /// `last` or `last-n`.
    last: bool = false,
    n: i64 = 0,
};

pub const Step = union(enum) {
    /// .key (decoded)
    key: []const u8,
    /// .*
    any_key,
    /// [n], [n to m]
    index: struct { lo: Idx, hi: ?Idx = null },
    /// [*]
    any_index,
    /// ** (applies the next step at any depth)
    descend,
};

pub const Path = struct {
    steps: []const Step,
    /// Has a wildcard or a range (may match several values).
    wild: bool = false,
};

/// A MariaDB JSON path; null if it is not one.
pub fn parsePath(a: Allocator, z: []const u8) Allocator.Error!?Path {
    var i: usize = 0;
    for ([_][]const u8{ "lax", "strict" }) |w| {
        if (z.len > w.len and std.ascii.eqlIgnoreCase(z[0..w.len], w) and isWs(z[w.len])) {
            i = w.len;
            while (i < z.len and isWs(z[i])) i += 1;
            break;
        }
    }
    if (i >= z.len or z[i] != '$') return null;
    i += 1;
    var steps: std.ArrayList(Step) = .empty;
    var wild = false;
    while (i < z.len) {
        switch (z[i]) {
            '.' => {
                i += 1;
                if (i >= z.len) return null;
                if (z[i] == '*') {
                    i += 1;
                    try steps.append(a, .any_key);
                    wild = true;
                } else if (z[i] == '"') {
                    const start = i + 1;
                    i += 1;
                    while (i < z.len and z[i] != '"') : (i += 1) {
                        if (z[i] == '\\') i += 1;
                    }
                    if (i >= z.len) return null;
                    try steps.append(a, .{ .key = try unescape(a, z[start..i]) });
                    i += 1;
                } else {
                    const start = i;
                    while (i < z.len and z[i] != '.' and z[i] != '[' and z[i] != '*' and !isWs(z[i])) i += 1;
                    if (i == start) return null;
                    try steps.append(a, .{ .key = z[start..i] });
                }
            },
            '[' => {
                i += 1;
                skipWs(z, &i);
                if (i < z.len and z[i] == '*') {
                    i += 1;
                    try steps.append(a, .any_index);
                    wild = true;
                } else {
                    const lo = index(z, &i) orelse return null;
                    skipWs(z, &i);
                    var hi: ?Idx = null;
                    if (i + 2 < z.len and std.ascii.eqlIgnoreCase(z[i .. i + 2], "to") and isWs(z[i + 2])) {
                        i += 2;
                        skipWs(z, &i);
                        hi = index(z, &i) orelse return null;
                        wild = true;
                    }
                    try steps.append(a, .{ .index = .{ .lo = lo, .hi = hi } });
                }
                skipWs(z, &i);
                if (i >= z.len or z[i] != ']') return null;
                i += 1;
            },
            '*' => {
                if (i + 1 >= z.len or z[i + 1] != '*') return null;
                i += 2;
                if (i >= z.len) return null;
                try steps.append(a, .descend);
                wild = true;
            },
            else => return null,
        }
    }
    return .{ .steps = steps.items, .wild = wild };
}

fn skipWs(z: []const u8, i: *usize) void {
    while (i.* < z.len and isWs(z[i.*])) i.* += 1;
}

fn index(z: []const u8, i: *usize) ?Idx {
    if (i.* + 4 <= z.len and std.ascii.eqlIgnoreCase(z[i.* .. i.* + 4], "last")) {
        i.* += 4;
        var j = i.*;
        skipWs(z, &j);
        if (j < z.len and z[j] == '-') {
            j += 1;
            skipWs(z, &j);
            const n = digits(z, &j) orelse return null;
            i.* = j;
            return .{ .last = true, .n = n };
        }
        return .{ .last = true };
    }
    var neg = false;
    if (i.* < z.len and z[i.*] == '-') {
        neg = true;
        i.* += 1;
    }
    const n = digits(z, i) orelse return null;
    return .{ .n = if (neg) -n else n };
}

fn digits(z: []const u8, i: *usize) ?i64 {
    const start = i.*;
    while (i.* < z.len and std.ascii.isDigit(z[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseInt(i64, z[start..i.*], 10) catch null;
}

/// The position `x` stands for in an array of `len`, null if none.
fn resolve(x: Idx, len: usize) ?usize {
    const l: i64 = @intCast(len);
    const v = if (x.last) l - 1 - x.n else if (x.n < 0) l + x.n else x.n;
    if (v < 0 or v >= l) return null;
    return @intCast(v);
}

/// Append the values `steps` lead to from `n`, in document order.
pub fn find(a: Allocator, n: *Node, steps: []const Step, out: *std.ArrayList(*Node)) Allocator.Error!void {
    return findIn(a, n, steps, out, true);
}

fn findIn(a: Allocator, n: *Node, steps: []const Step, out: *std.ArrayList(*Node), autowrap: bool) Allocator.Error!void {
    if (steps.len == 0) return out.append(a, n);
    const rest = steps[1..];
    switch (steps[0]) {
        .key => |k| if (n.kind == .object) {
            for (n.members) |*m| if (try keyEql(a, m.key, k)) {
                try findIn(a, &m.value, rest, out, true);
                break;
            };
        },
        .any_key => if (n.kind == .object) {
            for (n.members) |*m| try findIn(a, &m.value, rest, out, true);
        },
        .index => |r| {
            if (n.kind == .array) {
                const len = n.items.len;
                if (r.hi) |h| {
                    if (len == 0) return;
                    const lo = resolve(r.lo, len) orelse return;
                    const l: i64 = @intCast(len);
                    var hv = if (h.last) l - 1 - h.n else if (h.n < 0) l + h.n else h.n;
                    if (hv >= l) hv = l - 1;
                    if (hv < @as(i64, @intCast(lo))) return;
                    for (n.items[lo..@intCast(hv + 1)]) |*it| try findIn(a, it, rest, out, true);
                } else if (resolve(r.lo, len)) |k| try findIn(a, &n.items[k], rest, out, true);
            } else if (autowrap) {
                // A value that is not an array is an array of one.
                if (resolve(r.lo, 1) != null) try findIn(a, n, rest, out, true);
            }
        },
        .any_index => if (n.kind == .array) {
            for (n.items) |*it| try findIn(a, it, rest, out, true);
        },
        .descend => if (rest.len > 0) try descend(a, n, rest, out),
    }
}

fn descend(a: Allocator, n: *Node, steps: []const Step, out: *std.ArrayList(*Node)) Allocator.Error!void {
    try findIn(a, n, steps, out, false);
    switch (n.kind) {
        .array => for (n.items) |*it| try descend(a, it, steps, out),
        .object => for (n.members) |*m| try descend(a, &m.value, steps, out),
        else => {},
    }
}

fn findAll(a: Allocator, root: *Node, path: Path) Allocator.Error![]*Node {
    var out: std.ArrayList(*Node) = .empty;
    try find(a, root, path.steps, &out);
    return out.items;
}

fn findFirst(a: Allocator, root: *Node, steps: []const Step) Allocator.Error!?*Node {
    var out: std.ArrayList(*Node) = .empty;
    try find(a, root, steps, &out);
    return if (out.items.len > 0) out.items[0] else null;
}

// ================================================================ comparing

/// JSON equality: numbers by value, strings by value, objects whatever
/// the order of their members.
fn equal(a: Allocator, x: *const Node, y: *const Node) Allocator.Error!bool {
    if (x.kind != y.kind) return false;
    switch (x.kind) {
        .true_, .false_, .null_ => return true,
        .number => {
            var bx: std.ArrayList(u8) = .empty;
            var by: std.ArrayList(u8) = .empty;
            try appendNormalizedNumber(a, &bx, x.raw);
            try appendNormalizedNumber(a, &by, y.raw);
            return std.mem.eql(u8, bx.items, by.items);
        },
        .string => return std.mem.eql(u8, try stringValue(a, x), try stringValue(a, y)),
        .array => {
            if (x.items.len != y.items.len) return false;
            for (x.items, y.items) |*p, *q| if (!try equal(a, p, q)) return false;
            return true;
        },
        .object => {
            if (x.members.len != y.members.len) return false;
            outer: for (x.members) |*m| {
                for (y.members) |*o| if (try keysEql(a, m.key, o.key) and try equal(a, &m.value, &o.value)) continue :outer;
                return false;
            }
            return true;
        },
    }
}

/// JSON_CONTAINS: `c` is in `t`.
fn contains(a: Allocator, t: *const Node, c: *const Node) Allocator.Error!bool {
    switch (t.kind) {
        .object => {
            if (c.kind != .object) return false;
            for (c.members) |*m| {
                const v = for (t.members) |*o| {
                    if (try keysEql(a, o.key, m.key)) break &o.value;
                } else return false;
                if (!try contains(a, v, &m.value)) return false;
            }
            return true;
        },
        .array => {
            if (c.kind == .array) {
                for (c.items) |*e| {
                    for (t.items) |*x| {
                        if (try contains(a, x, e)) break;
                    } else return false;
                }
                return true;
            }
            for (t.items) |*x| if (try contains(a, x, c)) return true;
            return false;
        },
        else => return !c.isContainer() and try equal(a, t, c),
    }
}

/// JSON_OVERLAPS.
fn overlaps(a: Allocator, x: *const Node, y: *const Node) Allocator.Error!bool {
    if (x.kind == .array and y.kind == .array) {
        for (x.items) |*p| for (y.items) |*q| if (try equal(a, p, q)) return true;
        return false;
    }
    if (x.kind == .array) {
        for (x.items) |*p| if (try equal(a, p, y)) return true;
        return false;
    }
    if (y.kind == .array) return overlaps(a, y, x);
    if (x.kind == .object and y.kind == .object) {
        for (x.members) |*m| for (y.members) |*o| {
            if (try keysEql(a, m.key, o.key) and try equal(a, &m.value, &o.value)) return true;
        };
        return false;
    }
    return equal(a, x, y);
}

fn depth(n: *const Node) i64 {
    var d: i64 = 0;
    switch (n.kind) {
        .array => for (n.items) |*it| {
            d = @max(d, depth(it));
        },
        .object => for (n.members) |*m| {
            d = @max(d, depth(&m.value));
        },
        else => return 1,
    }
    return d + 1;
}

// ================================================================ SQL values

/// Append SQL value `m` as JSON: a JSON value (JSON subtype) as it is, a
/// string quoted, a number, null.
pub fn appendSqlValue(a: Allocator, out: *std.ArrayList(u8), m: *Mem) Allocator.Error!void {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => try out.appendSlice(a, "null"),
        vi.SQLITE_INTEGER => try out.print(a, "{d}", .{api.valueInt64(m)}),
        vi.SQLITE_FLOAT => try appendDouble(a, out, api.valueDouble(m)),
        vi.SQLITE_BLOB => try appendQuoted(a, out, api.valueBlob(m) orelse ""),
        else => {
            const z = api.valueText(m) orelse return error.OutOfMemory;
            if (api.valueSubtype(m) == subtype and isValid(a, z)) {
                try out.appendSlice(a, z);
            } else try appendQuoted(a, out, z);
        },
    }
}

fn isValid(gpa: Allocator, z: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = parse(arena.allocator(), z) catch return false;
    return true;
}

/// SQL value `m` as a JSON node (appendSqlValue()).
fn sqlValueNode(a: Allocator, m: *Mem) Allocator.Error!Node {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return null_node,
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => {
            var out: std.ArrayList(u8) = .empty;
            try appendSqlValue(a, &out, m);
            return .{ .kind = .number, .raw = out.items };
        },
        vi.SQLITE_BLOB => return stringNode(a, api.valueBlob(m) orelse ""),
        else => {
            const z = api.valueText(m) orelse return error.OutOfMemory;
            if (api.valueSubtype(m) == subtype) {
                if (parse(a, z)) |n| return n else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
            }
            return stringNode(a, z);
        },
    }
}

// ================================================================ functions

const Result = union(enum) {
    null,
    text: []const u8,
    json: []const u8,
    int: i64,
    err: []const u8,
};

const Impl = fn (a: Allocator, argv: []*Mem) Allocator.Error!Result;

/// `f` as a function taking at least `min` arguments (the parser
/// checks MariaDB's counts; this guards a call from another dialect).
fn wrap(comptime f: Impl, comptime min: usize) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (argv.len < min) return api.resultError(ctx, "wrong number of arguments");
            var arena = std.heap.ArenaAllocator.init(dfunc.gpa(ctx));
            defer arena.deinit();
            const r = f(arena.allocator(), argv) catch return api.resultErrorNomem(ctx);
            switch (r) {
                .null => api.resultNull(ctx),
                .text => |z| api.resultText(ctx, z, .transient),
                .json => |z| {
                    api.resultText(ctx, z, .transient);
                    api.resultSubtype(ctx, subtype);
                },
                .int => |v| api.resultInt64(ctx, v),
                .err => |msg| api.resultError(ctx, msg),
            }
        }
    }.call;
}

fn argText(m: *Mem) Allocator.Error!?[]const u8 {
    if (isNull(m)) return null;
    if (api.valueType(m) == vi.SQLITE_BLOB) return api.valueBlob(m) orelse "";
    return api.valueText(m) orelse error.OutOfMemory;
}

/// The document of argument `m`; null if it is NULL or not JSON.
fn docArg(a: Allocator, m: *Mem) Allocator.Error!?*Node {
    const z = (try argText(m)) orelse return null;
    const n = try a.create(Node);
    n.* = parse(a, z) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };
    return n;
}

/// The path of argument `m`; null if it is NULL or not a path.
fn pathArg(a: Allocator, m: *Mem) Allocator.Error!?Path {
    const z = (try argText(m)) orelse return null;
    return parsePath(a, z);
}

fn jsonText(a: Allocator, n: *const Node, f: Format) Allocator.Error!Result {
    return .{ .json = try toText(a, n, f) };
}

/// JSON_EXTRACT(doc, path, ...): the value at a path; for several paths
/// or a path with a wildcard, the array of the values found.
fn extract(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    var found: std.ArrayList(*Node) = .empty;
    var wild = argv.len > 2;
    for (argv[1..]) |m| {
        const p = (try pathArg(a, m)) orelse return .null;
        wild = wild or p.wild;
        try find(a, doc, p.steps, &found);
    }
    if (found.items.len == 0) return .null;
    // In document order (the order of their text), as MariaDB walks it.
    std.sort.insertion(*Node, found.items, {}, struct {
        fn lt(_: void, x: *Node, y: *Node) bool {
            return @intFromPtr(x.raw.ptr) < @intFromPtr(y.raw.ptr);
        }
    }.lt);
    if (!wild) return jsonText(a, found.items[0], .standard);
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (found.items, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try write(a, &out, n, .standard);
    }
    try out.append(a, ']');
    return .{ .json = out.items };
}

/// JSON_VALUE(doc, path): the scalar at the path, as text.
fn value(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    const p = (try pathArg(a, argv[1])) orelse return .null;
    if (p.wild) return .null;
    const n = (try findFirst(a, doc, p.steps)) orelse return .null;
    return switch (n.kind) {
        .string => .{ .text = try stringValue(a, n) },
        .number => .{ .text = n.raw },
        .true_ => .{ .text = "1" },
        .false_ => .{ .text = "0" },
        else => .null,
    };
}

/// JSON_QUERY(doc, path): the object or array at the path, as written.
fn query(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    const p = (try pathArg(a, argv[1])) orelse return .null;
    const n = (try findFirst(a, doc, p.steps)) orelse return .null;
    if (!n.isContainer()) return .null;
    return .{ .json = n.raw };
}

/// JSON_UNQUOTE(s): the value of a JSON string, else s.
fn unquote(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const z = (try argText(argv[0])) orelse return .null;
    const t = std.mem.trim(u8, z, " \t\n\r");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return .{ .text = try unescape(a, t[1 .. t.len - 1]) };
    return .{ .text = z };
}

/// JSON_QUOTE(s): s as a JSON string; NULL for a number.
fn quote(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const t = api.valueType(argv[0]);
    if (t != vi.SQLITE_TEXT and t != vi.SQLITE_BLOB) return .null;
    const z = (try argText(argv[0])) orelse return .null;
    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(a, &out, z);
    return .{ .text = out.items };
}

/// JSON_OBJECT(key, value, ...).
fn object(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '{');
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 2) {
        if (i > 0) try out.appendSlice(a, ", ");
        try appendQuoted(a, &out, (try argText(argv[i])) orelse "");
        try out.appendSlice(a, ": ");
        try appendSqlValue(a, &out, argv[i + 1]);
    }
    try out.append(a, '}');
    return .{ .json = out.items };
}

/// JSON_ARRAY(value, ...).
fn array(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (argv, 0..) |m, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try appendSqlValue(a, &out, m);
    }
    try out.append(a, ']');
    return .{ .json = out.items };
}

/// JSON_CONTAINS(doc, candidate[, path]).
fn containsFn(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    const c = (try docArg(a, argv[1])) orelse return .null;
    var t = doc;
    if (argv.len > 2) {
        const p = (try pathArg(a, argv[2])) orelse return .null;
        if (p.wild) return .null;
        t = (try findFirst(a, doc, p.steps)) orelse return .{ .int = 0 };
    }
    return .{ .int = @intFromBool(try contains(a, t, c)) };
}

/// 'one' (false) or 'all' (true); null for anything else.
fn oneOrAll(m: *Mem) Allocator.Error!?bool {
    const z = (try argText(m)) orelse return null;
    if (std.ascii.eqlIgnoreCase(z, "one")) return false;
    if (std.ascii.eqlIgnoreCase(z, "all")) return true;
    return null;
}

/// JSON_CONTAINS_PATH(doc, 'one'|'all', path, ...).
fn containsPath(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const all = (try oneOrAll(argv[1])) orelse return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    var n_found: usize = 0;
    for (argv[2..]) |m| {
        const p = (try pathArg(a, m)) orelse return .null;
        if ((try findFirst(a, doc, p.steps)) != null) n_found += 1;
    }
    const ok = if (all) n_found == argv.len - 2 else n_found > 0;
    return .{ .int = @intFromBool(ok) };
}

/// JSON_EXISTS(doc, path).
fn exists(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const p = (try pathArg(a, argv[1])) orelse return .null;
    // MariaDB answers `$` without reading the document.
    if (p.steps.len == 0) return .{ .int = 1 };
    const doc = (try docArg(a, argv[0])) orelse return .null;
    return .{ .int = @intFromBool((try findFirst(a, doc, p.steps)) != null) };
}

/// The value at the optional path argument of JSON_KEYS/JSON_LENGTH
/// (the document without one); null for none or a wildcard.
fn target(a: Allocator, argv: []*Mem) Allocator.Error!?*Node {
    if (dfunc.anyNull(argv)) return null;
    const doc = (try docArg(a, argv[0])) orelse return null;
    if (argv.len < 2) return doc;
    const p = (try pathArg(a, argv[1])) orelse return null;
    if (p.wild) return null;
    return findFirst(a, doc, p.steps);
}

/// JSON_KEYS(doc[, path]): the keys of an object, each once.
fn keys(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const t = (try target(a, argv)) orelse return .null;
    if (t.kind != .object) return .null;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    var n: usize = 0;
    for (t.members, 0..) |*m, i| {
        const dup = for (t.members[0..i]) |*o| {
            if (try keysEql(a, o.key, m.key)) break true;
        } else false;
        if (dup) continue;
        if (n > 0) try out.appendSlice(a, ", ");
        n += 1;
        try out.append(a, '"');
        try out.appendSlice(a, m.key);
        try out.append(a, '"');
    }
    try out.append(a, ']');
    return .{ .text = out.items };
}

/// JSON_LENGTH(doc[, path]).
fn length(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const t = (try target(a, argv)) orelse return .null;
    return .{ .int = switch (t.kind) {
        .array => @intCast(t.items.len),
        .object => @intCast(t.members.len),
        else => 1,
    } };
}

/// JSON_DEPTH(doc).
fn depthFn(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const doc = (try docArg(a, argv[0])) orelse return .null;
    return .{ .int = depth(doc) };
}

/// JSON_TYPE(doc): MariaDB's names; DOUBLE for a number with a fraction.
fn typeFn(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const doc = (try docArg(a, argv[0])) orelse return .null;
    return .{ .text = switch (doc.kind) {
        .object => "OBJECT",
        .array => "ARRAY",
        .string => "STRING",
        .number => if (std.mem.indexOfScalar(u8, doc.raw, '.') != null) "DOUBLE" else "INTEGER",
        .true_, .false_ => "BOOLEAN",
        .null_ => "NULL",
    } };
}

const Mode = enum { set, insert, replace };

fn escapedKey(a: Allocator, key: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendEscaped(a, &out, key);
    return out.items;
}

/// Store `v` at `path` in `root`; false for a path MariaDB refuses.
fn modify(a: Allocator, root: *Node, path: Path, v: Node, mode: Mode) Allocator.Error!bool {
    if (path.wild) return false;
    const steps = path.steps;
    if (steps.len == 0) {
        if (mode != .insert) root.* = v;
        return true;
    }
    const p = (try findFirst(a, root, steps[0 .. steps.len - 1])) orelse return true;
    switch (steps[steps.len - 1]) {
        .key => |k| {
            if (p.kind != .object) return true;
            for (p.members) |*m| if (try keyEql(a, m.key, k)) {
                if (mode != .insert) m.value = v;
                return true;
            };
            if (mode == .replace) return true;
            var ms: std.ArrayList(Member) = .fromOwnedSlice(p.members);
            try ms.append(a, .{ .key = try escapedKey(a, k), .value = v });
            p.members = ms.items;
        },
        .index => |r| {
            if (p.kind == .array) {
                if (resolve(r.lo, p.items.len)) |i| {
                    if (mode != .insert) p.items[i] = v;
                } else if (mode != .replace) {
                    var items: std.ArrayList(Node) = .fromOwnedSlice(p.items);
                    try items.append(a, v);
                    p.items = items.items;
                }
            } else if (resolve(r.lo, 1) != null) {
                if (mode != .insert) p.* = v;
            } else if (mode != .replace) {
                const old = p.*;
                p.* = .{ .kind = .array, .items = try a.dupe(Node, &.{ old, v }) };
            }
        },
        else => return false,
    }
    return true;
}

fn setLike(comptime mode: Mode) Impl {
    return struct {
        fn f(a: Allocator, argv: []*Mem) Allocator.Error!Result {
            if (isNull(argv[0])) return .null;
            const doc = (try docArg(a, argv[0])) orelse return .null;
            var i: usize = 1;
            while (i + 1 < argv.len) : (i += 2) {
                const p = (try pathArg(a, argv[i])) orelse return .null;
                if (!try modify(a, doc, p, try sqlValueNode(a, argv[i + 1]), mode)) return .null;
            }
            return jsonText(a, doc, .standard);
        }
    }.f;
}

/// JSON_REMOVE(doc, path, ...).
fn remove(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    for (argv[1..]) |m| {
        const path = (try pathArg(a, m)) orelse return .null;
        const steps = path.steps;
        if (path.wild or steps.len == 0) return .null;
        const p = (try findFirst(a, doc, steps[0 .. steps.len - 1])) orelse continue;
        switch (steps[steps.len - 1]) {
            .key => |k| if (p.kind == .object) {
                for (p.members, 0..) |*mm, i| if (try keyEql(a, mm.key, k)) {
                    var ms: std.ArrayList(Member) = .fromOwnedSlice(p.members);
                    _ = ms.orderedRemove(i);
                    p.members = ms.items;
                    break;
                };
            },
            .index => |r| if (p.kind == .array) {
                if (resolve(r.lo, p.items.len)) |i| {
                    var items: std.ArrayList(Node) = .fromOwnedSlice(p.items);
                    _ = items.orderedRemove(i);
                    p.items = items.items;
                }
            },
            else => return .null,
        }
    }
    return jsonText(a, doc, .standard);
}

/// JSON_ARRAY_APPEND(doc, path, value, ...).
fn arrayAppend(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (isNull(argv[0])) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const p = (try pathArg(a, argv[i])) orelse return .null;
        if (p.wild) return .null;
        const t = (try findFirst(a, doc, p.steps)) orelse return .null;
        const v = try sqlValueNode(a, argv[i + 1]);
        if (t.kind == .array) {
            var items: std.ArrayList(Node) = .fromOwnedSlice(t.items);
            try items.append(a, v);
            t.items = items.items;
        } else {
            const old = t.*;
            t.* = .{ .kind = .array, .items = try a.dupe(Node, &.{ old, v }) };
        }
    }
    return jsonText(a, doc, .standard);
}

/// JSON_ARRAY_INSERT(doc, path, value, ...): the path ends in [n].
fn arrayInsert(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (isNull(argv[0])) return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const path = (try pathArg(a, argv[i])) orelse return .null;
        const steps = path.steps;
        if (path.wild or steps.len == 0) return .null;
        const r = switch (steps[steps.len - 1]) {
            .index => |r| r,
            else => return .null,
        };
        const v = try sqlValueNode(a, argv[i + 1]);
        const p = (try findFirst(a, doc, steps[0 .. steps.len - 1])) orelse continue;
        if (p.kind != .array) continue;
        const len: i64 = @intCast(p.items.len);
        var at: i64 = if (r.lo.last) len - r.lo.n else if (r.lo.n < 0) len + r.lo.n else r.lo.n;
        at = std.math.clamp(at, 0, len);
        var items: std.ArrayList(Node) = .fromOwnedSlice(p.items);
        try items.insert(a, @intCast(at), v);
        p.items = items.items;
    }
    return jsonText(a, doc, .standard);
}

fn toItems(a: Allocator, n: Node) Allocator.Error![]const Node {
    if (n.kind == .array) return n.items;
    return a.dupe(Node, &.{n});
}

fn mergePreserve(a: Allocator, x: Node, y: Node) Allocator.Error!Node {
    if (x.kind == .object and y.kind == .object) {
        var ms: std.ArrayList(Member) = .empty;
        try ms.appendSlice(a, x.members);
        outer: for (y.members) |m| {
            for (ms.items) |*o| if (try keysEql(a, o.key, m.key)) {
                o.value = try mergePreserve(a, o.value, m.value);
                continue :outer;
            };
            try ms.append(a, m);
        }
        return .{ .kind = .object, .members = ms.items };
    }
    var items: std.ArrayList(Node) = .empty;
    try items.appendSlice(a, try toItems(a, x));
    try items.appendSlice(a, try toItems(a, y));
    return .{ .kind = .array, .items = items.items };
}

fn mergePatch(a: Allocator, t: ?Node, p: Node) Allocator.Error!Node {
    if (p.kind != .object) return p;
    var ms: std.ArrayList(Member) = .empty;
    if (t) |x| if (x.kind == .object) try ms.appendSlice(a, x.members);
    for (p.members) |m| {
        var at: ?usize = null;
        for (ms.items, 0..) |*o, i| if (try keysEql(a, o.key, m.key)) {
            at = i;
            break;
        };
        if (m.value.kind == .null_) {
            if (at) |i| _ = ms.orderedRemove(i);
        } else if (at) |i| {
            ms.items[i].value = try mergePatch(a, ms.items[i].value, m.value);
        } else {
            try ms.append(a, .{ .key = m.key, .value = try mergePatch(a, null, m.value) });
        }
    }
    return .{ .kind = .object, .members = ms.items };
}

fn mergeWith(comptime patch: bool) Impl {
    return struct {
        fn f(a: Allocator, argv: []*Mem) Allocator.Error!Result {
            if (dfunc.anyNull(argv)) return .null;
            var acc = ((try docArg(a, argv[0])) orelse return .null).*;
            for (argv[1..]) |m| {
                const n = (try docArg(a, m)) orelse return .null;
                acc = if (patch) try mergePatch(a, acc, n.*) else try mergePreserve(a, acc, n.*);
            }
            return jsonText(a, &acc, .standard);
        }
    }.f;
}

/// Unicode case folding for JSON_SEARCH (utf8mb4_general_ci): ASCII and
/// Latin-1 letters.
fn fold(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0xc0 and cp <= 0xde and cp != 0xd7) return cp + 32;
    return cp;
}

fn codepoints(a: Allocator, z: []const u8) Allocator.Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < z.len) {
        const n = std.unicode.utf8ByteSequenceLength(z[i]) catch 1;
        const cp: u21 = if (i + n <= z.len) std.unicode.utf8Decode(z[i .. i + n]) catch z[i] else z[i];
        try out.append(a, fold(cp));
        i += if (i + n <= z.len) n else 1;
    }
    return out.items;
}

/// LIKE `p` (escape `esc`) on `s`, case-insensitive.
fn like(s: []const u21, p: []const u21, esc: u21) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star: ?usize = null;
    var star_s: usize = 0;
    while (si < s.len) {
        if (pi < p.len) {
            const c = p[pi];
            if (c == '%') {
                star = pi;
                star_s = si;
                pi += 1;
                continue;
            }
            if (c == esc and pi + 1 < p.len) {
                if (p[pi + 1] == s[si]) {
                    pi += 2;
                    si += 1;
                    continue;
                }
            } else if (c == '_' or c == s[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        if (star) |st| {
            pi = st + 1;
            star_s += 1;
            si = star_s;
            continue;
        }
        return false;
    }
    while (pi < p.len and p[pi] == '%') pi += 1;
    return pi == p.len;
}

const Search = struct {
    a: Allocator,
    pat: []const u21,
    esc: u21,
    all: bool,
    /// The values the path arguments select (all of the document if none).
    scope: ?[]*Node,
    path: std.ArrayList(u8) = .empty,
    found: std.ArrayList([]const u8) = .empty,

    fn walk(s: *Search, n: *Node, inside_in: bool) Allocator.Error!void {
        if (!s.all and s.found.items.len > 0) return;
        var inside = inside_in;
        if (!inside) {
            for (s.scope.?) |x| if (x == n) {
                inside = true;
                break;
            };
        }
        const mark = s.path.items.len;
        defer s.path.shrinkRetainingCapacity(mark);
        switch (n.kind) {
            .array => for (n.items, 0..) |*it, i| {
                s.path.shrinkRetainingCapacity(mark);
                try s.path.print(s.a, "[{d}]", .{i});
                try s.walk(it, inside);
            },
            .object => for (n.members) |*m| {
                s.path.shrinkRetainingCapacity(mark);
                try s.path.append(s.a, '.');
                try s.path.appendSlice(s.a, m.key);
                try s.walk(&m.value, inside);
            },
            .null_ => {},
            else => if (inside) {
                const v = if (n.kind == .string) try stringValue(s.a, n) else n.raw;
                if (like(try codepoints(s.a, v), s.pat, s.esc)) {
                    for (s.found.items) |f| if (std.mem.eql(u8, f, s.path.items)) return;
                    try s.found.append(s.a, try s.a.dupe(u8, s.path.items));
                }
            },
        }
    }
};

/// JSON_SEARCH(doc, 'one'|'all', pattern[, escape[, path ...]]): the
/// paths of the strings (and numbers) that match the LIKE pattern.
fn search(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (isNull(argv[0]) or isNull(argv[1]) or isNull(argv[2])) return .null;
    const all = (try oneOrAll(argv[1])) orelse return .null;
    const doc = (try docArg(a, argv[0])) orelse return .null;
    var esc: u21 = '\\';
    if (argv.len > 3 and !isNull(argv[3])) {
        const e = try codepoints(a, (try argText(argv[3])).?);
        if (e.len > 0) esc = e[0];
    }
    var scope: ?[]*Node = null;
    if (argv.len > 4) {
        var nodes: std.ArrayList(*Node) = .empty;
        for (argv[4..]) |m| {
            const p = (try pathArg(a, m)) orelse return .null;
            try find(a, doc, p.steps, &nodes);
        }
        scope = nodes.items;
    }
    var s: Search = .{ .a = a, .pat = try codepoints(a, (try argText(argv[2])).?), .esc = esc, .all = all, .scope = scope };
    try s.path.append(a, '$');
    try s.walk(doc, scope == null);
    const found = s.found.items;
    if (found.len == 0) return .null;
    var out: std.ArrayList(u8) = .empty;
    if (found.len == 1) {
        try appendQuoted(a, &out, found[0]);
        return .{ .json = out.items };
    }
    try out.append(a, '[');
    for (found, 0..) |f, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try appendQuoted(a, &out, f);
    }
    try out.append(a, ']');
    return .{ .json = out.items };
}

fn reformat(comptime f: Format) Impl {
    return struct {
        fn call(a: Allocator, argv: []*Mem) Allocator.Error!Result {
            const doc = (try docArg(a, argv[0])) orelse return .null;
            return jsonText(a, doc, f);
        }
    }.call;
}

/// JSON_DETAILED(doc[, tab_size]) and JSON_PRETTY.
fn detailed(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const doc = (try docArg(a, argv[0])) orelse return .null;
    var tab: usize = 4;
    if (argv.len > 1 and !isNull(argv[1])) tab = @intCast(std.math.clamp(api.valueInt64(argv[1]), 0, 64));
    var out: std.ArrayList(u8) = .empty;
    try writeDetailed(a, &out, doc, 0, tab);
    return .{ .json = out.items };
}

/// JSON_NORMALIZE(doc).
fn normalize(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const doc = (try docArg(a, argv[0])) orelse return .null;
    return .{ .json = try normalized(a, doc) };
}

/// JSON_EQUALS(a, b): the same once normalized.
fn equals(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    const x = (try docArg(a, argv[0])) orelse return .null;
    const y = (try docArg(a, argv[1])) orelse return .null;
    return .{ .int = @intFromBool(std.mem.eql(u8, try normalized(a, x), try normalized(a, y))) };
}

/// JSON_OVERLAPS(a, b).
fn overlapsFn(a: Allocator, argv: []*Mem) Allocator.Error!Result {
    if (dfunc.anyNull(argv)) return .null;
    const x = (try docArg(a, argv[0])) orelse return .{ .int = 0 };
    const y = (try docArg(a, argv[1])) orelse return .{ .int = 0 };
    return .{ .int = @intFromBool(try overlaps(a, x, y)) };
}

pub const extractFunc = wrap(extract, 2);
pub const valueFunc = wrap(value, 2);
pub const queryFunc = wrap(query, 2);
pub const unquoteFunc = wrap(unquote, 1);
pub const quoteFunc = wrap(quote, 1);
pub const objectFunc = wrap(object, 0);
pub const arrayFunc = wrap(array, 0);
pub const containsFunc = wrap(containsFn, 2);
pub const containsPathFunc = wrap(containsPath, 3);
pub const existsFunc = wrap(exists, 2);
pub const keysFunc = wrap(keys, 1);
pub const lengthFunc = wrap(length, 1);
pub const depthFunc = wrap(depthFn, 1);
pub const typeFunc = wrap(typeFn, 1);
pub const setFunc = wrap(setLike(.set), 3);
pub const insertFunc = wrap(setLike(.insert), 3);
pub const replaceFunc = wrap(setLike(.replace), 3);
pub const removeFunc = wrap(remove, 2);
pub const arrayAppendFunc = wrap(arrayAppend, 3);
pub const arrayInsertFunc = wrap(arrayInsert, 3);
pub const mergePreserveFunc = wrap(mergeWith(false), 2);
pub const mergePatchFunc = wrap(mergeWith(true), 2);
pub const searchFunc = wrap(search, 3);
pub const compactFunc = wrap(reformat(.compact), 1);
pub const looseFunc = wrap(reformat(.standard), 1);
pub const detailedFunc = wrap(detailed, 1);
pub const normalizeFunc = wrap(normalize, 1);
pub const equalsFunc = wrap(equals, 2);
pub const overlapsFunc = wrap(overlapsFn, 2);

// ================================================================ aggregates

/// The state of JSON_ARRAYAGG/JSON_OBJECTAGG: the items so far (in the
/// connection's allocator), in the aggregate context.
const Agg = struct {
    buf: ?*std.ArrayList(u8) = null,
    n: u64 = 0,
    /// A NULL key (JSON_OBJECTAGG is NULL).
    bad: bool = false,
};

fn aggState(ctx: *Context) ?*align(1) Agg {
    return dfunc.aggState(Agg, ctx, .make);
}

fn aggBuf(ctx: *Context, st: *align(1) Agg) ?*std.ArrayList(u8) {
    if (st.buf) |b| return b;
    const gpa = dfunc.gpa(ctx);
    const b = gpa.create(std.ArrayList(u8)) catch {
        api.resultErrorNomem(ctx);
        return null;
    };
    b.* = .empty;
    st.buf = b;
    return b;
}

/// JSON_ARRAYAGG(value[, limit]): `[a,b]` (no spaces between the
/// items), at most `limit` items.
pub fn arrayaggStep(ctx: *Context, argv: []*Mem) void {
    const st = aggState(ctx) orelse return;
    const b = aggBuf(ctx, st) orelse return;
    if (argv.len > 1 and st.n >= @max(api.valueInt64(argv[1]), 0)) return;
    const gpa = dfunc.gpa(ctx);
    if (st.n > 0) b.append(gpa, ',') catch return api.resultErrorNomem(ctx);
    st.n += 1;
    appendSqlValue(gpa, b, argv[0]) catch return api.resultErrorNomem(ctx);
}

/// JSON_OBJECTAGG(key, value): `{"k":v, "k2":v2}`.
pub fn objectaggStep(ctx: *Context, argv: []*Mem) void {
    const st = aggState(ctx) orelse return;
    const b = aggBuf(ctx, st) orelse return;
    const gpa = dfunc.gpa(ctx);
    if (isNull(argv[0])) {
        st.bad = true;
        return;
    }
    if (st.n > 0) b.appendSlice(gpa, ", ") catch return api.resultErrorNomem(ctx);
    st.n += 1;
    const k = (argText(argv[0]) catch return api.resultErrorNomem(ctx)) orelse "";
    appendQuoted(gpa, b, k) catch return api.resultErrorNomem(ctx);
    b.append(gpa, ':') catch return api.resultErrorNomem(ctx);
    appendSqlValue(gpa, b, argv[1]) catch return api.resultErrorNomem(ctx);
}

fn aggFinal(comptime open: u8, comptime close: u8) dfunc.FinalFn {
    return struct {
        fn call(ctx: *Context) void {
            const st = dfunc.aggState(Agg, ctx, .find) orelse return api.resultNull(ctx);
            const gpa = dfunc.gpa(ctx);
            const buf = st.buf orelse return api.resultNull(ctx);
            defer {
                buf.deinit(gpa);
                gpa.destroy(buf);
                st.buf = null;
            }
            if (st.n == 0 or st.bad) return api.resultNull(ctx);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            out.ensureTotalCapacity(gpa, buf.items.len + 2) catch return api.resultErrorNomem(ctx);
            out.appendAssumeCapacity(open);
            out.appendSliceAssumeCapacity(buf.items);
            out.appendAssumeCapacity(close);
            api.resultText(ctx, out.items, .transient);
            api.resultSubtype(ctx, subtype);
        }
    }.call;
}

pub const arrayaggFinal = aggFinal('[', ']');
pub const objectaggFinal = aggFinal('{', '}');

// ================================================================ helpers the parser adds

/// xq_maria_json_bool(x): a boolean expression as JSON true/false.
pub fn boolFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    api.resultText(ctx, if (api.valueDouble(argv[0]) != 0) "true" else "false", .static);
    api.resultSubtype(ctx, subtype);
}

/// xq_maria_json_col(x): the value of a JSON column, used as JSON.
pub fn colFunc(ctx: *Context, argv: []*Mem) void {
    api.resultValue(ctx, argv[0]);
    if (api.valueType(argv[0]) != vi.SQLITE_TEXT) return;
    var arena = std.heap.ArenaAllocator.init(dfunc.gpa(ctx));
    defer arena.deinit();
    const z = api.valueText(argv[0]) orelse return api.resultErrorNomem(ctx);
    if (isValid(arena.allocator(), z)) api.resultSubtype(ctx, subtype);
}

/// xq_maria_json_cmp(x): JSON_EXTRACT's value as a comparison sees it: a
/// string its value, a number a number.
pub fn cmpFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (api.valueType(m) != vi.SQLITE_TEXT or api.valueSubtype(m) != subtype) return api.resultValue(ctx, m);
    var arena = std.heap.ArenaAllocator.init(dfunc.gpa(ctx));
    defer arena.deinit();
    const a = arena.allocator();
    const z = api.valueText(m) orelse return api.resultErrorNomem(ctx);
    const n = parse(a, z) catch return api.resultText(ctx, z, .transient);
    switch (n.kind) {
        .string => {
            const v = stringValue(a, &n) catch return api.resultErrorNomem(ctx);
            api.resultText(ctx, v, .transient);
        },
        .number => switch (types.parseNumber(n.raw).num) {
            .int => |v| api.resultInt64(ctx, v),
            .float => |v| api.resultDouble(ctx, v),
        },
        .true_ => api.resultInt64(ctx, 1),
        .false_ => api.resultInt64(ctx, 0),
        else => api.resultText(ctx, z, .transient),
    }
}

// ================================================================ tests

const testing = std.testing;

fn testExtract(doc: []const u8, path: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try parse(a, doc);
    const p = (try parsePath(a, path)).?;
    const found = try findAll(a, &d, p);
    var out: std.ArrayList(u8) = .empty;
    for (found, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, " | ");
        try write(a, &out, n, .standard);
    }
    return testing.allocator.dupe(u8, out.items);
}

test "paths" {
    const cases = [_][3][]const u8{
        .{ "{\"a\":1,\"b\":{\"c\":[1,2,{\"d\":\"x\"}]}}", "$.b", "{\"c\": [1, 2, {\"d\": \"x\"}]}" },
        .{ "{\"a\":1,\"b\":{\"c\":[1,2,{\"d\":\"x\"}]}}", "$**.d", "\"x\"" },
        .{ "[1,2,3]", "$[last]", "3" },
        .{ "[1,2,3]", "$[last-1]", "2" },
        .{ "[1,2,3]", "$[-1]", "3" },
        .{ "[1,2,3]", "$[0 to 1]", "1 | 2" },
        .{ "[1,2,3]", "$[1 to last]", "2 | 3" },
        .{ "[1,2,3]", "$[ 1 ]", "2" },
        .{ "{\"a\":1}", "$[0].a", "1" },
        .{ "{\"a\":1}", "$.a[0]", "1" },
        .{ "{\"a\":{\"a\":1}}", "$**.a", "{\"a\": 1} | 1" },
        .{ "[1,[2,[3]]]", "$**[0]", "1 | 2 | 3" },
        .{ "{\"a b\":1}", "$.\"a b\"", "1" },
        .{ "{\"1\":2}", "$.1", "2" },
        .{ "{\"a\":1}", "lax $.a", "1" },
        .{ "{\"a\":1,\"a\":2}", "$.a", "1" },
    };
    for (cases) |c| {
        const got = try testExtract(c[0], c[1]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "$ .a", "$.a ", "bad", "$**", "$[", "$.", "a.b" }) |p| {
        try testing.expect((try parsePath(arena.allocator(), p)) == null);
    }
}

test "formats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "{ \"a\" : [ 1 , 2 ] , \"b\":{\"c\" : 1.50}, \"d\": [], \"e\": {}}");
    try testing.expectEqualStrings("{\"a\": [1, 2], \"b\": {\"c\": 1.50}, \"d\": [], \"e\": {}}", try toText(a, &d, .standard));
    try testing.expectEqualStrings("{\"a\":[1,2],\"b\":{\"c\":1.50},\"d\":[],\"e\":{}}", try toText(a, &d, .compact));
    var out: std.ArrayList(u8) = .empty;
    try writeDetailed(a, &out, &d, 0, 4);
    // (Each key of an array or object ends its line with a space.)
    try testing.expectEqualStrings("{\n    \"a\": \n    [\n        1,\n        2\n    ],\n    \"b\": \n    {\n        \"c\": 1.50\n    },\n" ++
        "    \"d\": \n    [],\n    \"e\": \n    {\n    }\n}", out.items);
    const n = try parse(a, "{\"b\":1,\"a\":[1.5, 2e1, \"x\", 0.10, -0, 12345678901234567890, 0.000123]}");
    try testing.expectEqualStrings("{\"a\":[1.5E0,2.0E1,\"x\",1.0E-1,0.0E0,1.234567890123456789E19,1.23E-4],\"b\":1.0E0}", try normalized(a, &n));
}

test "doubles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { f64, []const u8 }{
        .{ 1.5, "1.5" },   .{ 1e20, "1e20" },             .{ 1e-7, "0.0000001" },
        .{ 3.0, "3" },     .{ -1.25e10, "-12500000000" }, .{ 0.30000000000000004, "0.30000000000000004" },
        .{ 1e15, "1e15" }, .{ 0.5, "0.5" },               .{ 100000.0, "100000" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        try appendDouble(a, &out, c[0]);
        try testing.expectEqualStrings(c[1], out.items);
    }
}

test "contains and overlaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const C = struct { []const u8, []const u8, bool };
    const cs = [_]C{
        .{ "[1,[2,3]]", "2", true },                             .{ "{\"a\":1}", "1", false },
        .{ "[1,2,[3]]", "[[3]]", true },                         .{ "[1,2]", "[1,2,3]", false },
        .{ "{\"a\":{\"b\":[1,2]}}", "{\"a\":{\"b\":1}}", true }, .{ "[1.0]", "1", true },
        .{ "true", "1", false },                                 .{ "\"abc\"", "\"a\"", false },
    };
    for (cs) |c| {
        const t = try parse(a, c[0]);
        const x = try parse(a, c[1]);
        try testing.expectEqual(c[2], try contains(a, &t, &x));
    }
    const os = [_]C{
        .{ "[1,[2]]", "[[2]]", true }, .{ "[1,{\"a\":1}]", "{\"a\":1}", true },
        .{ "[]", "[]", false },        .{ "{\"a\":1}", "{\"a\":2}", false },
        .{ "1", "[1]", true },
    };
    for (os) |c| {
        const t = try parse(a, c[0]);
        const x = try parse(a, c[1]);
        try testing.expectEqual(c[2], try overlaps(a, &t, &x));
    }
}

test "like" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const L = struct { []const u8, []const u8, bool };
    for ([_]L{
        .{ "abc", "a%", true },   .{ "abc", "%c", true },    .{ "abc", "a_c", true },
        .{ "a_b", "a|_b", true }, .{ "axb", "a|_b", false },
        .{ "é", "É", true },
        .{ "ABC", "abc", true },  .{ "abc", "b", false },
    }) |c| {
        try testing.expectEqual(c[2], like(try codepoints(a, c[0]), try codepoints(a, c[1]), '|'));
    }
}
