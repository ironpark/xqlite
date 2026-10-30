//! Oracle's JSON, independent of SQL: the value model, the parser (strict
//! and lax syntax, as IS JSON [STRICT] reads it), the serializer (compact
//! as Oracle prints it, and PRETTY), and the SQL/JSON path language
//! (lax and strict mode, member and array steps, wildcards, descendants,
//! filters, item methods) that JSON_VALUE, JSON_QUERY, JSON_EXISTS,
//! JSON_TABLE and JSON_TRANSFORM evaluate (jsonfuncs.zig).
//!
//! Everything is allocated in one arena per call (the function's), so
//! nothing is freed piecemeal.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Syntax, OutOfMemory };

pub const Member = struct { key: []const u8, value: Value };

pub const Value = union(enum) {
    null,
    bool: bool,
    /// A number as JSON text (canonical: no '+', no leading '.', no
    /// trailing '.').
    number: []const u8,
    string: []const u8,
    array: []Value,
    object: []Member,

    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .null => "null",
            .bool => "boolean",
            .number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    pub fn isScalar(v: Value) bool {
        return v != .array and v != .object;
    }

    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .object) return null;
        for (v.object) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
        return null;
    }

    pub fn toF64(v: Value) ?f64 {
        return switch (v) {
            .number => |t| std.fmt.parseFloat(f64, t) catch null,
            else => null,
        };
    }
};

// ================================================================ parse

pub const ParseOptions = struct {
    /// Oracle's lax syntax: unquoted member names, single-quoted
    /// strings, literals in any case, numbers like +1, .5, 1., 01.
    lax: bool = true,
};

/// Parse JSON text (blanks around it allowed). Fails with error.Syntax.
pub fn parse(a: Allocator, text: []const u8, opts: ParseOptions) Error!Value {
    var p: Parser = .{ .a = a, .s = text, .lax = opts.lax };
    p.blank();
    const v = try p.value(0);
    p.blank();
    if (p.i != p.s.len) return error.Syntax;
    return v;
}

/// Whether an object of `v` (at any depth) has a member name twice.
pub fn hasDuplicateKeys(v: Value) bool {
    switch (v) {
        .array => |items| for (items) |x| if (hasDuplicateKeys(x)) return true,
        .object => |ms| for (ms, 0..) |m, i| {
            for (ms[i + 1 ..]) |o| if (std.mem.eql(u8, m.key, o.key)) return true;
            if (hasDuplicateKeys(m.value)) return true;
        },
        else => {},
    }
    return false;
}

const max_depth = 1000;

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    lax: bool,

    fn peek(p: *const Parser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    /// Blanks, and comments in lax syntax (/* */ and //).
    fn blank(p: *Parser) void {
        while (p.i < p.s.len) switch (p.s[p.i]) {
            ' ', '\t', '\n', '\r' => p.i += 1,
            '/' => {
                if (!p.lax or p.i + 1 >= p.s.len) return;
                if (p.s[p.i + 1] == '*') {
                    const end = std.mem.indexOfPos(u8, p.s, p.i + 2, "*/") orelse return;
                    p.i = end + 2;
                } else if (p.s[p.i + 1] == '/') {
                    while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
                } else return;
            },
            else => return,
        };
    }

    fn value(p: *Parser, depth: usize) Error!Value {
        if (depth > max_depth) return error.Syntax;
        const c = p.peek();
        switch (c) {
            '{' => return p.object(depth),
            '[' => return p.array(depth),
            '"' => return .{ .string = try p.string('"') },
            '\'' => {
                if (!p.lax) return error.Syntax;
                return .{ .string = try p.string('\'') };
            },
            '-', '+', '.', '0'...'9' => return .{ .number = try p.number() },
            else => {},
        }
        // true, false, null (any case when lax)
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        const w = p.s[start..p.i];
        const eqw = if (p.lax) &std.ascii.eqlIgnoreCase else &eqlBytes;
        if (eqw(w, "true")) return .{ .bool = true };
        if (eqw(w, "false")) return .{ .bool = false };
        if (eqw(w, "null")) return .null;
        if (p.lax and (std.mem.eql(u8, w, "NaN") or std.mem.eql(u8, w, "Infinity"))) return .{ .number = w };
        return error.Syntax;
    }

    fn object(p: *Parser, depth: usize) Error!Value {
        p.i += 1;
        var ms: std.ArrayList(Member) = .empty;
        p.blank();
        if (p.peek() == '}') {
            p.i += 1;
            return .{ .object = ms.items };
        }
        while (true) {
            p.blank();
            if (p.lax and p.peek() == '}' and ms.items.len > 0) {
                p.i += 1;
                return .{ .object = ms.items };
            }
            const key = switch (p.peek()) {
                '"' => try p.string('"'),
                '\'' => if (p.lax) try p.string('\'') else return error.Syntax,
                else => blk: {
                    if (!p.lax) return error.Syntax;
                    const start = p.i;
                    while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_' or p.s[p.i] == '$' or p.s[p.i] >= 0x80)) p.i += 1;
                    if (p.i == start or std.ascii.isDigit(p.s[start])) return error.Syntax;
                    break :blk p.s[start..p.i];
                },
            };
            p.blank();
            if (p.peek() != ':') return error.Syntax;
            p.i += 1;
            p.blank();
            const v = try p.value(depth + 1);
            try ms.append(p.a, .{ .key = key, .value = v });
            p.blank();
            switch (p.peek()) {
                ',' => p.i += 1,
                '}' => {
                    p.i += 1;
                    return .{ .object = ms.items };
                },
                else => return error.Syntax,
            }
        }
    }

    fn array(p: *Parser, depth: usize) Error!Value {
        p.i += 1;
        var items: std.ArrayList(Value) = .empty;
        p.blank();
        if (p.peek() == ']') {
            p.i += 1;
            return .{ .array = items.items };
        }
        while (true) {
            p.blank();
            if (p.lax and p.peek() == ']' and items.items.len > 0) {
                p.i += 1;
                return .{ .array = items.items };
            }
            try items.append(p.a, try p.value(depth + 1));
            p.blank();
            switch (p.peek()) {
                ',' => p.i += 1,
                ']' => {
                    p.i += 1;
                    return .{ .array = items.items };
                },
                else => return error.Syntax,
            }
        }
    }

    fn hex4(p: *Parser) Error!u21 {
        if (p.i + 4 > p.s.len) return error.Syntax;
        const v = std.fmt.parseInt(u16, p.s[p.i .. p.i + 4], 16) catch return error.Syntax;
        p.i += 4;
        return v;
    }

    /// A string quoted with `q`, decoded.
    fn string(p: *Parser, q: u8) Error![]const u8 {
        p.i += 1;
        const start = p.i;
        // Fast path: no escapes.
        while (p.i < p.s.len and p.s[p.i] != q and p.s[p.i] != '\\' and p.s[p.i] >= 0x20) p.i += 1;
        if (p.i < p.s.len and p.s[p.i] == q) {
            p.i += 1;
            return p.s[start .. p.i - 1];
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.a, p.s[start..p.i]);
        while (true) {
            if (p.i >= p.s.len) return error.Syntax;
            const c = p.s[p.i];
            if (c == q) {
                p.i += 1;
                return out.items;
            }
            if (c < 0x20) return error.Syntax;
            if (c != '\\') {
                try out.append(p.a, c);
                p.i += 1;
                continue;
            }
            p.i += 1;
            const e = p.peek();
            p.i += 1;
            switch (e) {
                '"', '\\', '/' => try out.append(p.a, e),
                '\'' => if (p.lax) try out.append(p.a, e) else return error.Syntax,
                'b' => try out.append(p.a, 8),
                'f' => try out.append(p.a, 12),
                'n' => try out.append(p.a, '\n'),
                'r' => try out.append(p.a, '\r'),
                't' => try out.append(p.a, '\t'),
                'u' => {
                    var cp = try p.hex4();
                    if (cp >= 0xd800 and cp < 0xdc00) {
                        if (p.i + 6 <= p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                            p.i += 2;
                            const lo = try p.hex4();
                            if (lo < 0xdc00 or lo > 0xdfff) return error.Syntax;
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        } else return error.Syntax;
                    } else if (cp >= 0xdc00 and cp <= 0xdfff) return error.Syntax;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.Syntax;
                    try out.appendSlice(p.a, buf[0..n]);
                },
                else => return error.Syntax,
            }
        }
    }

    /// A number, as canonical JSON text.
    fn number(p: *Parser) Error![]const u8 {
        const start = p.i;
        var neg = false;
        if (p.peek() == '-') {
            neg = true;
            p.i += 1;
        } else if (p.peek() == '+') {
            if (!p.lax) return error.Syntax;
            p.i += 1;
        }
        if (p.lax and p.peek() == '0' and p.i + 1 < p.s.len and (p.s[p.i + 1] == 'x' or p.s[p.i + 1] == 'X')) {
            p.i += 2;
            const hs = p.i;
            while (p.i < p.s.len and std.ascii.isHex(p.s[p.i])) p.i += 1;
            const v = std.fmt.parseInt(u64, p.s[hs..p.i], 16) catch return error.Syntax;
            return std.fmt.allocPrint(p.a, "{s}{d}", .{ if (neg) "-" else "", v });
        }
        if (p.lax and std.mem.startsWith(u8, p.s[p.i..], "Infinity")) {
            p.i += "Infinity".len;
            return if (neg) "-Infinity" else "Infinity";
        }
        const int_start = p.i;
        while (std.ascii.isDigit(p.peek())) p.i += 1;
        const int_part = p.s[int_start..p.i];
        var frac: []const u8 = "";
        var had_point = false;
        if (p.peek() == '.') {
            had_point = true;
            p.i += 1;
            const fs = p.i;
            while (std.ascii.isDigit(p.peek())) p.i += 1;
            frac = p.s[fs..p.i];
        }
        if (int_part.len == 0 and frac.len == 0) return error.Syntax;
        var exp: []const u8 = "";
        if (p.peek() == 'e' or p.peek() == 'E') {
            const es = p.i;
            p.i += 1;
            if (p.peek() == '+' or p.peek() == '-') p.i += 1;
            const ds = p.i;
            while (std.ascii.isDigit(p.peek())) p.i += 1;
            if (p.i == ds) return error.Syntax;
            exp = p.s[es..p.i];
        }
        const strict_ok = int_part.len > 0 and !(int_part.len > 1 and int_part[0] == '0') and
            !(had_point and frac.len == 0) and p.s[start] != '+';
        if (strict_ok) {
            const t = p.s[start..p.i];
            // Oracle writes the exponent letter in upper case.
            if (std.mem.indexOfScalar(u8, t, 'e')) |k| {
                const u = try p.a.dupe(u8, t);
                u[k] = 'E';
                return u;
            }
            return t;
        }
        if (!p.lax) return error.Syntax;
        // Canonical: strip '+' and leading zeros, 0 before '.', no bare '.'.
        var out: std.ArrayList(u8) = .empty;
        if (neg) try out.append(p.a, '-');
        var ip = std.mem.trimStart(u8, int_part, "0");
        if (ip.len == 0) ip = "0";
        try out.appendSlice(p.a, ip);
        if (frac.len > 0) {
            try out.append(p.a, '.');
            try out.appendSlice(p.a, frac);
        }
        try out.appendSlice(p.a, exp);
        if (std.mem.indexOfScalar(u8, out.items, 'e')) |k| out.items[k] = 'E';
        return out.items;
    }
};

fn eqlBytes(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ============================================================ serialize

pub const WriteOptions = struct {
    pretty: bool = false,
    /// Non-ASCII characters as \uXXXX.
    ascii: bool = false,
    /// Members sorted by name (JSON_SERIALIZE ... ORDERED).
    ordered: bool = false,
};

pub fn write(a: Allocator, out: *std.ArrayList(u8), v: Value, opts: WriteOptions) Allocator.Error!void {
    try writeAt(a, out, v, opts, 0);
}

pub fn toText(a: Allocator, v: Value, opts: WriteOptions) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try write(a, &out, v, opts);
    return out.items;
}

fn indent(a: Allocator, out: *std.ArrayList(u8), level: usize) Allocator.Error!void {
    try out.append(a, '\n');
    try out.appendNTimes(a, ' ', level * 2);
}

fn keyLess(_: void, l: Member, r: Member) bool {
    return std.mem.lessThan(u8, l.key, r.key);
}

fn isContainer(v: Value) bool {
    return v == .array or v == .object;
}

/// Oracle's PRETTY layout: two blanks of indentation, `"key" : value`, a
/// container on its own line (after its key too), an empty one as an
/// opening and a closing line.
fn writeAt(a: Allocator, out: *std.ArrayList(u8), v: Value, opts: WriteOptions, level: usize) Allocator.Error!void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .number => |t| try out.appendSlice(a, t),
        .string => |s| try writeString(a, out, s, opts.ascii),
        .array => |items| {
            try out.append(a, '[');
            for (items, 0..) |x, i| {
                if (i > 0) try out.append(a, ',');
                if (opts.pretty) try indent(a, out, level + 1);
                try writeAt(a, out, x, opts, level + 1);
            }
            if (opts.pretty) try indent(a, out, level);
            try out.append(a, ']');
        },
        .object => |ms_arg| {
            var ms = ms_arg;
            if (opts.ordered) {
                ms = try a.dupe(Member, ms_arg);
                std.mem.sort(Member, ms, {}, keyLess);
            }
            try out.append(a, '{');
            for (ms, 0..) |m, i| {
                if (i > 0) try out.append(a, ',');
                if (opts.pretty) try indent(a, out, level + 1);
                try writeString(a, out, m.key, opts.ascii);
                if (opts.pretty) {
                    try out.appendSlice(a, " :");
                    if (isContainer(m.value)) {
                        try indent(a, out, level + 1);
                    } else try out.append(a, ' ');
                } else try out.append(a, ':');
                try writeAt(a, out, m.value, opts, level + 1);
            }
            if (opts.pretty) try indent(a, out, level);
            try out.append(a, '}');
        },
    }
}

pub fn writeString(a: Allocator, out: *std.ArrayList(u8), s: []const u8, ascii: bool) Allocator.Error!void {
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            8 => try out.appendSlice(a, "\\b"),
            12 => try out.appendSlice(a, "\\f"),
            0...7, 11, 14...0x1f => {
                var buf: [8]u8 = undefined;
                try out.appendSlice(a, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable);
            },
            else => {
                if (c >= 0x80 and ascii) {
                    const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
                    if (i + n <= s.len) {
                        if (std.unicode.utf8Decode(s[i .. i + n])) |cp| {
                            var buf: [16]u8 = undefined;
                            if (cp >= 0x10000) {
                                const u = cp - 0x10000;
                                const hi: u21 = 0xd800 + (u >> 10);
                                const lo: u21 = 0xdc00 + (u & 0x3ff);
                                try out.appendSlice(a, std.fmt.bufPrint(&buf, "\\u{X:0>4}\\u{X:0>4}", .{ hi, lo }) catch unreachable);
                            } else {
                                try out.appendSlice(a, std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{cp}) catch unreachable);
                            }
                            i += n;
                            continue;
                        } else |_| {}
                    }
                }
                try out.append(a, c);
            },
        }
        i += 1;
    }
    try out.append(a, '"');
}

/// The JSON number text of a real (shortest round trip, no exponent for
/// ordinary magnitudes).
pub fn realText(a: Allocator, x: f64) Allocator.Error![]const u8 {
    if (x == @trunc(x) and @abs(x) < 1e18) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(x))});
    return std.fmt.allocPrint(a, "{d}", .{x});
}

// ================================================================= paths

pub const PathError = error{ BadPath, OutOfMemory };

pub const Path = struct {
    strict: bool = false,
    base: Base = .root,
    /// The variable of a `$name` base.
    variable: []const u8 = "",
    steps: []Step = &.{},

    pub const Base = enum { root, current, variable };

    /// A path of member steps only ($.a.b), which names one place.
    pub fn isSimple(path: Path) bool {
        for (path.steps) |s| switch (s) {
            .member => {},
            .array => |r| if (r.len != 1 or r[0].to != null) return false,
            else => return false,
        };
        return true;
    }
};

pub const Index = struct {
    /// LAST - n when `last`, else n.
    last: bool = false,
    n: i64 = 0,

    fn resolve(x: Index, len: usize) i64 {
        return if (x.last) @as(i64, @intCast(len)) - 1 - x.n else x.n;
    }
};

pub const Range = struct { from: Index, to: ?Index = null };

pub const Method = enum {
    size,
    type,
    length,
    lower,
    upper,
    number,
    numberOnly,
    string,
    stringOnly,
    boolean,
    booleanOnly,
    abs,
    ceiling,
    floor,
    double,
    count,
    sum,
    avg,
    min,
    max,
    date,
    timestamp,
    binary,
};

const method_names = [_]struct { []const u8, Method }{
    .{ "size", .size },             .{ "type", .type },       .{ "length", .length },           .{ "lower", .lower },
    .{ "upper", .upper },           .{ "number", .number },   .{ "numberOnly", .numberOnly },   .{ "string", .string },
    .{ "stringOnly", .stringOnly }, .{ "boolean", .boolean }, .{ "booleanOnly", .booleanOnly }, .{ "abs", .abs },
    .{ "ceiling", .ceiling },       .{ "floor", .floor },     .{ "double", .double },           .{ "float", .double },
    .{ "count", .count },           .{ "sum", .sum },         .{ "avg", .avg },                 .{ "min", .min },
    .{ "max", .max },               .{ "minNumber", .min },   .{ "maxNumber", .max },           .{ "date", .date },
    .{ "timestamp", .timestamp },
};

pub const Step = union(enum) {
    member: []const u8,
    /// .*
    any_member,
    /// ..name (null: ..*)
    descendant: ?[]const u8,
    /// [ranges]; null for [*].
    array: ?[]Range,
    filter: *Cond,
    method: Method,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge };

pub const Operand = union(enum) {
    path: Path,
    literal: Value,
};

pub const Cond = union(enum) {
    @"and": [2]*Cond,
    @"or": [2]*Cond,
    not: *Cond,
    exists: Path,
    cmp: struct { op: CmpOp, l: Operand, r: Operand },
    starts_with: struct { l: Operand, r: Operand },
    has_substring: struct { l: Operand, r: Operand },
    like: struct { l: Operand, r: Operand },
    in_list: struct { l: Operand, items: []Value },
};

/// Parse an SQL/JSON path expression ('$.a[0]', 'strict $.a?(@ > 1)').
pub fn parsePath(a: Allocator, text: []const u8) PathError!Path {
    var p: PathParser = .{ .a = a, .s = text };
    p.blank();
    var strict = false;
    if (p.word("strict")) {
        strict = true;
    } else _ = p.word("lax");
    p.blank();
    if (p.peek() != '$') return error.BadPath;
    var path = try p.pathFrom(false);
    path.strict = strict;
    p.blank();
    if (p.i != p.s.len) return error.BadPath;
    if (path.base != .root) return error.BadPath;
    return path;
}

const PathParser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn peek(p: *const PathParser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn peekAt(p: *const PathParser, k: usize) u8 {
        return if (p.i + k < p.s.len) p.s[p.i + k] else 0;
    }

    fn blank(p: *PathParser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    /// The keyword `w` (followed by no name character).
    fn word(p: *PathParser, w: []const u8) bool {
        if (p.i + w.len > p.s.len) return false;
        if (!std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + w.len], w)) return false;
        const after = p.peekAt(w.len);
        if (std.ascii.isAlphanumeric(after) or after == '_') return false;
        p.i += w.len;
        return true;
    }

    fn name(p: *PathParser) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_' or p.s[p.i] == '$' or p.s[p.i] >= 0x80)) p.i += 1;
        return p.s[start..p.i];
    }

    fn quoted(p: *PathParser) PathError![]const u8 {
        var jp: Parser = .{ .a = p.a, .s = p.s, .i = p.i, .lax = false };
        const s = jp.string('"') catch return error.BadPath;
        p.i = jp.i;
        return s;
    }

    /// `$`, `@` or `$name`, and the steps after it. In a filter
    /// (`in_filter`), `@` may start it.
    fn pathFrom(p: *PathParser, in_filter: bool) PathError!Path {
        var path: Path = .{};
        if (p.peek() == '@') {
            if (!in_filter) return error.BadPath;
            path.base = .current;
            p.i += 1;
        } else if (p.peek() == '$') {
            p.i += 1;
            const n = p.name();
            if (n.len > 0) {
                path.base = .variable;
                path.variable = n;
            }
        } else return error.BadPath;
        var steps: std.ArrayList(Step) = .empty;
        while (true) {
            p.blank();
            const c = p.peek();
            if (c == '.') {
                p.i += 1;
                if (p.peek() == '.') {
                    p.i += 1;
                    if (p.peek() == '*') {
                        p.i += 1;
                        try steps.append(p.a, .{ .descendant = null });
                    } else if (p.peek() == '"') {
                        try steps.append(p.a, .{ .descendant = try p.quoted() });
                    } else {
                        const n = p.name();
                        if (n.len == 0) return error.BadPath;
                        try steps.append(p.a, .{ .descendant = n });
                    }
                    continue;
                }
                p.blank();
                if (p.peek() == '*') {
                    p.i += 1;
                    try steps.append(p.a, .any_member);
                    continue;
                }
                if (p.peek() == '"') {
                    try steps.append(p.a, .{ .member = try p.quoted() });
                    continue;
                }
                const n = p.name();
                if (n.len == 0) return error.BadPath;
                p.blank();
                if (p.peek() == '(' and p.peekAt(1) == ')') {
                    p.i += 2;
                    const m = for (method_names) |mn| {
                        if (std.mem.eql(u8, mn[0], n)) break mn[1];
                    } else return error.BadPath;
                    try steps.append(p.a, .{ .method = m });
                    continue;
                }
                try steps.append(p.a, .{ .member = n });
                continue;
            }
            if (c == '[') {
                p.i += 1;
                p.blank();
                if (p.peek() == '*') {
                    p.i += 1;
                    p.blank();
                    if (p.peek() != ']') return error.BadPath;
                    p.i += 1;
                    try steps.append(p.a, .{ .array = null });
                    continue;
                }
                var ranges: std.ArrayList(Range) = .empty;
                while (true) {
                    p.blank();
                    var r: Range = .{ .from = try p.index() };
                    p.blank();
                    if (p.word("to")) {
                        p.blank();
                        r.to = try p.index();
                    }
                    try ranges.append(p.a, r);
                    p.blank();
                    if (p.peek() == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.peek() != ']') return error.BadPath;
                    p.i += 1;
                    break;
                }
                try steps.append(p.a, .{ .array = ranges.items });
                continue;
            }
            if (c == '?') {
                p.i += 1;
                p.blank();
                if (p.peek() != '(') return error.BadPath;
                p.i += 1;
                const cond = try p.orCond();
                p.blank();
                if (p.peek() != ')') return error.BadPath;
                p.i += 1;
                try steps.append(p.a, .{ .filter = cond });
                continue;
            }
            break;
        }
        path.steps = steps.items;
        return path;
    }

    fn index(p: *PathParser) PathError!Index {
        if (p.word("last")) {
            p.blank();
            if (p.peek() == '-') {
                p.i += 1;
                p.blank();
                return .{ .last = true, .n = try p.int() };
            }
            return .{ .last = true };
        }
        return .{ .n = try p.int() };
    }

    fn int(p: *PathParser) PathError!i64 {
        const start = p.i;
        while (std.ascii.isDigit(p.peek())) p.i += 1;
        if (p.i == start) return error.BadPath;
        return std.fmt.parseInt(i64, p.s[start..p.i], 10) catch error.BadPath;
    }

    fn newCond(p: *PathParser, c: Cond) PathError!*Cond {
        const x = try p.a.create(Cond);
        x.* = c;
        return x;
    }

    fn orCond(p: *PathParser) PathError!*Cond {
        var l = try p.andCond();
        while (true) {
            p.blank();
            if (p.peek() == '|' and p.peekAt(1) == '|') {
                p.i += 2;
                const r = try p.andCond();
                l = try p.newCond(.{ .@"or" = .{ l, r } });
            } else return l;
        }
    }

    fn andCond(p: *PathParser) PathError!*Cond {
        var l = try p.notCond();
        while (true) {
            p.blank();
            if (p.peek() == '&' and p.peekAt(1) == '&') {
                p.i += 2;
                const r = try p.notCond();
                l = try p.newCond(.{ .@"and" = .{ l, r } });
            } else return l;
        }
    }

    fn notCond(p: *PathParser) PathError!*Cond {
        p.blank();
        if (p.peek() == '!' and p.peekAt(1) != '=') {
            p.i += 1;
            p.blank();
            return p.newCond(.{ .not = try p.notCond() });
        }
        return p.atomCond();
    }

    fn atomCond(p: *PathParser) PathError!*Cond {
        p.blank();
        if (p.peek() == '(') {
            p.i += 1;
            const c = try p.orCond();
            p.blank();
            if (p.peek() != ')') return error.BadPath;
            p.i += 1;
            return c;
        }
        if (p.word("exists")) {
            p.blank();
            if (p.peek() != '(') return error.BadPath;
            p.i += 1;
            p.blank();
            const path = try p.pathFrom(true);
            p.blank();
            if (p.peek() != ')') return error.BadPath;
            p.i += 1;
            return p.newCond(.{ .exists = path });
        }
        const l = try p.operand();
        p.blank();
        if (p.word("starts")) {
            p.blank();
            if (!p.word("with")) return error.BadPath;
            p.blank();
            return p.newCond(.{ .starts_with = .{ .l = l, .r = try p.operand() } });
        }
        if (p.word("has")) {
            p.blank();
            if (!p.word("substring")) return error.BadPath;
            p.blank();
            return p.newCond(.{ .has_substring = .{ .l = l, .r = try p.operand() } });
        }
        if (p.word("like")) {
            p.blank();
            return p.newCond(.{ .like = .{ .l = l, .r = try p.operand() } });
        }
        if (p.word("in")) {
            p.blank();
            if (p.peek() != '(') return error.BadPath;
            p.i += 1;
            var items: std.ArrayList(Value) = .empty;
            while (true) {
                p.blank();
                const o = try p.operand();
                if (o != .literal) return error.BadPath;
                try items.append(p.a, o.literal);
                p.blank();
                if (p.peek() == ',') {
                    p.i += 1;
                    continue;
                }
                if (p.peek() != ')') return error.BadPath;
                p.i += 1;
                break;
            }
            return p.newCond(.{ .in_list = .{ .l = l, .items = items.items } });
        }
        const ops = [_]struct { []const u8, CmpOp }{
            .{ "==", .eq }, .{ "!=", .ne }, .{ "<>", .ne }, .{ "<=", .le }, .{ ">=", .ge }, .{ "<", .lt }, .{ ">", .gt },
        };
        for (ops) |o| {
            if (std.mem.startsWith(u8, p.s[p.i..], o[0])) {
                p.i += o[0].len;
                p.blank();
                const r = try p.operand();
                return p.newCond(.{ .cmp = .{ .op = o[1], .l = l, .r = r } });
            }
        }
        return error.BadPath;
    }

    fn operand(p: *PathParser) PathError!Operand {
        p.blank();
        const c = p.peek();
        if (c == '@' or c == '$') return .{ .path = try p.pathFrom(true) };
        if (c == '"') return .{ .literal = .{ .string = try p.quoted() } };
        if (c == '-' or c == '+' or c == '.' or std.ascii.isDigit(c)) {
            var jp: Parser = .{ .a = p.a, .s = p.s, .i = p.i, .lax = true };
            const n = jp.number() catch return error.BadPath;
            p.i = jp.i;
            return .{ .literal = .{ .number = n } };
        }
        if (p.word("true")) return .{ .literal = .{ .bool = true } };
        if (p.word("false")) return .{ .literal = .{ .bool = false } };
        if (p.word("null")) return .{ .literal = .null };
        return error.BadPath;
    }
};

// ============================================================ evaluate

pub const EvalError = error{ Eval, OutOfMemory };

pub const Var = struct { name: []const u8, value: Value };

pub const Eval = struct {
    a: Allocator,
    strict: bool,
    root: Value,
    vars: []const Var = &.{},

    /// The items `path` selects (in a filter, from `current`).
    pub fn run(e: *Eval, path: Path, current: Value) EvalError![]Value {
        const start: Value = switch (path.base) {
            .root => e.root,
            .current => current,
            .variable => blk: {
                for (e.vars) |v| if (std.mem.eql(u8, v.name, path.variable)) break :blk v.value;
                return error.Eval;
            },
        };
        var items: std.ArrayList(Value) = .empty;
        try items.append(e.a, start);
        for (path.steps) |s| items = try e.step(s, items.items);
        return items.items;
    }

    fn step(e: *Eval, s: Step, in: []const Value) EvalError!std.ArrayList(Value) {
        var out: std.ArrayList(Value) = .empty;
        for (in) |v| try e.stepOne(s, v, &out, true);
        return out;
    }

    fn stepOne(e: *Eval, s: Step, v: Value, out: *std.ArrayList(Value), unwrap: bool) EvalError!void {
        switch (s) {
            .member => |k| switch (v) {
                .object => |ms| {
                    var found = false;
                    for (ms) |m| if (std.mem.eql(u8, m.key, k)) {
                        try out.append(e.a, m.value);
                        found = true;
                        break;
                    };
                    if (!found and e.strict) return error.Eval;
                },
                .array => |items| {
                    if (e.strict or !unwrap) return if (e.strict) error.Eval else {};
                    for (items) |x| try e.stepOne(s, x, out, false);
                },
                else => if (e.strict) return error.Eval,
            },
            .any_member => switch (v) {
                .object => |ms| for (ms) |m| try out.append(e.a, m.value),
                .array => |items| {
                    if (e.strict) return error.Eval;
                    if (unwrap) for (items) |x| try e.stepOne(s, x, out, false);
                },
                else => if (e.strict) return error.Eval,
            },
            .descendant => |k| try e.descend(k, v, out),
            .array => |ranges| {
                const items: []const Value = switch (v) {
                    .array => |x| x,
                    else => blk: {
                        if (e.strict) return error.Eval;
                        break :blk &.{v};
                    },
                };
                const rs = ranges orelse {
                    try out.appendSlice(e.a, items);
                    return;
                };
                for (rs) |r| {
                    const from = r.from.resolve(items.len);
                    const to = if (r.to) |t| t.resolve(items.len) else from;
                    if (from < 0 or to >= items.len or from > to) {
                        if (e.strict) return error.Eval;
                    }
                    var k = @max(from, 0);
                    while (k <= to and k < items.len) : (k += 1) try out.append(e.a, items[@intCast(k)]);
                }
            },
            .filter => |c| {
                if (v == .array and !e.strict and unwrap) {
                    for (v.array) |x| try e.stepOne(s, x, out, false);
                    return;
                }
                if (try e.cond(c, v) == .true) try out.append(e.a, v);
            },
            .method => |m| try e.method(m, v, out, unwrap),
        }
    }

    fn descend(e: *Eval, k: ?[]const u8, v: Value, out: *std.ArrayList(Value)) EvalError!void {
        switch (v) {
            .object => |ms| for (ms) |m| {
                if (k == null or std.mem.eql(u8, m.key, k.?)) try out.append(e.a, m.value);
                try e.descend(k, m.value, out);
            },
            .array => |items| for (items) |x| try e.descend(k, x, out),
            else => {},
        }
    }

    fn method(e: *Eval, m: Method, v: Value, out: *std.ArrayList(Value), unwrap: bool) EvalError!void {
        switch (m) {
            .size => return out.append(e.a, .{ .number = try std.fmt.allocPrint(e.a, "{d}", .{if (v == .array) v.array.len else 1}) }),
            .type => return out.append(e.a, .{ .string = v.typeName() }),
            .count, .sum, .avg, .min, .max => {
                const items: []const Value = if (v == .array) v.array else &.{v};
                if (m == .count) return out.append(e.a, .{ .number = try std.fmt.allocPrint(e.a, "{d}", .{items.len}) });
                var acc: f64 = 0;
                var n: usize = 0;
                var best: ?Value = null;
                var best_x: f64 = 0;
                for (items) |x| {
                    const f = x.toF64() orelse return error.Eval;
                    acc += f;
                    n += 1;
                    if (best == null or (m == .min and f < best_x) or (m == .max and f > best_x)) {
                        best = x;
                        best_x = f;
                    }
                }
                if (m == .min or m == .max) {
                    if (best) |b| try out.append(e.a, b);
                    return;
                }
                if (n == 0) return;
                const r = if (m == .avg) acc / @as(f64, @floatFromInt(n)) else acc;
                return out.append(e.a, .{ .number = try realText(e.a, r) });
            },
            else => {},
        }
        if (v == .array and unwrap and !e.strict) {
            for (v.array) |x| try e.method(m, x, out, false);
            return;
        }
        switch (m) {
            .length => {
                if (v != .string) return error.Eval;
                return out.append(e.a, .{ .number = try std.fmt.allocPrint(e.a, "{d}", .{std.unicode.utf8CountCodepoints(v.string) catch v.string.len}) });
            },
            .lower, .upper => {
                if (v != .string) return error.Eval;
                const s = try e.a.dupe(u8, v.string);
                for (s) |*c| c.* = if (m == .lower) std.ascii.toLower(c.*) else std.ascii.toUpper(c.*);
                return out.append(e.a, .{ .string = s });
            },
            .number, .numberOnly, .double => switch (v) {
                .number => return out.append(e.a, v),
                .string => |s| {
                    if (m == .numberOnly) return error.Eval;
                    const t = std.mem.trim(u8, s, " ");
                    var jp: Parser = .{ .a = e.a, .s = t, .lax = true };
                    const n = jp.number() catch return error.Eval;
                    if (jp.i != t.len) return error.Eval;
                    return out.append(e.a, .{ .number = n });
                },
                else => return error.Eval,
            },
            .string, .stringOnly => switch (v) {
                .string => return out.append(e.a, v),
                .number => |t| {
                    if (m == .stringOnly) return error.Eval;
                    return out.append(e.a, .{ .string = t });
                },
                .bool => |b| {
                    if (m == .stringOnly) return error.Eval;
                    return out.append(e.a, .{ .string = if (b) "true" else "false" });
                },
                else => return error.Eval,
            },
            .boolean, .booleanOnly => switch (v) {
                .bool => return out.append(e.a, v),
                .string => |s| {
                    if (m == .booleanOnly) return error.Eval;
                    if (std.ascii.eqlIgnoreCase(s, "true")) return out.append(e.a, .{ .bool = true });
                    if (std.ascii.eqlIgnoreCase(s, "false")) return out.append(e.a, .{ .bool = false });
                    return error.Eval;
                },
                else => return error.Eval,
            },
            .abs, .ceiling, .floor => {
                const x = v.toF64() orelse return error.Eval;
                const r = switch (m) {
                    .abs => @abs(x),
                    .ceiling => @ceil(x),
                    else => @floor(x),
                };
                if (m == .abs and v.number.len > 0 and v.number[0] != '-') return out.append(e.a, v);
                if (m == .abs) return out.append(e.a, .{ .number = v.number[1..] });
                return out.append(e.a, .{ .number = try realText(e.a, r) });
            },
            .date, .timestamp, .binary => {
                if (v != .string) return error.Eval;
                return out.append(e.a, v);
            },
            else => unreachable,
        }
    }

    pub const Truth = enum { true, false, unknown };

    fn operandItems(e: *Eval, o: Operand, current: Value) EvalError![]Value {
        return switch (o) {
            .literal => |v| blk: {
                const x = try e.a.alloc(Value, 1);
                x[0] = v;
                break :blk x;
            },
            .path => |p| blk: {
                // Comparisons unwrap arrays (lax).
                const r = try e.run(p, current);
                if (e.strict) break :blk r;
                var out: std.ArrayList(Value) = .empty;
                for (r) |x| {
                    if (x == .array) try out.appendSlice(e.a, x.array) else try out.append(e.a, x);
                }
                break :blk out.items;
            },
        };
    }

    fn cond(e: *Eval, c: *const Cond, current: Value) EvalError!Truth {
        switch (c.*) {
            .@"and" => |x| {
                const l = try e.cond(x[0], current);
                if (l == .false) return .false;
                const r = try e.cond(x[1], current);
                if (r == .false) return .false;
                if (l == .unknown or r == .unknown) return .unknown;
                return .true;
            },
            .@"or" => |x| {
                const l = try e.cond(x[0], current);
                if (l == .true) return .true;
                const r = try e.cond(x[1], current);
                if (r == .true) return .true;
                if (l == .unknown or r == .unknown) return .unknown;
                return .false;
            },
            .not => |x| return switch (try e.cond(x, current)) {
                .true => .false,
                .false => .true,
                .unknown => .unknown,
            },
            .exists => |p| {
                const r = e.run(p, current) catch |err| switch (err) {
                    error.Eval => return .unknown,
                    else => |x| return x,
                };
                return if (r.len > 0) .true else .false;
            },
            .cmp => |x| {
                const ls = e.operandItems(x.l, current) catch |err| return evalUnknown(err);
                const rs = e.operandItems(x.r, current) catch |err| return evalUnknown(err);
                var unknown = false;
                for (ls) |l| for (rs) |r| switch (compare(x.op, l, r)) {
                    .true => return .true,
                    .unknown => unknown = true,
                    .false => {},
                };
                return if (unknown) .unknown else .false;
            },
            .starts_with, .has_substring, .like => {
                const lo, const ro = switch (c.*) {
                    .starts_with => |x| .{ x.l, x.r },
                    .has_substring => |x| .{ x.l, x.r },
                    .like => |x| .{ x.l, x.r },
                    else => unreachable,
                };
                const ls = e.operandItems(lo, current) catch |err| return evalUnknown(err);
                const rs = e.operandItems(ro, current) catch |err| return evalUnknown(err);
                for (ls) |l| for (rs) |r| {
                    if (l != .string or r != .string) continue;
                    const ok = switch (c.*) {
                        .starts_with => std.mem.startsWith(u8, l.string, r.string),
                        .has_substring => std.mem.indexOf(u8, l.string, r.string) != null,
                        else => likeMatch(l.string, r.string),
                    };
                    if (ok) return .true;
                };
                return .false;
            },
            .in_list => |x| {
                const ls = e.operandItems(x.l, current) catch |err| return evalUnknown(err);
                for (ls) |l| for (x.items) |r| if (compare(.eq, l, r) == .true) return .true;
                return .false;
            },
        }
    }
};

fn evalUnknown(err: EvalError) EvalError!Eval.Truth {
    return switch (err) {
        error.Eval => .unknown,
        else => |x| x,
    };
}

/// The order of two scalars of one type, null when they do not compare.
pub fn order(l: Value, r: Value) ?std.math.Order {
    switch (l) {
        .number => {
            if (r != .number) return null;
            const a = l.toF64() orelse return null;
            const b = r.toF64() orelse return null;
            return std.math.order(a, b);
        },
        .string => |s| {
            if (r != .string) return null;
            return std.mem.order(u8, s, r.string);
        },
        .bool => |b| {
            if (r != .bool) return null;
            return std.math.order(@intFromBool(b), @intFromBool(r.bool));
        },
        .null => return if (r == .null) .eq else null,
        else => return null,
    }
}

fn compare(op: CmpOp, l: Value, r: Value) Eval.Truth {
    if (!l.isScalar() or !r.isScalar()) return .unknown;
    // null compares equal only with null; with other types it is not
    // equal (and not ordered).
    if (l == .null or r == .null) {
        const same = l == .null and r == .null;
        return switch (op) {
            .eq => if (same) .true else .false,
            .ne => if (same) .false else .true,
            else => .false,
        };
    }
    const o = order(l, r) orelse return .unknown;
    const ok = switch (op) {
        .eq => o == .eq,
        .ne => o != .eq,
        .lt => o == .lt,
        .le => o != .gt,
        .gt => o == .gt,
        .ge => o != .lt,
    };
    return if (ok) .true else .false;
}

/// LIKE with % and _ (no escape).
fn likeMatch(s: []const u8, pat: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    if (pat[0] == '%') {
        var k: usize = 0;
        while (k <= s.len) : (k += 1) if (likeMatch(s[k..], pat[1..])) return true;
        return false;
    }
    if (s.len == 0) return false;
    if (pat[0] == '_' or pat[0] == s[0]) return likeMatch(s[1..], pat[1..]);
    return false;
}

test "oracle json: parse and write" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, " {\"a\" : [1, 2.5, \"x\\n\"], b: 'q', \"c\": TRUE, d: .5} ", .{});
    try std.testing.expectEqualStrings("{\"a\":[1,2.5,\"x\\n\"],\"b\":\"q\",\"c\":true,\"d\":0.5}", try toText(a, v, .{}));
    try std.testing.expectError(error.Syntax, parse(a, "{a:1}", .{ .lax = false }));
    try std.testing.expect(hasDuplicateKeys(try parse(a, "{\"a\":1,\"a\":2}", .{})));
}

test "oracle json: paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a, "{\"a\":[{\"b\":1},{\"b\":5}],\"s\":\"xy\"}", .{});
    var e: Eval = .{ .a = a, .strict = false, .root = doc };
    const r = try e.run(try parsePath(a, "$.a.b"), doc);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    const f = try e.run(try parsePath(a, "$.a[*]?(@.b > 3).b"), doc);
    try std.testing.expectEqualStrings("5", f[0].number);
    const l = try e.run(try parsePath(a, "$.a[last].b"), doc);
    try std.testing.expectEqualStrings("5", l[0].number);
    const sz = try e.run(try parsePath(a, "$.a.size()"), doc);
    try std.testing.expectEqualStrings("2", sz[0].number);
    try std.testing.expectEqual(@as(usize, 1), (try e.run(try parsePath(a, "$?(@.s starts with \"x\")"), doc)).len);
}
