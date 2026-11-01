//! mysql_native_password: the client proves it knows the password by
//! sending SHA1(password) XOR SHA1(scramble ++ SHA1(SHA1(password))),
//! where the scramble is the 20 random bytes of the server's handshake.
//! An empty password is an empty response.

const std = @import("std");

const Sha1 = std.crypto.hash.Sha1;

pub const plugin = "mysql_native_password";
pub const scramble_len = 20;

/// A new scramble: printable bytes, as MariaDB makes them (no NUL, which
/// some clients take for the end of the handshake's second part).
pub fn newScramble(io: std.Io) [scramble_len]u8 {
    var s: [scramble_len]u8 = undefined;
    io.random(&s);
    for (&s) |*b| b.* = 0x21 + b.* % (0x7E - 0x21);
    return s;
}

/// The response a client sends for `password` (empty for an empty one).
pub fn response(password: []const u8, scramble: *const [scramble_len]u8, out: *[Sha1.digest_length]u8) []const u8 {
    if (password.len == 0) return out[0..0];
    var stage1: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(password, &stage1, .{});
    var stage2: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(&stage1, &stage2, .{});
    var h = Sha1.init(.{});
    h.update(scramble);
    h.update(&stage2);
    h.final(out);
    for (out, stage1) |*o, a| o.* ^= a;
    return out;
}

/// Whether `got` is the response for `password`.
pub fn check(password: []const u8, scramble: *const [scramble_len]u8, got: []const u8) bool {
    var want: [Sha1.digest_length]u8 = undefined;
    const w = response(password, scramble, &want);
    if (w.len != got.len) return false;
    var diff: u8 = 0;
    for (w, got) |a, b| diff |= a ^ b;
    return diff == 0;
}

test "native password" {
    const s = "abcdefghijklmnopqrst".*;
    var buf: [20]u8 = undefined;
    const r = response("secret", &s, &buf);
    try std.testing.expect(check("secret", &s, r));
    try std.testing.expect(!check("Secret", &s, r));
    try std.testing.expect(check("", &s, ""));
    try std.testing.expect(!check("", &s, r));
}
