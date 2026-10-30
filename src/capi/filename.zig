//! sqlite3_filename: a database filename in SQLite's layout, which
//! sqlite3_uri_parameter() and sqlite3_filename_*() walk:
//!
//!     \0\0\0\0  database \0  (key \0 value \0)*  \0  journal \0  wal \0  \0
//!
//! The pointer handed out is to the database name. sqlite3_db_filename()
//! returns one, and so do the names a C VFS's xOpen receives.

const std = @import("std");
const c = @import("common.zig");

/// A filename for database `path` with URI parameters `params` (pairs
/// of NUL-terminated strings, as uri.Result.file holds them after the
/// filename, without the final empty name), from sqlite3_malloc(). The
/// journal and WAL names are those SQLite derives. Null on OOM.
pub fn build(path: []const u8, params: []const u8) ?[]u8 {
    const journal_sfx = "-journal";
    const wal_sfx = "-wal";
    const n = 4 + path.len + 1 + params.len + 1 + (path.len + journal_sfx.len + 1) + (path.len + wal_sfx.len + 1) + 1;
    const b = c.gpa.alloc(u8, n) catch return null;
    @memset(b, 0);
    var i: usize = 4;
    @memcpy(b[i..][0..path.len], path);
    i += path.len + 1;
    @memcpy(b[i..][0..params.len], params);
    i += params.len + 1;
    if (path.len > 0) {
        for ([_][]const u8{ journal_sfx, wal_sfx }) |sfx| {
            @memcpy(b[i..][0..path.len], path);
            @memcpy(b[i + path.len ..][0..sfx.len], sfx);
            i += path.len + sfx.len + 1;
        }
    }
    return b;
}

/// The name pointer of a filename made by build().
pub fn ptr(b: []u8) [*:0]const u8 {
    return @ptrCast(b[4..].ptr);
}

fn next(z: [*:0]const u8) [*:0]const u8 {
    return z + std.mem.len(z) + 1;
}

fn uriParameter(z_filename: [*:0]const u8, param: [*:0]const u8) ?[*:0]const u8 {
    var z = next(z_filename);
    while (z[0] != 0) {
        const x = std.mem.orderZ(u8, z, param);
        z = next(z);
        if (x == .eq) return z;
        z = next(z);
    }
    return null;
}

pub export fn sqlite3_uri_parameter(z: ?[*:0]const u8, param: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return uriParameter(z orelse return null, param orelse return null);
}

pub export fn sqlite3_uri_key(z: ?[*:0]const u8, n_arg: c_int) callconv(.c) ?[*:0]const u8 {
    var p = next(z orelse return null);
    var n = n_arg;
    if (n < 0) return null;
    while (p[0] != 0 and n > 0) : (n -= 1) {
        p = next(next(p));
    }
    return if (p[0] == 0) null else p;
}

/// Port of sqlite3GetBoolean().
pub fn getBoolean(z: []const u8, dflt: bool) bool {
    if (z.len > 0 and z[0] >= '0' and z[0] <= '9') {
        return (std.fmt.parseInt(i64, z, 10) catch 1) != 0;
    }
    const yes = [_][]const u8{ "yes", "true", "on" };
    const no = [_][]const u8{ "no", "false", "off" };
    for (yes) |y| if (c.ctype.eqlNoCase(z, y)) return true;
    for (no) |x| if (c.ctype.eqlNoCase(z, x)) return false;
    return dflt;
}

pub export fn sqlite3_uri_boolean(z: ?[*:0]const u8, param: ?[*:0]const u8, dflt: c_int) callconv(.c) c_int {
    const v = sqlite3_uri_parameter(z, param) orelse return @intFromBool(dflt != 0);
    return @intFromBool(getBoolean(std.mem.span(v), dflt != 0));
}

pub export fn sqlite3_uri_int64(z: ?[*:0]const u8, param: ?[*:0]const u8, dflt: i64) callconv(.c) i64 {
    const v = std.mem.span(sqlite3_uri_parameter(z, param) orelse return dflt);
    if (v.len > 2 and v[0] == '0' and (v[1] == 'x' or v[1] == 'X')) {
        return @bitCast(std.fmt.parseInt(u64, v[2..], 16) catch return dflt);
    }
    return std.fmt.parseInt(i64, v, 10) catch dflt;
}

pub export fn sqlite3_filename_database(z: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    var p: [*]const u8 = z orelse return null;
    while ((p - 1)[0] != 0 or (p - 2)[0] != 0 or (p - 3)[0] != 0 or (p - 4)[0] != 0) p -= 1;
    return @ptrCast(p);
}

pub export fn sqlite3_filename_journal(z: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    var p = next(z orelse return null);
    while (p[0] != 0) p = next(next(p));
    return p + 1;
}

pub export fn sqlite3_filename_wal(z: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const j = sqlite3_filename_journal(z) orelse return null;
    return next(j);
}

pub export fn sqlite3_create_filename(
    z_db: ?[*:0]const u8,
    z_journal: ?[*:0]const u8,
    z_wal: ?[*:0]const u8,
    n_param: c_int,
    az_param: ?[*]const ?[*:0]const u8,
) callconv(.c) ?[*:0]const u8 {
    const parts = [_][]const u8{ c.span(z_db) orelse "", c.span(z_journal) orelse "", c.span(z_wal) orelse "" };
    var n: usize = 4 + parts[0].len + 1 + 1 + parts[1].len + 1 + parts[2].len + 1 + 1;
    const np: usize = @intCast(@max(n_param, 0) * 2);
    for (0..np) |i| n += (c.span(az_param.?[i]) orelse @as([]const u8, "")).len + 1;
    const b = c.gpa.alloc(u8, n) catch return null;
    @memset(b, 0);
    var i: usize = 4;
    const put = struct {
        fn f(buf: []u8, at: *usize, s: []const u8) void {
            @memcpy(buf[at.*..][0..s.len], s);
            at.* += s.len + 1;
        }
    }.f;
    put(b, &i, parts[0]);
    for (0..np) |k| put(b, &i, c.span(az_param.?[k]) orelse @as([]const u8, ""));
    i += 1;
    put(b, &i, parts[1]);
    put(b, &i, parts[2]);
    return @ptrCast(b[4..].ptr);
}

pub export fn sqlite3_free_filename(z: ?[*:0]const u8) callconv(.c) void {
    const db = sqlite3_filename_database(z) orelse return;
    c.malloc.free(@ptrCast(@constCast(db - 4)));
}

pub export fn sqlite3_database_file_object(_: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    // The engine's files are not sqlite3_file objects.
    return null;
}
