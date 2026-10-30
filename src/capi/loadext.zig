//! Loadable extensions (port of loadext.c): sqlite3_load_extension(),
//! sqlite3_enable_load_extension() and the load_extension() SQL
//! function's way in.
//!
//! A shared library is opened with the connection's VFS (xDlOpen,
//! xDlSym, xDlError, xDlClose; the default VFS uses dlopen()), and its
//! entry point gets the sqlite3_api_routines table of loadext.c
//! (src/capi/loadext.c), so extensions built against sqlite3ext.h work
//! unchanged. The libraries stay open until the connection closes.
//! WebAssembly has no dynamic loader: there xDlOpen always fails.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("common.zig");

const Handle = c.Handle;
const RC = c.RC;
const vfs_c = @import("vfs.zig");

/// SQLITE_OK_LOAD_PERMANENTLY.
const OK_LOAD_PERMANENTLY = 256;

/// The sqlite3_api_routines table (loadext.c's sqlite3Apis), in C.
extern const xq_sqlite3_apis: u8;

/// The table handed to extension entry points (pApi).
pub fn apis() *const anyopaque {
    return &xq_sqlite3_apis;
}

/// sqlite3_loadext_entry.
pub const Entry = *const fn (?*Handle, *?[*:0]u8, *const anyopaque) callconv(.c) c_int;

/// SQLITE_MAX_PATHLEN (FILENAME_MAX).
const max_pathlen: usize = if (builtin.os.tag.isDarwin()) 1024 else 4096;

/// Shared library endings to try if the file cannot be loaded as written.
const endings = [_][]const u8{if (builtin.os.tag.isDarwin()) "dylib" else "so"};

fn isDirSep(ch: u8) bool {
    return ch == '/';
}

fn dlOpen(v: *vfs_c.sqlite3_vfs, z: [*:0]const u8) ?*anyopaque {
    const f = v.xDlOpen orelse return null;
    return f(v, z);
}

fn dlSym(v: *vfs_c.sqlite3_vfs, h: ?*anyopaque, z: [*:0]const u8) ?Entry {
    const f = v.xDlSym orelse return null;
    return @ptrCast(f(v, h, z) orelse return null);
}

fn dlClose(v: *vfs_c.sqlite3_vfs, h: ?*anyopaque) void {
    if (v.xDlClose) |f| f(v, h);
}

/// The message "<fmt>" in a buffer from sqlite3_malloc() of `n` bytes,
/// then overwritten by the VFS's xDlError() if it has something to say
/// (sqlite3_snprintf() followed by sqlite3OsDlError()).
fn dlErrorMsg(v: *vfs_c.sqlite3_vfs, n: usize, comptime fmt: []const u8, args: anytype) ?[*:0]u8 {
    const buf = c.gpa.alloc(u8, n) catch return null;
    const s = std.fmt.bufPrint(buf[0 .. n - 1], fmt, args) catch buf[0 .. n - 1];
    buf[s.len] = 0;
    if (v.xDlError) |f| f(v, @intCast(n - 1), buf.ptr);
    return @ptrCast(buf.ptr);
}

/// Port of sqlite3LoadExtension().
fn loadExtension(db: *Handle, z_file: [*:0]const u8, z_proc: ?[*:0]const u8, pz_errmsg: ?*?[*:0]u8) c_int {
    const e = c.ext(db);
    const v = e.vfs.cvfs;
    const file = std.mem.span(z_file);
    const n_msg = file.len;
    if (pz_errmsg) |p| p.* = null;

    // Ticket #1863: extension loading is off until the application turns
    // it on (sqlite3_enable_load_extension() or
    // SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION).
    if (!db.flags.LoadExtension) {
        if (pz_errmsg) |p| p.* = c.dupZ("not authorized");
        return RC.ERROR;
    }
    var entry_name: [:0]const u8 = if (z_proc) |p| std.mem.span(p) else "sqlite3_extension_init";

    // tag-20210611-1: no oversize names for dlopen(), and no empty name
    // (which would link to the running program).
    const handle: ?*anyopaque = blk: {
        if (n_msg > max_pathlen or n_msg == 0) break :blk null;
        var h = dlOpen(v, z_file);
        if (builtin.os.tag != .wasi) {
            for (endings) |ending| {
                if (h != null) break;
                const alt = std.fmt.allocPrintSentinel(c.gpa, "{s}.{s}", .{ file, ending }, 0) catch return RC.NOMEM;
                defer c.gpa.free(alt);
                if (n_msg + ending.len + 1 <= max_pathlen) h = dlOpen(v, alt.ptr);
            }
        }
        break :blk h;
    };
    if (handle == null) {
        // extension_not_found:
        if (pz_errmsg) |p| p.* = dlErrorMsg(v, n_msg + 300, "unable to open shared library [{s}]", .{file[0..@min(file.len, max_pathlen)]});
        return RC.ERROR;
    }
    var x_init = dlSym(v, handle, entry_name.ptr);

    // No entry point named and no sqlite3_extension_init: try
    // "sqlite3_X_init", X being the lower-cased letters of the file name
    // after the last "/" up to the first "." (without a leading "lib"),
    // then the same with digits too.
    var alt_entry: ?[:0]u8 = null;
    defer if (alt_entry) |a| c.gpa.free(a);
    if (x_init == null and z_proc == null) {
        var cnt: u32 = 0;
        while (x_init == null and cnt < 2) : (cnt += 1) {
            var i_file = file.len;
            while (i_file > 0 and !isDirSep(file[i_file - 1])) i_file -= 1;
            if (file.len - i_file >= 3 and c.ctype.eqlNoCase(file[i_file..][0..3], "lib")) i_file += 3;
            var name: std.ArrayList(u8) = .empty;
            name.appendSlice(c.gpa, "sqlite3_") catch {
                dlClose(v, handle);
                return RC.NOMEM;
            };
            while (i_file < file.len and file[i_file] != '.') : (i_file += 1) {
                const ch = file[i_file];
                if (std.ascii.isAlphabetic(ch) or (cnt > 0 and std.ascii.isDigit(ch))) {
                    name.append(c.gpa, std.ascii.toLower(ch)) catch {
                        name.deinit(c.gpa);
                        dlClose(v, handle);
                        return RC.NOMEM;
                    };
                }
            }
            name.appendSlice(c.gpa, "_init") catch {
                name.deinit(c.gpa);
                dlClose(v, handle);
                return RC.NOMEM;
            };
            if (alt_entry) |a| c.gpa.free(a);
            alt_entry = name.toOwnedSliceSentinel(c.gpa, 0) catch {
                name.deinit(c.gpa);
                dlClose(v, handle);
                return RC.NOMEM;
            };
            entry_name = alt_entry.?;
            x_init = dlSym(v, handle, entry_name.ptr);
        }
    }
    const init_fn = x_init orelse {
        if (pz_errmsg) |p| p.* = dlErrorMsg(v, n_msg + entry_name.len + 300, "no entry point [{s}] in shared library [{s}]", .{ entry_name, file });
        dlClose(v, handle);
        return RC.ERROR;
    };
    var err: ?[*:0]u8 = null;
    const rc = init_fn(db, &err, apis());
    if (rc != RC.OK) {
        if (rc == OK_LOAD_PERMANENTLY) return RC.OK;
        if (pz_errmsg) |p| p.* = if (std.fmt.allocPrintSentinel(c.gpa, "error during initialization: {s}", .{std.mem.span(err orelse "")}, 0)) |m| m.ptr else |_| null;
        if (err) |m| c.malloc.free(m);
        dlClose(v, handle);
        return RC.ERROR;
    }
    e.extensions.append(c.gpa, handle.?) catch return RC.NOMEM;
    return RC.OK;
}

pub export fn sqlite3_load_extension(db_arg: ?*Handle, z_file: ?[*:0]const u8, z_proc: ?[*:0]const u8, pz_errmsg: ?*?[*:0]u8) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const rc = loadExtension(db, z_file orelse "", z_proc, pz_errmsg);
    if (rc == RC.NOMEM) db.oomFault();
    return c.main.apiExit(db, rc);
}

/// Port of sqlite3CloseExtensions(): close the libraries a connection
/// loaded, after everything of it (its functions, collations and
/// modules, whose code may be theirs) is gone.
pub fn closeExtensions(e: *c.Ext) void {
    for (e.extensions.items) |h| dlClose(e.vfs.cvfs, h);
    e.extensions.deinit(c.gpa);
}

/// Port of sqlite3_enable_load_extension(): both the C interface and the
/// load_extension() SQL function (SQLITE_LoadExtension and
/// SQLITE_LoadExtFunc).
pub export fn sqlite3_enable_load_extension(db_arg: ?*Handle, onoff: c_int) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    db.flags.LoadExtension = onoff != 0;
    db.flags.LoadExtFunc = onoff != 0;
    return RC.OK;
}

/// The engine's load_extension() SQL function calls this (it is
/// int.load_extension_hook while the C ABI is in use).
fn sqlLoadExtension(db: *Handle, file: [:0]const u8, proc: ?[:0]const u8) ?[*:0]u8 {
    var err: ?[*:0]u8 = null;
    if (loadExtension(db, file.ptr, if (proc) |p| p.ptr else null, &err) != RC.OK) {
        return err orelse c.dupZ("out of memory");
    }
    return null;
}

/// Install the hook of the load_extension() SQL function (from
/// sqlite3_initialize()).
pub fn initHook() void {
    @import("../sql/global.zig").load_extension = sqlLoadExtension;
}

// ======================================== the default VFS's dl methods

const has_dl = switch (builtin.os.tag) {
    .wasi, .freestanding => false,
    else => true,
};

/// Port of unixDlOpen().
pub fn osDlOpen(z: [*:0]const u8) ?*anyopaque {
    if (!has_dl) return null;
    return std.c.dlopen(z, .{ .NOW = true, .GLOBAL = true });
}

/// Port of unixDlError().
pub fn osDlError(n: c_int, out: [*]u8) void {
    if (n <= 0) return;
    const buf = out[0..@intCast(n)];
    if (!has_dl) {
        const msg = "loadable extensions are not supported on this platform";
        const k = @min(msg.len, buf.len - 1);
        @memcpy(buf[0..k], msg[0..k]);
        buf[k] = 0;
        return;
    }
    // dlerror() is per thread in the C libraries xqlite runs on, so the
    // mutex of unixDlError() is not needed.
    const z = std.mem.span(std.c.dlerror() orelse return);
    const k = @min(z.len, buf.len - 1);
    @memcpy(buf[0..k], z[0..k]);
    buf[k] = 0;
}

/// Port of unixDlSym().
pub fn osDlSym(h: ?*anyopaque, z: [*:0]const u8) ?*const fn () callconv(.c) void {
    if (!has_dl) return null;
    return @ptrCast(@alignCast(std.c.dlsym(h, z)));
}

/// Port of unixDlClose().
pub fn osDlClose(h: ?*anyopaque) void {
    if (!has_dl) return;
    _ = std.c.dlclose(h orelse return);
}
