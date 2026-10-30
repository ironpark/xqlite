//! sqlite3_carray_bind() and sqlite3_carray_bind_v2() (port of carray.c):
//! bind a C array to the one-argument form of the carray() table-valued
//! function (src/ext/carray.zig), which every connection of the C ABI
//! has, as in a build with SQLITE_ENABLE_CARRAY.

const std = @import("std");
const c = @import("common.zig");
const stmt = @import("stmt.zig");
const carray = @import("../ext/carray.zig");

const RC = c.RC;
const Bind = carray.Bind;

/// Port of carrayBindDel(): the destructor of the bound Bind.
fn carrayBindDel(p: ?*anyopaque) callconv(.c) void {
    const b: *Bind = @ptrCast(@alignCast(p.?));
    if (b.x_del) |f| f(b.p_del);
    c.malloc.free(b);
}

fn libraryFree(p: ?*anyopaque) callconv(.c) void {
    c.malloc.free(p);
}

/// Port of sqlite3_carray_bind_v2(): bind `n_data` elements of type
/// `m_flags` (CARRAY_INT32 ... CARRAY_BLOB) at `a_data` to parameter
/// `idx`. SQLITE_TRANSIENT copies them; any other destructor `x_destroy`
/// is called on `p_destroy` when the binding goes away, or at once on
/// failure.
pub export fn sqlite3_carray_bind_v2(
    p_stmt: ?*c.Vdbe,
    idx: c_int,
    a_data: ?*anyopaque,
    n_data: c_int,
    m_flags: c_int,
    x_destroy: ?*const anyopaque,
    p_destroy: ?*anyopaque,
) callconv(.c) c_int {
    const lk = c.lockStmt(p_stmt);
    defer lk.unlock();
    const transient = x_destroy != null and @intFromPtr(x_destroy.?) == c.SQLITE_TRANSIENT;
    var rc: c_int = RC.OK;
    var new: ?*Bind = null;
    fail: {
        if (m_flags < carray.INT32 or m_flags > carray.BLOB) {
            rc = RC.ERROR;
            break :fail;
        }
        const b: *Bind = @ptrCast(@alignCast(c.malloc.malloc(@sizeOf(Bind)) orelse {
            rc = RC.NOMEM;
            break :fail;
        }));
        new = b;
        b.* = .{ .data = null, .n_data = n_data, .m_flags = m_flags, .x_del = null, .p_del = null };
        if (transient) {
            const n: usize = @intCast(@max(n_data, 0));
            var sz: u64 = n * @as(u64, switch (m_flags) {
                carray.INT32 => 4,
                carray.INT64, carray.DOUBLE => 8,
                carray.TEXT => @sizeOf(?[*:0]const u8),
                else => @sizeOf(carray.Iovec),
            });
            if (m_flags == carray.TEXT) {
                const az: [*]const ?[*:0]const u8 = @ptrCast(@alignCast(a_data));
                for (0..n) |i| if (az[i]) |z| {
                    sz += std.mem.len(z) + 1;
                };
            } else if (m_flags == carray.BLOB) {
                const av: [*]const carray.Iovec = @ptrCast(@alignCast(a_data));
                for (0..n) |i| sz += av[i].len;
            }
            const buf = c.malloc.malloc(sz) orelse {
                rc = RC.NOMEM;
                break :fail;
            };
            b.data = buf;
            if (m_flags == carray.TEXT) {
                const src: [*]const ?[*:0]const u8 = @ptrCast(@alignCast(a_data));
                const az: [*]?[*:0]const u8 = @ptrCast(@alignCast(buf));
                var z: [*]u8 = buf + n * @sizeOf(?[*:0]const u8);
                for (0..n) |i| {
                    const s = std.mem.span(src[i] orelse {
                        az[i] = null;
                        continue;
                    });
                    @memcpy(z[0 .. s.len + 1], s.ptr[0 .. s.len + 1]);
                    az[i] = @ptrCast(z);
                    z += s.len + 1;
                }
            } else if (m_flags == carray.BLOB) {
                const src: [*]const carray.Iovec = @ptrCast(@alignCast(a_data));
                const p: [*]carray.Iovec = @ptrCast(@alignCast(buf));
                var z: [*]u8 = buf + n * @sizeOf(carray.Iovec);
                for (0..n) |i| {
                    const len = src[i].len;
                    p[i] = .{ .base = z, .len = len };
                    if (len > 0) @memcpy(z[0..len], @as([*]const u8, @ptrCast(src[i].base.?))[0..len]);
                    z += len;
                }
            } else if (sz > 0) {
                @memcpy(buf[0..@intCast(sz)], @as([*]const u8, @ptrCast(a_data.?))[0..@intCast(sz)]);
            }
            b.x_del = libraryFree;
            b.p_del = buf;
        } else {
            b.data = a_data;
            // SQLITE_STATIC (null) is left to the caller.
            b.x_del = c.cDestructor(x_destroy);
            b.p_del = p_destroy;
        }
        return stmt.sqlite3_bind_pointer(p_stmt, idx, b, "carray-bind", @ptrCast(&carrayBindDel));
    }
    // carray_bind_error:
    if (!transient) if (c.cDestructor(x_destroy)) |f| f(p_destroy);
    c.malloc.free(new);
    return rc;
}

/// Port of sqlite3_carray_bind(): sqlite3_carray_bind_v2() with the
/// destructor called on the array itself.
pub export fn sqlite3_carray_bind(p_stmt: ?*c.Vdbe, idx: c_int, a_data: ?*anyopaque, n_data: c_int, m_flags: c_int, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    return sqlite3_carray_bind_v2(p_stmt, idx, a_data, n_data, m_flags, x_destroy, a_data);
}
