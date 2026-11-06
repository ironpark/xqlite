//! JSON string escaping for the dialects' JSON functions. They escape
//! the same characters the same way (`"`, `\`, `\b \f \n \r \t`, the
//! other control characters as `\u00xx`), and differ in a few that the
//! options choose at compile time.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Escape `/` too (SQL Server).
    slash: bool = false,
    /// Keep a `\u0000` in the text as it is, not as `\\u0000`
    /// (PostgreSQL: json input keeps it written that way).
    keep_u0000: bool = false,
    /// Write the characters above U+007F as `\uXXXX` (upper-case hex,
    /// surrogate pairs above U+FFFF): Oracle's ASCII option. A byte that
    /// starts no sequence is written as the code point of its value, the
    /// first byte of a malformed sequence as it is.
    ascii: bool = false,
};

/// The escape of each byte, null for the bytes written as they are.
fn table(comptime o: Options) [256]?[]const u8 {
    var t: [256]?[]const u8 = @splat(null);
    for (0..0x20) |c| t[c] = std.fmt.comptimePrint("\\u{x:0>4}", .{c});
    t['"'] = "\\\"";
    t['\\'] = "\\\\";
    t[8] = "\\b";
    t[12] = "\\f";
    t['\n'] = "\\n";
    t['\r'] = "\\r";
    t['\t'] = "\\t";
    if (o.slash) t['/'] = "\\/";
    return t;
}

/// Append `s` as the text of a JSON string, without the quotes.
pub fn appendEscaped(comptime o: Options, a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const esc = comptime table(o);
    var i: usize = 0;
    while (i < s.len) {
        // The run of bytes written as they are.
        const start = i;
        while (i < s.len and esc[s[i]] == null and !(o.ascii and s[i] >= 0x80)) i += 1;
        try out.appendSlice(a, s[start..i]);
        if (i == s.len) break;
        const c = s[i];
        if (o.keep_u0000 and c == '\\' and std.mem.startsWith(u8, s[i..], "\\u0000")) {
            try out.appendSlice(a, "\\u0000");
            i += 6;
        } else if (esc[c]) |e| {
            try out.appendSlice(a, e);
            i += 1;
        } else {
            i += try appendNonAscii(a, out, s[i..]);
        }
    }
}

/// Append `s` as a JSON string.
pub fn appendQuoted(comptime o: Options, a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    try appendEscaped(o, a, out, s);
    try out.append(a, '"');
}

/// The character at the start of `s` (non-ASCII) as `\uXXXX` (see
/// Options.ascii); returns the bytes used.
fn appendNonAscii(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    if (n <= s.len) {
        if (std.unicode.utf8Decode(s[0..n])) |cp| {
            if (cp >= 0x10000) {
                const u = cp - 0x10000;
                try out.print(a, "\\u{X:0>4}\\u{X:0>4}", .{ 0xd800 + (u >> 10), 0xdc00 + (u & 0x3ff) });
            } else {
                try out.print(a, "\\u{X:0>4}", .{cp});
            }
            return n;
        } else |_| {}
    }
    try out.append(a, s[0]);
    return 1;
}

test "escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(.{}, a, &out, "a\"\\/\x01\n\u{e9}");
    try std.testing.expectEqualStrings("\"a\\\"\\\\/\\u0001\\n\u{e9}\"", out.items);
    out.clearRetainingCapacity();
    try appendEscaped(.{ .slash = true, .keep_u0000 = true, .ascii = true }, a, &out, "/\\u0000\u{e9}\u{1f600}\xff\xe2\x82");
    try std.testing.expectEqualStrings("\\/\\u0000\\u00E9\\uD83D\\uDE00\\u00FF\xe2\\u0082", out.items);
}
