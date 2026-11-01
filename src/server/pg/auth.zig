//! Password authentication: PostgreSQL's cleartext and MD5 exchanges, and
//! SCRAM-SHA-256 (RFC 5802, RFC 7677) without channel binding.
//!
//! The server keeps one password (Config); SCRAM's keys are derived from
//! it once (ScramSecret.init()), as PostgreSQL stores them, so that a
//! connection costs no PBKDF2. Passwords are not normalized (SASLprep):
//! one of ASCII characters authenticates as with PostgreSQL.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Md5 = std.crypto.hash.Md5;
const b64 = std.base64.standard;

pub const Method = enum {
    /// Any client, no password.
    trust,
    /// The password in clear (AuthenticationCleartextPassword).
    password,
    md5,
    @"scram-sha-256",
};

pub const Config = struct {
    method: Method = .trust,
    /// The one user name accepted, if set (else any).
    user: ?[]const u8 = null,
    /// The password of every user (method other than trust).
    password: []const u8 = "",
};

/// The salted password's keys of SCRAM (PostgreSQL's SCRAM secret).
pub const ScramSecret = struct {
    salt: [16]u8,
    iterations: u32,
    stored_key: [32]u8,
    server_key: [32]u8,

    pub fn init(password: []const u8, salt: [16]u8, iterations: u32) ScramSecret {
        var salted: [32]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, password, &salt, iterations, Hmac) catch unreachable;
        var client_key: [32]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &salted);
        var s: ScramSecret = .{ .salt = salt, .iterations = iterations, .stored_key = undefined, .server_key = undefined };
        Sha256.hash(&client_key, &s.stored_key, .{});
        Hmac.create(&s.server_key, "Server Key", &salted);
        return s;
    }
};

pub const mechanism = "SCRAM-SHA-256";

/// The server's side of one SCRAM exchange. Its messages are in `buf`.
pub const Scram = struct {
    secret: *const ScramSecret,
    buf: [1024]u8 = undefined,
    /// client-first-message-bare, then server-first-message, in buf.
    client_first_bare: []const u8 = "",
    server_first: []const u8 = "",
    /// The GS2 header ("n,," or "y,,"), whose base64 the final message
    /// repeats.
    gs2: []const u8 = "",
    /// The client's nonce and ours.
    nonce: []const u8 = "",

    /// Read the client-first-message and make the server-first-message
    /// (serverFirst()) with `random`, the server's part of the nonce.
    /// error.ChannelBinding: the client requires it (we offer none).
    pub fn start(s: *Scram, client_first: []const u8, random: [18]u8) !void {
        if (client_first.len > 400) return error.BadMessage;
        // gs2-header: n,, (no binding), y,, (the client could bind but
        // thinks we cannot), p=... (it requires binding).
        if (client_first.len < 3) return error.BadMessage;
        switch (client_first[0]) {
            'n', 'y' => if (client_first[1] != ',') return error.BadMessage,
            'p' => return error.ChannelBinding,
            else => return error.BadMessage,
        }
        // Then the authzid (empty, or a=...) and a comma.
        const second = std.mem.indexOfScalarPos(u8, client_first, 2, ',') orelse return error.BadMessage;
        const gs2 = client_first[0 .. second + 1];
        const bare = client_first[second + 1 ..];
        // n=user (PostgreSQL ignores it: the startup packet's user), r=nonce.
        var attrs = std.mem.splitScalar(u8, bare, ',');
        _ = attrs.next() orelse return error.BadMessage;
        const r = attrs.next() orelse return error.BadMessage;
        if (!std.mem.startsWith(u8, r, "r=") or r.len < 3) return error.BadMessage;
        var w: std.Io.Writer = .fixed(&s.buf);
        w.writeAll(gs2) catch return error.BadMessage;
        w.writeAll(bare) catch return error.BadMessage;
        const nonce_at = w.end;
        w.writeAll(r[2..]) catch return error.BadMessage;
        var enc: [24]u8 = undefined;
        w.writeAll(b64.Encoder.encode(&enc, &random)) catch return error.BadMessage;
        const nonce_end = w.end;
        const first_at = w.end;
        w.print("r={s},s=", .{s.buf[nonce_at..nonce_end]}) catch return error.BadMessage;
        var salt: [24]u8 = undefined;
        w.print("{s},i={d}", .{ b64.Encoder.encode(&salt, &s.secret.salt), s.secret.iterations }) catch return error.BadMessage;
        s.gs2 = s.buf[0..gs2.len];
        s.client_first_bare = s.buf[gs2.len..][0..bare.len];
        s.nonce = s.buf[nonce_at..nonce_end];
        s.server_first = s.buf[first_at..w.end];
    }

    pub fn serverFirst(s: *const Scram) []const u8 {
        return s.server_first;
    }

    /// Check the client-final-message's proof; the server-final-message
    /// in `out`. error.AuthFailed: a wrong password.
    pub fn finish(s: *Scram, client_final: []const u8, out: *[64]u8) ![]const u8 {
        const p_at = std.mem.lastIndexOf(u8, client_final, ",p=") orelse return error.BadMessage;
        const without_proof = client_final[0..p_at];
        var attrs = std.mem.splitScalar(u8, without_proof, ',');
        const c = attrs.next() orelse return error.BadMessage;
        const r = attrs.next() orelse return error.BadMessage;
        var gs2_enc: [32]u8 = undefined;
        if (s.gs2.len > 24) return error.BadMessage;
        if (!std.mem.startsWith(u8, c, "c=") or !std.mem.eql(u8, c[2..], b64.Encoder.encode(&gs2_enc, s.gs2))) return error.BadMessage;
        if (!std.mem.startsWith(u8, r, "r=") or !std.mem.eql(u8, r[2..], s.nonce)) return error.BadMessage;
        var proof: [32]u8 = undefined;
        const proof_text = client_final[p_at + 3 ..];
        if ((b64.Decoder.calcSizeForSlice(proof_text) catch return error.BadMessage) != 32) return error.BadMessage;
        b64.Decoder.decode(&proof, proof_text) catch return error.BadMessage;

        // AuthMessage = client-first-bare "," server-first "," client-final-without-proof.
        var mac = Hmac.init(&s.secret.stored_key);
        mac.update(s.client_first_bare);
        mac.update(",");
        mac.update(s.server_first);
        mac.update(",");
        mac.update(without_proof);
        var client_signature: [32]u8 = undefined;
        mac.final(&client_signature);
        var client_key: [32]u8 = undefined;
        for (&client_key, proof, client_signature) |*k, p, sig| k.* = p ^ sig;
        var stored: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored, .{});
        if (!std.crypto.timing_safe.eql([32]u8, stored, s.secret.stored_key)) return error.AuthFailed;

        var smac = Hmac.init(&s.secret.server_key);
        smac.update(s.client_first_bare);
        smac.update(",");
        smac.update(s.server_first);
        smac.update(",");
        smac.update(without_proof);
        var server_signature: [32]u8 = undefined;
        smac.final(&server_signature);
        @memcpy(out[0..2], "v=");
        const enc = b64.Encoder.encode(out[2..], &server_signature);
        return out[0 .. 2 + enc.len];
    }
};

/// What an MD5 client sends: "md5" and the hex of md5(hex(md5(password
/// user)) salt).
pub fn md5Response(user: []const u8, password: []const u8, salt: [4]u8) [35]u8 {
    var h = Md5.init(.{});
    h.update(password);
    h.update(user);
    var inner: [16]u8 = undefined;
    h.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);
    var h2 = Md5.init(.{});
    h2.update(&inner_hex);
    h2.update(&salt);
    var outer: [16]u8 = undefined;
    h2.final(&outer);
    var r: [35]u8 = undefined;
    @memcpy(r[0..3], "md5");
    r[3..].* = std.fmt.bytesToHex(outer, .lower);
    return r;
}

/// Compare a password a client sent with ours, in time that does not
/// depend on where they differ.
pub fn eqlSecret(a: []const u8, b: []const u8) bool {
    var x: u8 = @intFromBool(a.len != b.len);
    for (0..@min(a.len, b.len)) |i| x |= a[i] ^ b[i];
    return x == 0;
}

// ================================================================== tests

/// The client's side, for the tests (pg/test.zig): the client-final-message
/// and the server signature it expects, of `password` and the server's
/// first message.
pub fn clientFinal(buf: []u8, password: []const u8, client_first_bare: []const u8, server_first: []const u8, gs2: []const u8) !struct { []const u8, [32]u8 } {
    var it = std.mem.splitScalar(u8, server_first, ',');
    const r = (it.next() orelse return error.BadMessage)[2..];
    const salt_b64 = (it.next() orelse return error.BadMessage)[2..];
    const iters = try std.fmt.parseInt(u32, (it.next() orelse return error.BadMessage)[2..], 10);
    var salt: [64]u8 = undefined;
    const salt_len = try b64.Decoder.calcSizeForSlice(salt_b64);
    try b64.Decoder.decode(salt[0..salt_len], salt_b64);
    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, password, salt[0..salt_len], iters, Hmac);
    var client_key: [32]u8 = undefined;
    Hmac.create(&client_key, "Client Key", &salted);
    var stored: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored, .{});
    var server_key: [32]u8 = undefined;
    Hmac.create(&server_key, "Server Key", &salted);

    var w: std.Io.Writer = .fixed(buf);
    var gs2_enc: [32]u8 = undefined;
    try w.print("c={s},r={s}", .{ b64.Encoder.encode(&gs2_enc, gs2), r });
    const without_proof = w.buffered();
    var mac = Hmac.init(&stored);
    for ([_][]const u8{ client_first_bare, ",", server_first, ",", without_proof }) |part| mac.update(part);
    var sig: [32]u8 = undefined;
    mac.final(&sig);
    var proof: [32]u8 = undefined;
    for (&proof, client_key, sig) |*p, k, s| p.* = k ^ s;
    var smac = Hmac.init(&server_key);
    for ([_][]const u8{ client_first_bare, ",", server_first, ",", without_proof }) |part| smac.update(part);
    var server_sig: [32]u8 = undefined;
    smac.final(&server_sig);
    var proof_enc: [44]u8 = undefined;
    try w.print(",p={s}", .{b64.Encoder.encode(&proof_enc, &proof)});
    return .{ w.buffered(), server_sig };
}

test "SCRAM-SHA-256: RFC 7677's example" {
    const t = std.testing;
    var salt: [16]u8 = undefined;
    try b64.Decoder.decode(&salt, "W22ZaJ0SNY7soEsUEjb6gQ==");
    const secret: ScramSecret = .init("pencil", salt, 4096);
    var s: Scram = .{ .secret = &secret };
    // The RFC's server nonce is "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"; ours is
    // base64 of random bytes, so the messages are checked with ours.
    var random: [18]u8 = undefined;
    @memset(&random, 7);
    try s.start("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", random);
    try t.expectEqualStrings("n=user,r=rOprNGfwEbeRWgbNEkqO", s.client_first_bare);
    try t.expectStringStartsWith(s.serverFirst(), "r=rOprNGfwEbeRWgbNEkqOBwcHBwcHBwcHBwcHBwcHBwcH,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    var buf: [256]u8 = undefined;
    const final, const want_sig = try clientFinal(&buf, "pencil", s.client_first_bare, s.serverFirst(), "n,,");
    var out: [64]u8 = undefined;
    const server_final = try s.finish(final, &out);
    var enc: [44]u8 = undefined;
    try t.expectEqualStrings(b64.Encoder.encode(&enc, &want_sig), server_final[2..]);
    // A wrong password.
    var s2: Scram = .{ .secret = &secret };
    try s2.start("n,,n=user,r=abc", random);
    const bad, _ = try clientFinal(&buf, "pen", s2.client_first_bare, s2.serverFirst(), "n,,");
    try t.expectError(error.AuthFailed, s2.finish(bad, &out));
    var s3: Scram = .{ .secret = &secret };
    try t.expectError(error.ChannelBinding, s3.start("p=tls-server-end-point,,n=,r=abc", random));
}

test "SCRAM-SHA-256: the RFC's client proof and server signature" {
    // RFC 7677 section 3, with its own server nonce.
    var salt: [16]u8 = undefined;
    try b64.Decoder.decode(&salt, "W22ZaJ0SNY7soEsUEjb6gQ==");
    var buf: [256]u8 = undefined;
    const final, const sig = try clientFinal(&buf, "pencil", "n=user,r=rOprNGfwEbeRWgbNEkqO", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "n,,");
    try std.testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final);
    var enc: [44]u8 = undefined;
    try std.testing.expectEqualStrings("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", b64.Encoder.encode(&enc, &sig));
}

test md5Response {
    // md5(md5("secret" "u") hex, salt 01020304).
    const r = md5Response("u", "secret", .{ 1, 2, 3, 4 });
    var h = Md5.init(.{});
    h.update("secretu");
    var inner: [16]u8 = undefined;
    h.final(&inner);
    var h2 = Md5.init(.{});
    h2.update(&std.fmt.bytesToHex(inner, .lower));
    h2.update(&[_]u8{ 1, 2, 3, 4 });
    var outer: [16]u8 = undefined;
    h2.final(&outer);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(outer, .lower), r[3..]);
    try std.testing.expect(eqlSecret("abc", "abc") and !eqlSecret("abc", "abd") and !eqlSecret("abc", "ab"));
}
