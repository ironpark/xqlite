//! URI filenames (port of sqlite3ParseUri() of main.c).
//!
//! A filename that starts with "file:" is a URI when the connection was
//! opened with OpenFlags.uri (C: SQLITE_OPEN_URI or SQLITE_CONFIG_URI):
//! the authority is checked, %HH escapes are decoded, and the "mode" and
//! "cache" query parameters change the open flags. There is no VFS
//! registry, so a "vfs" parameter names a VFS that does not exist; there
//! is no shared cache either, so "cache" is checked and then ignored. The
//! other parameters are kept for the VFS (sqlite3_uri_parameter()), which
//! reads none of them.

const std = @import("std");
const ctype = @import("../util/ctype.zig");
const OpenFlags = @import("main.zig").OpenFlags;

const Allocator = std.mem.Allocator;

/// The result of parse(): the file to open and its flags, or an error.
pub const Result = struct {
    /// The filename, decoded, followed by the query parameters as name
    /// and value strings, each 0-terminated, and an empty name (C's
    /// zFile, without its leading 4 zero bytes). Null on error. Owned by
    /// the caller.
    file: ?[]u8 = null,
    flags: OpenFlags,
    /// The result code: OK, ERROR, PERM or NOMEM.
    rc: i32 = 0,
    /// The error message, if any. Owned by the caller.
    err_msg: ?[]u8 = null,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        if (r.file) |f| gpa.free(f);
        if (r.err_msg) |m| gpa.free(m);
        r.* = .{ .flags = r.flags };
    }

    /// The filename alone.
    pub fn filename(r: *const Result) [:0]const u8 {
        const f = r.file.?;
        return f[0..std.mem.indexOfScalar(u8, f, 0).? :0];
    }

    /// The value of query parameter `name` (sqlite3_uri_parameter()).
    pub fn parameter(r: *const Result, name: []const u8) ?[:0]const u8 {
        const f = r.file orelse return null;
        var i = std.mem.indexOfScalar(u8, f, 0).? + 1;
        while (i < f.len and f[i] != 0) {
            const opt = std.mem.sliceTo(f[i..], 0);
            i += opt.len + 1;
            const val = std.mem.sliceTo(f[i..], 0);
            if (std.mem.eql(u8, opt, name)) return f[i..][0..val.len :0];
            i += val.len + 1;
        }
        return null;
    }
};

const rc_ok = 0;
const rc_error = 1;
const rc_perm = 3;
const rc_nomem = 7;

// SQLITE_OPEN_* bits that a URI may change.
const READONLY: u32 = 0x01;
const READWRITE: u32 = 0x02;
const CREATE: u32 = 0x04;
const MEMORY: u32 = 0x80;
const SHAREDCACHE: u32 = 0x00020000;
const PRIVATECACHE: u32 = 0x00040000;

fn toBits(f: OpenFlags) u32 {
    var b: u32 = if (f.read_only) READONLY else READWRITE;
    if (f.create and !f.read_only) b |= CREATE;
    if (f.memory) b |= MEMORY;
    return b;
}

fn fromBits(b: u32, uri: bool) OpenFlags {
    return .{
        // mode=memory clears both READONLY and READWRITE: an in-memory
        // database can be written.
        .read_only = b & READONLY != 0,
        .create = b & CREATE != 0,
        .memory = b & MEMORY != 0,
        .uri = uri,
    };
}

const OpenMode = struct { z: []const u8, mode: u32 };

/// Port of sqlite3ParseUri(): the file `uri` names, and the flags to open
/// it with, starting from `flags`.
pub fn parse(gpa: Allocator, uri: []const u8, flags: OpenFlags) Result {
    var res: Result = .{ .flags = flags };
    parseInto(gpa, uri, &res) catch {
        res.deinit(gpa);
        res.rc = rc_nomem;
    };
    if (res.rc != rc_ok) {
        if (res.file) |f| gpa.free(f);
        res.file = null;
    }
    return res;
}

fn parseInto(gpa: Allocator, uri: []const u8, res: *Result) Allocator.Error!void {
    var bits = toBits(res.flags);
    var is_uri = res.flags.uri;
    const n_uri = uri.len;
    if (res.flags.uri and n_uri >= 5 and std.mem.eql(u8, uri[0..5], "file:")) {
        is_uri = true;
        var n_byte = n_uri + 8;
        for (uri) |c| n_byte += @intFromBool(c == '&');
        // C allocates 4 bytes more in front, the start-of-name marker.
        const z = try gpa.alloc(u8, n_byte - 4);
        @memset(z, 0);
        res.file = z;
        // Index past the end of `uri` reads its terminator, as in C.
        const at = struct {
            fn f(u: []const u8, i: usize) u8 {
                return if (i < u.len) u[i] else 0;
            }
        }.f;

        var i_in: usize = 5;
        // Discard the scheme and authority segments of the URI.
        if (at(uri, 5) == '/' and at(uri, 6) == '/') {
            i_in = 7;
            while (at(uri, i_in) != 0 and at(uri, i_in) != '/') i_in += 1;
            if (i_in != 7 and (i_in != 16 or !std.mem.eql(u8, "localhost", uri[7..16]))) {
                res.err_msg = try std.fmt.allocPrint(gpa, "invalid uri authority: {s}", .{uri[7..i_in]});
                res.rc = rc_error;
                return;
            }
        }

        // Copy the filename and the query parameters, decoding %HH. The
        // state is 0 in the filename, 1 in a parameter name and 2 in its
        // value.
        var i_out: usize = 0;
        var state: u8 = 0;
        while (true) {
            var c = at(uri, i_in);
            if (c == 0 or c == '#') break;
            i_in += 1;
            if (c == '%' and ctype.isXdigit(at(uri, i_in)) and ctype.isXdigit(at(uri, i_in + 1))) {
                var octet: u8 = hexToInt(uri[i_in]) << 4;
                octet += hexToInt(uri[i_in + 1]);
                i_in += 2;
                if (octet == 0) {
                    // "%00": ignore the rest of the path, name or value.
                    while (true) {
                        c = at(uri, i_in);
                        if (c == 0 or c == '#' or
                            (state == 0 and c == '?') or
                            (state == 1 and (c == '=' or c == '&')) or
                            (state == 2 and c == '&')) break;
                        i_in += 1;
                    }
                    continue;
                }
                c = octet;
            } else if (state == 1 and (c == '&' or c == '=')) {
                if (i_out == 0 or z[i_out - 1] == 0) {
                    // An empty option name: ignore the option.
                    while (at(uri, i_in) != 0 and at(uri, i_in) != '#' and at(uri, i_in - 1) != '&') i_in += 1;
                    continue;
                }
                if (c == '&') {
                    z[i_out] = 0;
                    i_out += 1;
                } else {
                    state = 2;
                }
                c = 0;
            } else if ((state == 0 and c == '?') or (state == 2 and c == '&')) {
                c = 0;
                state = 1;
            }
            z[i_out] = c;
            i_out += 1;
        }
        if (state == 1) {
            z[i_out] = 0;
            i_out += 1;
        }
        @memset(z[i_out..][0..4], 0);

        // The options interpreted here: "vfs" and those that correspond to
        // flags of sqlite3_open_v2().
        var opt_at = std.mem.indexOfScalar(u8, z, 0).? + 1;
        while (z[opt_at] != 0) {
            const opt = std.mem.sliceTo(z[opt_at..], 0);
            const val_at = opt_at + opt.len + 1;
            const val = std.mem.sliceTo(z[val_at..], 0);
            if (std.mem.eql(u8, opt, "vfs") and res.flags.vfs_resolved) {
                // The C ABI found the VFS by this name and opens with it.
            } else if (std.mem.eql(u8, opt, "vfs")) {
                // There is no VFS registry: only the connection's VFS
                // exists, and it has no name.
                res.err_msg = try std.fmt.allocPrint(gpa, "no such vfs: {s}", .{val});
                res.rc = rc_error;
                return;
            } else {
                var modes: []const OpenMode = &.{};
                var mode_type: []const u8 = "";
                var mask: u32 = 0;
                var limit: u32 = 0;
                if (std.mem.eql(u8, opt, "cache")) {
                    modes = &.{ .{ .z = "shared", .mode = SHAREDCACHE }, .{ .z = "private", .mode = PRIVATECACHE } };
                    mask = SHAREDCACHE | PRIVATECACHE;
                    limit = mask;
                    mode_type = "cache";
                }
                if (std.mem.eql(u8, opt, "mode")) {
                    modes = &.{
                        .{ .z = "ro", .mode = READONLY },
                        .{ .z = "rw", .mode = READWRITE },
                        .{ .z = "rwc", .mode = READWRITE | CREATE },
                        .{ .z = "memory", .mode = MEMORY },
                    };
                    mask = READONLY | READWRITE | CREATE | MEMORY;
                    limit = mask & bits;
                    mode_type = "access";
                }
                if (modes.len > 0) {
                    const mode = for (modes) |m| {
                        if (std.mem.eql(u8, val, m.z)) break m.mode;
                    } else 0;
                    if (mode == 0) {
                        res.err_msg = try std.fmt.allocPrint(gpa, "no such {s} mode: {s}", .{ mode_type, val });
                        res.rc = rc_error;
                        return;
                    }
                    if (mode & ~MEMORY > limit) {
                        res.err_msg = try std.fmt.allocPrint(gpa, "{s} mode not allowed: {s}", .{ mode_type, val });
                        res.rc = rc_perm;
                        return;
                    }
                    bits = (bits & ~mask) | mode;
                }
            }
            opt_at = val_at + val.len + 1;
        }
    } else {
        const z = try gpa.alloc(u8, n_uri + 4);
        @memset(z, 0);
        @memcpy(z[0..n_uri], uri);
        res.file = z;
        is_uri = false;
    }
    res.flags = fromBits(bits, is_uri);
}

fn hexToInt(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

test "parse() decodes URIs only when asked to" {
    const gpa = std.testing.allocator;
    {
        var r = parse(gpa, "file:a%20b.db?mode=ro&x=1#frag", .{ .uri = true });
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(i32, 0), r.rc);
        try std.testing.expectEqualStrings("a b.db", r.filename());
        try std.testing.expect(r.flags.read_only);
        try std.testing.expectEqualStrings("1", r.parameter("x").?);
        try std.testing.expectEqualStrings("ro", r.parameter("mode").?);
        try std.testing.expect(r.parameter("y") == null);
    }
    {
        var r = parse(gpa, "file:a.db?mode=ro", .{});
        defer r.deinit(gpa);
        try std.testing.expectEqualStrings("file:a.db?mode=ro", r.filename());
        try std.testing.expect(!r.flags.read_only);
    }
    {
        var r = parse(gpa, "file://host/a.db", .{ .uri = true });
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(i32, 1), r.rc);
        try std.testing.expectEqualStrings("invalid uri authority: host", r.err_msg.?);
    }
    {
        var r = parse(gpa, "file:///tmp/a.db?mode=rwc&mode=bogus", .{ .uri = true });
        defer r.deinit(gpa);
        try std.testing.expectEqualStrings("no such access mode: bogus", r.err_msg.?);
    }
    {
        var r = parse(gpa, "file:a.db?mode=rw", .{ .uri = true, .read_only = true });
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(i32, 3), r.rc);
        try std.testing.expectEqualStrings("access mode not allowed: rw", r.err_msg.?);
    }
    {
        var r = parse(gpa, "file:%00x?&=a&mode=memory", .{ .uri = true });
        defer r.deinit(gpa);
        try std.testing.expectEqualStrings("", r.filename());
        try std.testing.expect(r.flags.memory);
    }
}
