//! Typed callbacks behind the C-shaped `void*` ones.
//!
//! A C-style callback takes its context as an erased pointer (`void*`:
//! `?*anyopaque`, `*anyopaque`, `*const anyopaque`) that the callee casts
//! back to the type its registrant passed. Here the callee is written
//! with the typed context instead, and thunk() makes the C-shaped
//! function from it:
//!
//!     fn stress(p: *Pager, pg: *Page) error{SpillFailed}!void { ... }
//!     const s = Stress.init(pager, stress); // Stress = Closure(StressFn)
//!
//! so the cast back from the erased pointer lives in one generated place,
//! and the context type is checked when the callback is made (Closure.init()
//! takes the context and the function together; thunk() checks the other
//! parameters and the result against the C-shaped type). The thunk calls
//! the typed function inline, so it costs nothing over the hand-written
//! cast, and it is one function per (type, function): comparing callbacks
//! by address (C: `pMem->xDel==sqlite3RowSetDelete`) keeps working.

const std = @import("std");

/// `erased`, a context pointer of a C-shaped callback, as the `To` it
/// stands for (`*T`, `*const T`, or their optionals). A null `erased`
/// for a non-optional `To` is a bug of the registrant (checked in safe
/// builds); dropping const is a compile error.
pub inline fn downcast(comptime To: type, erased: anytype) To {
    if (@typeInfo(To) == .optional or @typeInfo(@TypeOf(erased)) != .optional) {
        return @ptrCast(@alignCast(erased));
    }
    return @ptrCast(@alignCast(erased.?));
}

/// `typed`, a context pointer, as the erased pointer type `To` (the
/// other way from downcast(); explicit, as Zig does not erase pointers
/// to pointers implicitly).
pub inline fn erase(comptime To: type, typed: anytype) To {
    return @ptrCast(typed);
}

/// erase() for a context that may point to const (`*const T`), into a
/// C-shaped `void*` that is not const: the callee gets it back with
/// downcast() as the same `*const T`, so the const is restored, never
/// dropped (as C passes a `const void*` through `void*`).
pub inline fn eraseConst(comptime To: type, typed: anytype) To {
    return @ptrCast(@constCast(typed));
}

/// Whether `T` is an erased context pointer (to anyopaque).
fn isErased(comptime T: type) bool {
    const P = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return switch (@typeInfo(P)) {
        .pointer => |p| p.size == .one and p.child == anyopaque,
        else => false,
    };
}

/// The function type behind the C-shaped callback type `Fn` (a function
/// or a pointer to one).
fn FnInfo(comptime Fn: type) std.builtin.Type.Fn {
    return switch (@typeInfo(Fn)) {
        .@"fn" => |f| f,
        .pointer => |p| @typeInfo(p.child).@"fn",
        .optional => |o| FnInfo(o.child),
        else => @compileError("not a function type: " ++ @typeName(Fn)),
    };
}

/// The index of the erased context parameter of `Fn`: its first `void*`.
fn contextIndex(comptime Fn: type) usize {
    for (FnInfo(Fn).param_types, 0..) |p, i| {
        if (isErased(p.?)) return i;
    }
    @compileError("no void* context parameter in " ++ @typeName(Fn));
}

/// The erased context type of the C-shaped callback type `Fn`.
fn Context(comptime Fn: type) type {
    return FnInfo(Fn).param_types[contextIndex(Fn)].?;
}

/// The function of the C-shaped callback type `Fn` (`*const fn (...)`)
/// that calls `f` with the same arguments, its erased context (the first
/// `void*` parameter) cast to the type of the matching parameter of `f`.
/// Every other parameter, and the result, must be those of `Fn`. `Fn`
/// has one to five parameters (at least the context).
pub fn thunk(comptime Fn: type, comptime f: anytype) Fn {
    const erased = comptime FnInfo(Fn);
    const typed = @typeInfo(@TypeOf(f)).@"fn";
    const k = comptime contextIndex(Fn);
    const P = erased.param_types;
    const R = erased.return_type.?;
    comptime {
        if (typed.param_types.len != P.len) @compileError("thunk: arity of " ++ @typeName(@TypeOf(f)) ++ " is not that of " ++ @typeName(Fn));
        for (P, typed.param_types, 0..) |pe, pt, i| {
            if (i != k and pe.? != pt.?) @compileError("thunk: parameter types of " ++ @typeName(@TypeOf(f)) ++ " differ from " ++ @typeName(Fn));
        }
        if (typed.return_type.? != R) @compileError("thunk: result type of " ++ @typeName(@TypeOf(f)) ++ " is not that of " ++ @typeName(Fn));
    }
    const Args = std.meta.ArgsTuple(@TypeOf(f));
    const T = struct {
        inline fn call(raw: anytype) R {
            var args: Args = undefined;
            inline for (0..P.len) |i| {
                args[i] = if (i == k) downcast(typed.param_types[k].?, raw[i]) else raw[i];
            }
            return @call(.always_inline, f, args);
        }
        fn f1(a0: P[0].?) R {
            return call(.{a0});
        }
        fn f2(a0: P[0].?, a1: P[1].?) R {
            return call(.{ a0, a1 });
        }
        fn f3(a0: P[0].?, a1: P[1].?, a2: P[2].?) R {
            return call(.{ a0, a1, a2 });
        }
        fn f4(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?) R {
            return call(.{ a0, a1, a2, a3 });
        }
        fn f5(a0: P[0].?, a1: P[1].?, a2: P[2].?, a3: P[3].?, a4: P[4].?) R {
            return call(.{ a0, a1, a2, a3, a4 });
        }
    };
    return switch (P.len) {
        1 => T.f1,
        2 => T.f2,
        3 => T.f3,
        4 => T.f4,
        5 => T.f5,
        else => @compileError("thunk: too many parameters"),
    };
}

/// A C-style callback bound to its context: `func` is called with `ctx`
/// as its first argument (`Fn` is the C-shaped function pointer type,
/// with the erased context first).
pub fn Closure(comptime Fn: type) type {
    comptime std.debug.assert(contextIndex(Fn) == 0);
    return struct {
        ctx: Context(Fn),
        func: Fn,

        const Self = @This();

        /// `f` (taking `ctx` typed as its first parameter) bound to
        /// `ctx`, through thunk().
        pub inline fn init(ctx: anytype, comptime f: anytype) Self {
            const Typed = @typeInfo(@TypeOf(f)).@"fn".param_types[0].?;
            const typed: Typed = ctx;
            return .{ .ctx = erase(Context(Fn), typed), .func = thunk(Fn, f) };
        }

        /// Call `func` with `ctx` and `args` (a tuple of the rest).
        pub inline fn call(self: Self, args: anytype) FnInfo(Fn).return_type.? {
            return @call(.auto, self.func, .{self.ctx} ++ args);
        }
    };
}

test "thunk casts the context and passes the rest" {
    const Counter = struct {
        n: i32 = 0,
        fn add(c: *@This(), by: i32) i32 {
            c.n += by;
            return c.n;
        }
        fn peek(c: *const @This()) i32 {
            return c.n;
        }
    };
    var c: Counter = .{};
    const add = thunk(*const fn (?*anyopaque, i32) i32, Counter.add);
    try std.testing.expectEqual(@as(i32, 3), add(&c, 3));
    // One function per (type, function).
    try std.testing.expect(add == thunk(*const fn (?*anyopaque, i32) i32, Counter.add));
    const peek = thunk(*const fn (*const anyopaque) i32, Counter.peek);
    try std.testing.expectEqual(@as(i32, 3), peek(&c));
    // A const context through a `void*` that is not const.
    const peek_mut = thunk(*const fn (?*anyopaque) i32, Counter.peek);
    const const_c: *const Counter = &c;
    try std.testing.expectEqual(@as(i32, 3), peek_mut(eraseConst(?*anyopaque, const_c)));

    const Cl = Closure(*const fn (*anyopaque, i32) i32);
    const cl = Cl.init(&c, Counter.add);
    try std.testing.expectEqual(@as(i32, 5), cl.call(.{2}));

    // A context in the middle (as the pAux of xCreate).
    const mid = thunk(*const fn (i32, ?*anyopaque) i32, struct {
        fn f(by: i32, x: *Counter) i32 {
            return x.add(by);
        }
    }.f);
    try std.testing.expectEqual(@as(i32, 6), mid(1, &c));
}
