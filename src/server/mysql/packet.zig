//! The packets of the MySQL client/server protocol: a 3-byte payload
//! length, a sequence id, the payload. A payload of 2^24-1 bytes or more
//! is split in packets of that size, the last one shorter (possibly
//! empty). The sequence id starts at 0 with each command and counts the
//! packets either side sends.
//!
//! Wire reads whole payloads (joined) and sends the payload built in its
//! buffer; Reader decodes the integers and strings of a payload, the
//! write helpers encode them.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The largest payload of one packet.
pub const max_payload = 0xFF_FFFF;

/// The largest payload Wire.read() accepts (MariaDB's default
/// max_allowed_packet is 16M; this leaves room for long data).
pub const max_message = 64 << 20;

pub const Wire = struct {
    gpa: Allocator,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    /// The sequence id of the next packet.
    seq: u8 = 0,
    recv: std.ArrayList(u8) = .empty,
    /// The payload being built (begin(), then the write helpers, then
    /// send()).
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *Wire) void {
        w.recv.deinit(w.gpa);
        w.buf.deinit(w.gpa);
    }

    /// The next payload from the client, valid until the next read().
    pub fn read(w: *Wire) ![]u8 {
        w.recv.clearRetainingCapacity();
        while (true) {
            const head = try w.in.takeArray(4);
            const len: usize = std.mem.readInt(u24, head[0..3], .little);
            w.seq = head[3] +% 1;
            if (w.recv.items.len + len > max_message) return error.PacketTooLarge;
            const at = w.recv.items.len;
            try w.recv.resize(w.gpa, at + len);
            try w.in.readSliceAll(w.recv.items[at..]);
            if (len < max_payload) return w.recv.items;
        }
    }

    /// Start a payload.
    pub fn begin(w: *Wire) *std.ArrayList(u8) {
        w.buf.clearRetainingCapacity();
        return &w.buf;
    }

    /// Send the payload built since begin() (buffered: flush() sends).
    pub fn send(w: *Wire) !void {
        try w.sendBytes(w.buf.items);
    }

    pub fn sendBytes(w: *Wire, payload: []const u8) !void {
        var rest = payload;
        while (true) {
            const n = @min(rest.len, max_payload);
            var head: [4]u8 = undefined;
            std.mem.writeInt(u24, head[0..3], @intCast(n), .little);
            head[3] = w.seq;
            w.seq +%= 1;
            try w.out.writeAll(&head);
            try w.out.writeAll(rest[0..n]);
            rest = rest[n..];
            if (n < max_payload) return;
        }
    }

    pub fn flush(w: *Wire) !void {
        try w.out.flush();
    }
};

// ================================================================ encoding

pub fn int1(gpa: Allocator, b: *std.ArrayList(u8), v: u8) !void {
    try b.append(gpa, v);
}

pub fn int2(gpa: Allocator, b: *std.ArrayList(u8), v: u16) !void {
    try intN(gpa, b, u16, v);
}

pub fn int4(gpa: Allocator, b: *std.ArrayList(u8), v: u32) !void {
    try intN(gpa, b, u32, v);
}

pub fn int8(gpa: Allocator, b: *std.ArrayList(u8), v: u64) !void {
    try intN(gpa, b, u64, v);
}

pub fn intN(gpa: Allocator, b: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var tmp: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &tmp, v, .little);
    try b.appendSlice(gpa, &tmp);
}

/// A length-encoded integer.
pub fn lenenc(gpa: Allocator, b: *std.ArrayList(u8), v: u64) !void {
    if (v < 0xFB) return b.append(gpa, @intCast(v));
    if (v <= 0xFFFF) {
        try b.append(gpa, 0xFC);
        return intN(gpa, b, u16, @intCast(v));
    }
    if (v <= 0xFF_FFFF) {
        try b.append(gpa, 0xFD);
        return intN(gpa, b, u24, @intCast(v));
    }
    try b.append(gpa, 0xFE);
    try intN(gpa, b, u64, v);
}

/// A length-encoded string.
pub fn lenencStr(gpa: Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    try lenenc(gpa, b, s.len);
    try b.appendSlice(gpa, s);
}

/// A NUL-terminated string.
pub fn strNul(gpa: Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    try b.appendSlice(gpa, s);
    try b.append(gpa, 0);
}

// ================================================================ decoding

/// Reads the fields of a payload. Past the end it fails with
/// error.Malformed.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn rest(r: *const Reader) []const u8 {
        return r.data[r.pos..];
    }

    pub fn atEnd(r: *const Reader) bool {
        return r.pos >= r.data.len;
    }

    pub fn bytes(r: *Reader, n: usize) error{Malformed}![]const u8 {
        if (r.data.len - r.pos < n) return error.Malformed;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    pub fn int(r: *Reader, comptime T: type) error{Malformed}!T {
        const b = try r.bytes(@divExact(@bitSizeOf(T), 8));
        return std.mem.readInt(T, b[0..@divExact(@bitSizeOf(T), 8)], .little);
    }

    pub fn byte(r: *Reader) error{Malformed}!u8 {
        return (try r.bytes(1))[0];
    }

    /// A length-encoded integer (0xFB, NULL, is error.Malformed here).
    pub fn lenenc(r: *Reader) error{Malformed}!u64 {
        const first = try r.byte();
        return switch (first) {
            0xFC => try r.int(u16),
            0xFD => try r.int(u24),
            0xFE => try r.int(u64),
            0xFB, 0xFF => error.Malformed,
            else => first,
        };
    }

    pub fn lenencStr(r: *Reader) error{Malformed}![]const u8 {
        const n = try r.lenenc();
        if (n > r.data.len - r.pos) return error.Malformed;
        return r.bytes(@intCast(n));
    }

    /// A NUL-terminated string (or the rest, if there is no NUL).
    pub fn strNul(r: *Reader) []const u8 {
        const s = r.data[r.pos..];
        const n = std.mem.indexOfScalar(u8, s, 0) orelse {
            r.pos = r.data.len;
            return s;
        };
        r.pos += n + 1;
        return s[0..n];
    }
};

test "lenenc round trip" {
    const gpa = std.testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    const values = [_]u64{ 0, 250, 251, 0xFFFF, 0x10000, 0xFF_FFFF, 0x100_0000, std.math.maxInt(u64) };
    for (values) |v| try lenenc(gpa, &b, v);
    try lenencStr(gpa, &b, "abc");
    var r: Reader = .{ .data = b.items };
    for (values) |v| try std.testing.expectEqual(v, try r.lenenc());
    try std.testing.expectEqualStrings("abc", try r.lenencStr());
    try std.testing.expect(r.atEnd());
    try std.testing.expectError(error.Malformed, r.byte());
}
