//! Building the function table of a dialect (Hooks.functions).
//!
//! The definitions are FuncDefs like SQLite's built-ins (func.zig's
//! FUNCTION() and friends), read-only and shared by every connection.
//! The overloads of one name must be next to each other in the table
//! (several argument counts, or -1 for any). An implementation has the
//! signature of a built-in, `fn (ctx: *Context, argv: []*Mem) void`, and
//! uses the C-shaped value API of src/vdbe/api.zig (valueText(),
//! resultInt64(), contextDbHandle() ...).
//!
//!     pub const hooks: Hooks = .{ .functions = &.{
//!         dfunc.scalar("version", 0, .{}, versionFunc),
//!         dfunc.scalar("concat", -1, .{ .deterministic = true }, concatFunc),
//!     } };

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");

const FuncDef = int.FuncDef;

pub const Context = vi.Context;
pub const Mem = vi.Mem;
pub const StepFn = FuncDef.StepFn;
pub const FinalFn = FuncDef.FinalFn;

pub const Options = struct {
    /// Same result for the same arguments within a statement
    /// (SQLITE_DETERMINISTIC): may be factored out of loops.
    deterministic: bool = false,
    /// Not usable from the schema (CHECK, DEFAULT, generated columns,
    /// views, triggers) while trusted_schema is off (SQLITE_FUNC_UNSAFE,
    /// as for an application function that is not SQLITE_INNOCUOUS).
    /// Off, as for SQLite's built-ins.
    unsafe: bool = false,
    /// Only usable from top-level SQL, not from the schema
    /// (SQLITE_DIRECTONLY); for functions with side effects.
    direct_only: bool = false,
    /// The user data, sqlite3_user_data() of the implementation.
    user_data: ?*anyopaque = null,
};

fn flags(o: Options) @import("../sql/callback.zig").FUNC {
    return .{
        .enc = vi.ENC.UTF8,
        .BUILTIN = true,
        .CONSTANT = o.deterministic,
        .DIRECT = o.direct_only,
        .UNSAFE = o.unsafe,
    };
}

/// A scalar function taking `n_arg` arguments (-1 for any number).
pub fn scalar(name: [:0]const u8, n_arg: i16, o: Options, x: StepFn) FuncDef {
    return .{ .n_arg = n_arg, .func_flags = flags(o), .user_data = o.user_data, .x_sfunc = x, .name = name };
}

/// An aggregate function: `step` per row, `final` for the result.
pub fn aggregate(name: [:0]const u8, n_arg: i16, o: Options, step: StepFn, final: FinalFn) FuncDef {
    return .{ .n_arg = n_arg, .func_flags = flags(o), .user_data = o.user_data, .x_sfunc = step, .x_finalize = final, .name = name };
}

/// Check at compile time that the overloads of each name are adjacent,
/// which dialect.functionSearch() relies on.
pub fn checkTable(comptime defs: []const FuncDef) void {
    @setEvalBranchQuota(100_000);
    for (defs, 0..) |a, i| {
        for (defs[i + 1 ..], i + 1..) |b, j| {
            if (std.ascii.eqlIgnoreCase(a.name, b.name) and j > i + 1 and
                !std.ascii.eqlIgnoreCase(defs[j - 1].name, a.name))
            {
                @compileError("dialect functions: the overloads of " ++ a.name ++ " must be adjacent");
            }
        }
    }
}

// ============================================== helpers of implementations

const api = @import("../vdbe/api.zig");

pub fn isNull(m: *Mem) bool {
    return api.valueType(m) == vi.SQLITE_NULL;
}

pub fn anyNull(argv: []*Mem) bool {
    for (argv) |m| if (isNull(m)) return true;
    return false;
}

/// Whether `m` is an integer, or text that looks like one.
pub fn isIntegral(m: *Mem) bool {
    return api.valueNumericType(m) == vi.SQLITE_INTEGER;
}

/// The text of `m` ("" for NULL); null on OOM, after making it the error
/// of the call.
pub fn text(ctx: *Context, m: *Mem) ?[]const u8 {
    if (isNull(m)) return "";
    return api.valueText(m) orelse {
        api.resultErrorNomem(ctx);
        return null;
    };
}

/// The connection's allocator, for buffers of a result: give them to the
/// result with .dynamic (they are freed with it).
pub fn gpa(ctx: *Context) std.mem.Allocator {
    return api.contextDbHandle(ctx).gpa;
}

/// Make the text in `out` (a buffer of gpa(ctx)) the result, which takes
/// the buffer over (.dynamic, as sqlite3_result_text(SQLITE_DYNAMIC));
/// `out` is left empty.
pub fn resultOwned(ctx: *Context, out: *std.ArrayList(u8)) void {
    if (out.items.len == 0) {
        out.deinit(gpa(ctx));
        return api.resultText(ctx, "", .static);
    }
    api.resultText(ctx, out.items, .dynamic);
    out.* = .empty;
}

/// The offset after the character at offset `i` of `z`, as SQLite counts
/// characters (length(), substr()): a byte from 0xc0 up and the
/// continuation bytes after it, or any other byte alone. Invalid UTF-8
/// counts the same in every dialect.
pub fn nextChar(z: []const u8, i: usize) usize {
    var j = i + 1;
    if (z[i] >= 0xc0) {
        while (j < z.len and z[j] & 0xc0 == 0x80) j += 1;
    }
    return j;
}

/// The number of characters of `z` (nextChar()).
pub fn charCount(z: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < z.len) : (n += 1) i = nextChar(z, i);
    return n;
}

/// The offset of character `n` of `z` (z.len past the end).
pub fn charOffset(z: []const u8, n: u64) usize {
    var i: usize = 0;
    var k: u64 = 0;
    while (i < z.len and k < n) : (k += 1) i = nextChar(z, i);
    return i;
}

/// A random float in [0, 1), from the connection's PRNG (randomness()).
pub fn randomUnit(ctx: *Context) f64 {
    var buf: [8]u8 = undefined;
    @import("../sql/func.zig").randomness(api.contextDbHandle(ctx), &buf);
    const r = std.mem.readInt(u64, &buf, .little) >> 11;
    return @as(f64, @floatFromInt(r)) / @as(f64, 1 << 53);
}

/// A random (version 4) UUID, in lower-case hexadecimal.
pub fn uuidV4(ctx: *Context) [36]u8 {
    var b: [16]u8 = undefined;
    @import("../sql/func.zig").randomness(api.contextDbHandle(ctx), &b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) catch unreachable;
    return out;
}

test "characters" {
    try std.testing.expectEqual(@as(usize, 3), charCount("a\xc3\xa9b"));
    try std.testing.expectEqual(@as(usize, 3), charOffset("a\xc3\xa9b", 2));
    try std.testing.expectEqual(@as(usize, 4), charOffset("a\xc3\xa9b", 9));
    // A stray continuation byte is a character of its own, as in SQLite.
    try std.testing.expectEqual(@as(usize, 3), charCount("a\x80b"));
}
