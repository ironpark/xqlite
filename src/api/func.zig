//! Application-defined SQL functions, aggregates and collations, with
//! their signatures taken from comptime-known Zig functions.
//!
//! The engine calls a generated wrapper (xFunc, xStep, xFinal ...) that
//! reads each argument as the Zig parameter type (see value.zig), calls
//! the Zig function and converts its return value into the SQL result.

const std = @import("std");
const engine = @import("engine.zig");
const errors = @import("errors.zig");
const value = @import("value.zig");
const Conn = @import("conn.zig").Conn;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Options of Db.createFunction() and Db.createAggregate():
/// `deterministic`, `direct_only` and `innocuous`.
pub const FunctionOptions = engine.FunctionFlags;

/// The arguments of a function that takes any number of them: declare a
/// single SQL parameter of this type.
///
///     fn concatAll(gpa: std.mem.Allocator, args: xqlite.Args) ![]const u8
pub const Args = struct {
    argv: []*engine.Mem,

    pub fn len(a: Args) usize {
        return a.argv.len;
    }

    /// The datatype of argument `i`.
    pub fn kind(a: Args, i: usize) value.Kind {
        return value.kindOf(engine.valueType(a.argv[i]));
    }

    /// Argument `i` as `T`. Text and blobs are borrowed for the call.
    pub fn get(a: Args, comptime T: type, i: usize) value.ReadError!T {
        return value.read(T, value.MemSource{ .m = a.argv[i] });
    }
};

/// What a registered function or module keeps (its user data, or the
/// pAux of a module): the Db's allocator, the caller's context and, for
/// a scalar function, the arena of its Allocator parameter. The engine
/// frees it (x_destroy) when the function or module is replaced or the
/// connection closes.
pub fn Box(comptime Ctx: type) type {
    return struct {
        gpa: Allocator,
        context: Ctx,
        /// The arena of the calls of a scalar function, reset after each.
        arena: std.heap.ArenaAllocator,
        /// Calls of the function in progress: a call made while another
        /// runs (the function runs SQL that calls it again) gets an arena
        /// of its own.
        depth: u32 = 0,

        const Self = @This();

        pub fn create(conn: Conn, gpa: Allocator, context: Ctx) Error!*Self {
            const b = gpa.create(Self) catch return conn.outOfMemory();
            b.* = .{ .gpa = gpa, .context = context, .arena = .init(gpa) };
            return b;
        }

        fn destroy(b: *Self) void {
            b.arena.deinit();
            b.gpa.destroy(b);
        }

        /// The xDestroy of the box.
        pub const x_destroy = engine.destructor(destroy);
    };
}

/// How much of its arena a scalar function keeps between calls.
const arena_retain_limit = 64 * 1024;

/// Check that `Ctx` is a valid context type: void or a single-item
/// pointer.
pub fn checkContext(comptime Ctx: type) void {
    if (Ctx == void) return;
    const info = @typeInfo(Ctx);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("xqlite: a context must be {} or a single-item pointer, not " ++ @typeName(Ctx));
    }
}

/// The role of each parameter of a callback.
const Param = enum { context, allocator, args, sql };

fn paramRoles(comptime F: type, comptime n_skip: usize, comptime Ctx: type) []const Param {
    const params = @typeInfo(F).@"fn".param_types;
    var roles: [params.len]Param = undefined;
    for (params, 0..) |P_opt, i| {
        const P = P_opt orelse @compileError("xqlite: function parameters must have concrete types (no anytype)");
        if (i < n_skip) {
            roles[i] = .context; // `self` of a method; filled in by the caller
        } else if (Ctx != void and i == n_skip) {
            if (P != Ctx) @compileError("xqlite: the first parameter must be the context, " ++ @typeName(Ctx) ++ ", not " ++ @typeName(P));
            roles[i] = .context;
        } else if (P == Allocator) {
            roles[i] = .allocator;
        } else if (P == Args) {
            roles[i] = .args;
        } else {
            roles[i] = .sql;
        }
    }
    const final = roles;
    return &final;
}

/// The SQL arity of a callback: its SQL parameters, or -1 with Args.
fn arity(comptime roles: []const Param) i32 {
    var n: i32 = 0;
    var variadic = false;
    for (roles) |r| switch (r) {
        .sql => n += 1,
        .args => variadic = true,
        else => {},
    };
    if (variadic and n > 0) @compileError("xqlite: a function with an xqlite.Args parameter cannot have other SQL parameters");
    return if (variadic) -1 else n;
}

/// Fill the arguments of a call: SQL parameters from `argv`, allocators
/// with `gpa`. Parameters with role .context are left to the caller.
/// Returns false (with the error set) if an argument does not convert.
fn fillArgs(comptime roles: []const Param, args: anytype, ctx: *engine.Context, argv: []*engine.Mem, gpa: Allocator) bool {
    const types = @typeInfo(@TypeOf(args.*)).@"struct".field_types;
    comptime var k: usize = 0;
    inline for (roles, 0..) |r, i| switch (r) {
        .context => {},
        .allocator => args[i] = gpa,
        .args => args[i] = .{ .argv = argv },
        .sql => {
            args[i] = value.read(types[i], value.MemSource{ .m = argv[k] }) catch |err| {
                if (err == error.OutOfMemory) {
                    engine.resultErrorNomem(ctx);
                } else {
                    var buf: [128]u8 = undefined;
                    engine.resultError(ctx, std.fmt.bufPrint(&buf, "argument {d}: {s}", .{ k + 1, @errorName(err) }) catch "bad argument");
                }
                return false;
            };
            k += 1;
        },
    };
    return true;
}

/// Call `f` with `args` and pass its result (or error) to `ctx`.
fn callAndSetResult(comptime f: anytype, args: anytype, ctx: *engine.Context) void {
    value.setResult(ctx, @call(.auto, f, args.*));
}

// ================================================================ scalars

/// Register `func` as the scalar SQL function `name` (see
/// Db.createFunction()).
pub fn createScalar(conn: Conn, gpa: Allocator, name: []const u8, context: anytype, comptime func: anytype, opts: FunctionOptions) Error!void {
    const Ctx = @TypeOf(context);
    checkContext(Ctx);
    const F = @TypeOf(func);
    if (@typeInfo(F) != .@"fn") @compileError("xqlite: createFunction() takes a function, not " ++ @typeName(F));
    const roles = comptime paramRoles(F, 0, Ctx);
    const uses_arena = comptime std.mem.indexOfScalar(Param, roles, .allocator) != null;
    const B = Box(Ctx);

    const W = struct {
        fn xFunc(ctx: *engine.Context, argv: []*engine.Mem, box: *B) void {
            var args: std.meta.ArgsTuple(F) = undefined;
            if (Ctx != void) args[0] = box.context;
            if (!uses_arena) {
                if (fillArgs(roles, &args, ctx, argv, undefined)) callAndSetResult(func, &args, ctx);
                return;
            }
            // Allocator parameters get the arena of the box, reset once
            // the result has been copied. A nested call has its own.
            var nested: std.heap.ArenaAllocator = undefined;
            const outer = box.depth == 0;
            if (!outer) nested = .init(box.gpa);
            const arena = if (outer) &box.arena else &nested;
            box.depth += 1;
            defer {
                box.depth -= 1;
                if (outer) {
                    _ = box.arena.reset(.{ .retain_with_limit = arena_retain_limit });
                } else {
                    nested.deinit();
                }
            }
            if (fillArgs(roles, &args, ctx, argv, arena.allocator())) callAndSetResult(func, &args, ctx);
        }
    };

    const box = try B.create(conn, gpa, context);
    return conn.check(engine.createFunction(conn.h, name, comptime arity(roles), opts, engine.userDataFor(W.xFunc, box), engine.withUserData(W.xFunc), null, null, null, B.x_destroy));
}

// ============================================================= aggregates

/// Register `State` as the aggregate SQL function `name` (see
/// Db.createAggregate()).
pub fn createAggregate(conn: Conn, gpa: Allocator, name: []const u8, comptime State: type, opts: FunctionOptions) Error!void {
    if (!@hasDecl(State, "step") or !@hasDecl(State, "final")) {
        @compileError("xqlite: an aggregate type needs `pub fn step(self: *" ++ @typeName(State) ++ ", ...)` and `pub fn final(self: *" ++ @typeName(State) ++ ") T`");
    }
    const step_roles = comptime paramRoles(@TypeOf(State.step), 1, void);
    const n_arg = comptime arity(step_roles);
    const is_window = @hasDecl(State, "inverse") and @hasDecl(State, "value");
    const inverse_roles = if (is_window) comptime paramRoles(@TypeOf(State.inverse), 1, void) else step_roles;
    if (is_window and comptime arity(inverse_roles) != n_arg) @compileError("xqlite: inverse() must take the same arguments as step()");
    const B = Box(void);

    // The state lives in the aggregate context: zeroed bytes the engine
    // keeps for one group, 8-byte aligned.
    const Slot = struct {
        initialized: bool,
        state: State,
    };
    if (@alignOf(Slot) > 8) @compileError("xqlite: aggregate state needs an alignment of at most 8");

    const W = struct {
        fn slot(ctx: *engine.Context) ?*Slot {
            const s = engine.aggContext(Slot, ctx) orelse return null;
            if (!s.initialized) {
                s.state = if (@hasDecl(State, "init")) State.init() else .{};
                s.initialized = true;
            }
            return s;
        }

        /// The box, from an xFinal or xValue.
        fn boxOf(ctx: *engine.Context) *B {
            return engine.userDataOf(ctx, xStep);
        }

        fn callStep(comptime method: anytype, comptime roles: []const Param, ctx: *engine.Context, argv: []*engine.Mem, box: *B) void {
            const s = slot(ctx) orelse return engine.resultErrorNomem(ctx);
            var args: std.meta.ArgsTuple(@TypeOf(method)) = undefined;
            args[0] = &s.state;
            if (!fillArgs(roles, &args, ctx, argv, box.gpa)) return;
            const r = @call(.auto, method, args);
            if (@typeInfo(@TypeOf(r)) == .error_union) {
                _ = r catch |err| value.setError(ctx, err);
            }
        }

        fn callResult(comptime method: anytype, ctx: *engine.Context, s: *Slot) void {
            const roles = comptime paramRoles(@TypeOf(method), 1, void);
            if (comptime arity(roles) != 0) @compileError("xqlite: final() and value() take no SQL arguments");
            var args: std.meta.ArgsTuple(@TypeOf(method)) = undefined;
            args[0] = &s.state;
            _ = fillArgs(roles, &args, ctx, &.{}, boxOf(ctx).gpa);
            callAndSetResult(method, &args, ctx);
        }

        fn xStep(ctx: *engine.Context, argv: []*engine.Mem, box: *B) void {
            callStep(State.step, step_roles, ctx, argv, box);
        }

        fn xInverse(ctx: *engine.Context, argv: []*engine.Mem, box: *B) void {
            callStep(State.inverse, inverse_roles, ctx, argv, box);
        }

        fn xValue(ctx: *engine.Context) void {
            const s = slot(ctx) orelse return engine.resultErrorNomem(ctx);
            callResult(State.value, ctx, s);
        }

        /// Also called when a statement is abandoned before the end of
        /// the group, so deinit() always runs.
        fn xFinal(ctx: *engine.Context) void {
            const s = slot(ctx) orelse return engine.resultErrorNomem(ctx);
            callResult(State.final, ctx, s);
            if (@hasDecl(State, "deinit")) {
                const P = @typeInfo(@TypeOf(State.deinit)).@"fn".param_types;
                if (P.len == 2) s.state.deinit(boxOf(ctx).gpa) else s.state.deinit();
            }
            s.initialized = false;
        }
    };

    const box = try B.create(conn, gpa, {});
    return conn.check(engine.createFunction(
        conn.h,
        name,
        n_arg,
        opts,
        engine.userDataFor(W.xStep, box),
        engine.withUserData(W.xStep),
        W.xFinal,
        if (is_window) W.xValue else null,
        if (is_window) engine.withUserData(W.xInverse) else null,
        B.x_destroy,
    ));
}

// ============================================================= collations

/// Register `cmp` as collation `name` (see Db.createCollation()).
pub fn createCollation(conn: Conn, name: []const u8, context: anytype, comptime cmp: anytype) Error!void {
    const Ctx = @TypeOf(context);
    checkContext(Ctx);
    if (Ctx == void) {
        const W = struct {
            fn compare(_: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
                return cmp(a, b);
            }
        };
        return conn.check(engine.createCollation(conn.h, name, null, W.compare));
    }
    const W = struct {
        fn compare(c: Ctx, a: []const u8, b: []const u8) std.math.Order {
            return cmp(c, a, b);
        }
    };
    return conn.check(engine.createCollation(conn.h, name, engine.eraseConst(?*anyopaque, context), engine.thunk(engine.CollationFn, W.compare)));
}
