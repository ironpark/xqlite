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
