//! SQLite's printf (port of printf.c): the StrAccum string builder and
//! the format engine behind sqlite3_mprintf(), the printf() SQL function
//! and the rendering of REAL values as text.
//!
//! C passes the arguments as varargs; here they come from an `Args`:
//! either a slice of `Arg` values (the internal sqlite3MPrintf() use,
//! with %T, %S and friends), or an `ArgSource` reading SQL function
//! arguments by index (SQLITE_PRINTF_SQLFUNC, where a missing argument
//! reads as 0, 0.0 or NULL). Each conversion takes the next argument and
//! coerces it the way the corresponding va_arg() or sqlite3_value_*()
//! call would.

const std = @import("std");
const numeric = @import("numeric.zig");
const int = @import("sqlite_int.zig");
const malloc = @import("malloc.zig");
const thunk = @import("../util/thunk.zig");

const Allocator = std.mem.Allocator;

/// Result codes kept in StrAccum.acc_error.
pub const NOMEM: u8 = 7;
pub const TOOBIG: u8 = 18;

/// SQLITE_MAX_LENGTH.
pub const max_length = 1000000000;

/// SQLITE_PRINT_BUF_SIZE (etBUFSIZE): the conversion buffer size.
const buf_size = 70;

/// SQLITE_FP_PRECISION_LIMIT.
const fp_precision_limit = 100000000;

/// One argument of an internal printf.
pub const Arg = union(enum) {
    int: i64,
    double: f64,
    /// A string, or null for a C NULL pointer (%Q prints NULL, %s "").
    /// Text after a NUL byte is ignored, as in C.
    str: ?[]const u8,
    /// %T: a token.
    token: ?*const int.Token,
    /// %#T: an expression whose token is printed.
    expr: *const int.Expr,
    /// %S: a FROM-clause term.
    src_item: *const int.SrcItem,
};

/// The arguments of the printf() SQL function (PrintfArguments), read
/// through callbacks so that this file needs no VDBE values. Made with
/// init() from typed readers.
pub const ArgSource = struct {
    ctx: *const anyopaque,
    n_arg: usize,
    n_used: usize = 0,
    int64: *const fn (ctx: *const anyopaque, i: usize) i64,
    double: *const fn (ctx: *const anyopaque, i: usize) f64,
    /// The argument as text, or null for NULL.
    text: *const fn (ctx: *const anyopaque, i: usize) ?[]const u8,

    /// The `n_arg` arguments of `ctx`, read by `int64(ctx, i)`,
    /// `double(ctx, i)` and `text(ctx, i)`, typed functions taking `ctx`
    /// first (made C-shaped by thunk.thunk()).
    pub fn init(ctx: anytype, n_arg: usize, comptime int64: anytype, comptime double: anytype, comptime text: anytype) ArgSource {
        const Ctx = @typeInfo(@TypeOf(int64)).@"fn".param_types[0].?;
        const typed: Ctx = ctx;
        return .{
            .ctx = thunk.erase(*const anyopaque, typed),
            .n_arg = n_arg,
            .int64 = thunk.thunk(@FieldType(ArgSource, "int64"), int64),
            .double = thunk.thunk(@FieldType(ArgSource, "double"), double),
            .text = thunk.thunk(@FieldType(ArgSource, "text"), text),
        };
    }
};

pub const Args = union(enum) {
    list: []const Arg,
    sql: *ArgSource,
};

/// A string under construction (StrAccum / sqlite3_str).
pub const StrAccum = struct {
    /// For growing the buffer and for temporary buffers. Without one,
    /// anything that needs memory fails with NOMEM.
    gpa: ?Allocator,
    /// The text so far, in buf[0..n_char]. buf.len is nAlloc.
    buf: []u8 = &.{},
    n_char: usize = 0,
    /// The largest allocation allowed; 0 means never allocate the buffer.
    mx_alloc: usize,
    /// 0, NOMEM or TOOBIG.
    acc_error: u8 = 0,
    /// SQLITE_PRINTF_INTERNAL: %T and %S are allowed.
    internal: bool = false,
    /// SQLITE_PRINTF_MALLOCED: buf was allocated with gpa.
    malloced: bool = false,
    /// The connection, if any (sqlite3MPrintf(db, ...)): %T and %#T
    /// record the error offset of its statement under construction.
    db: ?*int.Sqlite3 = null,

    /// Port of sqlite3StrAccumInit(): `base` is the initial buffer (may
    /// be empty); `mx_alloc` 0 means it never grows.
    pub fn init(gpa: ?Allocator, base: []u8, mx_alloc: usize) StrAccum {
        return .{ .gpa = gpa, .buf = base, .mx_alloc = mx_alloc };
    }

    /// Port of sqlite3StrAccumSetError(). (The C code also reports TOOBIG
    /// to the parser; callers check acc_error instead.)
    pub fn setError(p: *StrAccum, e: u8) void {
        std.debug.assert(e == NOMEM or e == TOOBIG);
        p.acc_error = e;
        if (p.mx_alloc != 0) p.reset();
    }

    /// Port of sqlite3StrAccumEnlarge(): make room for `n` more bytes.
    /// Returns how many can now be accepted (maybe 0).
    pub fn enlarge(p: *StrAccum, n: usize) usize {
        std.debug.assert(p.n_char + n >= p.buf.len);
        if (p.acc_error != 0) return 0;
        if (p.mx_alloc == 0) {
            p.setError(TOOBIG);
            return p.buf.len -| (p.n_char + 1);
        }
        var sz_new = p.n_char + n + 1;
        // Exponential growth, as long as it stays under the limit.
        if (sz_new + p.n_char <= p.mx_alloc) sz_new += p.n_char;
        if (sz_new > p.mx_alloc) {
            p.reset();
            p.setError(TOOBIG);
            return 0;
        }
        const gpa = p.gpa orelse {
            p.reset();
            p.setError(NOMEM);
            return 0;
        };
        // sqlite3DbRealloc() with a connection's allocator, else
        // sqlite3Realloc().
        const new = if (p.malloced)
            gpa.realloc(p.buf, sz_new) catch null
        else
            gpa.alloc(u8, sz_new) catch null;
        if (new) |z| {
            if (!p.malloced and p.n_char > 0) @memcpy(z[0..p.n_char], p.buf[0..p.n_char]);
            // nAlloc is sqlite3DbMallocSize(): all of a lookaside slot.
            p.buf = z.ptr[0..malloc.allocSize(gpa, z)];
            p.malloced = true;
        } else {
            p.reset();
            p.setError(NOMEM);
            return 0;
        }
        return n;
    }

    /// Port of sqlite3StrAccumEnlargeIfNeeded(): fails with the error of
    /// the accumulator (acc_error), if it has one.
    pub fn enlargeIfNeeded(p: *StrAccum, n: usize) Error!void {
        if (n + p.n_char >= p.buf.len) _ = p.enlarge(n);
        return switch (p.acc_error) {
            0 => {},
            TOOBIG => error.TooBig,
            else => error.OutOfMemory,
        };
    }

    /// Port of sqlite3_str_appendchar(): `n` copies of `c`.
    pub fn appendChar(p: *StrAccum, n_arg: i64, c: u8) void {
        if (n_arg <= 0) return;
        var n: usize = @intCast(n_arg);
        if (p.n_char + n >= p.buf.len) {
            n = p.enlarge(n);
            if (n == 0) return;
        }
        @memset(p.buf[p.n_char..][0..n], c);
        p.n_char += n;
    }

    /// Port of sqlite3_str_append().
    pub fn append(p: *StrAccum, z: []const u8) void {
        var n = z.len;
        if (p.n_char + n >= p.buf.len) {
            n = p.enlarge(n);
            if (n == 0) return;
        } else if (n == 0) {
            return;
        }
        @memcpy(p.buf[p.n_char..][0..n], z[0..n]);
        p.n_char += n;
    }

    /// Port of sqlite3_str_appendall(): `z` up to its first NUL.
    pub fn appendAll(p: *StrAccum, z: []const u8) void {
        p.append(cstr(z));
    }

    /// Port of sqlite3_str_appendf().
    pub fn appendf(p: *StrAccum, fmt: []const u8, args: []const Arg) void {
        vappendf(p, fmt, .{ .list = args });
    }

    /// The text so far.
    pub fn slice(p: *const StrAccum) []const u8 {
        return p.buf[0..p.n_char];
    }

    /// Port of sqlite3StrAccumFinish(): the NUL-terminated result in
    /// memory from gpa (or in the base buffer if it never grew and the
    /// accumulator may not allocate). Null after an error. The caller
    /// owns allocated results; they are not trimmed, as the allocators
    /// of malloc.zig free by pointer, except for other allocators, which
    /// need the exact length to free.
    pub fn finish(p: *StrAccum) ?[:0]u8 {
        if (p.acc_error != 0 or p.buf.len == 0) {
            if (p.buf.len == 0 and p.acc_error == 0 and p.mx_alloc > 0) {
                const gpa = p.gpa orelse return null;
                const z = gpa.alloc(u8, 1) catch {
                    p.setError(NOMEM);
                    return null;
                };
                z[0] = 0;
                return z[0..0 :0];
            }
            return null;
        }
        p.buf[p.n_char] = 0;
        if (p.mx_alloc > 0) {
            const gpa = p.gpa orelse return null;
            if (!p.malloced) {
                const z = gpa.alloc(u8, p.n_char + 1) catch {
                    p.setError(NOMEM);
                    return null;
                };
                @memcpy(z, p.buf[0 .. p.n_char + 1]);
                p.buf = z;
                p.malloced = true;
            } else if (p.buf.len != p.n_char + 1 and !malloc.freesByPointer(gpa)) {
                p.buf = gpa.realloc(p.buf, p.n_char + 1) catch p.buf;
            }
            const out = p.buf[0..p.n_char :0];
            p.buf = &.{};
            p.malloced = false;
            p.n_char = 0;
            return out;
        }
        return p.buf[0..p.n_char :0];
    }

    /// Port of sqlite3_str_truncate().
    pub fn truncate(p: *StrAccum, n: usize) void {
        if (n < p.n_char) p.n_char = n;
    }

    /// Port of sqlite3_str_reset(): free any allocated buffer.
    pub fn reset(p: *StrAccum) void {
        if (p.malloced) {
            p.gpa.?.free(p.buf);
            p.malloced = false;
        }
        p.buf = &.{};
        p.n_char = 0;
    }

    /// Port of printfTempBuf(): a temporary buffer of `n` bytes, or null
    /// (with an error set).
    fn tempBuf(p: *StrAccum, n: usize) ?[]u8 {
        if (p.acc_error != 0) return null;
        if (n > p.buf.len and n > p.mx_alloc) {
            p.setError(TOOBIG);
            return null;
        }
        const gpa = p.gpa orelse {
            p.setError(NOMEM);
            return null;
        };
        return gpa.alloc(u8, n) catch {
            p.setError(NOMEM);
            return null;
        };
    }

    fn freeTemp(p: *StrAccum, z: []u8) void {
        p.gpa.?.free(z);
    }
};

/// `s` up to its first NUL byte, as C would see it.
fn cstr(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, 0)) |i| s[0..i] else s;
}

// ============================================================ conversions

/// Conversion paradigms (et*).
const Et = enum(u8) {
    radix,
    float,
    exp,
    generic,
    size,
    string,
    dynstring,
    percent,
    charx,
    escape_q,
    escape_Q,
    token,
    srcitem,
    pointer,
    escape_w,
    ordinal,
    decimal,
    escape_j,
    escape_J,
    invalid,
};

/// FLAG_* of et_info.
const flag_signed = 1;
const flag_string = 4;

/// et_info: one conversion character.
const EtInfo = struct {
    fmttype: u8,
    base: u8,
    flags: u8,
    type: Et,
    charset: u8,
    prefix: u8,
    /// Next with the same hash, or 0.
    nxt: u8,
};

const a_digits = "0123456789ABCDEF0123456789abcdef";
const a_hex = "0123456789abcdef";
const a_prefix = "-x0\x00X0\x00";

/// fmtinfo[]: hashed on the conversion character modulo 25.
const fmtinfo = [25]EtInfo{
    .{ .fmttype = 'd', .base = 10, .flags = 1, .type = .decimal, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'e', .base = 0, .flags = 1, .type = .exp, .charset = 30, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'f', .base = 0, .flags = 1, .type = .float, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'g', .base = 0, .flags = 1, .type = .generic, .charset = 30, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'j', .base = 0, .flags = 0, .type = .escape_j, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'i', .base = 10, .flags = 1, .type = .decimal, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'Q', .base = 0, .flags = 4, .type = .escape_Q, .charset = 0, .prefix = 0, .nxt = 4 },
    .{ .fmttype = 'p', .base = 16, .flags = 0, .type = .pointer, .charset = 0, .prefix = 1, .nxt = 0 },
    .{ .fmttype = 'S', .base = 0, .flags = 0, .type = .srcitem, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'T', .base = 0, .flags = 0, .type = .token, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'n', .base = 0, .flags = 0, .type = .size, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'o', .base = 8, .flags = 0, .type = .radix, .charset = 0, .prefix = 2, .nxt = 0 },
    .{ .fmttype = '%', .base = 0, .flags = 0, .type = .percent, .charset = 0, .prefix = 0, .nxt = 7 },
    .{ .fmttype = 'q', .base = 0, .flags = 4, .type = .escape_q, .charset = 0, .prefix = 0, .nxt = 16 },
    .{ .fmttype = 'r', .base = 10, .flags = 1, .type = .ordinal, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 's', .base = 0, .flags = 4, .type = .string, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'X', .base = 16, .flags = 0, .type = .radix, .charset = 0, .prefix = 4, .nxt = 0 },
    .{ .fmttype = 'u', .base = 10, .flags = 0, .type = .decimal, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'w', .base = 0, .flags = 4, .type = .escape_w, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'E', .base = 0, .flags = 1, .type = .exp, .charset = 14, .prefix = 0, .nxt = 18 },
    .{ .fmttype = 'x', .base = 16, .flags = 0, .type = .radix, .charset = 16, .prefix = 1, .nxt = 0 },
    .{ .fmttype = 'G', .base = 0, .flags = 1, .type = .generic, .charset = 14, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'z', .base = 0, .flags = 4, .type = .dynstring, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'J', .base = 0, .flags = 0, .type = .escape_J, .charset = 0, .prefix = 0, .nxt = 0 },
    .{ .fmttype = 'c', .base = 0, .flags = 0, .type = .charx, .charset = 0, .prefix = 0, .nxt = 23 },
};

/// Port of sqlite3AppendOneUtf8Character() (utf.c).
pub fn appendOneUtf8Character(out: []u8, v: u32) usize {
    if (v < 0x80) {
        out[0] = @truncate(v);
        return 1;
    }
    if (v < 0x800) {
        out[0] = 0xc0 + @as(u8, @truncate((v >> 6) & 0x1f));
        out[1] = 0x80 + @as(u8, @truncate(v & 0x3f));
        return 2;
    }
    if (v < 0x10000) {
        out[0] = 0xe0 + @as(u8, @truncate((v >> 12) & 0x0f));
        out[1] = 0x80 + @as(u8, @truncate((v >> 6) & 0x3f));
        out[2] = 0x80 + @as(u8, @truncate(v & 0x3f));
        return 3;
    }
    out[0] = 0xf0 + @as(u8, @truncate((v >> 18) & 0x07));
    out[1] = 0x80 + @as(u8, @truncate((v >> 12) & 0x3f));
    out[2] = 0x80 + @as(u8, @truncate((v >> 6) & 0x3f));
    out[3] = 0x80 + @as(u8, @truncate(v & 0x3f));
    return 4;
}

/// Reads arguments in order (va_arg / getIntArg and friends).
const ArgReader = struct {
    args: Args,
    next: usize = 0,

    fn sqlFunc(r: *const ArgReader) bool {
        return r.args == .sql;
    }

    fn take(r: *ArgReader) ?Arg {
        const list = r.args.list;
        if (r.next >= list.len) return null;
        r.next += 1;
        return list[r.next - 1];
    }

    /// An integer argument; with `long` 0 a C int/unsigned int is read,
    /// so only the low 32 bits count.
    fn int64(r: *ArgReader) i64 {
        switch (r.args) {
            .sql => |s| {
                if (s.n_arg <= s.n_used) return 0;
                s.n_used += 1;
                return s.int64(s.ctx, s.n_used - 1);
            },
            .list => return switch (r.take() orelse return 0) {
                .int => |v| v,
                .double => |d| numeric.realToI64(d),
                else => 0,
            },
        }
    }

    fn double(r: *ArgReader) f64 {
        switch (r.args) {
            .sql => |s| {
                if (s.n_arg <= s.n_used) return 0.0;
                s.n_used += 1;
                return s.double(s.ctx, s.n_used - 1);
            },
            .list => return switch (r.take() orelse return 0.0) {
                .double => |d| d,
                .int => |v| @floatFromInt(v),
                else => 0.0,
            },
        }
    }

    fn text(r: *ArgReader) ?[]const u8 {
        switch (r.args) {
            .sql => |s| {
                if (s.n_arg <= s.n_used) return null;
                s.n_used += 1;
                return if (s.text(s.ctx, s.n_used - 1)) |t| cstr(t) else null;
            },
            .list => return switch (r.take() orelse return null) {
                .str => |t| if (t) |x| cstr(x) else null,
                else => null,
            },
        }
    }
};

/// Port of sqlite3_str_vappendf(): render `fmt` with `args` onto `acc`.
/// The format follows C printf with SQLite's extensions: flags - + space
/// # ! 0 and ',' (thousands), width and precision (possibly *), l and ll,
/// and the conversions d i u x X o c s z q Q w j J g G e E f p r n % T S.
/// %z is the same as %s (no ownership is transferred) and %n prints
/// nothing and reads no argument.
pub fn vappendf(acc: *StrAccum, fmt: []const u8, args: Args) void {
    var rd: ArgReader = .{ .args = args };
    const sql_func = rd.sqlFunc();
    const at = struct {
        fn f(s: []const u8, i: usize) u8 {
            return if (i < s.len) s[i] else 0;
        }
    }.f;

    var buf: [buf_size]u8 = undefined;
    var fi: usize = 0;
    outer: while (at(fmt, fi) != 0) : (fi += 1) {
        var c = fmt[fi];
        if (c != '%') {
            const start = fi;
            fi = std.mem.indexOfScalarPos(u8, fmt, fi, '%') orelse fmt.len;
            acc.append(cstr(fmt[start..fi]));
            if (at(fmt, fi) == 0) break;
        }
        fi += 1;
        c = at(fmt, fi);
        if (c == 0) {
            acc.append("%");
            break;
        }

        // Flags, width, precision and size.
        var flag_leftjustify = false;
        var flag_prefix: u8 = 0;
        var c_thousand: u8 = 0;
        var flag_alternateform = false;
        var flag_altform2 = false;
        var flag_zeropad = false;
        var flag_long: u2 = 0;
        var width: i64 = 0;
        var precision: i64 = -1;
        var done = false;
        while (true) {
            switch (c) {
                '-' => flag_leftjustify = true,
                '+' => flag_prefix = '+',
                ' ' => flag_prefix = ' ',
                '#' => flag_alternateform = true,
                '!' => flag_altform2 = true,
                '0' => flag_zeropad = true,
                ',' => c_thousand = ',',
                'l' => {
                    flag_long = 1;
                    fi += 1;
                    c = at(fmt, fi);
                    if (c == 'l') {
                        fi += 1;
                        c = at(fmt, fi);
                        flag_long = 2;
                    }
                    done = true;
                },
                '1'...'9' => {
                    var wx: u32 = c - '0';
                    while (true) {
                        fi += 1;
                        c = at(fmt, fi);
                        if (c < '0' or c > '9') break;
                        wx = wx *% 10 +% (c - '0');
                    }
                    width = wx & 0x7fffffff;
                    if (c != '.' and c != 'l') {
                        done = true;
                    } else {
                        fi -= 1;
                    }
                },
                '*' => {
                    width = if (sql_func) @as(i32, @truncate(rd.int64())) else @as(i32, @truncate(rd.int64()));
                    if (width < 0) {
                        flag_leftjustify = true;
                        width = if (width >= -2147483647) -width else 0;
                    }
                    c = at(fmt, fi + 1);
                    if (c != '.' and c != 'l') {
                        fi += 1;
                        c = at(fmt, fi);
                        done = true;
                    }
                },
                '.' => {
                    fi += 1;
                    c = at(fmt, fi);
                    if (c == '*') {
                        precision = @as(i32, @truncate(rd.int64()));
                        if (precision < 0) {
                            precision = if (precision >= -2147483647) -precision else -1;
                        }
                        fi += 1;
                        c = at(fmt, fi);
                    } else {
                        var px: u32 = 0;
                        while (c >= '0' and c <= '9') {
                            px = px *% 10 +% (c - '0');
                            fi += 1;
                            c = at(fmt, fi);
                        }
                        precision = px & 0x7fffffff;
                    }
                    if (c == 'l') {
                        fi -= 1;
                    } else {
                        done = true;
                    }
                },
                else => done = true,
            }
            if (done) break;
            fi += 1;
            c = at(fmt, fi);
            if (c == 0) break;
        }

        // The conversion.
        var idx: usize = c % 25;
        var infop = &fmtinfo[0];
        var xtype: Et = .invalid;
        if (fmtinfo[idx].fmttype == c or blk: {
            idx = fmtinfo[idx].nxt;
            break :blk fmtinfo[idx].fmttype == c;
        }) {
            infop = &fmtinfo[idx];
            xtype = infop.type;
        }

        // The text of the conversion, and an allocation to free after.
        var out: []const u8 = "";
        var extra: ?[]u8 = null;
        defer if (extra) |x| acc.freeTemp(x);

        switch (xtype) {
            .pointer, .ordinal, .radix, .decimal => {
                if (xtype == .pointer) flag_long = 2;
                if (xtype != .decimal) c_thousand = 0;
                var longvalue: u64 = undefined;
                var prefix: u8 = 0;
                if (infop.flags & flag_signed != 0) {
                    var v = rd.int64();
                    if (!sql_func and flag_long == 0) v = @as(i32, @truncate(v));
                    if (v < 0) {
                        longvalue = ~@as(u64, @bitCast(v)) +% 1;
                        prefix = '-';
                    } else {
                        longvalue = @intCast(v);
                        prefix = flag_prefix;
                    }
                } else {
                    const v: u64 = @bitCast(rd.int64());
                    longvalue = if (!sql_func and flag_long == 0) @as(u32, @truncate(v)) else v;
                    prefix = 0;
                }
                if (longvalue == 0) flag_alternateform = false;
                if (flag_zeropad and precision < width - @intFromBool(prefix != 0)) {
                    precision = width - @intFromBool(prefix != 0);
                }
                var z_out: []u8 = &buf;
                if (precision >= buf_size - 10 - buf_size / 3) {
                    var n: u64 = @as(u64, @intCast(precision)) + 10;
                    if (c_thousand != 0) n += @as(u64, @intCast(precision)) / 3;
                    z_out = acc.tempBuf(@intCast(n)) orelse return;
                    extra = z_out;
                }
                const end = z_out.len - 1;
                var bp = end;
                if (xtype == .ordinal) {
                    const z_ord = "thstndrd";
                    var x: usize = @intCast(longvalue % 10);
                    if (x >= 4 or (longvalue / 10) % 10 == 1) x = 0;
                    bp -= 1;
                    z_out[bp] = z_ord[x * 2 + 1];
                    bp -= 1;
                    z_out[bp] = z_ord[x * 2];
                }
                {
                    const cset = a_digits[infop.charset..];
                    const base = infop.base;
                    while (true) {
                        bp -= 1;
                        z_out[bp] = cset[@intCast(longvalue % base)];
                        longvalue /= base;
                        if (longvalue == 0) break;
                    }
                }
                var length: i64 = @intCast(end - bp);
                if (precision > length) {
                    const nn: usize = @intCast(precision - length);
                    bp -= nn;
                    @memset(z_out[bp..][0..nn], '0');
                    length = precision;
                }
                if (c_thousand != 0) {
                    var nn: i64 = @divTrunc(length - 1, 3);
                    var ix: i64 = @rem(length - 1, 3) + 1;
                    bp -= @intCast(nn);
                    var ii: usize = 0;
                    while (nn > 0) : (ii += 1) {
                        z_out[bp + ii] = z_out[bp + ii + @as(usize, @intCast(nn))];
                        ix -= 1;
                        if (ix == 0) {
                            ii += 1;
                            z_out[bp + ii] = c_thousand;
                            nn -= 1;
                            ix = 3;
                        }
                    }
                }
                if (prefix != 0) {
                    bp -= 1;
                    z_out[bp] = prefix;
                }
                if (flag_alternateform and infop.prefix != 0) {
                    var pre: usize = infop.prefix;
                    while (a_prefix[pre] != 0) : (pre += 1) {
                        bp -= 1;
                        z_out[bp] = a_prefix[pre];
                    }
                }
                out = z_out[bp..end];
            },
            .float, .exp, .generic => {
                const realvalue = rd.double();
                if (precision < 0) precision = 6;
                if (precision > fp_precision_limit) precision = fp_precision_limit;
                var i_round: i32 = undefined;
                if (xtype == .float) {
                    i_round = @intCast(-precision);
                } else if (xtype == .generic) {
                    if (precision == 0) precision = 1;
                    i_round = @intCast(precision);
                } else {
                    i_round = @intCast(precision + 1);
                }
                var s: numeric.FpDecode = .{};
                numeric.fpDecode(&s, realvalue, i_round, if (flag_altform2) 20 else 16);
                var prefix: u8 = 0;
                if (s.is_special != 0) {
                    if (s.is_special == 2) {
                        out = if (flag_zeropad) "null" else "NaN";
                        emit(acc, out, width, flag_leftjustify);
                        continue :outer;
                    } else if (flag_zeropad) {
                        s.buf[s.z] = '9';
                        s.i_dp = 1000;
                        s.n = 1;
                    } else {
                        @memcpy(buf[0..4], "-Inf");
                        var start: usize = 0;
                        if (s.sign == '-') {
                            // keep the '-'
                        } else if (flag_prefix != 0) {
                            buf[0] = flag_prefix;
                        } else {
                            start = 1;
                        }
                        emit(acc, buf[start..4], width, flag_leftjustify);
                        continue :outer;
                    }
                }
                if (s.sign == '-') {
                    if (flag_alternateform and flag_prefix == 0 and xtype == .float and s.i_dp <= i_round) {
                        // A displayed zero with '#' and %f: no minus sign.
                        prefix = 0;
                    } else {
                        prefix = '-';
                    }
                } else {
                    prefix = flag_prefix;
                }

                var exp: i32 = s.i_dp - 1;
                var flag_rtz: bool = undefined;
                if (xtype == .generic) {
                    precision -= 1;
                    flag_rtz = !flag_alternateform;
                    if (exp < -4 or exp > precision) {
                        xtype = .exp;
                    } else {
                        precision = precision - exp;
                        xtype = .float;
                    }
                } else {
                    flag_rtz = flag_altform2;
                }
                var e2: i64 = if (xtype == .exp) 0 else s.i_dp - 1;

                var sz_needed: i64 = @max(e2, 0) + precision + width + 10;
                if (c_thousand != 0 and e2 > 0) sz_needed += @divTrunc(e2 + 2, 3);
                const need: usize = @intCast(sz_needed);
                var z_out: []u8 = undefined;
                var direct = true;
                if (need + acc.n_char >= acc.buf.len) {
                    if (acc.mx_alloc == 0 and acc.acc_error == 0) {
                        // Render elsewhere, then copy what fits.
                        const gpa = acc.gpa orelse {
                            acc.setError(NOMEM);
                            return;
                        };
                        z_out = gpa.alloc(u8, need) catch {
                            acc.setError(NOMEM);
                            return;
                        };
                        extra = z_out;
                        direct = false;
                    } else if (acc.enlarge(need) < need) {
                        continue :outer;
                    } else {
                        z_out = acc.buf[acc.n_char..];
                    }
                } else {
                    z_out = acc.buf[acc.n_char..];
                }

                const flag_dp = precision > 0 or flag_alternateform or flag_altform2;
                var bp: usize = 0;
                if (prefix != 0) {
                    z_out[bp] = prefix;
                    bp += 1;
                }
                // Digits before the decimal point.
                const sz = s.buf[s.z..];
                const sn: usize = @intCast(s.n);
                var j: usize = 0;
                if (e2 < 0) {
                    z_out[bp] = '0';
                    bp += 1;
                } else if (c_thousand != 0) {
                    while (e2 >= 0) : (e2 -= 1) {
                        if (j < sn) {
                            z_out[bp] = sz[j];
                            j += 1;
                        } else {
                            z_out[bp] = '0';
                        }
                        bp += 1;
                        if (@rem(e2, 3) == 0 and e2 > 1) {
                            z_out[bp] = ',';
                            bp += 1;
                        }
                    }
                } else {
                    j = @intCast(e2 + 1);
                    if (j > sn) j = sn;
                    @memcpy(z_out[bp..][0..j], sz[0..j]);
                    bp += j;
                    e2 -= @intCast(j);
                    if (e2 >= 0) {
                        const nz: usize = @intCast(e2 + 1);
                        @memset(z_out[bp..][0..nz], '0');
                        bp += nz;
                        e2 = -1;
                    }
                }
                if (flag_dp) {
                    z_out[bp] = '.';
                    bp += 1;
                }
                // Zeros after the point, before the first significant digit.
                if (e2 < -1 and precision > 0) {
                    var nn: i64 = -1 - e2;
                    if (nn > precision) nn = precision;
                    @memset(z_out[bp..][0..@intCast(nn)], '0');
                    bp += @intCast(nn);
                    precision -= nn;
                }
                // Significant digits after the point.
                if (precision > 0) {
                    var nn: i64 = @as(i64, @intCast(sn)) - @as(i64, @intCast(j));
                    if (nn > precision) nn = precision;
                    if (nn > 0) {
                        @memcpy(z_out[bp..][0..@intCast(nn)], sz[j..][0..@intCast(nn)]);
                        bp += @intCast(nn);
                        precision -= nn;
                    }
                    if (precision > 0 and !flag_rtz) {
                        @memset(z_out[bp..][0..@intCast(precision)], '0');
                        bp += @intCast(precision);
                    }
                }
                // Drop trailing zeros, and the point if nothing follows it.
                if (flag_rtz and flag_dp) {
                    while (z_out[bp - 1] == '0') {
                        bp -= 1;
                        z_out[bp] = 0;
                    }
                    if (z_out[bp - 1] == '.') {
                        if (flag_altform2) {
                            z_out[bp] = '0';
                            bp += 1;
                        } else {
                            bp -= 1;
                            z_out[bp] = 0;
                        }
                    }
                }
                if (xtype == .exp) {
                    exp = s.i_dp - 1;
                    z_out[bp] = a_digits[infop.charset];
                    bp += 1;
                    if (exp < 0) {
                        z_out[bp] = '-';
                        exp = -exp;
                    } else {
                        z_out[bp] = '+';
                    }
                    bp += 1;
                    if (exp >= 100) {
                        z_out[bp] = @intCast(@divTrunc(exp, 100) + '0');
                        bp += 1;
                        exp = @rem(exp, 100);
                    }
                    z_out[bp] = @intCast(@divTrunc(exp, 10) + '0');
                    z_out[bp + 1] = @intCast(@rem(exp, 10) + '0');
                    bp += 2;
                }

                var length: usize = bp;
                if (length < width) {
                    const n_pad: usize = @intCast(width - @as(i64, @intCast(length)));
                    if (flag_leftjustify) {
                        @memset(z_out[bp..][0..n_pad], ' ');
                    } else if (!flag_zeropad) {
                        std.mem.copyBackwards(u8, z_out[n_pad..][0..length], z_out[0..length]);
                        @memset(z_out[0..n_pad], ' ');
                    } else {
                        const adj: usize = @intFromBool(prefix != 0);
                        std.mem.copyBackwards(u8, z_out[n_pad + adj ..][0 .. length - adj], z_out[adj..length]);
                        @memset(z_out[adj..][0..n_pad], '0');
                    }
                    length = @intCast(width);
                }
                if (direct) {
                    acc.n_char += length;
                    z_out[length] = 0;
                    continue :outer;
                }
                out = z_out[0..length];
            },
            .size => {
                width = 0;
            },
            .percent => out = "%",
            .charx => {
                var length: usize = 1;
                var from_text = sql_func;
                var text: ?[]const u8 = null;
                var code: u32 = 0;
                if (!sql_func) {
                    if (rd.take()) |a| switch (a) {
                        .str => |t| {
                            from_text = true;
                            text = if (t) |x| cstr(x) else null;
                        },
                        .int => |v| code = @truncate(@as(u64, @bitCast(v))),
                        else => {},
                    };
                } else {
                    text = rd.text();
                }
                if (from_text) {
                    if (text) |t| {
                        const first: u8 = if (t.len > 0) t[0] else 0;
                        buf[0] = first;
                        var k: usize = 1;
                        if (first & 0xc0 == 0xc0) {
                            while (length < 4 and k < t.len and t[k] & 0xc0 == 0x80) {
                                buf[length] = t[k];
                                length += 1;
                                k += 1;
                            }
                        }
                    } else {
                        buf[0] = 0;
                    }
                } else {
                    length = appendOneUtf8Character(&buf, code);
                }
                if (precision > 1) {
                    var n_prior: i64 = 1;
                    width -= precision - 1;
                    if (width > 1 and !flag_leftjustify) {
                        acc.appendChar(width - 1, ' ');
                        width = 0;
                    }
                    acc.append(buf[0..length]);
                    precision -= 1;
                    while (precision > 1) {
                        if (n_prior > precision - 1) n_prior = precision - 1;
                        const n_copy: usize = length * @as(usize, @intCast(n_prior));
                        acc.enlargeIfNeeded(n_copy) catch break;
                        @memcpy(acc.buf[acc.n_char..][0..n_copy], acc.buf[acc.n_char - n_copy ..][0..n_copy]);
                        acc.n_char += n_copy;
                        precision -= n_prior;
                        n_prior *= 2;
                    }
                }
                out = buf[0..length];
                flag_altform2 = true;
                width = adjustWidthForUtf8(out, width, flag_altform2);
            },
            .string, .dynstring => {
                const s = rd.text() orelse "";
                var length: usize = undefined;
                if (precision >= 0) {
                    if (flag_altform2) {
                        // Precision counts characters.
                        var k: usize = 0;
                        var prec = precision;
                        while (prec > 0 and k < s.len) : (prec -= 1) {
                            if (s[k] >= 0xc0) {
                                k += 1;
                                while (k < s.len and s[k] & 0xc0 == 0x80) k += 1;
                            } else {
                                k += 1;
                            }
                        }
                        length = k;
                    } else {
                        length = @min(s.len, @as(usize, @intCast(precision)));
                    }
                } else {
                    length = s.len;
                }
                out = s[0..length];
                width = adjustWidthForUtf8(out, width, flag_altform2);
            },
            .escape_j, .escape_J => {
                const escarg = rd.text();
                const i_start = acc.n_char;
                if (escarg) |e| {
                    if (xtype == .escape_J) acc.append("\"");
                    var px: usize = undefined;
                    if (precision < 0) {
                        px = 0x7fffffff;
                    } else {
                        px = @intCast(precision);
                        if (flag_altform2) {
                            // Precision from code points to bytes.
                            var i: usize = 0;
                            while (i < px and i < e.len) : (i += 1) {
                                if (e[i] & 0xc0 == 0x80) px += 1;
                            }
                            if (i == px) {
                                while (px < e.len and e[px] & 0xc0 == 0x80) px += 1;
                            }
                        }
                    }
                    var i: usize = 0;
                    var j: usize = 0;
                    while (i < px) : (i += 1) {
                        const ch: u8 = if (i < e.len) e[i] else 0;
                        if (ch <= 0x1f or ch == '"' or ch == '\\') {
                            if (j < i) acc.append(e[j..i]);
                            j = i + 1;
                            if (ch == 0) break;
                            acc.appendChar(1, '\\');
                            if (ch > 0x1f) {
                                acc.appendChar(1, ch);
                            } else if ((@as(u32, 1) << @intCast(ch)) & 0x3700 != 0) {
                                acc.appendChar(1, "btn?fr"[ch - 8]);
                            } else {
                                acc.append("u00");
                                acc.appendChar(1, a_hex[ch >> 4]);
                                acc.appendChar(1, a_hex[ch & 0xf]);
                            }
                        }
                    }
                    if (j < i) acc.append(e[j..@min(i, e.len)]);
                    if (xtype == .escape_J) acc.append("\"");
                } else if (xtype == .escape_J) {
                    acc.append("null");
                }
                if (width > 0 and acc.acc_error == 0) {
                    const n: usize = acc.n_char - i_start;
                    var len: i64 = @intCast(n);
                    if (flag_altform2 and n > 0) {
                        for (acc.buf[i_start..acc.n_char]) |b| {
                            if (b & 0xc0 == 0x80) len -= 1;
                        }
                    }
                    if (width > len) {
                        const sp: usize = @intCast(width - len);
                        acc.appendChar(@intCast(sp), ' ');
                        if (!flag_leftjustify and n > 0 and acc.acc_error == 0) {
                            const zz = acc.buf[i_start..];
                            std.mem.copyBackwards(u8, zz[sp..][0..n], zz[0..n]);
                            @memset(zz[0..sp], ' ');
                        }
                    }
                }
                continue :outer;
            },
            .escape_q, .escape_Q, .escape_w => {
                var need_quote: u2 = 0;
                const arg = rd.text();
                var escarg: []const u8 = undefined;
                if (arg) |a| {
                    escarg = a;
                    if (xtype == .escape_Q) need_quote = 1;
                } else {
                    escarg = if (xtype == .escape_Q) "NULL" else "(NULL)";
                }
                var q: u8 = '\'';
                if (xtype == .escape_w) {
                    q = '"';
                    flag_alternateform = false;
                }
                // The precision is the bytes (or characters with "!") of
                // input to use.
                var k: i64 = precision;
                var i: usize = 0;
                var n: usize = 0;
                while (k != 0 and i < escarg.len) : ({
                    i += 1;
                    k -= 1;
                }) {
                    const ch = escarg[i];
                    if (ch == q) n += 1;
                    if (flag_altform2 and ch & 0xc0 == 0xc0) {
                        while (i + 1 < escarg.len and escarg[i + 1] & 0xc0 == 0x80) i += 1;
                    }
                }
                if (flag_alternateform) {
                    // %#q: unistr()-style escapes for control characters
                    // and backslash; %#Q only if there is a control char.
                    var n_back: usize = 0;
                    var n_ctrl: usize = 0;
                    for (escarg[0..i]) |ch| {
                        if (ch == '\\') {
                            n_back += 1;
                        } else if (ch <= 0x1f) {
                            n_ctrl += 1;
                        }
                    }
                    if (n_ctrl != 0 or xtype == .escape_q) {
                        n += n_back + 5 * n_ctrl;
                        if (xtype == .escape_Q) {
                            n += 10;
                            need_quote = 2;
                        }
                    } else {
                        flag_alternateform = false;
                    }
                }
                n += i + 3;
                var z: []u8 = &buf;
                if (n > buf_size) {
                    z = acc.tempBuf(n) orelse return;
                    extra = z;
                }
                var j: usize = 0;
                if (need_quote != 0) {
                    if (need_quote == 2) {
                        @memcpy(z[0..8], "unistr('");
                        j = 8;
                    } else {
                        z[0] = '\'';
                        j = 1;
                    }
                }
                const kk = i;
                if (flag_alternateform) {
                    for (escarg[0..kk]) |ch| {
                        z[j] = ch;
                        j += 1;
                        if (ch == q) {
                            z[j] = ch;
                            j += 1;
                        } else if (ch == '\\') {
                            z[j] = '\\';
                            j += 1;
                        } else if (ch <= 0x1f) {
                            z[j - 1] = '\\';
                            z[j] = 'u';
                            z[j + 1] = '0';
                            z[j + 2] = '0';
                            z[j + 3] = if (ch >= 0x10) '1' else '0';
                            z[j + 4] = a_hex[ch & 0xf];
                            j += 5;
                        }
                    }
                } else {
                    for (escarg[0..kk]) |ch| {
                        z[j] = ch;
                        j += 1;
                        if (ch == q) {
                            z[j] = ch;
                            j += 1;
                        }
                    }
                }
                if (need_quote != 0) {
                    z[j] = '\'';
                    j += 1;
                    if (need_quote == 2) {
                        z[j] = ')';
                        j += 1;
                    }
                }
                out = z[0..j];
                width = adjustWidthForUtf8(out, width, flag_altform2);
            },
            .token => {
                if (!acc.internal) return;
                const a = rd.take();
                if (flag_alternateform) {
                    // %#T: the token of an expression.
                    if (a) |arg| if (arg == .expr) {
                        const e = arg.expr;
                        if (e.useUToken()) {
                            acc.appendAll(e.u.token orelse "");
                            if (acc.db) |db| recordErrorOffsetOfExpr(db, e);
                        }
                    };
                } else if (a) |arg| if (arg == .token) {
                    if (arg.token) |t| if (t.n != 0) {
                        acc.append(t.slice());
                        if (acc.db) |db| recordErrorByteOffset(db, t.z.?);
                    };
                };
                width = 0;
            },
            .srcitem => {
                if (!acc.internal) return;
                const a = rd.take() orelse return;
                if (a != .src_item) return;
                const item = a.src_item;
                if (item.alias != null and !flag_altform2) {
                    acc.appendAll(item.alias.?);
                } else if (item.name) |name| {
                    if (!item.fg.fixed_schema and !item.fg.is_subquery) {
                        if (item.u4.database) |db| {
                            acc.appendAll(db);
                            acc.append(".");
                        }
                    }
                    acc.appendAll(name);
                } else if (item.alias) |alias| {
                    acc.appendAll(alias);
                } else if (item.fg.is_subquery) {
                    const sel = item.u4.subq.?.select;
                    if (sel.sel_flags.NestedFrom) {
                        acc.appendf("(join-%u)", &.{.{ .int = sel.sel_id }});
                    } else if (sel.sel_flags.MultiValue) {
                        acc.appendf("%u-ROW VALUES CLAUSE", &.{.{ .int = item.u1.n_row }});
                    } else {
                        acc.appendf("(subquery-%u)", &.{.{ .int = sel.sel_id }});
                    }
                }
                width = 0;
            },
            .invalid => return,
        }
        emit(acc, out, width, flag_leftjustify);
    }
}

/// The common tail of a conversion: `out` padded to `width`.
fn emit(acc: *StrAccum, out: []const u8, width_arg: i64, flag_leftjustify: bool) void {
    const width = width_arg - @as(i64, @intCast(out.len));
    if (width > 0) {
        if (!flag_leftjustify) acc.appendChar(width, ' ');
        acc.append(out);
        if (flag_leftjustify) acc.appendChar(width, ' ');
    } else {
        acc.append(out);
    }
}

/// adjust_width_for_utf8: with "!", widths count characters, so add one
/// for every continuation byte.
fn adjustWidthForUtf8(out: []const u8, width_arg: i64, flag_altform2: bool) i64 {
    var width = width_arg;
    if (flag_altform2 and width > 0) {
        for (out) |b| {
            if (b & 0xc0 == 0x80) width += 1;
        }
    }
    return width;
}

// ================================================================ helpers

pub const Error = error{ OutOfMemory, TooBig };

/// Port of sqlite3RecordErrorByteOffset(): while an error message of
/// `db` is formatted (db.err_byte_offset is -2), remember where `z` is in
/// the statement being compiled, if it points into it.
fn recordErrorByteOffset(db: *int.Sqlite3, z: [*]const u8) void {
    const p = db.parse orelse return;
    @import("util.zig").recordErrorByteOffset(p, z);
}

/// Port of sqlite3RecordErrorOffsetOfExpr(), for the statement of `db`
/// being compiled.
fn recordErrorOffsetOfExpr(db: *int.Sqlite3, e: *const int.Expr) void {
    const p = db.parse orelse return;
    @import("expr.zig").recordErrorOffsetOfExpr(p, e);
}

/// Port of sqlite3MPrintf() with an explicit length limit: render into
/// memory from `gpa` (internal conversions allowed). The caller frees.
/// With `db`, %T and %#T record the error offset as C's do.
pub fn mprintfLimit(db: ?*int.Sqlite3, gpa: Allocator, limit: usize, fmt: []const u8, args: []const Arg) Error![:0]u8 {
    var base: [buf_size]u8 = undefined;
    var acc = StrAccum.init(gpa, &base, limit);
    acc.internal = true;
    acc.db = db;
    vappendf(&acc, fmt, .{ .list = args });
    if (acc.acc_error == TOOBIG) return error.TooBig;
    return acc.finish() orelse error.OutOfMemory;
}

/// sqlite3MPrintf() with SQLITE_MAX_LENGTH as the limit.
pub fn mprintf(gpa: Allocator, fmt: []const u8, args: []const Arg) Error![:0]u8 {
    return mprintfLimit(null, gpa, max_length, fmt, args);
}

/// Render `r` as SQLite turns a REAL into TEXT: "%!.*g" with `digits`
/// significant digits (sqlite3.nFpDigit, 17 by default; see
/// vdbeMemRenderNum()). Returns the text, in `out`.
pub fn formatDouble(out: *[64]u8, r: f64, digits: i32) []const u8 {
    var acc = StrAccum.init(null, out, 0);
    vappendf(&acc, "%!.*g", .{ .list = &.{ .{ .int = digits }, .{ .double = r } } });
    return acc.slice();
}

// =================================================================== tests

fn expectFmt(want: []const u8, fmt: []const u8, args: []const Arg) !void {
    const got = try mprintf(std.testing.allocator, fmt, args);
    defer std.testing.allocator.free(got);
    std.testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("format: {s}\n", .{fmt});
        return err;
    };
}

test "printf: integers" {
    try expectFmt("42", "%d", &.{.{ .int = 42 }});
    try expectFmt("-42", "%d", &.{.{ .int = -42 }});
    try expectFmt("   42|42   |00042", "%5d|%-5d|%05d", &.{ .{ .int = 42 }, .{ .int = 42 }, .{ .int = 42 } });
    try expectFmt("+7 7", "%+d% d", &.{ .{ .int = 7 }, .{ .int = 7 } });
    try expectFmt("-0042", "%05d", &.{.{ .int = -42 }});
    try expectFmt("9223372036854775807", "%lld", &.{.{ .int = std.math.maxInt(i64) }});
    try expectFmt("-9223372036854775808", "%lld", &.{.{ .int = std.math.minInt(i64) }});
    // Without "l" a C int is read.
    try expectFmt("-1", "%d", &.{.{ .int = 0xffffffff }});
    try expectFmt("4294967295", "%u", &.{.{ .int = -1 }});
    try expectFmt("ff FF 0xff 377 0377", "%x %X %#x %o %#o", &.{ .{ .int = 255 }, .{ .int = 255 }, .{ .int = 255 }, .{ .int = 255 }, .{ .int = 255 } });
    try expectFmt("1,234,567", "%,d", &.{.{ .int = 1234567 }});
    try expectFmt("-1,000", "%,d", &.{.{ .int = -1000 }});
    try expectFmt("1st 2nd 3rd 4th 11th 12th 13th 21st 101st", "%r %r %r %r %r %r %r %r %r", &.{
        .{ .int = 1 },  .{ .int = 2 },  .{ .int = 3 },  .{ .int = 4 },   .{ .int = 11 },
        .{ .int = 12 }, .{ .int = 13 }, .{ .int = 21 }, .{ .int = 101 },
    });
    try expectFmt("0000000042", "%.10d", &.{.{ .int = 42 }});
    try expectFmt("   42", "%*d", &.{ .{ .int = 5 }, .{ .int = 42 } });
    try expectFmt("42   |", "%*d|", &.{ .{ .int = -5 }, .{ .int = 42 } });
    try expectFmt("100%", "%d%%", &.{.{ .int = 100 }});
    try expectFmt("%", "%", &.{});
}

test "printf: strings and quoting" {
    try expectFmt("hello", "%s", &.{.{ .str = "hello" }});
    try expectFmt("hel", "%.3s", &.{.{ .str = "hello" }});
    try expectFmt("  abc|abc  ", "%5s|%-5s", &.{ .{ .str = "abc" }, .{ .str = "abc" } });
    try expectFmt("", "%s", &.{.{ .str = null }});
    try expectFmt("it''s", "%q", &.{.{ .str = "it's" }});
    try expectFmt("'it''s'", "%Q", &.{.{ .str = "it's" }});
    try expectFmt("NULL", "%Q", &.{.{ .str = null }});
    try expectFmt("(NULL)", "%q", &.{.{ .str = null }});
    try expectFmt("a\"\"b", "%w", &.{.{ .str = "a\"b" }});
    try expectFmt("unistr('a\\u000ab')", "%#Q", &.{.{ .str = "a\nb" }});
    try expectFmt("'ab'", "%#Q", &.{.{ .str = "ab" }});
    try expectFmt("a\\\\b", "%#q", &.{.{ .str = "a\\b" }});
    // "!" counts characters, not bytes.
    try expectFmt("\xc3\xa9t", "%!.2s", &.{.{ .str = "\xc3\xa9t\xc3\xa9" }});
    try expectFmt("  \xc3\xa9", "%!3s", &.{.{ .str = "\xc3\xa9" }});
    try expectFmt("a\\nb\\u0001\\\"", "%j", &.{.{ .str = "a\nb\x01\"" }});
    try expectFmt("\"x\"", "%J", &.{.{ .str = "x" }});
}

test "printf: characters" {
    try expectFmt("x", "%c", &.{.{ .int = 'x' }});
    try expectFmt("xxx", "%.*c", &.{ .{ .int = 3 }, .{ .int = 'x' } });
    // A precision of 0 still prints the character once.
    try expectFmt("x", "%.*c", &.{ .{ .int = 0 }, .{ .int = 'x' } });
    try expectFmt("\xc3\xa9\xc3\xa9", "%.2c", &.{.{ .int = 0xe9 }});
    try expectFmt("   xx", "%5.2c", &.{.{ .int = 'x' }});
    // From text, only the first character is used.
    try expectFmt("aaaaaaaaaaaaaaaaaaaa", "%.*c", &.{ .{ .int = 20 }, .{ .str = "ab" } });
}

test "printf: floats" {
    try expectFmt("3.141593", "%f", &.{.{ .double = 3.14159265 }});
    try expectFmt("3.14", "%.2f", &.{.{ .double = 3.14159265 }});
    try expectFmt("1.000000e+10", "%e", &.{.{ .double = 1e10 }});
    try expectFmt("1.5E-07", "%.1E", &.{.{ .double = 1.5e-7 }});
    try expectFmt("0.1", "%g", &.{.{ .double = 0.1 }});
    try expectFmt("1e+100", "%g", &.{.{ .double = 1e100 }});
    try expectFmt("100000", "%g", &.{.{ .double = 100000.0 }});
    try expectFmt("1e+06", "%g", &.{.{ .double = 1000000.0 }});
    try expectFmt("1.5e-07", "%g", &.{.{ .double = 1.5e-7 }});
    try expectFmt("0.0001", "%g", &.{.{ .double = 0.0001 }});
    try expectFmt("  3.1", "%5.1f", &.{.{ .double = 3.14 }});
    try expectFmt("003.1", "%05.1f", &.{.{ .double = 3.14 }});
    try expectFmt("-03.1", "%05.1f", &.{.{ .double = -3.14 }});
    try expectFmt("1,234,567.50", "%,.2f", &.{.{ .double = 1234567.5 }});
    try expectFmt("0", "%.0f", &.{.{ .double = 0.4 }});
    try expectFmt("1", "%.0f", &.{.{ .double = 0.5 }});
    try expectFmt("0.0", "%.1f", &.{.{ .double = -0.0 }});
    try expectFmt("0.0", "%#.1f", &.{.{ .double = -0.01 }});
    try expectFmt("NaN Inf -Inf +Inf", "%f %f %f %+f", &.{
        .{ .double = std.math.nan(f64) },  .{ .double = std.math.inf(f64) },
        .{ .double = -std.math.inf(f64) }, .{ .double = std.math.inf(f64) },
    });
    try expectFmt("null", "%0f", &.{.{ .double = std.math.nan(f64) }});
    try expectFmt(" null", "%05f", &.{.{ .double = std.math.nan(f64) }});
}

test "printf: REAL to TEXT (%!.15g, %!.17g)" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 0.1, "0.1" },
        .{ 1.0, "1.0" },
        .{ -1.0, "-1.0" },
        .{ 1e100, "1.0e+100" },
        .{ 1.5e-7, "1.5e-07" },
        .{ 123456789012345678.0, "1.23456789012346e+17" },
        .{ -0.0, "0.0" },
        .{ 49.47, "49.47" },
        .{ 100.0, "100.0" },
        .{ 1e15, "1.0e+15" },
        .{ 123456.789, "123456.789" },
    };
    for (cases) |c| try expectFmt(c[1], "%!.15g", &.{.{ .double = c[0] }});
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1", formatDouble(&out, 0.1, 17));
    var tenth: f64 = 0.1;
    _ = &tenth;
    try std.testing.expectEqualStrings("0.3", formatDouble(&out, tenth + 0.2, 15));
    try std.testing.expectEqualStrings("0.30000000000000004", formatDouble(&out, tenth + 0.2, 17));
    try std.testing.expectEqualStrings("49.47", formatDouble(&out, 49.47, 17));
    try std.testing.expectEqualStrings("1.0e+100", formatDouble(&out, 1e100, 17));
    try std.testing.expectEqualStrings("1.2345678901234568e+17", formatDouble(&out, 123456789012345678.0, 17));
    try std.testing.expectEqualStrings("Inf", formatDouble(&out, std.math.inf(f64), 17));
    try std.testing.expectEqualStrings("-Inf", formatDouble(&out, -std.math.inf(f64), 17));
    try std.testing.expectEqualStrings("NaN", formatDouble(&out, std.math.nan(f64), 17));
    try std.testing.expectEqualStrings("3.0", formatDouble(&out, 3.0, 17));
    try std.testing.expectEqualStrings("1.0e-05", formatDouble(&out, 1e-5, 17));
}

test "printf: tokens and source items need internal mode" {
    var sql = "select xyz from t".*;
    const tok: int.Token = .init(sql[7..10]);
    try expectFmt("near \"xyz\"", "near \"%T\"", &.{.{ .token = &tok }});
    var acc = StrAccum.init(std.testing.allocator, &.{}, 1000);
    defer acc.reset();
    acc.appendf("a%Tb", &.{.{ .token = &tok }});
    // Not internal: the conversion ends the output.
    try std.testing.expectEqualStrings("a", acc.slice());
    var item: int.SrcItem = .{ .name = @constCast("t"), .u4 = .{ .database = @constCast("main") } };
    try expectFmt("main.t", "%S", &.{.{ .src_item = &item }});
    item.alias = @constCast("x");
    try expectFmt("x main.t", "%S %!S", &.{ .{ .src_item = &item }, .{ .src_item = &item } });
}

test "printf: SQL function arguments" {
    const Ctx = struct {
        vals: []const ?[]const u8,
        fn get(self: *const @This(), i: usize) ?[]const u8 {
            return self.vals[i];
        }
        fn int64(self: *const @This(), i: usize) i64 {
            const t = get(self, i) orelse return 0;
            return std.fmt.parseInt(i64, t, 10) catch 0;
        }
        fn double(self: *const @This(), i: usize) f64 {
            const t = get(self, i) orelse return 0;
            return std.fmt.parseFloat(f64, t) catch 0;
        }
    };
    var ctx: Ctx = .{ .vals = &.{ "5", "hello", "\xc3\xa9x" } };
    var src: ArgSource = .init(&ctx, 3, Ctx.int64, Ctx.double, Ctx.get);
    var acc = StrAccum.init(std.testing.allocator, &.{}, 1000);
    defer acc.reset();
    // A missing argument reads as NULL / 0; %c takes a whole character.
    vappendf(&acc, "%d %s %c %d %s|", .{ .sql = &src });
    try std.testing.expectEqualStrings("5 hello \xc3\xa9 0 |", acc.slice());
}

test "printf: limits" {
    var base: [8]u8 = undefined;
    var acc = StrAccum.init(null, &base, 0);
    acc.appendf("%s", &.{.{ .str = "0123456789" }});
    try std.testing.expectEqual(TOOBIG, acc.acc_error);
    try std.testing.expectEqualStrings("0123456", acc.slice());
    // The limit applies to allocations past the 70-byte base buffer.
    const short = try mprintfLimit(null, std.testing.allocator, 5, "%s", &.{.{ .str = "0123456789" }});
    std.testing.allocator.free(short);
    try std.testing.expectError(error.TooBig, mprintfLimit(null, std.testing.allocator, 80, "%100d", &.{.{ .int = 1 }}));
}
