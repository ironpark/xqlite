//! The framing of PostgreSQL's v3 protocol: a message is a type byte
//! (none for the startup packets), a big-endian int32 length that counts
//! itself, and a body. Out writes messages, in() reads them.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The longest message a client may send (PostgreSQL's limit is 1 GB).
pub const max_message = 256 * 1024 * 1024;
/// The longest before it is authenticated (PostgreSQL's startup packet
/// limit).
pub const max_startup = 10000;

/// Messages from the client.
pub const Message = struct {
    /// 0 for a startup packet.
    type: u8,
    body: []const u8,
};

/// Read a message with a type byte (`startup`: a startup packet, without
/// one) of at most `max` bytes into `buf`. error.EndOfStream when the
/// client is gone; the body is valid until the next read.
pub fn read(r: *std.Io.Reader, gpa: Allocator, buf: *std.ArrayList(u8), startup: bool, max: u32) !Message {
    const t: u8 = if (startup) 0 else try r.takeByte();
    const len = try r.takeInt(u32, .big);
    if (len < 4 or len - 4 > max) return error.BadMessageLength;
    buf.clearRetainingCapacity();
    try buf.resize(gpa, len - 4);
    try r.readSliceAll(buf.items);
    return .{ .type = t, .body = buf.items };
}

/// A reader of a message's body. The errors are error.BadMessage: a
/// message shorter than its fields.
pub const Body = struct {
    rest: []const u8,

    pub fn int(b: *Body, comptime T: type) !T {
        const n = @sizeOf(T);
        if (b.rest.len < n) return error.BadMessage;
        defer b.rest = b.rest[n..];
        return std.mem.readInt(T, b.rest[0..n], .big);
    }

    pub fn byte(b: *Body) !u8 {
        return b.int(u8);
    }

    /// A NUL-terminated string.
    pub fn string(b: *Body) ![]const u8 {
        const end = std.mem.indexOfScalar(u8, b.rest, 0) orelse return error.BadMessage;
        defer b.rest = b.rest[end + 1 ..];
        return b.rest[0..end];
    }

    pub fn bytes(b: *Body, n: usize) ![]const u8 {
        if (b.rest.len < n) return error.BadMessage;
        defer b.rest = b.rest[n..];
        return b.rest[0..n];
    }
};

/// Messages to the client, each built in a buffer (its length is known at
/// its end) and then written to `w`.
pub const Out = struct {
    gpa: Allocator,
    w: *std.Io.Writer,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(o: *Out) void {
        o.buf.deinit(o.gpa);
    }

    /// Start a message of type `t`.
    pub fn begin(o: *Out, t: u8) !void {
        o.buf.clearRetainingCapacity();
        try o.buf.appendSlice(o.gpa, &.{ t, 0, 0, 0, 0 });
    }

    pub fn int(o: *Out, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        try o.buf.appendSlice(o.gpa, &b);
    }

    pub fn bytes(o: *Out, b: []const u8) !void {
        try o.buf.appendSlice(o.gpa, b);
    }

    /// A NUL-terminated string (a NUL inside is dropped).
    pub fn string(o: *Out, s: []const u8) !void {
        for (s) |c| if (c != 0) try o.buf.append(o.gpa, c);
        try o.buf.append(o.gpa, 0);
    }

    /// A field's length, then its bytes.
    pub fn field(o: *Out, b: []const u8) !void {
        try o.int(i32, @intCast(b.len));
        try o.bytes(b);
    }

    /// The writer of the message's body, for formatting.
    pub fn print(o: *Out, comptime fmt: []const u8, args: anytype) !void {
        try o.buf.print(o.gpa, fmt, args);
    }

    /// Drop the message being built.
    pub fn abandon(o: *Out) void {
        o.buf.clearRetainingCapacity();
    }

    /// End the message and write it (buffered: flush `w` to send).
    pub fn end(o: *Out) !void {
        std.mem.writeInt(u32, o.buf.items[1..5], @intCast(o.buf.items.len - 1), .big);
        try o.w.writeAll(o.buf.items);
        o.buf.clearRetainingCapacity();
    }

    /// A message of only a type (EmptyQueryResponse, NoData, ...).
    pub fn empty(o: *Out, t: u8) !void {
        try o.begin(t);
        try o.end();
    }
};

test "Out: lengths" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var o: Out = .{ .gpa = std.testing.allocator, .w = &aw.writer };
    defer o.deinit();
    try o.begin('S');
    try o.string("a");
    try o.string("b");
    try o.end();
    try o.empty('I');
    try std.testing.expectEqualSlices(u8, "S\x00\x00\x00\x08a\x00b\x00I\x00\x00\x00\x04", aw.written());
}
