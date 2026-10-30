//! sqlite3_mprintf() and friends, and the sqlite3_str interface, on the
//! engine's printf (sql/printf.zig).
//!
//! The variadic functions are in C (capi/varargs.c): it reads the
//! arguments out of the va_list, as the format says, into an array of
//! XqArg, and calls the xq_* functions here.

const std = @import("std");
const c = @import("common.zig");

const StrAccum = c.printf.StrAccum;
const Arg = c.printf.Arg;
const RC = c.RC;

/// One argument read from a va_list by capi/varargs.c.
pub const XqArg = extern struct {
    kind: c_int,
    v: extern union {
        i: i64,
        d: f64,
        s: ?[*:0]const u8,
        p: ?*anyopaque,
    },
};

const ARG_INT = 0;
const ARG_DOUBLE = 1;
const ARG_STR = 2;
/// %z: a string to sqlite3_free() once formatted.
const ARG_STR_FREE = 3;

/// The engine's arguments for `args`, in `buf` if they fit.
fn toArgs(args: ?[*]const XqArg, n: c_int, buf: []Arg) ?[]Arg {
    const count: usize = @intCast(@max(n, 0));
    const out = if (count <= buf.len) buf[0..count] else c.gpa.alloc(Arg, count) catch return null;
    for (out, 0..) |*o, i| {
        const a = args.?[i];
        o.* = switch (a.kind) {
            ARG_DOUBLE => .{ .double = a.v.d },
            ARG_STR, ARG_STR_FREE => .{ .str = c.span(a.v.s) },
            else => .{ .int = a.v.i },
        };
    }
    return out;
}

fn freeArgs(args: ?[*]const XqArg, n: c_int, list: []Arg, buf: []Arg) void {
    for (0..@intCast(@max(n, 0))) |i| {
        if (args.?[i].kind == ARG_STR_FREE) if (args.?[i].v.s) |s| c.malloc.free(@constCast(s));
    }
    if (list.ptr != buf.ptr) c.gpa.free(list);
}

/// Render `fmt` onto `acc`.
fn render(acc: *StrAccum, fmt: [*:0]const u8, args: ?[*]const XqArg, n: c_int) void {
    var buf: [32]Arg = undefined;
    const list = toArgs(args, n, &buf) orelse {
        acc.setError(c.printf.NOMEM);
        return;
    };
    defer freeArgs(args, n, list, &buf);
    c.printf.vappendf(acc, std.mem.span(fmt), .{ .list = list });
}

pub fn xq_vmprintf(fmt: ?[*:0]const u8, args: ?[*]const XqArg, n: c_int) callconv(.c) ?[*:0]u8 {
    const f = fmt orelse return null;
    var base: [70]u8 = undefined;
    var acc = StrAccum.init(c.gpa, &base, c.printf.max_length);
    render(&acc, f, args, n);
    const z = acc.finish() orelse return null;
    return z.ptr;
}

pub fn xq_vsnprintf(n_buf: c_int, buf: ?[*]u8, fmt: ?[*:0]const u8, args: ?[*]const XqArg, n: c_int) callconv(.c) ?[*]u8 {
    const b = buf orelse return null;
    if (n_buf <= 0) return b;
    const f = fmt orelse {
        b[0] = 0;
        return b;
    };
    var acc = StrAccum.init(null, b[0..@intCast(n_buf)], 0);
    render(&acc, f, args, n);
    b[acc.n_char] = 0;
    return b;
}

pub fn xq_str_vappendf(p: ?*StrAccum, fmt: ?[*:0]const u8, args: ?[*]const XqArg, n: c_int) callconv(.c) void {
    const acc = p orelse return;
    if (acc == &oom_str) return;
    render(acc, fmt orelse return, args, n);
}

/// Format the message of sqlite3_log() and pass it to the logger set
/// with SQLITE_CONFIG_LOG, if any.
pub fn xq_log(code: c_int, fmt: ?[*:0]const u8, args: ?[*]const XqArg, n: c_int) callconv(.c) void {
    const log = c.state.log;
    const f = log.f orelse return;
    var base: [512]u8 = undefined;
    var acc = StrAccum.init(null, &base, 0);
    render(&acc, fmt orelse return, args, n);
    base[acc.n_char] = 0;
    f(log.arg, code, @ptrCast(&base));
}

/// Whether sqlite3_log() would log anything (the C shim skips reading
/// the arguments otherwise).
pub fn xq_log_enabled() callconv(.c) c_int {
    return @intFromBool(c.state.log.f != null);
}

// ============================================================ sqlite3_str

/// The sqlite3_str of a failed sqlite3_str_new() (sqlite3OomStr).
var oom_str: StrAccum = .{ .gpa = null, .mx_alloc = 0, .acc_error = c.printf.NOMEM };

pub export fn sqlite3_str_new(db: ?*c.Handle) callconv(.c) *StrAccum {
    const p = c.gpa.create(StrAccum) catch return &oom_str;
    const limit: usize = if (db) |d| @intCast(d.limit(.length)) else c.printf.max_length;
    p.* = StrAccum.init(c.gpa, &.{}, limit);
    return p;
}

pub export fn sqlite3_str_finish(p_arg: ?*StrAccum) callconv(.c) ?[*:0]u8 {
    const p = p_arg orelse return null;
    if (p == &oom_str) return null;
    const z = p.finish();
    p.reset();
    c.gpa.destroy(p);
    return if (z) |s| s.ptr else null;
}

pub export fn sqlite3_str_free(p_arg: ?*StrAccum) callconv(.c) void {
    const p = p_arg orelse return;
    if (p == &oom_str) return;
    p.reset();
    c.gpa.destroy(p);
}

pub export fn sqlite3_str_append(p: ?*StrAccum, z: ?[*]const u8, n: c_int) callconv(.c) void {
    const acc = p orelse return;
    if (acc == &oom_str or n <= 0) return;
    acc.append((z orelse return)[0..@intCast(n)]);
}

pub export fn sqlite3_str_appendall(p: ?*StrAccum, z: ?[*:0]const u8) callconv(.c) void {
    const acc = p orelse return;
    if (acc == &oom_str) return;
    acc.appendAll(std.mem.span(z orelse return));
}

pub export fn sqlite3_str_appendchar(p: ?*StrAccum, n: c_int, ch: u8) callconv(.c) void {
    const acc = p orelse return;
    if (acc == &oom_str) return;
    acc.appendChar(n, ch);
}

pub export fn sqlite3_str_reset(p: ?*StrAccum) callconv(.c) void {
    const acc = p orelse return;
    if (acc == &oom_str) return;
    acc.reset();
    acc.acc_error = 0;
}

pub export fn sqlite3_str_truncate(p: ?*StrAccum, n: c_int) callconv(.c) void {
    const acc = p orelse return;
    if (acc == &oom_str or acc.acc_error != 0) return;
    acc.truncate(@intCast(@max(n, 0)));
}

pub export fn sqlite3_str_errcode(p: ?*StrAccum) callconv(.c) c_int {
    return (p orelse return RC.NOMEM).acc_error;
}

pub export fn sqlite3_str_length(p: ?*StrAccum) callconv(.c) c_int {
    return @intCast((p orelse return 0).n_char);
}

pub export fn sqlite3_str_value(p_arg: ?*StrAccum) callconv(.c) ?[*:0]u8 {
    const p = p_arg orelse return null;
    if (p.n_char == 0 or p.acc_error != 0 or p.buf.len == 0) return null;
    p.buf[p.n_char] = 0;
    return @ptrCast(p.buf.ptr);
}

// The flags of sqlite3_result_str().
const COPY = 0;
const XFER = 1;
const FINISH = 2;

pub export fn sqlite3_result_str(ctx_arg: ?*c.Context, p_arg: ?*StrAccum, flags: c_int) callconv(.c) void {
    const ctx = ctx_arg orelse return;
    const p = p_arg orelse return c.api.resultNull(ctx);
    if (p == &oom_str) return c.api.resultErrorNomem(ctx);
    c.api.resultStr(ctx, p, if (flags == COPY) .copy else .xfer);
    if (flags == FINISH) sqlite3_str_free(p);
}

// The xq_* functions are for capi/varargs.c only: hidden outside the library.
comptime {
    @export(&xq_vmprintf, .{ .name = "xq_vmprintf", .visibility = .hidden });
    @export(&xq_vsnprintf, .{ .name = "xq_vsnprintf", .visibility = .hidden });
    @export(&xq_str_vappendf, .{ .name = "xq_str_vappendf", .visibility = .hidden });
    @export(&xq_log, .{ .name = "xq_log", .visibility = .hidden });
    @export(&xq_log_enabled, .{ .name = "xq_log_enabled", .visibility = .hidden });
}
