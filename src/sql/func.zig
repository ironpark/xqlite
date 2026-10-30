//! The built-in SQL functions (port of func.c): scalar functions such as
//! substr() and like(), the aggregates count(), sum(), group_concat() and
//! friends, and the table that registers them.
//!
//! Only what a default build includes is here: soundex(), the math
//! functions (SQLITE_ENABLE_MATH_FUNCTIONS), median()/percentile()
//! (SQLITE_ENABLE_PERCENTILE), unknown(), sqlite_offset() and the
//! SQLITE_DEBUG helpers are compiled out by default and so are omitted.
//! load_extension() is registered but always refused, as extensions
//! cannot be loaded.

const std = @import("std");
const builtin = @import("builtin");
const int = @import("sqlite_int.zig");
const callback = @import("callback.zig");
const printf = @import("printf.zig");
const numeric = @import("numeric.zig");
const util = @import("util.zig");
const ctype = @import("../util/ctype.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const api = @import("../vdbe/api.zig");
const mem = @import("../vdbe/mem.zig");
const serial = @import("../vdbe/serial.zig");

const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const Expr = int.Expr;
const Context = vi.Context;
const Mem = vi.Mem;
const ENC = vi.ENC;
const FUNC = callback.FUNC;
const RC = int.RC;

const SQLITE_INTEGER = vi.SQLITE_INTEGER;
const SQLITE_FLOAT = vi.SQLITE_FLOAT;
const SQLITE_TEXT = vi.SQLITE_TEXT;
const SQLITE_BLOB = vi.SQLITE_BLOB;
const SQLITE_NULL = vi.SQLITE_NULL;

const largest_int64: i64 = std.math.maxInt(i64);
const smallest_int64: i64 = std.math.minInt(i64);

/// sqlite3_libversion() (SQLITE_VERSION).
pub const sqlite_version = "3.54.1";
/// sqlite3_sourceid() (SQLITE_SOURCE_ID).
pub const sqlite_source_id = "2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76";

/// Functions the code generator codes in-line; FuncDef.user_data holds
/// one of these (INLINEFUNC_*).
pub const INLINEFUNC_coalesce = 0;
pub const INLINEFUNC_implies_nonnull_row = 1;
pub const INLINEFUNC_expr_implies_expr = 2;
pub const INLINEFUNC_expr_compare = 3;
pub const INLINEFUNC_affinity = 4;
pub const INLINEFUNC_iif = 5;
pub const INLINEFUNC_sqlite_offset = 6;
pub const INLINEFUNC_unlikely = 99;

/// SQLITE_INT_TO_PTR().
pub fn intToPtr(i: usize) ?*anyopaque {
    return if (i == 0) null else @ptrFromInt(i);
}

/// SQLITE_PTR_TO_INT(), e.g. for the INLINEFUNC_* of FuncDef.user_data.
pub fn ptrToInt(p: ?*const anyopaque) usize {
    return if (p) |x| @intFromPtr(x) else 0;
}

// ================================================================ helpers

/// sqlite3Utf8Trans1: the value bits of a UTF-8 lead byte (0xc0..0xff).
pub const utf8_trans1 = [64]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x00, 0x01, 0x02, 0x03, 0x00, 0x01, 0x00, 0x00,
};

/// Port of sqlite3Utf8Read() (utf.c): the next character of a
/// NUL-terminated UTF-8 string, advancing past it. Malformed sequences
/// and surrogates read as U+FFFD.
pub fn utf8Read(pz: *[*:0]const u8) u32 {
    var z = pz.*;
    var c: u32 = z[0];
    z += 1;
    if (c >= 0xc0) {
        c = utf8_trans1[c - 0xc0];
        while (z[0] & 0xc0 == 0x80) {
            c = (c << 6) + (0x3f & z[0]);
            z += 1;
        }
        if (c < 0x80 or c & 0xFFFFF800 == 0xD800) c = 0xFFFD;
    }
    pz.* = z;
    return c;
}

/// SQLITE_SKIP_UTF8().
fn skipUtf8(pz: *[*:0]const u8) void {
    var z = pz.*;
    const c = z[0];
    z += 1;
    if (c >= 0xc0) {
        while (z[0] & 0xc0 == 0x80) z += 1;
    }
    pz.* = z;
}

/// Port of sqlite3Utf8CharLen() (utf.c): characters in the first
/// `n_byte` bytes of `z` (all of it if negative), stopping at a NUL.
pub fn utf8CharLen(z_in: [*:0]const u8, n_byte: i64) i64 {
    var r: i64 = 0;
    var z = z_in;
    const term: usize = if (n_byte >= 0) @intFromPtr(z_in) + @as(usize, @intCast(n_byte)) else std.math.maxInt(usize);
    while (z[0] != 0 and @intFromPtr(z) < term) : (r += 1) skipUtf8(&z);
    return r;
}

/// Bytes between two pointers into the same string.
fn ptrDiff(hi: [*]const u8, lo: [*]const u8) usize {
    return @intFromPtr(hi) - @intFromPtr(lo);
}

/// Port of sqlite3GetFuncCollSeq(): the collation of the OP_CollSeq that
/// precedes the call. Null (BINARY) when called outside a statement.
fn getFuncCollSeq(ctx: *Context) ?*const int.CollSeq {
    const v = ctx.vdbe orelse return null;
    const op = &v.ops.items[@intCast(ctx.i_op - 1)];
    std.debug.assert(op.opcode == vi.OP.CollSeq);
    return if (op.p4type == .collseq) op.p4.collseq else null;
}

/// Port of sqlite3SkipAccumulatorLoad(): skip the accumulator load on this
/// iteration of the aggregate loop.
fn skipAccumulatorLoad(ctx: *Context) void {
    std.debug.assert(ctx.is_error <= 0);
    ctx.is_error = -1;
    ctx.skip_flag = true;
}

/// The aggregate context as a `T`, created zeroed if `create`. The
/// buffer comes from the connection's allocator, aligned for any `T`
/// used here.
pub fn aggContext(comptime T: type, ctx: *Context, create: bool) ?*T {
    const b = api.aggregateContext(ctx, if (create) @sizeOf(T) else 0) orelse return null;
    return @ptrCast(@alignCast(b.ptr));
}

const sqlite3_malloc = @import("malloc.zig").allocator;

/// Port of contextMalloc(): `n_byte` bytes from sqlite3_malloc(), or null
/// with a TOOBIG or NOMEM error set. The connection's allocator (and a
/// .dynamic result) frees it too.
fn contextMalloc(ctx: *Context, n_byte: i64) ?[]u8 {
    const db = api.contextDbHandle(ctx);
    std.debug.assert(n_byte > 0);
    if (n_byte > db.limit(.length)) {
        api.resultErrorTooBig(ctx);
        return null;
    }
    return sqlite3_malloc.alloc(u8, @intCast(n_byte)) catch {
        api.resultErrorNomem(ctx);
        return null;
    };
}

/// Hand `buf` (from the connection's allocator, db.gpa, or from
/// sqlite3_malloc()) to the result as the text in buf[0..n] (buf[n]
/// becomes the terminator), as sqlite3_result_text(...,SQLITE_DYNAMIC)
/// does: the result takes over the whole allocation.
pub fn resultOwnedText(ctx: *Context, buf: []u8, n: usize) void {
    std.debug.assert(buf.len > n);
    buf[n] = 0;
    api.resultTextZ(ctx, buf[0..n :0], .dynamic);
}

/// Like resultOwnedText() for the blob in buf[0..n].
pub fn resultOwnedBlob(ctx: *Context, buf: []u8, n: usize) void {
    if (n == 0) {
        api.contextDbHandle(ctx).gpa.free(buf);
        api.resultBlob(ctx, "", .static);
        return;
    }
    api.resultBlob(ctx, buf[0..n], .dynamic);
}

// ====================================================== scalar functions

/// minmaxFunc(): the scalar min() and max(); user data 0 for min().
fn minmaxFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len > 1);
    const mask: i32 = if (api.userData(ctx) == null) 0 else -1;
    const coll = getFuncCollSeq(ctx);
    var best: usize = 0;
    if (api.valueType(argv[0]) == SQLITE_NULL) return;
    for (1..argv.len) |i| {
        if (api.valueType(argv[i]) == SQLITE_NULL) return;
        if ((serial.memCompare(argv[best], argv[i], coll) ^ mask) >= 0) best = i;
    }
    api.resultValue(ctx, argv[best]);
}

/// typeofFunc(): the type of the argument.
fn typeofFunc(ctx: *Context, argv: []*Mem) void {
    const az_type = [_][]const u8{ "integer", "real", "text", "blob", "null" };
    const i: usize = @intCast(api.valueType(argv[0]) - 1);
    api.resultText(ctx, az_type[i], .static);
}

/// subtypeFunc(): subtype(X).
fn subtypeFunc(ctx: *Context, argv: []*Mem) void {
    api.resultInt64(ctx, api.valueSubtype(argv[0]));
}

/// lengthFunc(): length(X), in characters for text.
fn lengthFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    switch (api.valueType(argv[0])) {
        SQLITE_BLOB, SQLITE_INTEGER, SQLITE_FLOAT => {
            api.resultInt64(ctx, @intCast(api.valueBytes(argv[0])));
        },
        SQLITE_TEXT => {
            const s = api.valueText(argv[0]) orelse return;
            var z: [*:0]const u8 = s.ptr;
            var z0: [*:0]const u8 = s.ptr;
            while (true) {
                // See tag-20260418-01.
                if (z[0] -% 1 < 0x80 - 1) {
                    z += 1;
                } else if (z[0] == 0) {
                    break;
                } else {
                    z += 1;
                    while (z[0] & 0xc0 == 0x80) {
                        z += 1;
                        z0 += 1;
                    }
                }
            }
            api.resultInt64(ctx, @intCast(ptrDiff(z, z0)));
        },
        else => api.resultNull(ctx),
    }
}

/// bytelengthFunc(): octet_length(X).
fn bytelengthFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    switch (api.valueType(argv[0])) {
        SQLITE_BLOB => api.resultInt64(ctx, @intCast(api.valueBytes(argv[0]))),
        SQLITE_INTEGER, SQLITE_FLOAT => {
            const m: i64 = if (api.contextDbHandle(ctx).enc <= ENC.UTF8) 1 else 2;
            api.resultInt64(ctx, @as(i64, @intCast(api.valueBytes(argv[0]))) * m);
        },
        // Only UTF-8 text exists so far, so sqlite3_value_bytes16() is
        // never needed.
        SQLITE_TEXT => api.resultInt64(ctx, @intCast(api.valueBytes(argv[0]))),
        else => api.resultNull(ctx),
    }
}

/// absFunc(): abs(X).
fn absFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    switch (api.valueType(argv[0])) {
        SQLITE_INTEGER => {
            var i_val = api.valueInt64(argv[0]);
            if (i_val < 0) {
                if (i_val == smallest_int64) {
                    api.resultError(ctx, "integer overflow");
                    return;
                }
                i_val = -i_val;
            }
            api.resultInt64(ctx, i_val);
        },
        SQLITE_NULL => api.resultNull(ctx),
        else => {
            // Text or blobs that are not numbers give 0.0.
            var r_val = api.valueDouble(argv[0]);
            if (r_val < 0) r_val = -r_val;
            api.resultDouble(ctx, r_val);
        },
    }
}

/// instrFunc(): instr(haystack, needle), the 1-based position of the
/// first occurrence in characters (bytes if both are blobs), or 0.
fn instrFunc(ctx: *Context, argv: []*Mem) void {
    const type_haystack = api.valueType(argv[0]);
    const type_needle = api.valueType(argv[1]);
    if (type_haystack == SQLITE_NULL or type_needle == SQLITE_NULL) return;
    var n_haystack: i64 = @intCast(api.valueBytes(argv[0]));
    var n_needle: i64 = @intCast(api.valueBytes(argv[1]));
    var c1: ?*Mem = null;
    var c2: ?*Mem = null;
    defer {
        api.valueFree(c1);
        api.valueFree(c2);
    }
    var n: i32 = 1;
    if (n_needle > 0) {
        var haystack: ?[*]const u8 = null;
        var needle: ?[*]const u8 = null;
        var is_text: bool = undefined;
        if (type_haystack == SQLITE_BLOB and type_needle == SQLITE_BLOB) {
            haystack = if (api.valueBlob(argv[0])) |b| b.ptr else null;
            needle = if (api.valueBlob(argv[1])) |b| b.ptr else null;
            is_text = false;
        } else if (type_haystack != SQLITE_BLOB and type_needle != SQLITE_BLOB) {
            haystack = if (api.valueText(argv[0])) |t| t.ptr else null;
            needle = if (api.valueText(argv[1])) |t| t.ptr else null;
            is_text = true;
        } else {
            c1 = api.valueDup(argv[0]);
            const h = (if (c1) |c| api.valueText(c) else null) orelse return api.resultErrorNomem(ctx);
            haystack = h.ptr;
            n_haystack = @intCast(api.valueBytes(c1.?));
            c2 = api.valueDup(argv[1]);
            const nd = (if (c2) |c| api.valueText(c) else null) orelse return api.resultErrorNomem(ctx);
            needle = nd.ptr;
            n_needle = @intCast(api.valueBytes(c2.?));
            is_text = true;
        }
        if (needle == null or (n_haystack != 0 and haystack == null)) return api.resultErrorNomem(ctx);
        const nd = needle.?;
        const nn: usize = @intCast(n_needle);
        const first_char = nd[0];
        var h = haystack orelse nd;
        while (n_needle <= n_haystack and (h[0] != first_char or !std.mem.eql(u8, h[0..nn], nd[0..nn]))) {
            n += 1;
            while (true) {
                n_haystack -= 1;
                h += 1;
                if (!(is_text and h[0] & 0xc0 == 0x80)) break;
            }
        }
        if (n_needle > n_haystack) n = 0;
    }
    api.resultInt(ctx, n);
}

/// The arguments of printf() after the format (PrintfArguments).
fn printfArgInt64(args: *const []*Mem, i: usize) i64 {
    return api.valueInt64(args.*[i]);
}

fn printfArgDouble(args: *const []*Mem, i: usize) f64 {
    return api.valueDouble(args.*[i]);
}

fn printfArgText(args: *const []*Mem, i: usize) ?[]const u8 {
    return api.valueText(args.*[i]);
}

/// printfFunc(): printf(FORMAT, ...) a.k.a. format().
fn printfFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (argv.len < 1) return;
    const z_format = api.valueText(argv[0]) orelse return;
    const rest: []*Mem = argv[1..];
    var x: printf.ArgSource = .init(&rest, rest.len, printfArgInt64, printfArgDouble, printfArgText);
    var str = printf.StrAccum.init(db.gpa, &.{}, @intCast(db.limit(.length)));
    printf.vappendf(&str, z_format, .{ .sql = &x });
    api.resultStr(ctx, &str, .xfer);
}

/// substrFunc(): substr(X, P1[, P2]), counting characters of text and
/// bytes of blobs. A negative P1 counts from the end; a negative P2 takes
/// the characters before P1.
fn substrFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 3 or argv.len == 2);
    const p0type = api.valueType(argv[0]);
    var p1 = api.valueInt64(argv[1]);
    var len: i64 = 0;
    var z_blob: [*]const u8 = undefined;
    var z_text: [*:0]const u8 = undefined;
    if (p0type == SQLITE_BLOB) {
        len = @intCast(api.valueBytes(argv[0]));
        const b = api.valueBlob(argv[0]) orelse return;
        z_blob = b.ptr;
    } else {
        const t = api.valueText(argv[0]) orelse return;
        z_text = t.ptr;
        if (p1 < 0) {
            var z2 = z_text;
            while (z2[0] != 0) : (len += 1) skipUtf8(&z2);
        }
    }
    var p2: i64 = undefined;
    if (argv.len == 3) {
        p2 = api.valueInt64(argv[2]);
        if (p2 == 0 and api.valueType(argv[2]) == SQLITE_NULL) return;
    } else {
        p2 = largest_int64;
    }
    if (p1 == 0) {
        // Without SQLITE_SUBSTR_COMPATIBILITY, substr(X,0,N) is not
        // substr(X,1,N).
        if (api.valueType(argv[1]) == SQLITE_NULL) return;
    }
    if (p1 < 0) {
        p1 += len;
        if (p1 < 0) {
            if (p2 < 0) {
                p2 = 0;
            } else {
                p2 += p1;
            }
            p1 = 0;
        }
    } else if (p1 > 0) {
        p1 -= 1;
    } else if (p2 > 0) {
        p2 -= 1;
    }
    if (p2 < 0) {
        if (p2 < -p1) {
            p2 = p1;
        } else {
            p2 = -p2;
        }
        p1 -= p2;
    }
    std.debug.assert(p1 >= 0 and p2 >= 0);
    if (p0type != SQLITE_BLOB) {
        var z = z_text;
        while (p1 > 0) : (p1 -= 1) {
            // See tag-20260418-01.
            if (z[0] -% 1 < 0x80 - 1) {
                z += 1;
            } else if (z[0] == 0) {
                break;
            } else {
                z += 1;
                while (z[0] & 0xc0 == 0x80) z += 1;
            }
        }
        var z2 = z;
        while (p2 > 0) : (p2 -= 1) {
            if (z2[0] -% 1 < 0x80 - 1) {
                z2 += 1;
            } else if (z2[0] == 0) {
                break;
            } else {
                z2 += 1;
                while (z2[0] & 0xc0 == 0x80) z2 += 1;
            }
        }
        api.resultText64(ctx, z[0..ptrDiff(z2, z)], .transient);
    } else {
        if (p1 >= len) {
            p1 = 0;
            p2 = 0;
        } else if (p2 > len - p1) {
            p2 = len - p1;
        }
        const start: usize = @intCast(p1);
        api.resultBlob(ctx, z_blob[start .. start + @as(usize, @intCast(p2))], .transient);
    }
}

/// roundFunc(): round(X[, N]).
fn roundFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1 or argv.len == 2);
    var n: i64 = 0;
    if (argv.len == 2) {
        if (api.valueType(argv[1]) == SQLITE_NULL) return;
        n = api.valueInt64(argv[1]);
        if (n > 30) n = 30;
        if (n < 0) n = 0;
    }
    if (api.valueType(argv[0]) == SQLITE_NULL) return;
    var r = api.valueDouble(argv[0]);
    // With N==0 and X fitting in 64 bits, round directly; otherwise print
    // and parse back.
    if (r < -4503599627370496.0 or r > 4503599627370496.0) {
        // No fractional part: nothing to round.
    } else if (n == 0) {
        r = @floatFromInt(numeric.realToI64(r + (if (r < 0) @as(f64, -0.5) else 0.5)));
    } else {
        const gpa = api.contextDbHandle(ctx).gpa;
        const z = printf.mprintf(gpa, "%!.*f", &.{ .{ .int = n }, .{ .double = r } }) catch {
            api.resultErrorNomem(ctx);
            return;
        };
        defer gpa.free(z);
        _ = numeric.atoF(z.ptr, &r);
    }
    api.resultDouble(ctx, r);
}

/// upperFunc() and lowerFunc(): ASCII-only case conversion.
fn caseFunc(ctx: *Context, argv: []*Mem, comptime conv: fn (u8) u8) void {
    const z2 = api.valueText(argv[0]) orelse return;
    const n = z2.len;
    const z1 = contextMalloc(ctx, @as(i64, @intCast(n)) + 1) orelse return;
    for (z2, 0..) |c, i| z1[i] = conv(c);
    z1[n] = 0;
    api.resultTextZ(ctx, z1[0..n :0], .dynamic);
}

fn upperFunc(ctx: *Context, argv: []*Mem) void {
    caseFunc(ctx, argv, ctype.toUpper);
}

fn lowerFunc(ctx: *Context, argv: []*Mem) void {
    caseFunc(ctx, argv, ctype.toLower);
}

/// The PRNG shared by all connections (sqlite3Prng, global.prng):
/// ChaCha20 state and unused output, under a lock (C: the PRNG mutex).
pub const Prng = struct {
    s: [16]u32 = @splat(0),
    out: [64]u8 = undefined,
    n: u8 = 0,
    lock: std.atomic.Value(bool) = .init(false),
};

/// The quarter round of ChaCha20 (QR()).
fn chachaQr(x: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    x[a] +%= x[b];
    x[d] ^= x[a];
    x[d] = std.math.rotl(u32, x[d], 16);
    x[c] +%= x[d];
    x[b] ^= x[c];
    x[b] = std.math.rotl(u32, x[b], 12);
    x[a] +%= x[b];
    x[d] ^= x[a];
    x[d] = std.math.rotl(u32, x[d], 8);
    x[c] +%= x[d];
    x[b] ^= x[c];
    x[b] = std.math.rotl(u32, x[b], 7);
}

/// Port of chacha_block() (random.c): the RFC-7539 ChaCha20 block function.
fn chachaBlock(out: *[16]u32, in: *const [16]u32) void {
    var x = in.*;
    for (0..10) |_| {
        chachaQr(&x, 0, 4, 8, 12);
        chachaQr(&x, 1, 5, 9, 13);
        chachaQr(&x, 2, 6, 10, 14);
        chachaQr(&x, 3, 7, 11, 15);
        chachaQr(&x, 0, 5, 10, 15);
        chachaQr(&x, 1, 6, 11, 12);
        chachaQr(&x, 2, 7, 8, 13);
        chachaQr(&x, 3, 4, 9, 14);
    }
    for (0..16) |i| out[i] = x[i] +% in[i];
}

/// Port of sqlite3_randomness() (random.c): fill `buf` with
/// pseudo-random bytes. The generator is seeded on first use from the
/// connection's VFS (C uses the default VFS); an empty `buf` resets it.
pub fn randomness(db: ?*const Sqlite3, buf: []u8) void {
    const prng = &@import("global.zig").prng;
    while (prng.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer prng.lock.store(false, .release);
    if (buf.len == 0) {
        prng.s[0] = 0;
        return;
    }
    if (prng.s[0] == 0) {
        prng.s[0..4].* = .{ 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 };
        const seed = std.mem.sliceAsBytes(prng.s[4..15]);
        const fixed = @import("global.zig").testctrl.prng_seed;
        if (fixed != 0) {
            // sqlite3OsRandomness() with SQLITE_TESTCTRL_PRNG_SEED.
            @memset(seed, 0);
            @memcpy(seed[0..4], std.mem.asBytes(&fixed));
        } else if (db != null and db.?.vfs != null) {
            db.?.vfs.?.randomness(seed);
        } else {
            @memset(seed, 0);
        }
        prng.s[15] = prng.s[12];
        prng.s[12] = 0;
        prng.n = 0;
    }
    var z = buf;
    while (true) {
        if (z.len <= prng.n) {
            @memcpy(z, prng.out[prng.n - z.len .. prng.n]);
            prng.n -= @intCast(z.len);
            break;
        }
        if (prng.n > 0) {
            @memcpy(z[0..prng.n], prng.out[0..prng.n]);
            z = z[prng.n..];
        }
        prng.s[12] +%= 1;
        var block: [16]u32 = undefined;
        chachaBlock(&block, &prng.s);
        prng.out = @bitCast(block);
        prng.n = 64;
    }
}

/// randomFunc(): random(), never -9223372036854775808.
fn randomFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    var buf: [8]u8 = undefined;
    randomness(api.contextDbHandle(ctx), &buf);
    var r: i64 = @bitCast(std.mem.readInt(u64, &buf, builtin.cpu.arch.endian()));
    // Mask the sign bit off negative values and negate, so abs() of the
    // result never overflows.
    if (r < 0) r = -(r & largest_int64);
    api.resultInt64(ctx, r);
}

/// randomBlob(): randomblob(N).
fn randomBlob(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    var n = api.valueInt64(argv[0]);
    if (n < 1) n = 1;
    const p = contextMalloc(ctx, n) orelse return;
    randomness(api.contextDbHandle(ctx), p);
    api.resultBlob(ctx, p, .dynamic);
}

/// last_insert_rowid(): sqlite3_last_insert_rowid().
fn lastInsertRowid(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    api.resultInt64(ctx, api.contextDbHandle(ctx).last_rowid);
}

/// changes(): sqlite3_changes64().
fn changesFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    api.resultInt64(ctx, api.changes(api.contextDbHandle(ctx)));
}

/// total_changes(): sqlite3_total_changes64().
fn totalChangesFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    api.resultInt64(ctx, api.totalChanges(api.contextDbHandle(ctx)));
}

/// How GLOB or LIKE compares (struct compareInfo).
pub const CompareInfo = struct {
    /// "*" or "%".
    match_all: u8,
    /// "?" or "_".
    match_one: u8,
    /// "[" or 0.
    match_set: u8,
    /// Case-insensitive (ASCII only).
    no_case: bool,
};

const glob_info: CompareInfo = .{ .match_all = '*', .match_one = '?', .match_set = '[', .no_case = false };
/// SQL-92 LIKE ignores case: 'a' LIKE 'A' is true.
const like_info_norm: CompareInfo = .{ .match_all = '%', .match_one = '_', .match_set = 0, .no_case = true };
/// LIKE with PRAGMA case_sensitive_like=ON.
const like_info_alt: CompareInfo = .{ .match_all = '%', .match_one = '_', .match_set = 0, .no_case = false };

/// patternCompare() results.
const SQLITE_MATCH = 0;
const SQLITE_NOMATCH = 1;
const SQLITE_NOWILDCARDMATCH = 2;

/// Port of patternCompare(): match `string` against the GLOB or LIKE
/// pattern `pattern`. `match_other` is the LIKE escape character, or '['
/// for GLOB. Returns SQLITE_MATCH, SQLITE_NOMATCH or
/// SQLITE_NOWILDCARDMATCH (no match in spite of wildcards).
fn patternCompare(pattern: [*:0]const u8, string: [*:0]const u8, info: *const CompareInfo, match_other: u32) i32 {
    var z_pattern = pattern;
    var z_string = string;
    const match_one: u32 = info.match_one;
    const match_all: u32 = info.match_all;
    const no_case = info.no_case;
    // One past the last escaped pattern character.
    var z_escaped: ?[*:0]const u8 = null;

    while (true) {
        var c = utf8Read(&z_pattern);
        if (c == 0) break;
        if (c == match_all) {
            // Skip further "*"s, and "?"s each with one input character.
            while (true) {
                c = utf8Read(&z_pattern);
                if (!(c == match_all or (c == match_one and match_one != 0))) break;
                if (c == match_one and utf8Read(&z_string) == 0) return SQLITE_NOWILDCARDMATCH;
            }
            if (c == 0) return SQLITE_MATCH; // "*" at the end matches
            if (c == match_other) {
                if (info.match_set == 0) {
                    c = utf8Read(&z_pattern);
                    if (c == 0) return SQLITE_NOWILDCARDMATCH;
                } else {
                    // "[...]" right after "*": a slow recursive search.
                    std.debug.assert(match_other < 0x80);
                    while (z_string[0] != 0) {
                        const b = patternCompare(z_pattern - 1, z_string, info, match_other);
                        if (b != SQLITE_NOMATCH) return b;
                        skipUtf8(&z_string);
                    }
                    return SQLITE_NOWILDCARDMATCH;
                }
            }

            // c is the first pattern character after the "*": look for it
            // (in either case if case-insensitive) and recurse from there.
            if (c < 0x80) {
                var stop: [2]u8 = undefined;
                var n_stop: usize = 1;
                if (no_case) {
                    stop = .{ ctype.toUpper(@intCast(c)), ctype.toLower(@intCast(c)) };
                    n_stop = 2;
                } else {
                    stop[0] = @intCast(c);
                }
                while (true) {
                    // strcspn()
                    while (z_string[0] != 0 and std.mem.indexOfScalar(u8, stop[0..n_stop], z_string[0]) == null) z_string += 1;
                    if (z_string[0] == 0) break;
                    z_string += 1;
                    const b = patternCompare(z_pattern, z_string, info, match_other);
                    if (b != SQLITE_NOMATCH) return b;
                }
            } else {
                while (true) {
                    const c2 = utf8Read(&z_string);
                    if (c2 == 0) break;
                    if (c2 != c) continue;
                    const b = patternCompare(z_pattern, z_string, info, match_other);
                    if (b != SQLITE_NOMATCH) return b;
                }
            }
            return SQLITE_NOWILDCARDMATCH;
        }
        if (c == match_other) {
            if (info.match_set == 0) {
                c = utf8Read(&z_pattern);
                if (c == 0) return SQLITE_NOMATCH;
                z_escaped = z_pattern;
            } else {
                var prior_c: u32 = 0;
                var seen = false;
                var invert = false;
                c = utf8Read(&z_string);
                if (c == 0) return SQLITE_NOMATCH;
                var c2 = utf8Read(&z_pattern);
                if (c2 == '^') {
                    invert = true;
                    c2 = utf8Read(&z_pattern);
                }
                if (c2 == ']') {
                    if (c == ']') seen = true;
                    c2 = utf8Read(&z_pattern);
                }
                while (c2 != 0 and c2 != ']') {
                    if (c2 == '-' and z_pattern[0] != ']' and z_pattern[0] != 0 and prior_c > 0) {
                        c2 = utf8Read(&z_pattern);
                        if (c >= prior_c and c <= c2) seen = true;
                        prior_c = 0;
                    } else {
                        if (c == c2) seen = true;
                        prior_c = c2;
                    }
                    c2 = utf8Read(&z_pattern);
                }
                if (c2 == 0 or seen == invert) return SQLITE_NOMATCH;
                continue;
            }
        }
        const c2 = utf8Read(&z_string);
        if (c == c2) continue;
        if (no_case and c < 0x80 and c2 < 0x80 and ctype.toLower(@intCast(c)) == ctype.toLower(@intCast(c2))) continue;
        if (c == match_one and (z_escaped == null or z_pattern != z_escaped.?) and c2 != 0) continue;
        return SQLITE_NOMATCH;
    }
    return if (z_string[0] == 0) SQLITE_MATCH else SQLITE_NOMATCH;
}

/// Port of sqlite3_strglob(): 0 if `string` matches the GLOB `pattern`.
pub fn strglob(pattern: ?[*:0]const u8, string: ?[*:0]const u8) i32 {
    const s = string orelse return @intFromBool(pattern != null);
    const p = pattern orelse return 1;
    return patternCompare(p, s, &glob_info, '[');
}

/// Port of sqlite3_strlike(): 0 if `string` matches the LIKE `pattern`
/// with escape character `esc`.
pub fn strlike(pattern: ?[*:0]const u8, string: ?[*:0]const u8, esc: u32) i32 {
    const s = string orelse return @intFromBool(pattern != null);
    const p = pattern orelse return 1;
    return patternCompare(p, s, &like_info_norm, esc);
}

/// likeFunc(): like(PATTERN, STRING[, ESCAPE]), which implements
/// "STRING LIKE PATTERN"; with glob_info as user data, GLOB.
fn likeFunc(ctx: *Context, argv: []*Mem, user_info: *const CompareInfo) void {
    const db = api.contextDbHandle(ctx);
    var info = user_info;
    var backup_info: CompareInfo = undefined;

    // Limit the pattern length against deep recursion and N*N behavior.
    const n_pat = api.valueBytes(argv[0]);
    if (n_pat > db.limit(.like_pattern_length)) {
        api.resultError(ctx, "LIKE or GLOB pattern too complex");
        return;
    }
    var escape: u32 = undefined;
    if (argv.len == 3) {
        // The escape must be a single UTF-8 character.
        const z_esc = api.valueText(argv[2]) orelse return;
        if (utf8CharLen(z_esc.ptr, -1) != 1) {
            api.resultError(ctx, "ESCAPE expression must be a single character");
            return;
        }
        var pe: [*:0]const u8 = z_esc.ptr;
        escape = utf8Read(&pe);
        if (escape == info.match_all or escape == info.match_one) {
            backup_info = info.*;
            info = &backup_info;
            if (escape == backup_info.match_all) backup_info.match_all = 0;
            if (escape == backup_info.match_one) backup_info.match_one = 0;
        }
    } else {
        escape = info.match_set;
    }
    const z_b = api.valueText(argv[0]);
    const z_a = api.valueText(argv[1]);
    if (z_a != null and z_b != null) {
        api.resultInt(ctx, @intFromBool(patternCompare(z_b.?.ptr, z_a.?.ptr, info, escape) == SQLITE_MATCH));
    }
}

/// nullifFunc(): NULLIF(X, Y).
fn nullifFunc(ctx: *Context, argv: []*Mem) void {
    const coll = getFuncCollSeq(ctx);
    if (serial.memCompare(argv[0], argv[1], coll) != 0) api.resultValue(ctx, argv[0]);
}

/// versionFunc(): sqlite_version(). Also the never-called implementation
/// of the in-line functions (noopFunc).
fn versionFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    api.resultText(ctx, sqlite_version, .static);
}

const noopFunc = versionFunc;

/// sourceidFunc(): sqlite_source_id().
fn sourceidFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    api.resultText(ctx, sqlite_source_id, .static);
}

/// errlogFunc(): sqlite_log(CODE, MSG). There is no error log
/// (sqlite3_log()) yet, so it only evaluates its arguments.
fn errlogFunc(ctx: *Context, argv: []*Mem) void {
    _ = ctx;
    _ = api.valueInt(argv[0]);
    _ = api.valueText(argv[1]);
}

/// sqlite3CompileOptions() (ctime.c): the options of a default build.
const compile_options = [_][]const u8{
    "ATOMIC_INTRINSICS=1",
    "COMPILER=zig-" ++ builtin.zig_version_string,
    "SYSTEM_MALLOC",
    "THREADSAFE=1",
};

/// Port of sqlite3_compileoption_used() (main.c): whether option
/// `opt_name` (with or without "SQLITE_") was used.
pub fn compileoptionUsed(opt_name: []const u8) bool {
    var z = opt_name;
    if (z.len >= 7 and ctype.eqlNoCase(z[0..7], "SQLITE_")) z = z[7..];
    for (compile_options) |o| {
        if (o.len >= z.len and ctype.eqlNoCase(o[0..z.len], z) and
            (o.len == z.len or !ctype.isIdChar(o[z.len])))
        {
            return true;
        }
    }
    return false;
}

/// Port of sqlite3_compileoption_get() (main.c): option `n`, or null.
pub fn compileoptionGet(n: i32) ?[]const u8 {
    if (n >= 0 and n < compile_options.len) return compile_options[@intCast(n)];
    return null;
}

/// compileoptionusedFunc(): sqlite_compileoption_used(X).
fn compileoptionusedFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    if (api.valueText(argv[0])) |z| api.resultInt(ctx, @intFromBool(compileoptionUsed(std.mem.sliceTo(z, 0))));
}

/// compileoptiongetFunc(): sqlite_compileoption_get(N).
fn compileoptiongetFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const n = api.valueInt(argv[0]);
    if (compileoptionGet(n)) |z| api.resultText(ctx, z, .static) else api.resultNull(ctx);
}

/// Nybbles to upper-case hex digits.
const hexdigits = "0123456789ABCDEF";

/// Port of sqlite3QuoteValue(): append the SQL literal for `value` to the
/// empty `str`. With `escape`, control characters in text use unistr().
pub fn quoteValue(str: *printf.StrAccum, value: *Mem, escape: bool) void {
    std.debug.assert(str.n_char == 0);
    switch (api.valueType(value)) {
        SQLITE_FLOAT => {
            // "!" shows infinity as 9.0e+999; 17 digits round-trip.
            str.appendf("%!0.17g", &.{.{ .double = api.valueDouble(value) }});
        },
        SQLITE_INTEGER => str.appendf("%lld", &.{.{ .int = api.valueInt64(value) }}),
        SQLITE_BLOB => {
            const blob = api.valueBlob(value) orelse "";
            const n_blob = api.valueBytes(value);
            _ = str.enlarge(n_blob * 2 + 4);
            if (str.acc_error == 0) {
                const z = str.buf;
                for (0..n_blob) |i| {
                    z[i * 2 + 2] = hexdigits[(blob[i] >> 4) & 0x0F];
                    z[i * 2 + 3] = hexdigits[blob[i] & 0x0F];
                }
                z[n_blob * 2 + 2] = '\'';
                z[n_blob * 2 + 3] = 0;
                z[0] = 'X';
                z[1] = '\'';
                str.n_char = n_blob * 2 + 3;
            }
        },
        SQLITE_TEXT => {
            const z_arg = api.valueText(value);
            str.appendf(if (escape) "%#Q" else "%Q", &.{.{ .str = z_arg }});
        },
        else => str.append("NULL"),
    }
}

/// Port of isNHex(): the value of the `n` hex digits at `z`, or null if
/// any is not a hex digit.
fn isNHex(z: [*:0]const u8, n: usize) ?u32 {
    var v: u32 = 0;
    for (0..n) |i| {
        if (!ctype.isXdigit(z[i])) return null;
        v = (v << 4) + util.hexToInt(z[i]);
    }
    return v;
}

/// unistrFunc(): unistr(X), which decodes \XXXX, \+XXXXXX, \uXXXX,
/// \UXXXXXXXX and \\ as PostgreSQL does.
fn unistrFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const s = api.valueText(argv[0]) orelse return;
    const z_in: [*:0]const u8 = s.ptr;
    const n_in = s.len;
    const gpa = api.contextDbHandle(ctx).gpa;
    const z_out = gpa.alloc(u8, n_in + 1) catch return api.resultErrorNomem(ctx);
    var i: usize = 0;
    var j: usize = 0;
    const ok = while (i < n_in) {
        // strchr(&zIn[i], '\\')
        var k = i;
        while (z_in[k] != 0 and z_in[k] != '\\') k += 1;
        if (z_in[k] != '\\') {
            const n = n_in - i;
            @memcpy(z_out[j..][0..n], z_in[i..n_in]);
            j += n;
            break true;
        }
        const n = k - i;
        if (n > 0) {
            @memcpy(z_out[j..][0..n], z_in[i..k]);
            j += n;
            i += n;
        }
        var v: u32 = undefined;
        if (z_in[i + 1] == '\\') {
            i += 2;
            z_out[j] = '\\';
            j += 1;
            continue;
        } else if (ctype.isXdigit(z_in[i + 1])) {
            v = isNHex(z_in + i + 1, 4) orelse break false;
            i += 5;
        } else if (z_in[i + 1] == '+') {
            v = isNHex(z_in + i + 2, 6) orelse break false;
            i += 8;
        } else if (z_in[i + 1] == 'u') {
            v = isNHex(z_in + i + 2, 4) orelse break false;
            i += 6;
        } else if (z_in[i + 1] == 'U') {
            v = isNHex(z_in + i + 2, 8) orelse break false;
            i += 10;
        } else {
            break false;
        }
        j += printf.appendOneUtf8Character(z_out[j..], v);
    } else true;
    if (!ok) {
        gpa.free(z_out);
        api.resultError(ctx, "invalid Unicode escape");
        return;
    }
    resultOwnedText(ctx, z_out, j);
}

/// quoteFunc(): quote(X), the SQL literal for X. With user data,
/// unistr_quote(X), which escapes control characters with unistr().
fn quoteFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const db = api.contextDbHandle(ctx);
    var str = printf.StrAccum.init(db.gpa, &.{}, @intCast(db.limit(.length)));
    quoteValue(&str, argv[0], api.userData(ctx) != null);
    api.resultStr(ctx, &str, .xfer);
}

/// unicodeFunc(): unicode(X), the code point of the first character.
fn unicodeFunc(ctx: *Context, argv: []*Mem) void {
    const s = api.valueText(argv[0]) orelse return;
    var z: [*:0]const u8 = s.ptr;
    if (z[0] != 0) api.resultInt64(ctx, utf8Read(&z));
}

/// charFunc(): char(X1, ..., XN), the string of those code points.
fn charFunc(ctx: *Context, argv: []*Mem) void {
    const gpa = api.contextDbHandle(ctx).gpa;
    const z = gpa.alloc(u8, argv.len * 4 + 1) catch return api.resultErrorNomem(ctx);
    var n: usize = 0;
    for (argv) |a| {
        var x = api.valueInt64(a);
        if (x < 0 or x > 0x10ffff) x = 0xfffd;
        const c: u32 = @intCast(x & 0x1fffff);
        n += printf.appendOneUtf8Character(z[n..], c);
    }
    resultOwnedText(ctx, z, n);
}

/// hexFunc(): hex(X), the bytes of X as upper-case hex text.
fn hexFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const blob = api.valueBlob(argv[0]) orelse "";
    const n = api.valueBytes(argv[0]);
    const z_hex = contextMalloc(ctx, @as(i64, @intCast(n)) * 2 + 1) orelse return;
    for (0..n) |i| {
        const c = blob[i];
        z_hex[i * 2] = hexdigits[(c >> 4) & 0xf];
        z_hex[i * 2 + 1] = hexdigits[c & 0xf];
    }
    z_hex[n * 2] = 0;
    api.resultTextZ(ctx, z_hex[0 .. n * 2 :0], .dynamic);
}

/// Port of strContainsChar(): whether the UTF-8 text `z` has `ch`.
fn strContainsChar(z_str: [*:0]const u8, n_str: usize, ch: u32) bool {
    const end = @intFromPtr(z_str) + n_str;
    var z = z_str;
    while (@intFromPtr(z) < end) {
        if (utf8Read(&z) == ch) return true;
    }
    return false;
}

/// unhexFunc(): unhex(X[, Y]), the blob of the hex digit pairs in X.
/// Characters of Y may appear between pairs; anything else gives NULL.
fn unhexFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1 or argv.len == 2);
    var z_pass: ?[*:0]const u8 = "";
    var n_pass: usize = 0;
    const hex_text = api.valueText(argv[0]);
    const n_hex = api.valueBytes(argv[0]);
    if (argv.len == 2) {
        z_pass = if (api.valueText(argv[1])) |p| p.ptr else null;
        n_pass = api.valueBytes(argv[1]);
    }
    const hx = hex_text orelse return;
    const pass = z_pass orelse return;

    const blob = contextMalloc(ctx, @as(i64, @intCast(n_hex / 2)) + 1) orelse return api.resultNull(ctx);
    var z_hex: [*:0]const u8 = hx.ptr;
    var p: usize = 0;
    outer: while (true) {
        var c = z_hex[0]; // most significant digit of the next byte
        if (c == 0) break;
        while (!ctype.isXdigit(c)) {
            const ch = utf8Read(&z_hex);
            if (!strContainsChar(pass, n_pass, ch)) {
                sqlite3_malloc.free(blob);
                return;
            }
            c = z_hex[0];
            if (c == 0) break :outer;
        }
        z_hex += 1;
        const d = z_hex[0]; // least significant digit
        z_hex += 1;
        if (!ctype.isXdigit(d)) {
            sqlite3_malloc.free(blob);
            return;
        }
        blob[p] = (util.hexToInt(c) << 4) | util.hexToInt(d);
        p += 1;
    }
    resultOwnedBlob(ctx, blob, p);
}

/// zeroblobFunc(): zeroblob(N).
fn zeroblobFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    var n = api.valueInt64(argv[0]);
    if (n < 0) n = 0;
    const rc = api.resultZeroblob64(ctx, @intCast(n));
    if (rc != 0) api.resultErrorCode(ctx, rc);
}

/// replaceFunc(): replace(A, B, C), A with every B replaced by C. The
/// match is exact; collations are not used.
fn replaceFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 3);
    const db = api.contextDbHandle(ctx);
    const z_str = api.valueText(argv[0]) orelse return;
    const n_str: i64 = @intCast(z_str.len);
    const z_pattern = api.valueText(argv[1]) orelse return;
    if (z_pattern.ptr[0] == 0) {
        api.resultText(ctx, z_str, .transient);
        return;
    }
    const n_pattern: i64 = @intCast(z_pattern.len);
    const z_rep = api.valueText(argv[2]) orelse return;
    const n_rep: i64 = @intCast(z_rep.len);
    var n_out: i64 = n_str + 1;
    var z_out = contextMalloc(ctx, n_out) orelse return;
    const loop_limit = n_str - n_pattern;
    var cnt_expand: u32 = 0;
    var i: i64 = 0;
    var j: usize = 0;
    while (i <= loop_limit) : (i += 1) {
        const at: usize = @intCast(i);
        if (z_str[at] != z_pattern[0] or !std.mem.eql(u8, z_str[at..][0..@intCast(n_pattern)], z_pattern)) {
            z_out[j] = z_str[at];
            j += 1;
        } else {
            if (n_rep > n_pattern) {
                n_out += n_rep - n_pattern;
                if (n_out - 1 > db.limit(.length)) {
                    api.resultErrorTooBig(ctx);
                    sqlite3_malloc.free(z_out);
                    return;
                }
                cnt_expand += 1;
                if (cnt_expand & (cnt_expand - 1) == 0) {
                    // Grow only on substitutions 1, 2, 4, 8, ...
                    z_out = sqlite3_malloc.realloc(z_out, @intCast(n_out + (n_out - n_str - 1))) catch {
                        api.resultErrorNomem(ctx);
                        sqlite3_malloc.free(z_out);
                        return;
                    };
                }
            }
            @memcpy(z_out[j..][0..z_rep.len], z_rep);
            j += z_rep.len;
            i += n_pattern - 1;
        }
    }
    const tail: usize = @intCast(n_str - i);
    @memcpy(z_out[j..][0..tail], z_str[@intCast(i)..]);
    j += tail;
    resultOwnedText(ctx, z_out, j);
}

/// trimFunc(): trim(), ltrim() and rtrim(), with an optional set of
/// characters (default " "). User data: 1 left, 2 right, 3 both.
fn trimFunc(ctx: *Context, argv: []*Mem) void {
    if (api.valueType(argv[0]) == SQLITE_NULL) return;
    const s = api.valueText(argv[0]) orelse return;
    var z_in: [*]const u8 = s.ptr;
    var n_in: usize = s.len;
    const db = api.contextDbHandle(ctx);
    var az_char: []const []const u8 = &.{" "};
    var allocated: ?[][]const u8 = null;
    defer if (allocated) |a| sqlite3_malloc.free(a);
    if (argv.len != 1) {
        const char_set = api.valueText(argv[1]) orelse return;
        var n_char: usize = 0;
        var z: [*:0]const u8 = char_set.ptr;
        while (z[0] != 0) : (n_char += 1) skipUtf8(&z);
        az_char = &.{};
        if (n_char > 0) {
            // contextMalloc() of the pointer and length arrays.
            if (@as(i64, @intCast(n_char * (@sizeOf(usize) + @sizeOf(u32)))) > db.limit(.length)) {
                api.resultErrorTooBig(ctx);
                return;
            }
            const a = sqlite3_malloc.alloc([]const u8, n_char) catch return api.resultErrorNomem(ctx);
            allocated = a;
            z = char_set.ptr;
            for (a) |*ch| {
                const start = z;
                skipUtf8(&z);
                ch.* = start[0..ptrDiff(z, start)];
            }
            az_char = a;
        }
    }
    if (az_char.len > 0) {
        const flags = ptrToInt(api.userData(ctx));
        if (flags & 1 != 0) {
            while (n_in > 0) {
                var len: usize = 0;
                const found = for (az_char) |ch| {
                    len = ch.len;
                    if (len <= n_in and std.mem.eql(u8, z_in[0..len], ch)) break true;
                } else false;
                if (!found) break;
                z_in += len;
                n_in -= len;
            }
        }
        if (flags & 2 != 0) {
            while (n_in > 0) {
                var len: usize = 0;
                const found = for (az_char) |ch| {
                    len = ch.len;
                    if (len <= n_in and std.mem.eql(u8, z_in[n_in - len .. n_in], ch)) break true;
                } else false;
                if (!found) break;
                n_in -= len;
            }
        }
    }
    api.resultText(ctx, z_in[0..n_in], .transient);
}

/// Port of concatFuncCore(): the non-NULL arguments joined by `sep`.
fn concatFuncCore(ctx: *Context, argv: []*Mem, sep: []const u8) void {
    var n: usize = 0;
    for (argv) |a| n += api.valueBytes(a);
    if (argv.len > 0) n += (argv.len - 1) * sep.len;
    const gpa = api.contextDbHandle(ctx).gpa;
    const z = gpa.alloc(u8, n + 1) catch return api.resultErrorNomem(ctx);
    var j: usize = 0;
    var not_null = false;
    for (argv) |a| {
        if (api.valueType(a) != SQLITE_NULL) {
            const k = api.valueBytes(a);
            if (api.valueText(a)) |v| {
                if (not_null and sep.len > 0) {
                    @memcpy(z[j..][0..sep.len], sep);
                    j += sep.len;
                }
                @memcpy(z[j..][0..k], v[0..k]);
                j += k;
                not_null = true;
            }
        }
    }
    std.debug.assert(j <= n);
    resultOwnedText(ctx, z, j);
}

/// concatFunc(): concat(...).
fn concatFunc(ctx: *Context, argv: []*Mem) void {
    concatFuncCore(ctx, argv, "");
}

/// concatwsFunc(): concat_ws(SEP, ...); NULL if SEP is NULL.
fn concatwsFunc(ctx: *Context, argv: []*Mem) void {
    const sep = api.valueText(argv[0]) orelse return;
    concatFuncCore(ctx, argv[1..], sep);
}

/// loadExt(): load_extension(X[, Y]). Extensions cannot be loaded, so
/// once allowed it fails as sqlite3_load_extension() of a build without
/// a dynamic loader does.
fn loadExt(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    // Only with SQLITE_LoadExtFunc (sqlite3_enable_load_extension()).
    if (!db.flags.LoadExtFunc) {
        api.resultError(ctx, "not authorized");
        return;
    }
    if (api.valueText(argv[0]) != null) api.resultError(ctx, "extension loading is not supported");
}

/// signFunc(): sign(X): -1, 0 or +1, NULL if X is not a number.
fn signFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const type0 = api.valueNumericType(argv[0]);
    if (type0 != SQLITE_INTEGER and type0 != SQLITE_FLOAT) return;
    const x = api.valueDouble(argv[0]);
    api.resultInt(ctx, if (x < 0.0) -1 else if (x > 0.0) 1 else 0);
}

// ============================================================ aggregates

/// The state of sum(), total() and avg() (SumCtx).
const SumCtx = struct {
    /// Running sum as a double.
    r_sum: f64,
    /// Error term of the Kahan-Babuska-Neumaier summation.
    r_err: f64,
    /// Running sum as an integer.
    i_sum: i64,
    /// Number of elements summed.
    cnt: i64,
    /// A non-integer value was summed.
    approx: bool,
    /// Integer overflow seen.
    ovrfl: bool,
};

/// Port of kahanBabuskaNeumaierStep().
fn kbnStep(p: *SumCtx, r: f64) void {
    const s = p.r_sum;
    const t = s + r;
    if (@abs(s) > @abs(r)) {
        p.r_err += (s - t) + r;
    } else {
        p.r_err += (r - t) + s;
    }
    p.r_sum = t;
}

/// Port of kahanBabuskaNeumaierStepInt64(): add a (maybe large) integer.
fn kbnStepInt64(p: *SumCtx, i_val: i64) void {
    if (i_val <= -4503599627370496 or i_val >= 4503599627370496) {
        const i_sm = @rem(i_val, 16384);
        const i_big = i_val - i_sm;
        kbnStep(p, @floatFromInt(i_big));
        kbnStep(p, @floatFromInt(i_sm));
    } else {
        kbnStep(p, @floatFromInt(i_val));
    }
}

/// Port of kahanBabuskaNeumaierInit(): start the sum from an integer.
fn kbnInit(p: *SumCtx, i_val: i64) void {
    if (i_val <= -4503599627370496 or i_val >= 4503599627370496) {
        const i_sm = @rem(i_val, 16384);
        p.r_sum = @floatFromInt(i_val - i_sm);
        p.r_err = @floatFromInt(i_sm);
    } else {
        p.r_sum = @floatFromInt(i_val);
        p.r_err = 0.0;
    }
}

/// sumStep(): the step of sum(), total() and avg(). sum() follows the SQL
/// standard (NULL over no rows, an error on integer overflow); total()
/// is always a float.
fn sumStep(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const p = aggContext(SumCtx, ctx, true);
    const t = api.valueNumericType(argv[0]);
    const s = p orelse return;
    if (t == SQLITE_NULL) return;
    s.cnt += 1;
    if (!s.approx) {
        if (t != SQLITE_INTEGER) {
            kbnInit(s, s.i_sum);
            s.approx = true;
            kbnStep(s, api.valueDouble(argv[0]));
        } else {
            const r = @addWithOverflow(s.i_sum, api.valueInt64(argv[0]));
            if (r[1] == 0) {
                s.i_sum = r[0];
            } else {
                s.ovrfl = true;
                kbnInit(s, s.i_sum);
                s.approx = true;
                kbnStepInt64(s, api.valueInt64(argv[0]));
            }
        }
    } else {
        if (t == SQLITE_INTEGER) {
            kbnStepInt64(s, api.valueInt64(argv[0]));
        } else {
            s.ovrfl = false;
            kbnStep(s, api.valueDouble(argv[0]));
        }
    }
}

/// sumInverse(): remove a value from a window of sum(), total() or avg().
fn sumInverse(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1);
    const p = aggContext(SumCtx, ctx, true);
    const t = api.valueNumericType(argv[0]);
    // sumStep() always ran first.
    const s = p orelse return;
    if (t == SQLITE_NULL) return;
    std.debug.assert(s.cnt > 0);
    s.cnt -= 1;
    if (!s.approx) {
        const r = @subWithOverflow(s.i_sum, api.valueInt64(argv[0]));
        if (r[1] == 0) {
            s.i_sum = r[0];
            return;
        }
        s.ovrfl = true;
        s.approx = true;
        kbnInit(s, s.i_sum);
    }
    if (t == SQLITE_INTEGER) {
        const i_val = api.valueInt64(argv[0]);
        if (i_val != smallest_int64) {
            kbnStepInt64(s, -i_val);
        } else {
            kbnStepInt64(s, largest_int64);
            kbnStepInt64(s, 1);
        }
    } else {
        kbnStep(s, -api.valueDouble(argv[0]));
    }
}

/// sumFinalize(): sum().
fn sumFinalize(ctx: *Context) void {
    const s = aggContext(SumCtx, ctx, false) orelse return;
    if (s.cnt <= 0) return;
    if (s.approx) {
        if (s.ovrfl) {
            api.resultError(ctx, "integer overflow");
        } else if (!numeric.isOverflow(s.r_err)) {
            api.resultDouble(ctx, s.r_sum + s.r_err);
        } else {
            api.resultDouble(ctx, s.r_sum);
        }
    } else {
        api.resultInt64(ctx, s.i_sum);
    }
}

/// avgFinalize(): avg().
fn avgFinalize(ctx: *Context) void {
    const s = aggContext(SumCtx, ctx, false) orelse return;
    if (s.cnt <= 0) return;
    var r: f64 = undefined;
    if (s.approx) {
        r = s.r_sum;
        if (!numeric.isOverflow(s.r_err)) r += s.r_err;
    } else {
        r = @floatFromInt(s.i_sum);
    }
    api.resultDouble(ctx, r / @as(f64, @floatFromInt(s.cnt)));
}

/// totalFinalize(): total().
fn totalFinalize(ctx: *Context) void {
    var r: f64 = 0.0;
    if (aggContext(SumCtx, ctx, false)) |s| {
        if (s.approx) {
            r = s.r_sum;
            if (!numeric.isOverflow(s.r_err)) r += s.r_err;
        } else {
            r = @floatFromInt(s.i_sum);
        }
    }
    api.resultDouble(ctx, r);
}

/// The state of count() (CountCtx).
const CountCtx = struct { n: i64 };

/// countStep(): count(*) and count(X).
fn countStep(ctx: *Context, argv: []*Mem) void {
    const p = aggContext(CountCtx, ctx, true);
    if ((argv.len == 0 or api.valueType(argv[0]) != SQLITE_NULL) and p != null) p.?.n += 1;
}

fn countFinalize(ctx: *Context) void {
    const p = aggContext(CountCtx, ctx, false);
    api.resultInt64(ctx, if (p) |c| c.n else 0);
}

fn countInverse(ctx: *Context, argv: []*Mem) void {
    const p = aggContext(CountCtx, ctx, true);
    // countStep() always ran first.
    if ((argv.len == 0 or api.valueType(argv[0]) != SQLITE_NULL) and p != null) p.?.n -= 1;
}

/// The state of the min() and max() aggregates: the best value so far.
/// `init` stands for the C test of pBest->flags.
const MinMaxCtx = struct {
    init: bool,
    best: Mem,
};

/// minmaxStep(): the step of the min() and max() aggregates; user data
/// is non-null for max().
fn minmaxStep(ctx: *Context, argv: []*Mem) void {
    const arg = argv[0];
    const p = aggContext(MinMaxCtx, ctx, true) orelse return;
    const db = api.contextDbHandle(ctx);
    if (api.valueType(arg) == SQLITE_NULL) {
        if (p.init) skipAccumulatorLoad(ctx);
    } else if (p.init) {
        const max = api.userData(ctx) != null;
        const cmp = serial.memCompare(&p.best, arg, getFuncCollSeq(ctx));
        if ((max and cmp < 0) or (!max and cmp > 0)) {
            mem.copy(&p.best, arg) catch {
                db.oomFault();
            };
        } else {
            skipAccumulatorLoad(ctx);
        }
    } else {
        p.init = true;
        p.best = .{ .db = db };
        mem.copy(&p.best, arg) catch {
            db.oomFault();
        };
    }
}

/// minMaxValueFinalize(): the result of min() or max(); the value is
/// freed unless this is xValue.
fn minMaxValueFinalize(ctx: *Context, b_value: bool) void {
    const p = aggContext(MinMaxCtx, ctx, false) orelse return;
    if (!p.init) return;
    if (!p.best.flags.isEmpty()) api.resultValue(ctx, &p.best);
    if (!b_value) mem.release(&p.best);
}

fn minMaxValue(ctx: *Context) void {
    minMaxValueFinalize(ctx, true);
}

fn minMaxFinalize(ctx: *Context) void {
    minMaxValueFinalize(ctx, false);
}

/// The state of group_concat(EXPR[, SEP]) and string_agg(EXPR, SEP)
/// (GroupConcatCtx). The separator goes before each value but the first.
/// `init` is set once `str` is initialized.
const GroupConcatCtx = struct {
    init: bool,
    str: printf.StrAccum,
    /// Number of strings presently concatenated.
    n_accum: i32,
    /// Used to detect a change of the separator length.
    n_first_sep_length: i32,
    /// If not null, the lengths of the separators as incorporated into
    /// the result (n_accum-1 in use between calls); otherwise
    /// n_first_sep_length is the length throughout.
    sep_lengths: ?[]i32,
};

fn groupConcatInit(g: *GroupConcatCtx) void {
    if (g.init) return;
    g.* = .{
        .init = true,
        // pGCC->str.db is 0: sqlite3_malloc() memory.
        .str = printf.StrAccum.init(sqlite3_malloc, &.{}, 0),
        .n_accum = 0,
        .n_first_sep_length = 0,
        .sep_lengths = null,
    };
}

/// groupConcatStep().
fn groupConcatStep(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1 or argv.len == 2);
    if (api.valueType(argv[0]) == SQLITE_NULL) return;
    const g = aggContext(GroupConcatCtx, ctx, true) orelse return;
    const db = api.contextDbHandle(ctx);
    groupConcatInit(g);
    const first_term = g.str.mx_alloc == 0;
    g.str.mx_alloc = @intCast(db.limit(.length));
    if (argv.len == 1) {
        if (!first_term) {
            g.str.appendChar(1, ',');
        } else {
            g.n_first_sep_length = 1;
        }
    } else if (!first_term) {
        var n_sep: i32 = 0;
        if (api.valueText(argv[1])) |sep| {
            g.str.append(sep);
            n_sep = @intCast(sep.len);
        }
        if (n_sep != g.n_first_sep_length or g.sep_lengths != null) {
            const n_accum: usize = @intCast(g.n_accum);
            var pnsl: ?[]i32 = null;
            if (g.sep_lengths) |old| {
                pnsl = db.gpa.realloc(old, n_accum) catch null;
            } else {
                // First variation of the separator length: start tracking.
                pnsl = db.gpa.alloc(i32, n_accum + 1) catch null;
                if (pnsl) |a| {
                    if (n_accum > 1) @memset(a[0 .. n_accum - 1], g.n_first_sep_length);
                }
            }
            if (pnsl) |a| {
                if (n_accum > 0) a[n_accum - 1] = n_sep;
                g.sep_lengths = a;
            } else {
                g.str.setError(printf.NOMEM);
            }
        }
    } else {
        g.n_first_sep_length = @intCast(api.valueBytes(argv[1]));
    }
    g.n_accum += 1;
    if (api.valueText(argv[0])) |v| g.str.append(v);
}

/// groupConcatInverse(): remove the oldest value (and its separator).
fn groupConcatInverse(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1 or argv.len == 2);
    if (api.valueType(argv[0]) == SQLITE_NULL) return;
    // groupConcatStep() always ran first.
    const g = aggContext(GroupConcatCtx, ctx, true) orelse return;
    const db = api.contextDbHandle(ctx);
    groupConcatInit(g);
    // value_text() first so value_bytes() counts the text.
    _ = api.valueText(argv[0]);
    var n_vs: usize = api.valueBytes(argv[0]);
    g.n_accum -= 1;
    if (g.sep_lengths) |sl| {
        std.debug.assert(g.n_accum >= 0);
        if (g.n_accum > 0) {
            const n: usize = @intCast(g.n_accum);
            n_vs += @intCast(sl[0]);
            std.mem.copyForwards(i32, sl[0 .. n - 1], sl[1..n]);
        }
    } else {
        // Removing the only string harmlessly over-does it.
        n_vs += @intCast(g.n_first_sep_length);
    }
    if (n_vs >= g.str.n_char) {
        g.str.n_char = 0;
    } else {
        g.str.n_char -= n_vs;
        std.mem.copyForwards(u8, g.str.buf[0..g.str.n_char], g.str.buf[n_vs..][0..g.str.n_char]);
    }
    if (g.str.n_char == 0) {
        g.str.mx_alloc = 0;
        if (g.sep_lengths) |sl| db.gpa.free(sl);
        g.sep_lengths = null;
    }
}

fn groupConcatFinalize(ctx: *Context) void {
    const g = aggContext(GroupConcatCtx, ctx, false) orelse return;
    if (!g.init) return;
    api.resultStr(ctx, &g.str, .xfer);
    if (g.sep_lengths) |sl| api.contextDbHandle(ctx).gpa.free(sl);
    g.sep_lengths = null;
}

fn groupConcatValue(ctx: *Context) void {
    const g = aggContext(GroupConcatCtx, ctx, false) orelse return;
    if (g.init and g.n_accum > 0) api.resultStr(ctx, &g.str, .copy);
}

// ========================================================= registration

/// Port of sqlite3RegisterPerConnectionBuiltinFunctions(): the functions
/// every connection has that are not global (MATCH, for virtual tables).
pub fn registerPerConnectionBuiltinFunctions(db: *Sqlite3) void {
    const rc = callback.overloadFunction(db, "MATCH", 2);
    std.debug.assert(rc == RC.NOMEM or rc == RC.OK);
    if (rc == RC.NOMEM) db.oomFault();
}

/// Port of sqlite3RegisterLikeFunctions(): re-register like() as case
/// sensitive or not (PRAGMA case_sensitive_like).
pub fn registerLikeFunctions(db: *Sqlite3, case_sensitive: bool) void {
    const info: *const CompareInfo = if (case_sensitive) &like_info_alt else &like_info_norm;
    const like_flags: FUNC = .{ .LIKE = true, .CASE = case_sensitive };
    var n_arg: i32 = 2;
    while (n_arg <= 3) : (n_arg += 1) {
        if (callback.createFunc(db, "like", n_arg, ENC.UTF8, .{}, FuncDef.userDataFor(likeFunc, info), FuncDef.withUserData(likeFunc), null, null, null, null, null) != RC.OK) return;
        // The function just made, an exact match (C finds it with
        // sqlite3FindFunction() without createFlag; built-ins are
        // read-only here).
        const def = callback.findFunction(db, "like", n_arg, ENC.UTF8, true).?;
        def.func_flags.set(like_flags);
        def.func_flags.UNSAFE = false;
    }
}

/// Port of sqlite3IsLikeFunction(): if `e` (a TK_FUNCTION) calls a
/// LIKE-style function the LIKE optimization can use, set `wc` to its
/// wildcards "%", "_", "[" and escape character (0 if none) and
/// `is_nocase`, and return true.
pub fn isLikeFunction(db: *Sqlite3, e: *Expr, is_nocase: *bool, wc: *[4]u8) bool {
    std.debug.assert(e.op == int.TK.FUNCTION);
    std.debug.assert(e.useXList());
    const list = e.x.list orelse return false;
    const n_expr = list.len();
    const def = callback.findFunction(db, e.token(), @intCast(n_expr), ENC.UTF8, false) orelse return false;
    if (!def.func_flags.LIKE) return false;

    const info = def.userDataOf(likeFunc);
    wc[0] = info.match_all;
    wc[1] = info.match_one;
    wc[2] = info.match_set;
    if (n_expr < 3) {
        wc[3] = 0;
    } else {
        const escape = list.at(2).expr.?;
        if (escape.op != int.TK.STRING) return false;
        const z = escape.token();
        if (z.len == 0 or z[0] == 0 or z[1] != 0) return false;
        if (z[0] == wc[0] or z[0] == wc[1]) return false;
        wc[3] = z[0];
    }
    is_nocase.* = !def.func_flags.CASE;
    return true;
}

/// FUNCTION(): a deterministic scalar function; `bnc` sets
/// FUNC.NEEDCOLL.
fn function(name: [:0]const u8, n_arg: i16, i_arg: usize, bnc: u1, x: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = .{ .enc = ENC.UTF8, .BUILTIN = true, .CONSTANT = true, .NEEDCOLL = bnc != 0 },
        .user_data = intToPtr(i_arg),
        .x_sfunc = x,
        .name = name,
    };
}

/// VFUNCTION(): a scalar function that is not deterministic.
fn vfunction(name: [:0]const u8, n_arg: i16, i_arg: usize, bnc: u1, x: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = .{ .enc = ENC.UTF8, .BUILTIN = true, .NEEDCOLL = bnc != 0 },
        .user_data = intToPtr(i_arg),
        .x_sfunc = x,
        .name = name,
    };
}

/// SFUNCTION(): a direct-only function with side effects.
fn sfunction(name: [:0]const u8, n_arg: i16, i_arg: usize, x: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        // SQLITE_DIRECTONLY is SQLITE_FUNC_DIRECT.
        .func_flags = .{ .enc = ENC.UTF8, .BUILTIN = true, .DIRECT = true, .UNSAFE = true },
        .user_data = intToPtr(i_arg),
        .x_sfunc = x,
        .name = name,
    };
}

/// DFUNCTION(): constant during one statement (FUNC.SLOCHNG).
pub fn dfunction(name: [:0]const u8, n_arg: i16, x: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = .{ .enc = ENC.UTF8, .BUILTIN = true, .SLOCHNG = true },
        .x_sfunc = x,
        .name = name,
    };
}

/// FUNCTION2(): FUNCTION() with extra flags.
fn function2(name: [:0]const u8, n_arg: i16, i_arg: usize, bnc: u1, x: FuncDef.StepFn, extra: FUNC) FuncDef {
    var f = function(name, n_arg, i_arg, bnc, x);
    f.func_flags.set(extra);
    return f;
}

/// INLINE_FUNC(): coded in-line by the code generator; user data is the
/// INLINEFUNC_* number.
fn inlineFunc(name: [:0]const u8, n_arg: i16, i_arg: usize, m_flags: FUNC) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = m_flags.with(.{ .enc = ENC.UTF8, .BUILTIN = true, .INLINE = true, .CONSTANT = true }),
        .user_data = intToPtr(i_arg),
        .x_sfunc = noopFunc,
        .name = name,
    };
}

/// TEST_FUNC(): an in-line function for SQLITE_TESTCTRL_INTERNAL_FUNCTIONS.
fn testFunc(name: [:0]const u8, n_arg: i16, i_arg: usize, m_flags: FUNC) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = m_flags.with(.{ .enc = ENC.UTF8, .BUILTIN = true, .INTERNAL = true, .TEST = true, .INLINE = true, .CONSTANT = true }),
        .user_data = intToPtr(i_arg),
        .x_sfunc = noopFunc,
        .name = name,
    };
}

/// LIKEFUNC(): like() or glob() with its CompareInfo.
fn likeFuncDef(name: [:0]const u8, n_arg: i16, info: *const CompareInfo, like_flags: FUNC) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = like_flags.with(.{ .enc = ENC.UTF8, .BUILTIN = true, .CONSTANT = true }),
        .user_data = FuncDef.userDataFor(likeFunc, info),
        .x_sfunc = FuncDef.withUserData(likeFunc),
        .name = name,
    };
}

/// WAGGREGATE(): an aggregate, usable as a window function if it has
/// `value` and `inverse`.
fn waggregate(
    name: [:0]const u8,
    n_arg: i16,
    arg: usize,
    nc: u1,
    step: FuncDef.StepFn,
    final: FuncDef.FinalFn,
    value: ?FuncDef.FinalFn,
    inverse: ?FuncDef.StepFn,
    f: FUNC,
) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = f.with(.{ .enc = ENC.UTF8, .BUILTIN = true, .NEEDCOLL = nc != 0 }),
        .user_data = intToPtr(arg),
        .x_sfunc = step,
        .x_finalize = final,
        .x_value = value,
        .x_inverse = inverse,
        .name = name,
    };
}

/// aBuiltinFunc[] of sqlite3RegisterBuiltinFunctions(): the functions of
/// this file, in callback.builtins.
pub const funcs = [_]FuncDef{
    // Only with SQLITE_TESTCTRL_INTERNAL_FUNCTIONS.
    testFunc("implies_nonnull_row", 2, INLINEFUNC_implies_nonnull_row, .{}),
    testFunc("expr_compare", 2, INLINEFUNC_expr_compare, .{}),
    testFunc("expr_implies_expr", 2, INLINEFUNC_expr_implies_expr, .{}),
    testFunc("affinity", 1, INLINEFUNC_affinity, .{}),
    // Regular functions.
    sfunction("load_extension", 1, 0, loadExt),
    sfunction("load_extension", 2, 0, loadExt),
    dfunction("sqlite_compileoption_used", 1, compileoptionusedFunc),
    dfunction("sqlite_compileoption_get", 1, compileoptiongetFunc),
    inlineFunc("unlikely", 1, INLINEFUNC_unlikely, .{ .UNLIKELY = true }),
    inlineFunc("likelihood", 2, INLINEFUNC_unlikely, .{ .UNLIKELY = true }),
    inlineFunc("likely", 1, INLINEFUNC_unlikely, .{ .UNLIKELY = true }),
    function("ltrim", 1, 1, 0, trimFunc),
    function("ltrim", 2, 1, 0, trimFunc),
    function("rtrim", 1, 2, 0, trimFunc),
    function("rtrim", 2, 2, 0, trimFunc),
    function("trim", 1, 3, 0, trimFunc),
    function("trim", 2, 3, 0, trimFunc),
    function("min", -3, 0, 1, minmaxFunc),
    waggregate("min", 1, 0, 1, minmaxStep, minMaxFinalize, minMaxValue, null, .{ .MINMAX = true, .ANYORDER = true }),
    function("max", -3, 1, 1, minmaxFunc),
    waggregate("max", 1, 1, 1, minmaxStep, minMaxFinalize, minMaxValue, null, .{ .MINMAX = true, .ANYORDER = true }),
    function2("typeof", 1, 0, 0, typeofFunc, .{ .TYPEOF = true }),
    function2("subtype", 1, 0, 0, subtypeFunc, .{ .TYPEOF = true, .SUBTYPE = true }),
    function2("length", 1, 0, 0, lengthFunc, .{ .LENGTH = true }),
    function2("octet_length", 1, 0, 0, bytelengthFunc, FUNC.BYTELEN),
    function("instr", 2, 0, 0, instrFunc),
    function("printf", -1, 0, 0, printfFunc),
    function("format", -1, 0, 0, printfFunc),
    function("unicode", 1, 0, 0, unicodeFunc),
    function("char", -1, 0, 0, charFunc),
    function("abs", 1, 0, 0, absFunc),
    function("round", 1, 0, 0, roundFunc),
    function("round", 2, 0, 0, roundFunc),
    function("upper", 1, 0, 0, upperFunc),
    function("lower", 1, 0, 0, lowerFunc),
    function("hex", 1, 0, 0, hexFunc),
    function("unhex", 1, 0, 0, unhexFunc),
    function("unhex", 2, 0, 0, unhexFunc),
    function("concat", -3, 0, 0, concatFunc),
    function("concat_ws", -4, 0, 0, concatwsFunc),
    inlineFunc("ifnull", 2, INLINEFUNC_coalesce, .{}),
    vfunction("random", 0, 0, 0, randomFunc),
    vfunction("randomblob", 1, 0, 0, randomBlob),
    function("nullif", 2, 0, 1, nullifFunc),
    dfunction("sqlite_version", 0, versionFunc),
    dfunction("sqlite_source_id", 0, sourceidFunc),
    sfunction("sqlite_log", 2, 0, errlogFunc),
    function("unistr", 1, 0, 0, unistrFunc),
    function("quote", 1, 0, 0, quoteFunc),
    function("unistr_quote", 1, 1, 0, quoteFunc),
    vfunction("last_insert_rowid", 0, 0, 0, lastInsertRowid),
    vfunction("changes", 0, 0, 0, changesFunc),
    vfunction("total_changes", 0, 0, 0, totalChangesFunc),
    function("replace", 3, 0, 0, replaceFunc),
    function("zeroblob", 1, 0, 0, zeroblobFunc),
    function("substr", 2, 0, 0, substrFunc),
    function("substr", 3, 0, 0, substrFunc),
    function("substring", 2, 0, 0, substrFunc),
    function("substring", 3, 0, 0, substrFunc),
    waggregate("sum", 1, 0, 0, sumStep, sumFinalize, sumFinalize, sumInverse, .{}),
    waggregate("total", 1, 0, 0, sumStep, totalFinalize, totalFinalize, sumInverse, .{}),
    waggregate("avg", 1, 0, 0, sumStep, avgFinalize, avgFinalize, sumInverse, .{}),
    waggregate("count", 0, 0, 0, countStep, countFinalize, countFinalize, countInverse, .{ .COUNT = true, .ANYORDER = true }),
    waggregate("count", 1, 0, 0, countStep, countFinalize, countFinalize, countInverse, .{ .ANYORDER = true }),
    waggregate("group_concat", 1, 0, 0, groupConcatStep, groupConcatFinalize, groupConcatValue, groupConcatInverse, .{}),
    waggregate("group_concat", 2, 0, 0, groupConcatStep, groupConcatFinalize, groupConcatValue, groupConcatInverse, .{}),
    waggregate("string_agg", 2, 0, 0, groupConcatStep, groupConcatFinalize, groupConcatValue, groupConcatInverse, .{}),
    likeFuncDef("glob", 2, &glob_info, .{ .LIKE = true, .CASE = true }),
    likeFuncDef("like", 2, &like_info_norm, .{ .LIKE = true }),
    likeFuncDef("like", 3, &like_info_norm, .{ .LIKE = true }),
    function("sign", 1, 0, 0, signFunc),
    inlineFunc("coalesce", -4, INLINEFUNC_coalesce, .{}),
    inlineFunc("iif", -4, INLINEFUNC_iif, .{}),
    inlineFunc("if", -4, INLINEFUNC_iif, .{}),
};

// ================================================================== tests

const testing = std.testing;

fn testDb(db: *Sqlite3) void {
    db.* = .{ .gpa = @import("malloc.zig").dbAllocator(db) };
}

fn tInt(db: *Sqlite3, v: i64) Mem {
    var m: Mem = .{ .db = db };
    mem.setInt64(&m, v);
    return m;
}

fn tReal(db: *Sqlite3, v: f64) Mem {
    var m: Mem = .{ .db = db };
    mem.setDouble(&m, v);
    return m;
}

fn tText(db: *Sqlite3, s: []const u8) Mem {
    var m: Mem = .{ .db = db };
    mem.setStr(&m, s, ENC.UTF8, .static) catch unreachable;
    return m;
}

fn tBlob(db: *Sqlite3, s: []const u8) Mem {
    var m: Mem = .{ .db = db };
    mem.setStr(&m, s, 0, .static) catch unreachable;
    return m;
}

fn tNull(db: *Sqlite3) Mem {
    return .{ .db = db };
}

fn releaseAll(args: []Mem) void {
    for (args) |*a| mem.release(a);
}

/// Call the scalar function `name` on `args`, leaving the result in
/// `out`. Returns Context.is_error.
fn callScalar(db: *Sqlite3, name: []const u8, args: []Mem, out: *Mem) !i32 {
    const def = callback.findFunction(db, name, @intCast(args.len), ENC.UTF8, false) orelse return error.NoSuchFunction;
    try testing.expect(!def.isAggregate());
    var ptrs: [8]*Mem = undefined;
    for (args, 0..) |*a, i| ptrs[i] = a;
    out.* = .{ .db = db };
    var ctx: Context = .{ .out = out, .func = def, .argc = @intCast(args.len), .argv = ptrs[0..args.len] };
    def.x_sfunc.?(&ctx, ptrs[0..args.len]);
    return ctx.is_error;
}

/// Expect `name(args)` to give the text `want` (releases args).
fn expectText(db: *Sqlite3, want: []const u8, name: []const u8, args_in: anytype) !void {
    var args: [args_in.len]Mem = args_in;
    defer releaseAll(&args);
    var out: Mem = undefined;
    const rc = try callScalar(db, name, &args, &out);
    defer mem.release(&out);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqual(SQLITE_TEXT, api.valueType(&out));
    try testing.expectEqualStrings(want, out.bytes());
}

fn expectInt(db: *Sqlite3, want: i64, name: []const u8, args_in: anytype) !void {
    var args: [args_in.len]Mem = args_in;
    defer releaseAll(&args);
    var out: Mem = undefined;
    const rc = try callScalar(db, name, &args, &out);
    defer mem.release(&out);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqual(SQLITE_INTEGER, api.valueType(&out));
    try testing.expectEqual(want, out.u.i);
}

fn expectReal(db: *Sqlite3, want: f64, name: []const u8, args_in: anytype) !void {
    var args: [args_in.len]Mem = args_in;
    defer releaseAll(&args);
    var out: Mem = undefined;
    const rc = try callScalar(db, name, &args, &out);
    defer mem.release(&out);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqual(SQLITE_FLOAT, api.valueType(&out));
    try testing.expectEqual(want, out.u.r);
}

fn expectNull(db: *Sqlite3, name: []const u8, args_in: anytype) !void {
    var args: [args_in.len]Mem = args_in;
    defer releaseAll(&args);
    var out: Mem = undefined;
    const rc = try callScalar(db, name, &args, &out);
    defer mem.release(&out);
    try testing.expectEqual(@as(i32, 0), rc);
    try testing.expectEqual(SQLITE_NULL, api.valueType(&out));
}

fn expectError(db: *Sqlite3, want: []const u8, name: []const u8, args_in: anytype) !void {
    var args: [args_in.len]Mem = args_in;
    defer releaseAll(&args);
    var out: Mem = undefined;
    const rc = try callScalar(db, name, &args, &out);
    defer mem.release(&out);
    try testing.expectEqual(RC.ERROR, rc);
    try testing.expectEqualStrings(want, out.bytes());
}

/// Run aggregate `name` over rows of one or two arguments; `inverse`
/// rows (indexes into `rows`) are removed after all steps.
const Agg = struct {
    db: *Sqlite3,
    def: *const FuncDef,
    acc: Mem,

    fn init(db: *Sqlite3, name: []const u8, n_arg: i32) !Agg {
        const def = callback.findFunction(db, name, n_arg, ENC.UTF8, false) orelse return error.NoSuchFunction;
        try testing.expect(def.isAggregate());
        return .{ .db = db, .def = def, .acc = .{ .db = db } };
    }

    fn call(a: *Agg, args_in: anytype, inv: bool) i32 {
        var args: [args_in.len]Mem = args_in;
        defer releaseAll(&args);
        var ptrs: [4]*Mem = undefined;
        for (&args, 0..) |*m, i| ptrs[i] = m;
        var out: Mem = .{ .db = a.db };
        defer mem.release(&out);
        var ctx: Context = .{ .out = &out, .func = a.def, .mem = &a.acc, .argc = @intCast(args.len), .argv = ptrs[0..args.len] };
        if (inv) a.def.x_inverse.?(&ctx, ptrs[0..args.len]) else a.def.x_sfunc.?(&ctx, ptrs[0..args.len]);
        return if (ctx.is_error > 0) ctx.is_error else 0;
    }

    fn step(a: *Agg, args_in: anytype) i32 {
        return a.call(args_in, false);
    }

    fn inverse(a: *Agg, args_in: anytype) i32 {
        return a.call(args_in, true);
    }

    /// xValue into `out`.
    fn value(a: *Agg, out: *Mem) i32 {
        out.* = .{ .db = a.db };
        return mem.aggValue(&a.acc, out, a.def);
    }

    /// xFinal; the result is in `a.acc`. Release it with deinit().
    fn final(a: *Agg) i32 {
        return mem.finalize(&a.acc, a.def);
    }

    fn deinit(a: *Agg) void {
        mem.release(&a.acc);
    }
};

test "func: substr edge cases" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    try expectText(&db, "bc", "substr", .{ tText(&db, "abcde"), tInt(&db, 2), tInt(&db, 2) });
    try expectText(&db, "cde", "substr", .{ tText(&db, "abcde"), tInt(&db, 3) });
    // Negative start counts from the end.
    try expectText(&db, "de", "substr", .{ tText(&db, "abcde"), tInt(&db, -2) });
    try expectText(&db, "c", "substr", .{ tText(&db, "abcde"), tInt(&db, -3), tInt(&db, 1) });
    // Negative length takes the characters before the start.
    try expectText(&db, "bc", "substr", .{ tText(&db, "abcde"), tInt(&db, 4), tInt(&db, -2) });
    try expectText(&db, "a", "substr", .{ tText(&db, "abcde"), tInt(&db, 2), tInt(&db, -5) });
    // Start 0 is before the first character.
    try expectText(&db, "ab", "substr", .{ tText(&db, "abcde"), tInt(&db, 0), tInt(&db, 3) });
    try expectText(&db, "", "substr", .{ tText(&db, "abcde"), tInt(&db, 2), tInt(&db, 0) });
    try expectText(&db, "", "substr", .{ tText(&db, "abcde"), tInt(&db, 10) });
    try expectText(&db, "ab", "substr", .{ tText(&db, "abcde"), tInt(&db, -10), tInt(&db, 7) });
    // Characters, not bytes.
    try expectText(&db, "\u{e9}t\u{e9}", "substring", .{ tText(&db, "\u{e9}t\u{e9}!"), tInt(&db, 1), tInt(&db, 3) });
    try expectText(&db, "!", "substr", .{ tText(&db, "\u{e9}t\u{e9}!"), tInt(&db, -1) });
    try expectNull(&db, "substr", .{ tText(&db, "abc"), tNull(&db) });
    try expectNull(&db, "substr", .{ tText(&db, "abc"), tInt(&db, 1), tNull(&db) });
    // Blobs count bytes.
    var args = [_]Mem{ tBlob(&db, "\x01\x02\x03"), tInt(&db, 2) };
    defer releaseAll(&args);
    var out: Mem = undefined;
    _ = try callScalar(&db, "substr", &args, &out);
    defer mem.release(&out);
    try testing.expectEqual(SQLITE_BLOB, api.valueType(&out));
    try testing.expectEqualSlices(u8, "\x02\x03", out.bytes());
}

test "func: like, glob and escapes" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    // like(PATTERN, STRING)
    try expectInt(&db, 1, "like", .{ tText(&db, "a%C"), tText(&db, "AbbbC") });
    try expectInt(&db, 1, "like", .{ tText(&db, "_B_"), tText(&db, "abc") });
    try expectInt(&db, 0, "like", .{ tText(&db, "a_c"), tText(&db, "abbc") });
    // Case folding is ASCII only.
    try expectInt(&db, 0, "like", .{ tText(&db, "\u{c9}"), tText(&db, "\u{e9}") });
    try expectInt(&db, 1, "like", .{ tText(&db, "%\u{e9}%"), tText(&db, "caf\u{e9}s") });
    // ESCAPE
    try expectInt(&db, 1, "like", .{ tText(&db, "10!%"), tText(&db, "10%"), tText(&db, "!") });
    try expectInt(&db, 0, "like", .{ tText(&db, "10!%"), tText(&db, "100"), tText(&db, "!") });
    try expectInt(&db, 1, "like", .{ tText(&db, "a\\_c"), tText(&db, "a_c"), tText(&db, "\\") });
    try expectInt(&db, 0, "like", .{ tText(&db, "a\\_c"), tText(&db, "abc"), tText(&db, "\\") });
    // An escape that is also a wildcard loses its wildcard meaning.
    try expectInt(&db, 1, "like", .{ tText(&db, "a%%"), tText(&db, "a%"), tText(&db, "%") });
    try expectInt(&db, 0, "like", .{ tText(&db, "a%%"), tText(&db, "ab"), tText(&db, "%") });
    try expectError(&db, "ESCAPE expression must be a single character", "like", .{ tText(&db, "a"), tText(&db, "a"), tText(&db, "xy") });
    try expectNull(&db, "like", .{ tNull(&db), tText(&db, "a") });
    // GLOB is case sensitive and has character classes.
    try expectInt(&db, 0, "glob", .{ tText(&db, "A*"), tText(&db, "abc") });
    try expectInt(&db, 1, "glob", .{ tText(&db, "a*[b-d]"), tText(&db, "axxc") });
    try expectInt(&db, 0, "glob", .{ tText(&db, "a[^b]c"), tText(&db, "abc") });
    try expectInt(&db, 1, "glob", .{ tText(&db, "a?c"), tText(&db, "a\u{e9}c") });
    try testing.expectEqual(@as(i32, 0), strglob("*.zig", "func.zig"));
    try testing.expectEqual(@as(i32, 0), strlike("F%", "func", 0));

    // PRAGMA case_sensitive_like=ON
    registerLikeFunctions(&db, true);
    try expectInt(&db, 0, "like", .{ tText(&db, "a%"), tText(&db, "ABC") });
    try expectInt(&db, 1, "like", .{ tText(&db, "A%"), tText(&db, "ABC") });
    registerLikeFunctions(&db, false);
    try expectInt(&db, 1, "like", .{ tText(&db, "a%"), tText(&db, "ABC") });
}

test "func: round, abs and sign" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    try expectReal(&db, 3.0, "round", .{tReal(&db, 2.5)});
    try expectReal(&db, -3.0, "round", .{tReal(&db, -2.5)});
    try expectReal(&db, 1.23, "round", .{ tReal(&db, 1.2345), tInt(&db, 2) });
    try expectReal(&db, 0.5, "round", .{ tReal(&db, 0.45), tInt(&db, 1) });
    try expectReal(&db, 12.0, "round", .{ tText(&db, "12.3"), tInt(&db, -4) });
    try expectNull(&db, "round", .{ tReal(&db, 1.5), tNull(&db) });
    try expectInt(&db, 5, "abs", .{tInt(&db, -5)});
    try expectReal(&db, 2.5, "abs", .{tReal(&db, -2.5)});
    try expectReal(&db, 0.0, "abs", .{tText(&db, "abc")});
    try expectNull(&db, "abs", .{tNull(&db)});
    try expectError(&db, "integer overflow", "abs", .{tInt(&db, smallest_int64)});
    try expectInt(&db, -1, "sign", .{tReal(&db, -0.1)});
    try expectInt(&db, 1, "sign", .{tText(&db, "7")});
    try expectNull(&db, "sign", .{tText(&db, "x")});
}

test "func: sum, total, avg and count" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    {
        var a = try Agg.init(&db, "sum", 1);
        defer a.deinit();
        try testing.expectEqual(@as(i32, 0), a.step(.{tInt(&db, largest_int64)}));
        try testing.expectEqual(@as(i32, 0), a.step(.{tInt(&db, 1)}));
        try testing.expectEqual(RC.ERROR, a.final());
        try testing.expectEqualStrings("integer overflow", a.acc.bytes());
    }
    {
        // Overflow then back in range is still an error for sum() ...
        var a = try Agg.init(&db, "sum", 1);
        defer a.deinit();
        _ = a.step(.{tInt(&db, largest_int64)});
        _ = a.step(.{tInt(&db, 10)});
        _ = a.step(.{tInt(&db, -20)});
        try testing.expectEqual(RC.ERROR, a.final());
    }
    {
        // ... but total() gives a float.
        var a = try Agg.init(&db, "total", 1);
        defer a.deinit();
        _ = a.step(.{tInt(&db, largest_int64)});
        _ = a.step(.{tInt(&db, 1)});
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqual(@as(f64, 9223372036854775808.0), a.acc.u.r);
    }
    {
        var a = try Agg.init(&db, "sum", 1);
        defer a.deinit();
        _ = a.step(.{tInt(&db, 3)});
        _ = a.step(.{tNull(&db)});
        _ = a.step(.{tText(&db, "4")});
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqual(SQLITE_INTEGER, api.valueType(&a.acc));
        try testing.expectEqual(@as(i64, 7), a.acc.u.i);
    }
    {
        // Kahan-Babuska-Neumaier summation keeps the small terms.
        var a = try Agg.init(&db, "sum", 1);
        defer a.deinit();
        _ = a.step(.{tReal(&db, 1e100)});
        _ = a.step(.{tReal(&db, 1.0)});
        _ = a.step(.{tReal(&db, -1e100)});
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqual(@as(f64, 1.0), a.acc.u.r);
    }
    {
        var a = try Agg.init(&db, "avg", 1);
        defer a.deinit();
        _ = a.step(.{tInt(&db, 1)});
        _ = a.step(.{tInt(&db, 2)});
        _ = a.step(.{tNull(&db)});
        _ = a.step(.{tReal(&db, 4.5)});
        var v: Mem = undefined;
        try testing.expectEqual(@as(i32, 0), a.value(&v));
        try testing.expectEqual(@as(f64, 2.5), v.u.r);
        _ = a.inverse(.{tInt(&db, 1)});
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqual(@as(f64, 3.25), a.acc.u.r);
    }
    {
        // avg() and sum() of nothing are NULL; total() is 0.0.
        var a = try Agg.init(&db, "avg", 1);
        defer a.deinit();
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqual(SQLITE_NULL, api.valueType(&a.acc));
        var t = try Agg.init(&db, "total", 1);
        defer t.deinit();
        _ = t.step(.{tNull(&db)});
        try testing.expectEqual(@as(i32, 0), t.final());
        try testing.expectEqual(@as(f64, 0.0), t.acc.u.r);
    }
    {
        var a = try Agg.init(&db, "count", 1);
        defer a.deinit();
        _ = a.step(.{tInt(&db, 1)});
        _ = a.step(.{tNull(&db)});
        _ = a.step(.{tText(&db, "x")});
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqual(@as(i64, 2), a.acc.u.i);
        var star = try Agg.init(&db, "count", 0);
        defer star.deinit();
        try testing.expect(star.def.func_flags.COUNT);
        try testing.expectEqual(@as(i32, 0), star.final());
        try testing.expectEqual(@as(i64, 0), star.acc.u.i);
    }
}

test "func: min and max" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    try expectInt(&db, 1, "min", .{ tInt(&db, 3), tInt(&db, 1), tInt(&db, 2) });
    try expectText(&db, "b", "max", .{ tInt(&db, 3), tText(&db, "a"), tText(&db, "b") });
    try expectNull(&db, "max", .{ tInt(&db, 3), tNull(&db) });
    var a = try Agg.init(&db, "max", 1);
    defer a.deinit();
    _ = a.step(.{tText(&db, "pear")});
    _ = a.step(.{tNull(&db)});
    _ = a.step(.{tText(&db, "zucchini")});
    _ = a.step(.{tText(&db, "apple")});
    try testing.expectEqual(@as(i32, 0), a.final());
    try testing.expectEqualStrings("zucchini", a.acc.bytes());
}

test "func: group_concat with separators and inverse" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    {
        var a = try Agg.init(&db, "group_concat", 1);
        defer a.deinit();
        _ = a.step(.{tText(&db, "a")});
        _ = a.step(.{tNull(&db)});
        _ = a.step(.{tInt(&db, 2)});
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqualStrings("a,2", a.acc.bytes());
    }
    {
        var a = try Agg.init(&db, "string_agg", 2);
        defer a.deinit();
        _ = a.step(.{ tText(&db, "x"), tText(&db, "; ") });
        _ = a.step(.{ tText(&db, "y"), tText(&db, "; ") });
        _ = a.step(.{ tText(&db, "z"), tText(&db, "-") });
        var v: Mem = undefined;
        try testing.expectEqual(@as(i32, 0), a.value(&v));
        try testing.expectEqualStrings("x; y-z", v.bytes());
        mem.release(&v);
        // Remove "x" and then "y", with their separators.
        _ = a.inverse(.{ tText(&db, "x"), tText(&db, "; ") });
        try testing.expectEqual(@as(i32, 0), a.value(&v));
        try testing.expectEqualStrings("y-z", v.bytes());
        mem.release(&v);
        _ = a.inverse(.{ tText(&db, "y"), tText(&db, "; ") });
        try testing.expectEqual(@as(i32, 0), a.value(&v));
        try testing.expectEqualStrings("z", v.bytes());
        mem.release(&v);
        _ = a.step(.{ tText(&db, "w"), tText(&db, "+") });
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqualStrings("z+w", a.acc.bytes());
    }
    {
        // Emptied by inverse, then refilled.
        var a = try Agg.init(&db, "group_concat", 2);
        defer a.deinit();
        _ = a.step(.{ tText(&db, "a"), tText(&db, "|") });
        _ = a.inverse(.{ tText(&db, "a"), tText(&db, "|") });
        _ = a.step(.{ tText(&db, "b"), tText(&db, "|") });
        _ = a.step(.{ tText(&db, "c"), tText(&db, "|") });
        try testing.expectEqual(@as(i32, 0), a.final());
        try testing.expectEqualStrings("b|c", a.acc.bytes());
    }
}

test "func: quote, hex and unhex" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    try expectText(&db, "'it''s'", "quote", .{tText(&db, "it's")});
    try expectText(&db, "X'00FF10'", "quote", .{tBlob(&db, "\x00\xff\x10")});
    try expectText(&db, "X''", "quote", .{tBlob(&db, "")});
    try expectText(&db, "0.1", "quote", .{tReal(&db, 0.1)});
    try expectText(&db, "1.0", "quote", .{tReal(&db, 1.0)});
    try expectText(&db, "9.0e+999", "quote", .{tReal(&db, std.math.inf(f64))});
    try expectText(&db, "-42", "quote", .{tInt(&db, -42)});
    try expectText(&db, "NULL", "quote", .{tNull(&db)});
    try expectText(&db, "616263", "hex", .{tText(&db, "abc")});
    try expectText(&db, "00FF", "hex", .{tBlob(&db, "\x00\xff")});
    try expectText(&db, "3132", "hex", .{tInt(&db, 12)});
    try expectText(&db, "", "hex", .{tNull(&db)});
    {
        var args = [_]Mem{ tText(&db, "AB cd"), tText(&db, " ") };
        defer releaseAll(&args);
        var out: Mem = undefined;
        _ = try callScalar(&db, "unhex", &args, &out);
        defer mem.release(&out);
        try testing.expectEqual(SQLITE_BLOB, api.valueType(&out));
        try testing.expectEqualSlices(u8, "\xab\xcd", out.bytes());
    }
    try expectNull(&db, "unhex", .{tText(&db, "AB CD")});
    try expectNull(&db, "unhex", .{ tText(&db, "A BCD"), tText(&db, " ") });
    try expectNull(&db, "unhex", .{tText(&db, "ABC")});
}

test "func: replace, trim, case and concat" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    try expectText(&db, "a--b--c", "replace", .{ tText(&db, "a,b,c"), tText(&db, ","), tText(&db, "--") });
    try expectText(&db, "XXXXXXXX", "replace", .{ tText(&db, "aaaaaaaa"), tText(&db, "a"), tText(&db, "X") });
    try expectText(&db, "bcbcbcbcbcbcbcbcbc", "replace", .{ tText(&db, "aaaaaaaaa"), tText(&db, "a"), tText(&db, "bc") });
    try expectText(&db, "ac", "replace", .{ tText(&db, "abbc"), tText(&db, "bb"), tText(&db, "") });
    try expectText(&db, "abc", "replace", .{ tText(&db, "abc"), tText(&db, ""), tText(&db, "x") });
    try expectNull(&db, "replace", .{ tText(&db, "abc"), tNull(&db), tText(&db, "x") });
    try expectText(&db, "abc", "trim", .{tText(&db, "  abc  ")});
    try expectText(&db, "abc  ", "ltrim", .{tText(&db, "  abc  ")});
    try expectText(&db, "  abc", "rtrim", .{tText(&db, "  abc  ")});
    try expectText(&db, "abc", "trim", .{ tText(&db, "xyxabcyx"), tText(&db, "xy") });
    try expectText(&db, "b", "trim", .{ tText(&db, "\u{e9}a\u{e9}ba\u{e9}"), tText(&db, "a\u{e9}") });
    try expectText(&db, "xyxabcyx", "trim", .{ tText(&db, "xyxabcyx"), tText(&db, "") });
    try expectNull(&db, "trim", .{ tText(&db, "abc"), tNull(&db) });
    try expectText(&db, "ABC\u{e9}", "upper", .{tText(&db, "abC\u{e9}")});
    try expectText(&db, "abc\u{c9}", "lower", .{tText(&db, "AbC\u{c9}")});
    try expectText(&db, "a1b", "concat", .{ tText(&db, "a"), tNull(&db), tInt(&db, 1), tText(&db, "b") });
    try expectText(&db, "a, 1, b", "concat_ws", .{ tText(&db, ", "), tText(&db, "a"), tNull(&db), tInt(&db, 1), tText(&db, "b") });
    try expectNull(&db, "concat_ws", .{ tNull(&db), tText(&db, "a"), tText(&db, "b") });
}

test "func: typeof, length, instr, char, unicode, printf" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    try expectText(&db, "integer", "typeof", .{tInt(&db, 1)});
    try expectText(&db, "real", "typeof", .{tReal(&db, 1.5)});
    try expectText(&db, "text", "typeof", .{tText(&db, "1")});
    try expectText(&db, "blob", "typeof", .{tBlob(&db, "1")});
    try expectText(&db, "null", "typeof", .{tNull(&db)});
    try expectInt(&db, 4, "length", .{tText(&db, "caf\u{e9}")});
    try expectInt(&db, 5, "octet_length", .{tText(&db, "caf\u{e9}")});
    try expectInt(&db, 3, "length", .{tReal(&db, 1.5)});
    try expectNull(&db, "length", .{tNull(&db)});
    try expectInt(&db, 3, "instr", .{ tText(&db, "a\u{e9}t"), tText(&db, "t") });
    try expectInt(&db, 0, "instr", .{ tText(&db, "abc"), tText(&db, "x") });
    try expectInt(&db, 2, "instr", .{ tBlob(&db, "\x01\x02\x03"), tBlob(&db, "\x02") });
    try expectInt(&db, 2, "instr", .{ tText(&db, "a2c"), tInt(&db, 2) });
    try expectInt(&db, 3, "instr", .{ tBlob(&db, "ab3"), tInt(&db, 3) });
    try expectInt(&db, 1, "instr", .{ tText(&db, "abc"), tText(&db, "") });
    try expectText(&db, "A\u{e9}\u{fffd}", "char", .{ tInt(&db, 65), tInt(&db, 0xe9), tInt(&db, -1) });
    try expectInt(&db, 0xe9, "unicode", .{tText(&db, "\u{e9}t\u{e9}")});
    try expectText(&db, "x=05 y=1.50 z", "printf", .{ tText(&db, "x=%02d y=%.2f %s"), tInt(&db, 5), tReal(&db, 1.5), tText(&db, "z") });
    try expectText(&db, "'a''b' NULL", "format", .{ tText(&db, "%Q %Q"), tText(&db, "a'b"), tNull(&db) });
    try expectText(&db, "\u{e9}\\A", "unistr", .{tText(&db, "\\00e9\\\\\\u0041")});
    try expectError(&db, "invalid Unicode escape", "unistr", .{tText(&db, "a\\xyz")});
    try expectText(&db, sqlite_version, "sqlite_version", .{});
    try expectInt(&db, 1, "sqlite_compileoption_used", .{tText(&db, "SQLITE_THREADSAFE")});
    try expectInt(&db, 0, "sqlite_compileoption_used", .{tText(&db, "THREAD")});
    {
        var args = [_]Mem{tInt(&db, 3)};
        var out: Mem = undefined;
        _ = try callScalar(&db, "zeroblob", &args, &out);
        defer mem.release(&out);
        try testing.expectEqual(SQLITE_BLOB, api.valueType(&out));
        try testing.expectEqual(@as(usize, 3), api.valueBytes(&out));
    }
    {
        var args = [_]Mem{tInt(&db, 16)};
        var out: Mem = undefined;
        _ = try callScalar(&db, "randomblob", &args, &out);
        defer mem.release(&out);
        try testing.expectEqual(@as(usize, 16), api.valueBytes(&out));
        var out2: Mem = undefined;
        _ = try callScalar(&db, "random", &.{}, &out2);
        try testing.expectEqual(SQLITE_INTEGER, api.valueType(&out2));
        try testing.expect(out2.u.i != smallest_int64);
    }
}

test "func: registration and lookup" {
    var db: Sqlite3 = undefined;
    testDb(&db);
    defer callback.freeFunctions(&db);
    // In-line functions are coded by the code generator.
    for ([_][]const u8{ "coalesce", "iif", "if" }) |name| {
        const def = callback.findFunction(&db, name, 3, ENC.UTF8, false).?;
        try testing.expect(def.func_flags.INLINE);
        try testing.expect(def.func_flags.BUILTIN);
    }
    try testing.expectEqual(@as(usize, INLINEFUNC_coalesce), ptrToInt(callback.findFunction(&db, "COALESCE", 2, ENC.UTF8, false).?.user_data));
    try testing.expectEqual(@as(usize, INLINEFUNC_iif), ptrToInt(callback.findFunction(&db, "iif", 3, ENC.UTF8, false).?.user_data));
    try testing.expectEqual(@as(usize, INLINEFUNC_coalesce), ptrToInt(callback.findFunction(&db, "ifnull", 2, ENC.UTF8, false).?.user_data));
    try testing.expectEqual(@as(usize, INLINEFUNC_unlikely), ptrToInt(callback.findFunction(&db, "likely", 1, ENC.UTF8, false).?.user_data));
    // coalesce() needs two or more arguments, concat() one or more.
    try testing.expect(callback.findFunction(&db, "coalesce", 1, ENC.UTF8, false) == null);
    try testing.expect(callback.findFunction(&db, "concat", 0, ENC.UTF8, false) == null);
    try testing.expect(callback.findFunction(&db, "concat", 1, ENC.UTF8, false) != null);
    try testing.expect(callback.findFunction(&db, "substr", 4, ENC.UTF8, false) == null);
    try testing.expect(callback.findFunction(&db, "substr", -2, ENC.UTF8, false) != null);
    try testing.expect(callback.findFunction(&db, "no_such_function", 1, ENC.UTF8, false) == null);
    // min() with one argument is the aggregate.
    try testing.expect(callback.findFunction(&db, "min", 1, ENC.UTF8, false).?.isAggregate());
    try testing.expect(!callback.findFunction(&db, "min", 2, ENC.UTF8, false).?.isAggregate());

    // An application-defined function overrides the built-in ...
    const custom = struct {
        fn f(ctx: *Context, argv: []*Mem) void {
            _ = argv;
            api.resultInt(ctx, 42);
        }
    }.f;
    try testing.expectEqual(RC.OK, callback.createFunction(&db, "Abs", 1, ENC.UTF8 | callback.FNFLAG.DETERMINISTIC.int(), null, custom, null, null, null));
    try expectInt(&db, 42, "abs", .{tInt(&db, -1)});
    // ... unless built-ins are preferred.
    db.m_db_flags.PreferBuiltin = true;
    try expectInt(&db, 1, "abs", .{tInt(&db, -1)});
    db.m_db_flags.PreferBuiltin = false;
    const def = callback.findFunction(&db, "ABS", 1, ENC.UTF8, false).?;
    try testing.expectEqualStrings("abs", def.name);
    try testing.expect(!def.func_flags.BUILTIN);
    try testing.expect(def.func_flags.CONSTANT);
    try testing.expect(def.func_flags.UNSAFE);
    // Replacing keeps one FuncDef; a different arity adds another.
    try testing.expectEqual(RC.OK, callback.createFunction(&db, "abs", 1, ENC.UTF8, null, custom, null, null, null));
    try testing.expectEqual(def, callback.findFunction(&db, "abs", 1, ENC.UTF8, false).?);
    try testing.expectEqual(RC.OK, callback.createFunction(&db, "abs", 2, ENC.UTF8, null, custom, null, null, null));
    try testing.expect(callback.findFunction(&db, "abs", 2, ENC.UTF8, false).? != def);
    // Misuse.
    try testing.expectEqual(RC.MISUSE, callback.createFunction(&db, "f", -2, ENC.UTF8, null, custom, null, null, null));
    try testing.expectEqual(RC.MISUSE, callback.createFunction(&db, null, 1, ENC.UTF8, null, custom, null, null, null));
    // SQLITE_ANY adds all three encodings, sharing one destructor.
    const destroyed = struct {
        var n: u32 = 0;
        fn f(p: ?*anyopaque) void {
            _ = p;
            n += 1;
        }
    };
    try testing.expectEqual(RC.OK, callback.createFunctionV2(&db, "anyenc", 0, ENC.ANY, null, custom, null, null, null, destroyed.f));
    try testing.expect(callback.findFunction(&db, "anyenc", 0, ENC.UTF16BE, false).?.func_flags.enc == ENC.UTF16BE);
    try testing.expectEqual(@as(u32, 0), destroyed.n);
    // MATCH exists but fails outside a virtual table.
    registerPerConnectionBuiltinFunctions(&db);
    try expectError(&db, "unable to use function MATCH in the requested context", "match", .{ tText(&db, "a"), tText(&db, "b") });
    callback.freeFunctions(&db);
    try testing.expectEqual(@as(u32, 1), destroyed.n);
}
