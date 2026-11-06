//! PostgreSQL's array text (array_in() and array_out()): `{1,2,NULL}`,
//! `{"a b",c}`, `{{1,2},{3,4}}`, with the bounds before it when a lower
//! bound is not 1 (`[0:1]={1,2}`), and the space-separated integers of an
//! int2vector or oidvector (`1 2`, from 0). An element is its text; what
//! it means is the element type's, the caller's.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_dims = 6;

/// An array: its dimensions (none if empty) and its elements, the last
/// dimension's fastest; an element is its text (null for NULL).
pub const Array = struct {
    ndim: u8 = 0,
    dims: [max_dims]u32 = @splat(0),
    lower: [max_dims]i32 = @splat(1),
    elems: []?[]const u8 = &.{},

    pub fn count(x: *const Array) usize {
        if (x.ndim == 0) return 0;
        var n: usize = 1;
        for (x.dims[0..x.ndim]) |d| n *= d;
        return n;
    }

    /// A one-dimensional array of `elems` (from 1).
    pub fn list(elems: []?[]const u8) Array {
        var x: Array = .{ .elems = elems };
        if (elems.len > 0) {
            x.ndim = 1;
            x.dims[0] = @intCast(elems.len);
        }
        return x;
    }

    /// The upper bound of dimension `d`.
    pub fn upper(x: *const Array, d: usize) i64 {
        return @as(i64, x.lower[d]) + x.dims[d] - 1;
    }
};

pub const ParseError = error{ Malformed, OutOfMemory };

const Parse = struct {
    a: Allocator,
    z: []const u8,
    i: usize = 0,
    out: std.ArrayList(?[]const u8) = .empty,
    x: Array = .{},
    seen: [max_dims]bool = @splat(false),
    /// PostgreSQL's DETAIL of the error, if known (parseWith()).
    detail: ?[]const u8 = null,
    /// The text gave the dimensions ([1:2]=...).
    dims_given: bool = false,

    /// Malformed, with PostgreSQL's DETAIL.
    fn bad(p: *Parse, detail: []const u8) error{Malformed} {
        p.detail = detail;
        return error.Malformed;
    }

    /// Malformed: the sub-arrays do not match (dimension_error).
    fn dimensionError(p: *Parse) error{Malformed} {
        return p.bad(if (p.dims_given) "Specified array dimensions do not match array contents." else "Multidimensional arrays must have sub-arrays with matching dimensions.");
    }

    const end_of_input = "Unexpected end of input.";

    fn ws(p: *Parse) void {
        while (p.i < p.z.len and isSpace(p.z[p.i])) p.i += 1;
    }

    fn peek(p: *const Parse) ?u8 {
        return if (p.i < p.z.len) p.z[p.i] else null;
    }

    fn int(p: *Parse) ?i64 {
        const start = p.i;
        if (p.i < p.z.len and (p.z[p.i] == '-' or p.z[p.i] == '+')) p.i += 1;
        while (p.i < p.z.len and std.ascii.isDigit(p.z[p.i])) p.i += 1;
        return std.fmt.parseInt(i64, p.z[start..p.i], 10) catch null;
    }

    fn level(p: *Parse, depth: usize) ParseError!void {
        if (depth >= max_dims) return error.Malformed;
        p.i += 1; // {
        p.ws();
        var n: u32 = 0;
        if (p.peek() == '}') {
            p.i += 1;
            // {} only as the whole array.
            if (depth != 0) return error.Malformed;
            return;
        }
        while (true) {
            p.ws();
            const c = p.peek() orelse return p.bad(end_of_input);
            const quoted = c == '"';
            if (c == '{') {
                if (p.x.ndim != 0 and depth + 1 >= p.x.ndim) return p.dimensionError();
                try p.level(depth + 1);
                if (p.x.ndim == 0) return error.Malformed;
            } else {
                if (p.x.ndim == 0) p.x.ndim = @intCast(depth + 1) else if (p.x.ndim != depth + 1) return p.dimensionError();
                try p.element();
            }
            n += 1;
            p.ws();
            const d = p.peek() orelse return p.bad(end_of_input);
            p.i += 1;
            if (d == ',') continue;
            if (d == '}') break;
            // ReadArrayToken(): what may not follow an element.
            if (d == '{') return p.bad("Unexpected \"{\" character.");
            return p.bad(if (quoted) "Incorrectly quoted array element." else "Unexpected array element.");
        }
        if (!p.seen[depth]) {
            p.seen[depth] = true;
            p.x.dims[depth] = n;
        } else if (p.x.dims[depth] != n) return p.dimensionError();
    }

    /// An element: a slice of the text where it has no escape, else its
    /// unescaped copy.
    fn element(p: *Parse) ParseError!void {
        if (p.peek() == '"') {
            p.i += 1;
            const start = p.i;
            var buf: ?std.ArrayList(u8) = null;
            while (true) {
                const c = p.peek() orelse return p.bad(end_of_input);
                p.i += 1;
                if (c == '"') break;
                if (c == '\\') {
                    const e = p.peek() orelse return p.bad(end_of_input);
                    if (buf == null) buf = .fromOwnedSlice(try p.a.dupe(u8, p.z[start .. p.i - 1]));
                    p.i += 1;
                    try buf.?.append(p.a, e);
                } else if (buf) |*b| try b.append(p.a, c);
            }
            return p.out.append(p.a, if (buf) |b| b.items else p.z[start .. p.i - 1]);
        }
        const start = p.i;
        var buf: ?std.ArrayList(u8) = null;
        var keep: usize = 0; // the length without trailing blanks
        while (true) {
            const c = p.peek() orelse return p.bad(end_of_input);
            if (c == ',' or c == '}') break;
            if (c == '{') return p.bad("Unexpected \"{\" character.");
            if (c == '"') return p.bad("Incorrectly quoted array element.");
            p.i += 1;
            if (c == '\\') {
                const e = p.peek() orelse return p.bad(end_of_input);
                if (buf == null) buf = .fromOwnedSlice(try p.a.dupe(u8, p.z[start .. p.i - 1]));
                p.i += 1;
                try buf.?.append(p.a, e);
                keep = buf.?.items.len;
            } else if (buf) |*b| {
                try b.append(p.a, c);
                if (!isSpace(c)) keep = b.items.len;
            } else if (!isSpace(c)) keep = p.i - start;
        }
        const text = if (buf) |b| b.items[0..keep] else p.z[start..][0..keep];
        // A delimiter or a brace where an element is expected.
        if (text.len == 0) return p.bad(if (p.z[p.i] == ',') "Unexpected \",\" character." else "Unexpected \"}\" character.");
        if (buf == null and std.ascii.eqlIgnoreCase(text, "null")) return p.out.append(p.a, null);
        try p.out.append(p.a, text);
    }
};

/// array_isspace(): the blanks array_in() skips.
pub const isSpace = std.ascii.isWhitespace;

/// Array `z` (array_in()'s syntax). `vector`: also the space-separated
/// integers of an int2vector or oidvector (`1 2`, from 0).
pub fn parse(a: Allocator, z: []const u8, vector: bool) ParseError!Array {
    var detail: ?[]const u8 = null;
    return parseWith(a, z, vector, &detail);
}

/// parse(), leaving PostgreSQL's DETAIL of a malformed array in
/// `detail` where it is known (static text).
pub fn parseWith(a: Allocator, z: []const u8, vector: bool, detail: *?[]const u8) ParseError!Array {
    var p: Parse = .{ .a = a, .z = z };
    defer detail.* = p.detail;
    p.ws();
    // [lo:hi][lo:hi]=
    var bounds: [max_dims][2]i64 = undefined;
    var nb: usize = 0;
    while (p.peek() == '[') {
        if (nb == max_dims) return error.Malformed;
        p.i += 1;
        p.ws();
        p.dims_given = true;
        const lo = p.int() orelse return p.bad("\"[\" must introduce explicitly-specified array dimensions.");
        p.ws();
        var hi = lo;
        var l = lo;
        if (p.peek() == ':') {
            p.i += 1;
            p.ws();
            hi = p.int() orelse return p.bad("Missing array dimension value.");
            p.ws();
        } else l = 1;
        if (p.peek() != ']') return p.bad("Missing \"]\" after array dimensions.");
        p.i += 1;
        if (hi < l - 1) return error.Malformed;
        bounds[nb] = .{ l, hi };
        nb += 1;
        p.ws();
    }
    if (nb > 0) {
        if (p.peek() != '=') return p.bad("Missing \"=\" after array dimensions.");
        p.i += 1;
        p.ws();
    }
    if (p.peek() != '{') {
        const must = "Array value must start with \"{\" or dimension information.";
        if (nb == 0 and vector) return parseVector(a, z) catch |err| if (err == error.Malformed) p.bad(must) else err;
        return p.bad(must);
    }
    try p.level(0);
    p.ws();
    if (p.i != p.z.len) return p.bad("Junk after closing right brace.");
    p.x.elems = p.out.items;
    if (nb > 0) {
        if (nb != p.x.ndim) return p.dimensionError();
        for (bounds[0..nb], 0..) |b, d| {
            if (b[1] - b[0] + 1 != p.x.dims[d]) return p.dimensionError();
            p.x.lower[d] = std.math.cast(i32, b[0]) orelse return error.Malformed;
        }
    }
    return p.x;
}

fn parseVector(a: Allocator, z: []const u8) ParseError!Array {
    var out: std.ArrayList(?[]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, z, &std.ascii.whitespace);
    while (it.next()) |w| {
        _ = std.fmt.parseInt(i64, w, 10) catch return error.Malformed;
        try out.append(a, w);
    }
    var x = Array.list(out.items);
    x.lower[0] = 0;
    return x;
}

/// The text of `x`, as array_out() writes it.
pub fn write(a: Allocator, x: *const Array) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeTo(a, &out, x);
    return out.items;
}

pub fn writeTo(a: Allocator, out: *std.ArrayList(u8), x: *const Array) error{OutOfMemory}!void {
    if (x.ndim == 0 or x.count() == 0) return out.appendSlice(a, "{}");
    var decorate = false;
    for (x.lower[0..x.ndim]) |l| {
        if (l != 1) decorate = true;
    }
    if (decorate) {
        for (0..x.ndim) |d| try out.print(a, "[{d}:{d}]", .{ x.lower[d], x.upper(d) });
        try out.append(a, '=');
    }
    var i: usize = 0;
    try writeLevel(a, out, x, 0, &i);
}

fn writeLevel(a: Allocator, out: *std.ArrayList(u8), x: *const Array, d: usize, i: *usize) error{OutOfMemory}!void {
    try out.append(a, '{');
    for (0..x.dims[d]) |k| {
        if (k > 0) try out.append(a, ',');
        if (d + 1 < x.ndim) {
            try writeLevel(a, out, x, d + 1, i);
        } else {
            try writeElem(a, out, x.elems[i.*]);
            i.* += 1;
        }
    }
    try out.append(a, '}');
}

/// An element as array_out() writes it (null: NULL): quoted if empty,
/// NULL, or with blanks or `{},"\`.
pub fn writeElem(a: Allocator, out: *std.ArrayList(u8), e: ?[]const u8) error{OutOfMemory}!void {
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

fn expectRound(in: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const x = try parse(arena.allocator(), in, false);
    try std.testing.expectEqualStrings(want, try write(arena.allocator(), &x));
}

test "array literals" {
    try expectRound("{1,2,NULL}", "{1,2,NULL}");
    try expectRound(" { 1 , 2 } ", "{1,2}");
    try expectRound("{\"a b\",c,\"\",\"NULL\",d\\,e}", "{\"a b\",c,\"\",\"NULL\",\"d,e\"}");
    try expectRound("{{1,2},{3,4}}", "{{1,2},{3,4}}");
    try expectRound("[0:1]={1,2}", "[0:1]={1,2}");
    try expectRound("[1:2]={1,2}", "{1,2}");
    try expectRound("{}", "{}");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "x", "{1,2", "{{1},{2,3}}", "{1,{2}}", "{{1},2}", "{,}", "[1:3]={1,2}", "{a\"b}", "{{}}" }) |bad| {
        try std.testing.expectError(error.Malformed, parse(a, bad, false));
    }
    const v = try parse(a, "1 2 3", true);
    try std.testing.expectEqual(@as(i32, 0), v.lower[0]);
    try std.testing.expectEqual(@as(usize, 3), v.count());
}
