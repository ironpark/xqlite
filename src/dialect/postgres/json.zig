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
const sqllex = @import("sql/lexer");
const simd = @import("xqlite_base").simd;
const json_text = @import("../json_text.zig");
const bin = @import("../jsonb.zig");
const util = @import("../../sql/util.zig");
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

// ============================================================ input errors

/// What PostgreSQL says of json input `text` it cannot read: the message
/// `msg`, then the DETAIL (json_errdetail(): `Token "bad" is invalid.`)
/// and CONTEXT (report_json_context(): `JSON data, line 1: {bad`), found
/// by reading `text` again as its lexer and parser do; none where they
/// find no error (or nest too deep).
pub fn errorReport(a: Allocator, text: []const u8, jsonb: bool, msg: []const u8) Allocator.Error!util.ErrorFields {
    // PostgreSQL's text has no NUL (and a C string's message ends there).
    if (std.mem.indexOfScalar(u8, text, 0) != null) return .{ .message = msg };
    var d: Diag = .{ .s = text, .jsonb = jsonb };
    d.parse() catch {};
    const code = d.code orelse return .{ .message = msg };
    var buf: [160]u8 = undefined;
    const tok = text[d.start..d.term];
    const detail = switch (code) {
        .invalid_token => std.fmt.bufPrint(&buf, "Token \"{s}\" is invalid.", .{tok}),
        .escaping_invalid => std.fmt.bufPrint(&buf, "Escape sequence \"\\{s}\" is invalid.", .{tok}),
        .escaping_required => std.fmt.bufPrint(&buf, "Character with value 0x{x:0>2} must be escaped.", .{text[d.term]}),
        .unicode_format => std.fmt.bufPrint(&buf, "\"\\u\" must be followed by four hexadecimal digits.", .{}),
        .high_surrogate => std.fmt.bufPrint(&buf, "Unicode high surrogate must not follow a high surrogate.", .{}),
        .low_surrogate => std.fmt.bufPrint(&buf, "Unicode low surrogate must follow a high surrogate.", .{}),
        .code_point_zero => std.fmt.bufPrint(&buf, "\\u0000 cannot be converted to text.", .{}),
        .expected_more => std.fmt.bufPrint(&buf, "The input string ended unexpectedly.", .{}),
        .expected_json => std.fmt.bufPrint(&buf, "Expected JSON value, but found \"{s}\".", .{tok}),
        .expected_end => std.fmt.bufPrint(&buf, "Expected end of input, but found \"{s}\".", .{tok}),
        .expected_colon => std.fmt.bufPrint(&buf, "Expected \":\", but found \"{s}\".", .{tok}),
        .expected_string => std.fmt.bufPrint(&buf, "Expected string, but found \"{s}\".", .{tok}),
        .expected_object_first => std.fmt.bufPrint(&buf, "Expected string or \"}}\", but found \"{s}\".", .{tok}),
        .expected_object_next => std.fmt.bufPrint(&buf, "Expected \",\" or \"}}\", but found \"{s}\".", .{tok}),
        .expected_array_next => std.fmt.bufPrint(&buf, "Expected \",\" or \"]\", but found \"{s}\".", .{tok}),
    } catch "";
    // The line up to the end of the token, at most 49 bytes of it.
    const end = d.term;
    var start = d.line_start;
    while (end - start >= 50) start += charLen(text, start);
    const more = !d.at_end and end < text.len and text[end] != '\n' and text[end] != '\r';
    return .{
        .message = msg,
        .detail = try a.dupe(u8, detail),
        .context = try std.fmt.allocPrint(a, "JSON data, line {d}: {s}{s}{s}", .{
            d.line,
            if (start > d.line_start) "..." else "",
            text[start..end],
            if (more) "..." else "",
        }),
    };
}

/// pg_mblen() of UTF-8: the bytes of the character at `i`, within `s`
/// (1 at its end, or for a byte that starts none).
pub fn charLen(s: []const u8, i: usize) usize {
    return if (i >= s.len) 1 else sqllex.charLen(s, i);
}

/// PostgreSQL's json lexer and recursive parser (common/jsonapi.c),
/// for the error only.
const Diag = struct {
    s: []const u8,
    jsonb: bool,
    i: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    tok: Tok = .none,
    /// The token (or the part of it the error names), the end of the
    /// text the error's context shows.
    start: usize = 0,
    term: usize = 0,
    depth: u32 = 0,
    code: ?Code = null,
    /// The error is about the end of the input.
    at_end: bool = false,

    const Tok = enum { none, obj_start, obj_end, arr_start, arr_end, comma, colon, string, number, true, false, null, end };
    const Code = enum {
        invalid_token,
        escaping_invalid,
        escaping_required,
        unicode_format,
        high_surrogate,
        low_surrogate,
        code_point_zero,
        expected_more,
        expected_json,
        expected_end,
        expected_colon,
        expected_string,
        expected_object_first,
        expected_object_next,
        expected_array_next,
    };
    const Fail = error{Fail};

    /// A lexer error: the token ends at `term`.
    fn lexFail(d: *Diag, code: Code, term: usize) Fail {
        d.code = code;
        d.term = @min(term, d.s.len);
        return error.Fail;
    }

    /// A parser error at the current token (the end of the input:
    /// "ended unexpectedly").
    fn parseFail(d: *Diag, code: Code) Fail {
        d.at_end = d.tok == .end;
        d.code = if (d.at_end) .expected_more else code;
        return error.Fail;
    }

    fn lex(d: *Diag) Fail!void {
        const s = d.s;
        while (d.i < s.len) : (d.i += 1) switch (s[d.i]) {
            ' ', '\t', '\r' => {},
            '\n' => {
                d.line += 1;
                d.line_start = d.i + 1;
            },
            else => break,
        };
        d.start = d.i;
        if (d.i >= s.len) {
            d.tok = .end;
            d.term = d.i;
            return;
        }
        const c = s[d.i];
        const punct: ?Tok = switch (c) {
            '{' => .obj_start,
            '}' => .obj_end,
            '[' => .arr_start,
            ']' => .arr_end,
            ',' => .comma,
            ':' => .colon,
            else => null,
        };
        if (punct) |t| {
            d.i += 1;
            d.term = d.i;
            d.tok = t;
            return;
        }
        switch (c) {
            '"' => try d.string(),
            '-', '0'...'9' => try d.number(),
            else => {
                var p = d.i;
                while (p < s.len and isWordChar(s[p])) p += 1;
                if (p == d.i) return d.lexFail(.invalid_token, p + charLen(s, p));
                const w = s[d.i..p];
                d.tok = if (std.mem.eql(u8, w, "true")) .true else if (std.mem.eql(u8, w, "false")) .false else if (std.mem.eql(u8, w, "null")) .null else return d.lexFail(.invalid_token, p);
                d.i = p;
                d.term = p;
            },
        }
    }

    fn number(d: *Diag) Fail!void {
        const s = d.s;
        var p = d.i;
        var bad = false;
        if (s[p] == '-') p += 1;
        if (p < s.len and s[p] == '0') {
            p += 1;
        } else if (p < s.len and s[p] >= '1' and s[p] <= '9') {
            while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
        } else bad = true;
        if (p < s.len and s[p] == '.') {
            p += 1;
            if (p >= s.len or !std.ascii.isDigit(s[p])) bad = true;
            while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
        }
        if (p < s.len and (s[p] == 'e' or s[p] == 'E')) {
            p += 1;
            if (p < s.len and (s[p] == '+' or s[p] == '-')) p += 1;
            if (p >= s.len or !std.ascii.isDigit(s[p])) bad = true;
            while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
        }
        while (p < s.len and isWordChar(s[p])) : (p += 1) bad = true;
        if (bad) return d.lexFail(.invalid_token, p);
        d.i = p;
        d.term = p;
        d.tok = .number;
    }

    fn string(d: *Diag) Fail!void {
        const s = d.s;
        var p = d.i + 1;
        var hi = false;
        while (true) : (p += 1) {
            if (p >= s.len) return d.lexFail(.invalid_token, p);
            const c = s[p];
            if (c == '"') {
                if (hi) return d.lexFail(.low_surrogate, p + 1);
                break;
            }
            if (c == '\\') {
                p += 1;
                if (p >= s.len) return d.lexFail(.invalid_token, p);
                if (s[p] == 'u') {
                    var cp: u32 = 0;
                    for (0..4) |_| {
                        p += 1;
                        if (p >= s.len) return d.lexFail(.invalid_token, p);
                        const h = std.fmt.charToDigit(s[p], 16) catch return d.lexFail(.unicode_format, p + charLen(s, p));
                        cp = cp * 16 + h;
                    }
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (hi) return d.lexFail(.high_surrogate, p + 1);
                        hi = true;
                        continue;
                    }
                    if (cp >= 0xDC00 and cp <= 0xDFFF) {
                        if (!hi) return d.lexFail(.low_surrogate, p + 1);
                        hi = false;
                    }
                    if (hi) return d.lexFail(.low_surrogate, p + 1);
                    if (cp == 0 and d.jsonb) return d.lexFail(.code_point_zero, p + 1);
                    continue;
                }
                if (hi) return d.lexFail(.low_surrogate, p + charLen(s, p));
                if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", s[p]) == null) {
                    d.start = p;
                    return d.lexFail(.escaping_invalid, p + charLen(s, p));
                }
                continue;
            }
            if (c < 0x20) return d.lexFail(.escaping_required, p);
            if (hi) return d.lexFail(.low_surrogate, p + charLen(s, p));
        }
        d.i = p + 1;
        d.term = d.i;
        d.tok = .string;
    }

    fn parse(d: *Diag) Fail!void {
        try d.lex();
        try d.value();
        if (d.tok != .end) return d.parseFail(.expected_end);
    }

    fn value(d: *Diag) Fail!void {
        switch (d.tok) {
            .string, .number, .true, .false, .null => try d.lex(),
            .obj_start => try d.object(),
            .arr_start => try d.array(),
            else => return d.parseFail(.expected_json),
        }
    }

    fn object(d: *Diag) Fail!void {
        d.depth += 1;
        // PostgreSQL's stack depth limit: another error.
        if (d.depth > 6400) return error.Fail;
        try d.lex();
        switch (d.tok) {
            .string => while (true) {
                try d.lex();
                if (d.tok != .colon) return d.parseFail(.expected_colon);
                try d.lex();
                try d.value();
                if (d.tok != .comma) break;
                try d.lex();
                if (d.tok != .string) return d.parseFail(.expected_string);
            },
            .obj_end => {},
            else => return d.parseFail(.expected_object_first),
        }
        if (d.tok != .obj_end) return d.parseFail(.expected_object_next);
        try d.lex();
        d.depth -= 1;
    }

    fn array(d: *Diag) Fail!void {
        d.depth += 1;
        if (d.depth > 6400) return error.Fail;
        try d.lex();
        if (d.tok != .arr_end) {
            try d.value();
            while (d.tok == .comma) {
                try d.lex();
                try d.value();
            }
        }
        if (d.tok != .arr_end) return d.parseFail(.expected_array_next);
        try d.lex();
        d.depth -= 1;
    }
};

test "json input errors as PostgreSQL reports them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "{bad", "Token \"bad\" is invalid.", "JSON data, line 1: {bad" },
        .{ "{\"a\":1", "The input string ended unexpectedly.", "JSON data, line 1: {\"a\":1" },
        .{ "[1,2", "The input string ended unexpectedly.", "JSON data, line 1: [1,2" },
        .{ "{\"a\" 1}", "Expected \":\", but found \"1\".", "JSON data, line 1: {\"a\" 1..." },
        .{ "[1 2]", "Expected \",\" or \"]\", but found \"2\".", "JSON data, line 1: [1 2..." },
        .{ "{1}", "Expected string or \"}\", but found \"1\".", "JSON data, line 1: {1..." },
        .{ "1 2", "Expected end of input, but found \"2\".", "JSON data, line 1: 1 2" },
        .{ "\"\\x\"", "Escape sequence \"\\x\" is invalid.", "JSON data, line 1: \"\\x..." },
        .{ "[1,\n}", "Expected JSON value, but found \"}\".", "JSON data, line 2: }" },
        .{ "01", "Token \"01\" is invalid.", "JSON data, line 1: 01" },
    };
    for (cases) |c| {
        const r = try errorReport(a, c[0], true, "m");
        try std.testing.expectEqualStrings(c[1], r.detail.?);
        try std.testing.expectEqualStrings(c[2], r.context.?);
    }
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
    return simd.order(x, y);
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
    try json_text.appendQuoted(.{ .keep_u0000 = true }, a, out, s);
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
    const o = simd.order(x[0..ix], y[0..iy]);
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
        .string => |s| return simd.order(s, y.v.string),
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
                var o = simd.order(p.key, q.key);
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

// ================================================================ JSONB

// A jsonb column stores SQLite's JSONB (jsonb.zig), one canonical blob
// per value, so that equal values are equal bytes (UNIQUE, GROUP BY,
// DISTINCT) and sqlite3 reads them with json()/json_extract()/->>:
//  - the value normalized (keys in jsonb's order without duplicates,
//    numbers as numeric_out() writes them);
//  - each node with the smallest header;
//  - null/true/false; a number INT without a point, else FLOAT (no
//    exponent: numeric_out()'s digits, 1.50 stays 1.50); a string TEXT
//    if it has nothing to escape, else TEXTRAW (its characters as they
//    are); arrays in order; objects key, value, ... in jsonb's order.
// Any other valid JSONB (what sqlite3's own functions write: TEXTJ
// strings, JSON5 numbers, keys in the order written, duplicates, larger
// headers) is read the same (fromBlob() normalizes it), and canonical()
// tells the two apart.

/// The value of JSONB blob `b` (bin.valid()), normalized.
pub fn fromBlob(a: Allocator, b: []const u8) Error!Value {
    const n = bin.node(b, 0) orelse return error.Invalid;
    // The value of a canonical blob is normalized already.
    var canon = true;
    var v = try decodeNode(a, b, 0, n, &canon);
    if (!canon) try normalize(a, &v);
    return v;
}

/// The value of node `n` at b[i]; `canon` cleared if the node is not
/// as canonical() wants it (the keys of its objects compared to know).
fn decodeNode(a: Allocator, b: []const u8, i: usize, n: bin.Node, canon: *bool) Error!Value {
    const z = bin.payload(b, i, n);
    switch (n.typ) {
        bin.NULL => return null_value,
        bin.TRUE => return .{ .v = .{ .bool = true } },
        bin.FALSE => return .{ .v = .{ .bool = false } },
        bin.INT, bin.INT5, bin.FLOAT, bin.FLOAT5 => {
            if ((n.typ != bin.INT and n.typ != bin.FLOAT) or !normalNumber(z, n.typ == bin.FLOAT)) canon.* = false;
            const t = (try bin.number(a, n.typ, z)) orelse return null_value;
            return .{ .v = .{ .number = t } };
        },
        bin.TEXT, bin.TEXTJ, bin.TEXT5, bin.TEXTRAW => {
            if (n.typ == bin.TEXTJ or n.typ == bin.TEXT5) canon.* = false;
            return .{ .v = .{ .string = try bin.string(a, n.typ, z) } };
        },
        bin.ARRAY => {
            var items: std.ArrayList(Value) = .empty;
            var it = bin.children(b, i, n);
            while (it.next()) |c| try items.append(a, try decodeNode(a, b, c.at, c.n, canon));
            return .{ .v = .{ .array = items.items } };
        },
        bin.OBJECT => {
            var pairs: std.ArrayList(Pair) = .empty;
            var it = bin.children(b, i, n);
            while (it.next()) |k| {
                const v = it.next() orelse return error.Invalid;
                if (k.n.typ == bin.TEXTJ or k.n.typ == bin.TEXT5) canon.* = false;
                const key = try bin.string(a, k.n.typ, k.body(b));
                if (pairs.items.len > 0 and keyOrder(pairs.items[pairs.items.len - 1].key, key) != .lt) canon.* = false;
                try pairs.append(a, .{ .key = key, .value = try decodeNode(a, b, v.at, v.n, canon) });
            }
            return .{ .v = .{ .object = pairs.items } };
        },
        else => return error.Invalid,
    }
}

/// The node type of string `s`: TEXT if nothing in it needs escaping,
/// else TEXTRAW.
fn stringType(s: []const u8) u8 {
    for (s) |c| if (c < 0x20 or c == '"' or c == '\\') return bin.TEXTRAW;
    return bin.TEXT;
}

/// The canonical JSONB of normalized value `v`.
pub fn toBlob(a: Allocator, v_arg: Value) Error![]u8 {
    var v = v_arg;
    try normalNumbers(a, &v);
    var sizes: std.ArrayList(usize) = .empty;
    const total = try measure(a, v, &sizes);
    var out: std.ArrayList(u8) = try .initCapacity(a, total);
    var k: usize = 0;
    try emit(a, &out, v, sizes.items, &k);
    return out.items;
}

/// The numbers of `v` as numeric_out() writes them (a value a function
/// computed, a jsonpath's arithmetic, may have another spelling).
fn normalNumbers(a: Allocator, v: *Value) Error!void {
    switch (v.v) {
        .number => |t| if (!normalNumber(t, std.mem.indexOfScalar(u8, t, '.') != null)) {
            v.v = .{ .number = try numericOut(a, t) };
        },
        .array => |items| for (items) |*x| try normalNumbers(a, x),
        .object => |pairs| for (pairs) |*pp| try normalNumbers(a, &pp.value),
        else => {},
    }
}

/// The size of the node of `v`; the payload sizes of its containers are
/// appended to `sizes`, in the order emit() writes them.
fn measure(a: Allocator, v: Value, sizes: *std.ArrayList(usize)) Error!usize {
    const len: usize = switch (v.v) {
        .null, .bool => 0,
        .number => |t| t.len,
        .string => |t| t.len,
        .array => |items| blk: {
            const slot = sizes.items.len;
            try sizes.append(a, 0);
            var p: usize = 0;
            for (items) |x| p += try measure(a, x, sizes);
            sizes.items[slot] = p;
            break :blk p;
        },
        .object => |pairs| blk: {
            const slot = sizes.items.len;
            try sizes.append(a, 0);
            var p: usize = 0;
            for (pairs) |pp| p += bin.headerSize(pp.key.len) + pp.key.len + try measure(a, pp.value, sizes);
            sizes.items[slot] = p;
            break :blk p;
        },
    };
    return bin.headerSize(len) + len;
}

fn emit(a: Allocator, out: *std.ArrayList(u8), v: Value, sizes: []const usize, k: *usize) Error!void {
    switch (v.v) {
        .null => try bin.appendHeader(a, out, bin.NULL, 0),
        .bool => |x| try bin.appendHeader(a, out, if (x) bin.TRUE else bin.FALSE, 0),
        .number => |t| {
            const point = std.mem.indexOfScalar(u8, t, '.') != null;
            try bin.appendHeader(a, out, if (point) bin.FLOAT else bin.INT, t.len);
            try out.appendSlice(a, t);
        },
        .string => |t| {
            try bin.appendHeader(a, out, stringType(t), t.len);
            try out.appendSlice(a, t);
        },
        .array => |items| {
            try bin.appendHeader(a, out, bin.ARRAY, sizes[k.*]);
            k.* += 1;
            for (items) |x| try emit(a, out, x, sizes, k);
        },
        .object => |pairs| {
            try bin.appendHeader(a, out, bin.OBJECT, sizes[k.*]);
            k.* += 1;
            for (pairs) |pp| {
                try bin.appendHeader(a, out, stringType(pp.key), pp.key.len);
                try out.appendSlice(a, pp.key);
                try emit(a, out, pp.value, sizes, k);
            }
        },
    }
}

/// Whether JSONB blob `b` (bin.valid()) is the canonical encoding of
/// its value, as toBlob() writes it.
pub fn canonical(b: []const u8) bool {
    const n = bin.node(b, 0) orelse return false;
    return n.size() == b.len and canonicalNode(b, 0, n);
}

fn canonicalNode(b: []const u8, i: usize, n: bin.Node) bool {
    if (n.hdr != bin.headerSize(n.len)) return false;
    const z = bin.payload(b, i, n);
    switch (n.typ) {
        bin.NULL, bin.TRUE, bin.FALSE => return n.len == 0,
        bin.INT, bin.FLOAT => return normalNumber(z, n.typ == bin.FLOAT),
        bin.TEXT, bin.TEXTRAW => return stringType(z) == n.typ,
        bin.ARRAY => {
            var it = bin.children(b, i, n);
            while (it.next()) |c| if (!canonicalNode(b, c.at, c.n)) return false;
            return true;
        },
        bin.OBJECT => {
            var it = bin.children(b, i, n);
            var prev: ?[]const u8 = null;
            while (it.next()) |k| {
                if (k.n.typ != bin.TEXT and k.n.typ != bin.TEXTRAW) return false;
                if (!canonicalNode(b, k.at, k.n)) return false;
                const key = k.body(b);
                if (prev) |p| if (keyOrder(p, key) != .lt) return false;
                prev = key;
                const v = it.next() orelse return false;
                if (!canonicalNode(b, v.at, v.n)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Whether `z` is a number as numeric_out() writes it (no exponent, no
/// leading zero, no negative zero), with a point if `point`.
fn normalNumber(z: []const u8, point: bool) bool {
    var s = z;
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    const dot = std.mem.indexOfScalar(u8, s, '.');
    if ((dot != null) != point) return false;
    const ip = if (dot) |d| s[0..d] else s;
    const fp = if (dot) |d| s[d + 1 ..] else "";
    if (ip.len == 0 or (ip.len > 1 and ip[0] == '0')) return false;
    if (point and fp.len == 0) return false;
    for (ip) |c| if (!std.ascii.isDigit(c)) return false;
    for (fp) |c| if (!std.ascii.isDigit(c)) return false;
    return !(neg and allZero(ip) and allZero(fp));
}

/// jsonb's text of JSONB blob `b` (bin.valid()): of a canonical one
/// its nodes as they are, of another its value normalized.
pub fn blobText(a: Allocator, b: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (canonical(b)) {
        try bin.appendText(a, &out, b);
    } else try writeJsonb(a, &out, try fromBlob(a, b));
    return out.items;
}

/// The canonical JSONB of JSONB blob `b` (bin.valid()): `b` itself if
/// it is.
pub fn canonicalBlob(a: Allocator, b: []const u8) Error![]const u8 {
    if (canonical(b)) return b;
    return toBlob(a, try fromBlob(a, b));
}

// ============================================================ sort keys

// xq_pg_jsonb_key(): bytes whose order (memcmp, SQLite's BINARY) is
// jsonb's (compareTop()), equal for equal values ('1.0' and '1'). The
// encoding is part of the file format (an index on the key, a view's
// comparison): it never changes.
//   value  := null 0x10 | string 0x20 str | number 0x30 num
//           | false 0x40 0x00 | true 0x40 0x01
//           | array 0x50 count value* | object 0x60 count (str value)*
//   str    := its bytes, 0x00 as 0x00 0xff, then 0x00 0x00
//   count  := 4 bytes, big-endian
//   num    := 0x02 (zero) | 0x03 exp digits 0x00 (positive)
//           | 0x01 ~exp ~digits 0xff (negative)
//   exp    := the decimal exponent E of 0.d1d2... x 10^E, an i32
//             big-endian with its sign bit flipped
//   digits := the significant digits without trailing zeros, each as
//             1 + its value
// An empty array at the top is 0x08, less than any other value, as
// PostgreSQL sorts it (where a scalar at the top is an array of one).

/// Append the sort key of normalized value `v` (at the top).
pub fn appendKey(a: Allocator, out: *std.ArrayList(u8), v: Value) Error!void {
    if (v.v == .array and v.v.array.len == 0) return out.append(a, 0x08);
    try keyNode(a, out, v);
}

fn keyNode(a: Allocator, out: *std.ArrayList(u8), v: Value) Error!void {
    switch (v.v) {
        .null => try out.append(a, 0x10),
        .string => |t| {
            try out.append(a, 0x20);
            try keyString(a, out, t);
        },
        .number => |t| {
            try out.append(a, 0x30);
            try keyNumber(a, out, t);
        },
        .bool => |x| try out.appendSlice(a, &.{ 0x40, @intFromBool(x) }),
        .array => |items| {
            try out.append(a, 0x50);
            try keyCount(a, out, items.len);
            for (items) |x| try keyNode(a, out, x);
        },
        .object => |pairs| {
            try out.append(a, 0x60);
            try keyCount(a, out, pairs.len);
            for (pairs) |pp| {
                try keyString(a, out, pp.key);
                try keyNode(a, out, pp.value);
            }
        },
    }
}

fn keyCount(a: Allocator, out: *std.ArrayList(u8), n: usize) Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(@min(n, std.math.maxInt(u32))), .big);
    try out.appendSlice(a, &buf);
}

fn keyString(a: Allocator, out: *std.ArrayList(u8), t: []const u8) Error!void {
    for (t) |c| {
        try out.append(a, c);
        if (c == 0) try out.append(a, 0xff);
    }
    try out.appendSlice(a, &.{ 0, 0 });
}

/// A JSON number's text as the key's `num`.
fn keyNumber(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Error!void {
    var s = text;
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var mant_end: usize = 0;
    while (mant_end < s.len and s[mant_end] != 'e' and s[mant_end] != 'E') mant_end += 1;
    var exp: i64 = 0;
    if (mant_end < s.len) exp = std.fmt.parseInt(i64, s[mant_end + 1 ..], 10) catch 0;
    const mant = s[0..mant_end];
    const dot = std.mem.indexOfScalar(u8, mant, '.');
    const ip = if (dot) |d| mant[0..d] else mant;
    const fp = if (dot) |d| mant[d + 1 ..] else "";
    const D = struct {
        ip: []const u8,
        fp: []const u8,
        fn at(d: @This(), k: usize) u8 {
            return if (k < d.ip.len) d.ip[k] else d.fp[k - d.ip.len];
        }
    };
    const d: D = .{ .ip = ip, .fp = fp };
    const n = ip.len + fp.len;
    var lead: usize = 0;
    while (lead < n and d.at(lead) == '0') lead += 1;
    var last = n;
    while (last > lead and d.at(last - 1) == '0') last -= 1;
    if (lead == last) return out.append(a, 0x02);
    const point: i64 = @as(i64, @intCast(ip.len)) - @as(i64, @intCast(lead));
    const e: i32 = @intCast(std.math.clamp(point + exp, std.math.minInt(i32), std.math.maxInt(i32)));
    var eb: [4]u8 = undefined;
    std.mem.writeInt(u32, &eb, @as(u32, @bitCast(e)) ^ 0x8000_0000, .big);
    if (neg) {
        try out.append(a, 0x01);
        for (eb) |x| try out.append(a, ~x);
        for (lead..last) |k| try out.append(a, ~(d.at(k) - '0' + 1));
        try out.append(a, 0xff);
    } else {
        try out.append(a, 0x03);
        try out.appendSlice(a, &eb);
        for (lead..last) |k| try out.append(a, d.at(k) - '0' + 1);
        try out.append(a, 0x00);
    }
}

/// appendKey() of canonical JSONB blob `b` (canonical()), read node by
/// node: the same bytes as of its value.
pub fn appendBlobKey(a: Allocator, out: *std.ArrayList(u8), b: []const u8) Error!void {
    const n = bin.node(b, 0) orelse return error.Invalid;
    if (n.typ == bin.ARRAY and n.len == 0) return out.append(a, 0x08);
    try blobKeyNode(a, out, b, 0, n);
}

fn blobKeyNode(a: Allocator, out: *std.ArrayList(u8), b: []const u8, i: usize, n: bin.Node) Error!void {
    const z = bin.payload(b, i, n);
    switch (n.typ) {
        bin.NULL => try out.append(a, 0x10),
        bin.TRUE => try out.appendSlice(a, &.{ 0x40, 1 }),
        bin.FALSE => try out.appendSlice(a, &.{ 0x40, 0 }),
        bin.INT, bin.FLOAT => {
            try out.append(a, 0x30);
            try keyNumber(a, out, z);
        },
        bin.TEXT, bin.TEXTRAW => {
            try out.append(a, 0x20);
            try keyString(a, out, z);
        },
        bin.ARRAY, bin.OBJECT => {
            var count: usize = 0;
            var it = bin.children(b, i, n);
            while (it.next()) |_| count += 1;
            try out.append(a, if (n.typ == bin.ARRAY) 0x50 else 0x60);
            try keyCount(a, out, if (n.typ == bin.ARRAY) count else count / 2);
            it = bin.children(b, i, n);
            var k: usize = 0;
            while (it.next()) |c| : (k += 1) {
                // An object's keys: strings without their tag.
                if (n.typ == bin.OBJECT and k % 2 == 0) {
                    try keyString(a, out, c.body(b));
                } else try blobKeyNode(a, out, b, c.at, c.n);
            }
        },
        else => return error.Invalid,
    }
}

/// jsonb's order of two values at the top of a document: compare(), but
/// an empty array is less than any other value (PostgreSQL's scalars
/// are arrays of one element at the top).
pub fn compareTop(x: Value, y: Value) std.math.Order {
    const ex = x.v == .array and x.v.array.len == 0;
    const ey = y.v == .array and y.v.array.len == 0;
    if (ex or ey) return if (ex and ey) .eq else if (ex) .lt else .gt;
    return compare(x, y);
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

test "jsonb blobs: canonical encoding, reading, sort keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    // Round trips, canonical.
    for ([_][]const u8{ "{\"b\":1,\"a\":[1.50,\"x\\\"y\",null,true,false],\"a\":3,\"aa\":{}}", "[]", "\"\"", "-0.0015", "1e2", "\"\\u00e9\\n\"", "{\"k\":\"vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\"}" }) |src| {
        const v = try parseJsonb(a, src);
        const b = try toBlob(a, v);
        try t.expect(bin.valid(b));
        try t.expect(canonical(b));
        try t.expectEqualStrings(try toText(a, v, true), try blobText(a, b));
        try t.expectEqualStrings(try toText(a, v, true), try toText(a, try fromBlob(a, b), true));
    }
    // {"a":1}: a TEXT key, an INT.
    try t.expectEqualSlices(u8, "\x4c\x17a\x131", try toBlob(a, try parseJsonb(a, "{\"a\":1}")));
    // What sqlite3's jsonb('{"b":1,"a":1.0e0,"a":"A"}') writes: keys
    // as written, a duplicate, TEXTJ, an exponent. Not canonical, read
    // normalized.
    const s3 = "\xcc\x15\x17b\x131\x17a\x551.0e0\x17a\x68\\u0041";
    try t.expect(bin.valid(s3));
    try t.expect(!canonical(s3));
    try t.expectEqualStrings("{\"a\": \"A\", \"b\": 1}", try blobText(a, s3));
    try t.expectEqualSlices(u8, try toBlob(a, try parseJsonb(a, "{\"a\":\"A\",\"b\":1}")), try canonicalBlob(a, s3));
    // The keys sort as compareTop() does.
    const vals = [_][]const u8{ "[]", "null", "\"\"", "\"a\"", "\"a\\u0001\"", "\"ab\"", "\"b\"", "-10", "-2.5", "-2", "-0.001", "0", "0.000", "0.001", "1", "1.0", "1.5", "2", "10", "1e20", "false", "true", "[null]", "[1]", "[\"z\"]", "[[]]", "[1,2]", "{}", "{\"b\":1}", "{\"aa\":1}", "{\"a\":1,\"b\":1}" };
    for (vals) |x| for (vals) |y| {
        const vx = try parseJsonb(a, x);
        const vy = try parseJsonb(a, y);
        var kx: std.ArrayList(u8) = .empty;
        var ky: std.ArrayList(u8) = .empty;
        try appendKey(a, &kx, vx);
        try appendKey(a, &ky, vy);
        var bx: std.ArrayList(u8) = .empty;
        try appendBlobKey(a, &bx, try toBlob(a, vx));
        try t.expectEqualSlices(u8, kx.items, bx.items);
        const want = compareTop(vx, vy);
        const got = std.mem.order(u8, kx.items, ky.items);
        if (want != got) {
            std.debug.print("key order of {s} and {s}: {} vs {}\n", .{ x, y, got, want });
            return error.TestUnexpectedResult;
        }
    };
}
