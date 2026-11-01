//! SQL Server's JSON text: the scanner, paths and escaping behind the
//! T-SQL dialect's JSON functions (json_func.zig).
//!
//! SQL Server keeps JSON as text and returns pieces of it as written
//! (JSON_QUERY, OPENJSON's value, the parts JSON_MODIFY leaves alone,
//! spaces included), so this works on byte ranges of the text (Item)
//! instead of a tree. The grammar is RFC 8259's without JSON5's
//! extensions (unlike SQLite's json functions), and a document is an
//! object or an array.
//!
//! SQL Server reads a document as far as it needs: JSON_VALUE and
//! JSON_QUERY stop at the value they find (`{"a":1` has an `a`), OPENJSON
//! reads an element at a time, ISJSON and JSON_MODIFY read everything.
//! A syntax error is at the character offset of the token that is wrong
//! (a string, number or literal at its start), and the end of the text
//! is the character '.' (as SQL Server reports it).
//!
//! Paths: `[append ][lax |strict ]$` followed by `.key`, `."key"` and
//! `[n]` steps; keys compare as decoded strings, case-sensitively, and
//! the first of duplicate keys counts.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const json_text = @import("../json_text.zig");

/// The types of values, numbered as OPENJSON's type column.
pub const Kind = enum(u8) { null = 0, string = 1, number = 2, boolean = 3, array = 4, object = 5 };

/// A value of the text: z[start..end].
pub const Item = struct {
    start: usize,
    end: usize,
    kind: Kind,

    pub fn text(it: Item, z: []const u8) []const u8 {
        return z[it.start..it.end];
    }

    pub fn isContainer(it: Item) bool {
        return it.kind == .array or it.kind == .object;
    }
};

/// The byte offset where the text stops being JSON (z.len at its end).
pub const SyntaxError = struct { pos: usize = 0 };

pub const Syntax = error{Syntax};

const max_depth = 128;

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn skipWs(z: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < z.len and isWs(z[i])) i += 1;
    return i;
}

fn fault(err: *SyntaxError, pos: usize) error{Syntax} {
    err.pos = pos;
    return error.Syntax;
}

/// The value at offset `i` (no spaces before it), all of it.
pub fn scan(z: []const u8, i: usize, depth: u32, err: *SyntaxError) Syntax!Item {
    if (i >= z.len) return fault(err, i);
    switch (z[i]) {
        '{', '[' => {
            if (depth >= max_depth) return fault(err, i);
            var m: Members = .open(z, i);
            while (try m.next(depth + 1, err)) |_| {}
            return .{ .start = i, .end = m.i, .kind = if (z[i] == '{') .object else .array };
        },
        '"' => return .{ .start = i, .end = try scanString(z, i, err), .kind = .string },
        't' => return literal(z, i, "true", .boolean, err),
        'f' => return literal(z, i, "false", .boolean, err),
        'n' => return literal(z, i, "null", .null, err),
        '-', '0'...'9' => return .{ .start = i, .end = try scanNumber(z, i, err), .kind = .number },
        else => return fault(err, i),
    }
}

fn literal(z: []const u8, i: usize, w: []const u8, kind: Kind, err: *SyntaxError) Syntax!Item {
    if (z.len - i < w.len or !std.mem.eql(u8, z[i .. i + w.len], w)) return fault(err, i);
    return .{ .start = i, .end = i + w.len, .kind = kind };
}

/// The offset after the string starting at `i` (a quote); an error is
/// at its start.
fn scanString(z: []const u8, i: usize, err: *SyntaxError) Syntax!usize {
    var j = i + 1;
    while (j < z.len) {
        const c = z[j];
        if (c == '"') return j + 1;
        if (c < 0x20) return fault(err, i);
        if (c == '\\') {
            if (j + 1 >= z.len) return fault(err, i);
            switch (z[j + 1]) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => j += 2,
                'u' => {
                    if (z.len - j < 6) return fault(err, i);
                    for (z[j + 2 .. j + 6]) |h| if (!std.ascii.isHex(h)) return fault(err, i);
                    j += 6;
                },
                else => return fault(err, i),
            }
            continue;
        }
        j += 1;
    }
    return fault(err, i);
}

fn scanNumber(z: []const u8, i: usize, err: *SyntaxError) Syntax!usize {
    var j = i;
    if (z[j] == '-') j += 1;
    if (j >= z.len or !std.ascii.isDigit(z[j])) return fault(err, i);
    if (z[j] == '0') {
        j += 1;
        if (j < z.len and std.ascii.isDigit(z[j])) return fault(err, i);
    } else {
        while (j < z.len and std.ascii.isDigit(z[j])) j += 1;
    }
    if (j < z.len and z[j] == '.') {
        j += 1;
        if (j >= z.len or !std.ascii.isDigit(z[j])) return fault(err, i);
        while (j < z.len and std.ascii.isDigit(z[j])) j += 1;
    }
    if (j < z.len and (z[j] == 'e' or z[j] == 'E')) {
        j += 1;
        if (j < z.len and (z[j] == '+' or z[j] == '-')) j += 1;
        if (j >= z.len or !std.ascii.isDigit(z[j])) return fault(err, i);
        while (j < z.len and std.ascii.isDigit(z[j])) j += 1;
    }
    // A number runs into the next token only through a delimiter.
    if (j < z.len and (std.ascii.isAlphanumeric(z[j]) or z[j] == '.' or z[j] == '"')) return fault(err, i);
    return j;
}

/// The start of the document (an object or an array) in `z`.
pub fn root(z: []const u8, err: *SyntaxError) Syntax!usize {
    const i = skipWs(z, 0);
    if (i >= z.len or (z[i] != '{' and z[i] != '[')) return fault(err, i);
    return i;
}

/// The document `z`, all of it (ISJSON, JSON_MODIFY).
pub fn parse(z: []const u8, err: *SyntaxError) Syntax!Item {
    const v = try scan(z, try root(z, err), 0, err);
    const e = skipWs(z, v.end);
    if (e != z.len) return fault(err, e);
    return v;
}

/// Whether `z` is a JSON value of any kind (ISJSON(x, VALUE)).
pub fn parseValue(z: []const u8) ?Item {
    var err: SyntaxError = .{};
    const v = scan(z, skipWs(z, 0), 0, &err) catch return null;
    if (skipWs(z, v.end) != z.len) return null;
    return v;
}

// ============================================================ iteration

/// The members of an object or the elements of an array, read (and
/// checked) one at a time.
pub const Members = struct {
    z: []const u8,
    /// The offset of the next member (or of the closing bracket).
    i: usize,
    object: bool,
    index: usize = 0,
    done: bool = false,
    first: bool = true,

    /// The members of the container that starts at `start` (its bracket).
    pub fn open(z: []const u8, start: usize) Members {
        return .{ .z = z, .i = skipWs(z, start + 1), .object = z[start] == '{' };
    }

    pub const Entry = struct {
        /// The key as written (with its quotes), for objects.
        key: ?Item = null,
        index: usize,
        value: Item,
        /// Where the member starts (its key, or the value).
        start: usize,
    };

    /// The next member's key (null for arrays) and the offset of its
    /// value, the value not read yet: read it with value() or skip it.
    pub fn nextKey(m: *Members, err: *SyntaxError) Syntax!?struct { key: ?Item, value_start: usize, start: usize } {
        if (m.done) return null;
        const z = m.z;
        const close: u8 = if (m.object) '}' else ']';
        if (!m.first) {
            if (m.i < z.len and z[m.i] == ',') {
                m.i = skipWs(z, m.i + 1);
            } else if (m.i < z.len and z[m.i] == close) {
                m.i += 1;
                m.done = true;
                return null;
            } else return fault(err, m.i);
        } else if (m.i < z.len and z[m.i] == close) {
            m.i += 1;
            m.done = true;
            return null;
        }
        m.first = false;
        const start = m.i;
        var key: ?Item = null;
        var j = m.i;
        if (m.object) {
            if (j >= z.len or z[j] != '"') return fault(err, j);
            const ke = try scanString(z, j, err);
            key = .{ .start = j, .end = ke, .kind = .string };
            j = skipWs(z, ke);
            if (j >= z.len or z[j] != ':') return fault(err, j);
            j = skipWs(z, j + 1);
        }
        m.i = j;
        return .{ .key = key, .value_start = j, .start = start };
    }

    /// After nextKey(): read the value (all of it) and move past it.
    pub fn value(m: *Members, depth: u32, err: *SyntaxError) Syntax!Item {
        const v = try scan(m.z, m.i, depth, err);
        m.i = skipWs(m.z, v.end);
        m.index += 1;
        return v;
    }

    pub fn next(m: *Members, depth: u32, err: *SyntaxError) Syntax!?Entry {
        const k = (try m.nextKey(err)) orelse return null;
        const index = m.index;
        const v = try m.value(depth, err);
        return .{ .key = k.key, .index = index, .value = v, .start = k.start };
    }
};

/// Whether the quoted string `raw` (as written, with quotes) means `key`.
pub fn keyEquals(raw: []const u8, key: []const u8) bool {
    const body = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return std.mem.eql(u8, body, key);
    var it: Decoder = .{ .body = body };
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (it.next(&buf)) |part| {
        if (key.len - i < part.len or !std.mem.eql(u8, key[i .. i + part.len], part)) return false;
        i += part.len;
    }
    return i == key.len;
}

/// The characters of the body of a (valid) JSON string, unescaped, a
/// piece at a time.
const Decoder = struct {
    body: []const u8,
    i: usize = 0,

    fn next(d: *Decoder, buf: *[4]u8) ?[]const u8 {
        const body = d.body;
        if (d.i >= body.len) return null;
        if (body[d.i] != '\\') {
            const s = d.i;
            while (d.i < body.len and body[d.i] != '\\') d.i += 1;
            return body[s..d.i];
        }
        const e = body[d.i + 1];
        d.i += 2;
        buf[0] = switch (e) {
            'b' => 8,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                var cp: u21 = std.fmt.parseInt(u16, body[d.i .. d.i + 4], 16) catch 0xfffd;
                d.i += 4;
                if (cp >= 0xd800 and cp < 0xdc00 and d.i + 6 <= body.len and body[d.i] == '\\' and body[d.i + 1] == 'u') {
                    const lo = std.fmt.parseInt(u16, body[d.i + 2 .. d.i + 6], 16) catch 0;
                    if (lo >= 0xdc00 and lo < 0xe000) {
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        d.i += 6;
                    }
                }
                if (cp >= 0xd800 and cp < 0xe000) cp = 0xfffd;
                const n = std.unicode.utf8Encode(cp, buf) catch unreachable;
                return buf[0..n];
            },
            else => e,
        };
        return buf[0..1];
    }
};

/// The value of the (valid) string `raw`, with its quotes, unescaped.
pub fn decodeString(a: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, raw.len);
    var d: Decoder = .{ .body = raw[1 .. raw.len - 1] };
    var buf: [4]u8 = undefined;
    while (d.next(&buf)) |part| try out.appendSlice(a, part);
    return out.toOwnedSlice(a);
}

/// The text of a scalar as SQL Server returns it (JSON_VALUE, OPENJSON):
/// a string unescaped, a number or true/false as written; null for null
/// and containers. Allocated in `a` (or a slice of `z`).
pub fn scalarText(a: std.mem.Allocator, z: []const u8, it: Item) error{OutOfMemory}!?[]const u8 {
    return switch (it.kind) {
        .string => try decodeString(a, it.text(z)),
        .number, .boolean => it.text(z),
        else => null,
    };
}

/// Append `s` as a JSON string, escaped as SQL Server escapes (`/` too).
pub fn writeString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    try out.append(a, '"');
    try writeEscaped(a, out, s);
    try out.append(a, '"');
}

/// The body of a JSON string for `s` (STRING_ESCAPE(s, 'json')).
pub fn writeEscaped(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    try json_text.appendEscaped(.{ .slash = true }, a, out, s);
}

// ============================================================= messages

/// The character offset of byte `pos` of `z` (UTF-8).
pub fn charPos(z: []const u8, pos: usize) usize {
    var n: usize = 0;
    for (z[0..@min(pos, z.len)]) |c| {
        if (c & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// The character at byte `pos` of `z` for a message ('.' at the end).
pub fn charAt(z: []const u8, pos: usize) []const u8 {
    if (pos >= z.len) return ".";
    var e = pos + 1;
    if (z[pos] >= 0xc0) {
        while (e < z.len and z[e] & 0xc0 == 0x80) e += 1;
    }
    return z[pos..e];
}

/// SQL Server's message of a syntax error at byte `pos` of `z`.
/// What the errors of textMessage() and pathMessage() are.
pub const text_error: int.ErrorState = .numbered("22032", 13609);
pub const path_error: int.ErrorState = .numbered("42601", 13607);

pub fn textMessage(buf: []u8, z: []const u8, pos: usize) []const u8 {
    return std.fmt.bufPrint(buf, "JSON text is not properly formatted. Unexpected character '{s}' is found at position {d}.", .{ charAt(z, pos), charPos(z, pos) }) catch buf;
}

pub fn pathMessage(buf: []u8, z: []const u8, pos: usize) []const u8 {
    return std.fmt.bufPrint(buf, "JSON path is not properly formatted. Unexpected character '{s}' is found at position {d}.", .{ charAt(z, pos), charPos(z, pos) }) catch buf;
}

// ================================================================= paths

pub const Step = union(enum) {
    key: []const u8,
    index: u64,
};

pub const Path = struct {
    strict: bool = false,
    append: bool = false,
    steps: []Step = &.{},
};

/// Where a path stops being one (a byte offset).
pub const PathError = struct { pos: usize = 0 };

/// Parse path `z` ("append" is for JSON_MODIFY: `allow_append`).
pub fn parsePath(a: std.mem.Allocator, z: []const u8, allow_append: bool, err: *PathError) error{ OutOfMemory, BadPath }!Path {
    var p: Path = .{};
    var i: usize = 0;
    while (i < z.len and z[i] == ' ') i += 1;
    // [append ][lax |strict ]: a word is matched character by character,
    // the first that does not fit is the error.
    var stage: u8 = 0;
    while (i >= z.len or z[i] != '$') {
        if (stage > 1) return badPath(err, i);
        const words: []const []const u8 = if (stage == 0) &.{ "append", "lax", "strict" } else &.{ "lax", "strict" };
        var w: ?[]const u8 = null;
        for (words) |cand| if (i < z.len and z[i] == cand[0]) {
            w = cand;
        };
        const word = w orelse return badPath(err, i);
        var k: usize = 0;
        while (k < word.len) : (k += 1) {
            if (i + k >= z.len or z[i + k] != word[k]) return badPath(err, i + k);
        }
        i += word.len;
        // A space, or (lax and strict) the $ at once.
        if (i >= z.len or (z[i] != ' ' and (z[i] != '$' or std.mem.eql(u8, word, "append")))) return badPath(err, i);
        while (i < z.len and z[i] == ' ') i += 1;
        if (std.mem.eql(u8, word, "append")) {
            if (!allow_append) return badPath(err, i - word.len);
            p.append = true;
            stage = 1;
        } else {
            p.strict = std.mem.eql(u8, word, "strict");
            stage = 2;
        }
    }
    i += 1;
    var steps: std.ArrayList(Step) = .empty;
    while (i < z.len) {
        const c = z[i];
        if (c == ' ') {
            // Spaces only at the end.
            var j = i;
            while (j < z.len and z[j] == ' ') j += 1;
            if (j == z.len) break;
            return badPath(err, i);
        }
        if (c == '.') {
            i += 1;
            if (i < z.len and z[i] == '"') {
                var e: SyntaxError = .{};
                const end = scanString(z, i, &e) catch return badPath(err, i);
                try steps.append(a, .{ .key = try decodeString(a, z[i..end]) });
                i = end;
                continue;
            }
            const s = i;
            while (i < z.len and z[i] != '.' and z[i] != '[' and z[i] != ' ') : (i += 1) {
                if (!isKeyChar(z[i], i == s)) return badPath(err, i);
            }
            if (i == s) return badPath(err, i);
            try steps.append(a, .{ .key = z[s..i] });
        } else if (c == '[') {
            i += 1;
            const s = i;
            while (i < z.len and std.ascii.isDigit(z[i])) i += 1;
            if (i == s) return badPath(err, i);
            const n = std.fmt.parseInt(u64, z[s..i], 10) catch return badPath(err, s);
            if (i >= z.len or z[i] != ']') return badPath(err, i);
            i += 1;
            try steps.append(a, .{ .index = n });
        } else return badPath(err, i);
    }
    p.steps = steps.items;
    return p;
}

fn badPath(err: *PathError, pos: usize) error{BadPath} {
    err.pos = pos;
    return error.BadPath;
}

/// A character of an unquoted key: ASCII letters, `_`, and digits and
/// `$` after the first.
fn isKeyChar(c: u8, first: bool) bool {
    if (std.ascii.isAlphabetic(c) or c == '_') return true;
    return !first and (std.ascii.isDigit(c) or c == '$');
}

// ================================================================ lookup

/// What a path found.
pub const Found = union(enum) {
    /// The value (read all of it).
    item: Item,
    /// The path does not exist.
    missing,
};

/// The value at `steps` in document `z`, read as SQL Server does: only
/// as far as the value (which is read all), and if a container that
/// should have the next step does not, to the end of the document. A
/// step into a value of the wrong type ends the search at once.
pub fn find(z: []const u8, steps: []const Step, err: *SyntaxError) Syntax!Found {
    const r = try root(z, err);
    if (steps.len == 0) return .{ .item = try scan(z, r, 0, err) };
    var pos = r;
    var depth: u32 = 0;
    for (steps, 0..) |st, n| {
        const c = if (pos < z.len) z[pos] else 0;
        const want: u8 = if (st == .key) '{' else '[';
        // A scalar here, or a container of the other kind: SQL Server
        // looks no further.
        if (c != want) return .missing;
        var m: Members = .open(z, pos);
        depth += 1;
        const at: ?usize = while (try m.nextKey(err)) |k| {
            const hit = switch (st) {
                .key => |key| keyEquals(k.key.?.text(z), key),
                .index => |idx| m.index == idx,
            };
            if (hit) break k.value_start;
            _ = try m.value(depth, err);
        } else null;
        const v_start = at orelse {
            // Not there: the rest of the document must still be JSON.
            _ = try parse(z, err);
            return .missing;
        };
        if (n == steps.len - 1) return .{ .item = try scan(z, v_start, depth, err) };
        pos = v_start;
    }
    unreachable;
}

/// The offset where the value at `steps` starts, the value not read
/// (OPENJSON reads it an element at a time); null if there is none.
pub fn locate(z: []const u8, steps: []const Step, err: *SyntaxError) Syntax!?usize {
    var pos = try root(z, err);
    var depth: u32 = 0;
    for (steps) |st| {
        const c = if (pos < z.len) z[pos] else 0;
        if (c != (if (st == .key) @as(u8, '{') else '[')) return null;
        var m: Members = .open(z, pos);
        depth += 1;
        pos = while (try m.nextKey(err)) |k| {
            const hit = switch (st) {
                .key => |key| keyEquals(k.key.?.text(z), key),
                .index => |idx| m.index == idx,
            };
            if (hit) break k.value_start;
            _ = try m.value(depth, err);
        } else {
            _ = try parse(z, err);
            return null;
        };
    }
    return pos;
}

/// The value at `steps` of document `root_item` (read all, valid).
pub fn lookup(z: []const u8, root_item: Item, steps: []const Step) ?Item {
    var cur = root_item;
    var err: SyntaxError = .{};
    for (steps) |st| {
        const want: Kind = if (st == .key) .object else .array;
        if (cur.kind != want) return null;
        var m: Members = .open(z, cur.start);
        cur = while (m.next(0, &err) catch return null) |e| {
            const hit = switch (st) {
                .key => |key| keyEquals(e.key.?.text(z), key),
                .index => |idx| e.index == idx,
            };
            if (hit) break e.value;
        } else return null;
    }
    return cur;
}

// ================================================================= tests

test "json scan" {
    const t = std.testing;
    var err: SyntaxError = .{};
    const z = " {\"a\": [1, 2.5e3, \"x\\u00e9\"], \"b\": {\"c\": null}} ";
    const r = try parse(z, &err);
    try t.expectEqual(Kind.object, r.kind);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var perr: PathError = .{};
    const p = try parsePath(arena.allocator(), "$.a[2]", false, &perr);
    const v = lookup(z, r, p.steps).?;
    try t.expectEqualStrings("\"x\\u00e9\"", v.text(z));
    const d = try decodeString(t.allocator, v.text(z));
    defer t.allocator.free(d);
    try t.expectEqualStrings("x\u{e9}", d);
    try t.expect(keyEquals("\"a\\u0062\"", "ab"));
    try t.expectError(error.Syntax, parse("[1,]", &err));
    try t.expectEqual(@as(usize, 3), err.pos);
    try t.expectError(error.Syntax, parse("[01]", &err));
    try t.expectError(error.Syntax, parse("1", &err));
    try t.expectError(error.Syntax, parse("{\"a\":1,}", &err));
    try t.expectEqual(@as(usize, 7), err.pos);
    // Lazy lookups.
    const f = try find("{\"a\":1", &.{.{ .key = "a" }}, &err);
    try t.expectEqualStrings("1", f.item.text("{\"a\":1"));
    try t.expectEqual(Found.missing, try find("[1, 2", &.{.{ .key = "zz" }}, &err));
    try t.expectError(error.Syntax, find("{\"a\":1} x", &.{.{ .key = "zz" }}, &err));
    try t.expectEqual(@as(usize, 8), err.pos);
}

test "json paths" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: PathError = .{};
    const bad = [_]struct { []const u8, usize }{
        .{ "a", 1 },        .{ "ab", 1 },      .{ "", 0 },     .{ "lax", 3 },          .{ "lax ", 4 },
        .{ "$a", 1 },       .{ "$.a.", 4 },    .{ "$[", 2 },   .{ "$[1", 3 },          .{ "$.$a", 2 },
        .{ "$[\"a\"]", 2 }, .{ "LAX $.a", 0 }, .{ "x.y", 0 },  .{ "strictly $.a", 6 }, .{ "$.a[-1]", 4 },
        .{ "$.a-b", 3 },    .{ "$ .a", 1 },    .{ "$.1a", 2 },
    };
    for (bad) |b| {
        try t.expectError(error.BadPath, parsePath(a, b[0], false, &err));
        try t.expectEqual(b[1], err.pos);
    }
    const p = try parsePath(a, " lax  $.\"a b\"[3].c ", false, &err);
    try t.expect(!p.strict);
    try t.expectEqual(@as(usize, 3), p.steps.len);
    const q = try parsePath(a, "append strict $.a", true, &err);
    try t.expect(q.strict and q.append);
    try t.expectError(error.BadPath, parsePath(a, "strict append $.a", true, &err));
    try t.expectEqual(@as(usize, 7), err.pos);
}
