//! SQL text with `{key}` holes, for the catalog views of the dialects:
//! what a view reads depends on the database (whether xq_catalog exists,
//! which user is asking), so its text is filled in when it is used. The
//! holes are checked at compile time against an enum of keys, so that a
//! misspelt or forgotten key does not compile rather than read the wrong
//! table.

const std = @import("std");

/// Fails compilation unless every `{...}` in `text` is closed and names a
/// field of `Key`.
pub fn check(comptime Key: type, comptime text: []const u8) void {
    comptime {
        @setEvalBranchQuota(20 * text.len + 1000);
        var rest: []const u8 = text;
        while (std.mem.indexOfScalar(u8, rest, '{')) |i| {
            const end = std.mem.indexOfScalarPos(u8, rest, i, '}') orelse
                @compileError("unclosed { in view text: " ++ rest[i..@min(rest.len, i + 40)]);
            const key = rest[i + 1 .. end];
            if (!@hasField(Key, key)) @compileError("unknown key {" ++ key ++ "} in view text");
            rest = rest[end + 1 ..];
        }
    }
}

/// `text` with every `{key}` replaced by `values.get(key)`, itself
/// expanded (a value may have holes too), allocated in `arena`. The text
/// must have passed `check`.
pub fn expand(comptime Key: type, arena: std.mem.Allocator, text: []const u8, values: std.EnumArray(Key, []const u8)) error{OutOfMemory}![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try append(Key, arena, &out, text, values);
    return arena.dupeSentinel(u8, out.items, 0);
}

fn append(comptime Key: type, arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, values: std.EnumArray(Key, []const u8)) error{OutOfMemory}!void {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '{')) |i| {
        try out.appendSlice(arena, rest[0..i]);
        const end = std.mem.indexOfScalarPos(u8, rest, i, '}').?;
        const key = std.meta.stringToEnum(Key, rest[i + 1 .. end]).?;
        try append(Key, arena, out, values.get(key), values);
        rest = rest[end + 1 ..];
    }
    try out.appendSlice(arena, rest);
}

test "expand fills holes, also those in values" {
    const Key = enum { a, b };
    comptime check(Key, "x{a}y{b}");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try expand(Key, arena.allocator(), "x{a}y{b}", .init(.{ .a = "<{b}>", .b = "B" }));
    try std.testing.expectEqualStrings("x<B>yB", got);
}
