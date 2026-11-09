//! xq_lateral_rows(v1, ..., vn) and xq_lateral_col(row, i [, type]): a
//! LATERAL subquery in the text of a view, which SQLite has no syntax
//! for. The arguments of a table-valued function may name the FROM items
//! before it, so PostgreSQL's view of
//!
//!     FROM a, LATERAL (SELECT ...) AS b
//!
//! is stored as (postgres/viewlateral.zig)
//!
//!     FROM a, json_each((SELECT xq_lateral_rows(c1, c2) FROM
//!         (WITH "xq_alias"(c1, c2) AS (SELECT ...) SELECT * FROM "xq_alias")
//!         AS "xq_lateral")) AS b
//!
//! and its columns b.x as xq_lateral_col(b.value, 0, 'type'): the
//! aggregate packs the subquery's rows, in their order, into a JSON array
//! of one string per row, json_each() (SQLite's, built in) gives the
//! rows, xq_lateral_col() takes one value back out. A row's string keeps
//! each value's type and bytes exactly (JSON would lose a BLOB, a REAL's
//! last bits, NaN): per value a letter and hex digits, nothing to escape
//! in JSON,
//!
//!     N                       NULL
//!     I<16 hex>               INTEGER, its 64 bits
//!     R<16 hex>               REAL, its IEEE 754 bits
//!     T<8 hex length><hex>    TEXT, its UTF-8 bytes
//!     B<8 hex length><hex>    BLOB
//!
//! The third argument of xq_lateral_col() is the type of the column as
//! the dialect spells it, for the core's typing (sql/typing.zig) only:
//! the value does not depend on it.
//!
//! Engine functions outside the dialect directories, so that a build
//! with any set of dialects (-Ddialects) reads such a view, as does
//! sqlite3 with the extension (docs/extension.md).

const std = @import("std");
const api = @import("../vdbe/api.zig");
const int = @import("../sql/sqlite_int.zig");
const printf = @import("../sql/printf.zig");
const dfunc = @import("func.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const vi = @import("../vdbe/vdbe_int.zig");

const det: dfunc.Options = .{ .deterministic = true };

/// Hooks.engine_functions of no dialect: dialect.zig adds them.
pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_lateral_col", 2, det, colFunc),
    dfunc.scalar("xq_lateral_col", 3, det, colFunc),
    dfunc.aggregate("xq_lateral_rows", -1, det, rowsStep, rowsFinal),
};

const Rows = struct {
    init: bool,
    str: printf.StrAccum,
};

fn putHex(str: *printf.StrAccum, bytes: []const u8) void {
    const hex = std.fmt.hex_charset;
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = @min(bytes.len - i, buf.len / 2);
        for (bytes[i..][0..n], 0..) |c, k| {
            buf[2 * k] = hex[c >> 4];
            buf[2 * k + 1] = hex[c & 15];
        }
        str.append(buf[0 .. 2 * n]);
        i += n;
    }
}

fn putU64(str: *printf.StrAccum, v: u64) void {
    str.append(&std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u64, v)), .lower));
}

fn putLen(str: *printf.StrAccum, n: usize) void {
    const len: u32 = @intCast(@min(n, std.math.maxInt(u32)));
    str.append(&std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u32, len)), .lower));
}

fn rowsStep(ctx: *Context, argv: []*Mem) void {
    const g = dfunc.aggState(Rows, ctx, true) orelse return;
    if (!g.init) {
        const db = api.contextDbHandle(ctx);
        g.* = .{ .init = true, .str = printf.StrAccum.init(@import("../sql/malloc.zig").allocator, &.{}, @intCast(db.limit(.length))) };
        g.str.appendChar(1, '[');
    } else g.str.appendChar(1, ',');
    g.str.appendChar(1, '"');
    for (argv) |m| switch (api.valueType(m)) {
        vi.SQLITE_INTEGER => {
            g.str.appendChar(1, 'I');
            putU64(&g.str, @bitCast(api.valueInt64(m)));
        },
        vi.SQLITE_FLOAT => {
            g.str.appendChar(1, 'R');
            putU64(&g.str, @bitCast(api.valueDouble(m)));
        },
        vi.SQLITE_TEXT => {
            const z = api.valueText(m) orelse "";
            g.str.appendChar(1, 'T');
            putLen(&g.str, z.len);
            putHex(&g.str, z);
        },
        vi.SQLITE_BLOB => {
            const z = api.valueBlob(m) orelse "";
            g.str.appendChar(1, 'B');
            putLen(&g.str, z.len);
            putHex(&g.str, z);
        },
        else => g.str.appendChar(1, 'N'),
    };
    g.str.appendChar(1, '"');
}

fn rowsFinal(ctx: *Context) void {
    const g = dfunc.aggState(Rows, ctx, false) orelse return api.resultText(ctx, "[]", .static);
    if (!g.init) return api.resultText(ctx, "[]", .static);
    g.str.appendChar(1, ']');
    api.resultStr(ctx, &g.str, .xfer);
}

fn malformed(ctx: *Context) void {
    api.resultErrorState(ctx, .of("XX000"), "malformed LATERAL row");
}

fn readU64(z: []const u8, at: *usize) ?u64 {
    if (at.* + 16 > z.len) return null;
    var b: [8]u8 = undefined;
    _ = std.fmt.hexToBytes(&b, z[at.*..][0..16]) catch return null;
    at.* += 16;
    return std.mem.readInt(u64, &b, .big);
}

/// The length and offset of a TEXT's or BLOB's hex digits at `at`.
fn readBytes(z: []const u8, at: *usize) ?[]const u8 {
    if (at.* + 8 > z.len) return null;
    var b: [4]u8 = undefined;
    _ = std.fmt.hexToBytes(&b, z[at.*..][0..8]) catch return null;
    at.* += 8;
    const n: usize = std.mem.readInt(u32, &b, .big);
    if (at.* + 2 * n > z.len) return null;
    const out = z[at.*..][0 .. 2 * n];
    at.* += 2 * n;
    return out;
}

fn colFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.isNull(argv[0]) or dfunc.isNull(argv[1])) return api.resultNull(ctx);
    const z = api.valueText(argv[0]) orelse return api.resultErrorNomem(ctx);
    const want = api.valueInt64(argv[1]);
    var at: usize = 0;
    var i: i64 = 0;
    while (at < z.len) : (i += 1) {
        const tag = z[at];
        at += 1;
        const here = i == want;
        switch (tag) {
            'N' => if (here) return api.resultNull(ctx),
            'I', 'R' => {
                // An earlier value: passed over, not read.
                if (!here) {
                    if (at + 16 > z.len) return malformed(ctx);
                    at += 16;
                    continue;
                }
                const v = readU64(z, &at) orelse return malformed(ctx);
                return if (tag == 'I') api.resultInt64(ctx, @bitCast(v)) else api.resultDouble(ctx, @bitCast(v));
            },
            'T', 'B' => {
                const digits = readBytes(z, &at) orelse return malformed(ctx);
                if (!here) continue;
                if (digits.len == 0) return if (tag == 'T') api.resultText(ctx, "", .static) else api.resultBlob(ctx, "", .static);
                // Decoded into the result's own buffer (.dynamic: it takes
                // the buffer over).
                const gpa = dfunc.gpa(ctx);
                const buf = gpa.alloc(u8, digits.len / 2) catch return api.resultErrorNomem(ctx);
                _ = std.fmt.hexToBytes(buf, digits) catch {
                    gpa.free(buf);
                    return malformed(ctx);
                };
                return if (tag == 'T') api.resultText(ctx, buf, .dynamic) else api.resultBlob(ctx, buf, .dynamic);
            },
            else => return malformed(ctx),
        }
    }
    // A column past the row's values (none such is written).
    api.resultNull(ctx);
}

test "lateral: row encoding" {
    var buf: [256]u8 = undefined;
    var str = printf.StrAccum.init(null, &buf, buf.len);
    putU64(&str, @bitCast(@as(i64, -2)));
    try std.testing.expectEqualStrings("fffffffffffffffe", buf[0..str.n_char]);
    var at: usize = 0;
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -2))), readU64(buf[0..str.n_char], &at).?);
    var s2 = printf.StrAccum.init(null, &buf, buf.len);
    putLen(&s2, 2);
    putHex(&s2, "hi");
    at = 0;
    try std.testing.expectEqualStrings("6869", readBytes(buf[0..s2.n_char], &at).?);
}
