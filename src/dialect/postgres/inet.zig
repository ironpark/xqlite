//! PostgreSQL's inet and cidr: an IPv4 or IPv6 address with a netmask
//! length, stored as its text (types.zig: TEXT), written as
//! PostgreSQL's inet_out() and cidr_out() write it:
//!
//!   inet  '192.168.1.5'  '192.168.1.5/24'  '::1'  '2001:db8::/32'
//!   cidr  '192.168.1.0/24' (always with the length; no bits right of it)
//!
//! The input (inet_in(), cidr_in()) takes an address, optionally /bits;
//! IPv6 in any form, written back in RFC 5952's (lowercase, the longest
//! run of zero groups as ::, an IPv4-mapped address with its IPv4 tail).
//! An inet compares as its text (PostgreSQL orders by family, then the
//! address: a known difference).
//!
//! Engine functions (in the schema: casts, DEFAULTs):
//!   xq_pg_inet(x), xq_pg_cidr(x)    the casts, an error on bad input,
//!                                   and what a string or parameter
//!                                   stored into a column goes through
//! Functions: host(inet), masklen(inet), family(inet).

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const int = @import("../../sql/sqlite_int.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const det: dfunc.Options = .{ .deterministic = true };

pub const cast_inet = dfunc.scalar("xq_pg_inet", 1, det, dfunc.bind(castFunc, .{false}));
pub const cast_cidr = dfunc.scalar("xq_pg_cidr", 1, det, dfunc.bind(castFunc, .{true}));

pub const engine_functions = [_]int.FuncDef{ cast_inet, cast_cidr };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("host", 1, det, hostFunc),
    dfunc.scalar("masklen", 1, det, masklenFunc),
    dfunc.scalar("family", 1, det, familyFunc),
};

const Addr = struct {
    v6: bool,
    /// IPv4 in the first 4 bytes.
    bytes: [16]u8 = @splat(0),
    bits: u8,

    fn width(a: Addr) u8 {
        return if (a.v6) 128 else 32;
    }
};

/// The address of `s`, null if it is none.
fn parse(s_in: []const u8) ?Addr {
    const s = std.mem.trim(u8, s_in, " \t\n\r");
    var host = s;
    var bits: ?u8 = null;
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        host = s[0..slash];
        bits = std.fmt.parseInt(u8, s[slash + 1 ..], 10) catch return null;
    }
    var a: Addr = undefined;
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        a = .{ .v6 = true, .bits = 128 };
        if (!parse6(host, &a.bytes)) return null;
    } else {
        a = .{ .v6 = false, .bits = 32 };
        if (!parse4(host, a.bytes[0..4])) return null;
    }
    if (bits) |b| {
        if (b > a.width()) return null;
        a.bits = b;
    }
    return a;
}

fn parse4(s: []const u8, out: *[4]u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4 or part.len == 0 or part.len > 3) return false;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return i == 4;
}

fn parse6(s: []const u8, out: *[16]u8) bool {
    var groups: [8]u16 = @splat(0);
    var n: usize = 0;
    var gap: ?usize = null;
    var rest = s;
    if (std.mem.startsWith(u8, rest, "::")) {
        gap = 0;
        rest = rest[2..];
    }
    while (rest.len > 0) {
        const colon = std.mem.indexOfScalar(u8, rest, ':');
        const part = rest[0 .. colon orelse rest.len];
        // An IPv4 tail.
        if (colon == null and std.mem.indexOfScalar(u8, part, '.') != null) {
            if (n > 6) return false;
            var v4: [4]u8 = undefined;
            if (!parse4(part, &v4)) return false;
            groups[n] = @as(u16, v4[0]) << 8 | v4[1];
            groups[n + 1] = @as(u16, v4[2]) << 8 | v4[3];
            n += 2;
            break;
        }
        if (part.len == 0 or part.len > 4 or n == 8) return false;
        groups[n] = std.fmt.parseInt(u16, part, 16) catch return false;
        n += 1;
        const c = colon orelse break;
        rest = rest[c + 1 ..];
        if (rest.len > 0 and rest[0] == ':') {
            if (gap != null) return false;
            gap = n;
            rest = rest[1..];
        } else if (rest.len == 0) return false;
    }
    if (gap) |g| {
        if (n == 8) return false;
        const tail = n - g;
        var full: [8]u16 = @splat(0);
        @memcpy(full[0..g], groups[0..g]);
        @memcpy(full[8 - tail ..], groups[g..n]);
        groups = full;
    } else if (n != 8) return false;
    for (groups, 0..) |g, i| {
        out[2 * i] = @intCast(g >> 8);
        out[2 * i + 1] = @truncate(g);
    }
    return true;
}

/// The text of `a` (inet_out(); cidr_out() with `cidr`).
fn format(buf: []u8, a: Addr, cidr: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeHost(&w, a) catch return "";
    if (cidr or a.bits != a.width()) w.print("/{d}", .{a.bits}) catch return "";
    return w.buffered();
}

fn writeHost(w: *std.Io.Writer, a: Addr) !void {
    if (!a.v6) return w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] });
    var g: [8]u16 = undefined;
    for (&g, 0..) |*x, i| x.* = @as(u16, a.bytes[2 * i]) << 8 | a.bytes[2 * i + 1];
    // The longest run of two or more zero groups (the first of equals).
    var best: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (g[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and g[j] == 0) j += 1;
        if (j - i > best_len) {
            best = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best_len = 0;
    // ::ffff:a.b.c.d and ::a.b.c.d keep the IPv4 tail.
    const v4_tail = best == 0 and (best_len == 6 or (best_len == 5 and g[5] == 0xffff));
    const end: usize = if (v4_tail) 6 else 8;
    i = 0;
    while (i < end) {
        if (best_len > 0 and i == best) {
            try w.writeAll("::");
            i += best_len;
            continue;
        }
        try w.print("{x}", .{g[i]});
        i += 1;
        if (i < end and !(best_len > 0 and i == best)) try w.writeByte(':');
    }
    if (v4_tail) {
        if (best_len == 5) try w.writeByte(':');
        try w.print("{d}.{d}.{d}.{d}", .{ a.bytes[12], a.bytes[13], a.bytes[14], a.bytes[15] });
    }
}

fn castFunc(ctx: *Context, argv: []*Mem, cidr: bool) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const a = arg(ctx, argv[0], if (cidr) "cidr" else "inet") orelse return;
    if (cidr) {
        // No bits right of the length.
        var k: usize = a.bits;
        while (k < a.width()) : (k += 1) if (a.bytes[k / 8] & (@as(u8, 0x80) >> @intCast(k % 8)) != 0) {
            return fail(ctx, "invalid cidr value: \"{s}\"", dfunc.text(ctx, argv[0]) orelse "");
        };
    }
    var buf: [64]u8 = undefined;
    api.resultText(ctx, format(&buf, a, cidr), .transient);
}

/// The address of `m`, else PostgreSQL's error for type `t` (and null).
fn arg(ctx: *Context, m: *Mem, comptime t: []const u8) ?Addr {
    const s = dfunc.text(ctx, m) orelse return null;
    return parse(s) orelse {
        fail(ctx, "invalid input syntax for type " ++ t ++ ": \"{s}\"", s);
        return null;
    };
}

/// Error 22P02, `fmt` of input `s` (its first 100 bytes).
fn fail(ctx: *Context, comptime fmt: []const u8, s: []const u8) void {
    var msg: [160]u8 = undefined;
    api.resultErrorState(ctx, .of("22P02"), std.fmt.bufPrint(&msg, fmt, .{s[0..@min(s.len, 100)]}) catch "invalid input syntax");
}

fn hostFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    var a = arg(ctx, argv[0], "inet") orelse return;
    a.bits = a.width();
    var buf: [64]u8 = undefined;
    api.resultText(ctx, format(&buf, a, false), .transient);
}

fn masklenFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const a = arg(ctx, argv[0], "inet") orelse return;
    api.resultInt64(ctx, a.bits);
}

fn familyFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const a = arg(ctx, argv[0], "inet") orelse return;
    api.resultInt64(ctx, if (a.v6) 6 else 4);
}

test "inet: input and output" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "127.0.0.1", "127.0.0.1" },
        .{ "10.1.2.3/8", "10.1.2.3/8" },
        .{ "192.168.0.1/32", "192.168.0.1" },
        .{ "::1", "::1" },
        .{ "2001:DB8:0:0:0:0:0:1", "2001:db8::1" },
        .{ "2001:db8::/32", "2001:db8::/32" },
        .{ "::ffff:1.2.3.4", "::ffff:1.2.3.4" },
        .{ "1:0:0:2:0:0:0:3", "1:0:0:2::3" },
        .{ "::", "::" },
        .{ "fe80::1:2", "fe80::1:2" },
        .{ "2001:0db8::1", "2001:db8::1" },
        .{ "1::", "1::" },
        .{ "::1.2.3.4", "::1.2.3.4" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        const a = parse(c[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c[1], format(&buf, a, false));
    }
    const bad = [_][]const u8{ "1.2.3", "1.2.3.256", "1::2::3", "1.2.3.4/33", "", "abc", "1:2:3:4:5:6:7:8:9" };
    for (bad) |b| try std.testing.expect(parse(b) == null);
}
