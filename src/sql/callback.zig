//! Function and collation lookup (port of callback.c), plus the
//! registration of application-defined functions (sqlite3CreateFunc() and
//! friends of main.c).
//!
//! Built-in functions live in one process-wide hash table
//! (sqlite3BuiltinFunctions), filled once on first use from the static
//! FuncDef arrays of func.zig. Application-defined functions belong to
//! the connection (Sqlite3.funcs).

const std = @import("std");
const int = @import("sqlite_int.zig");
const ctype = @import("../util/ctype.zig");
const func = @import("func.zig");
const vi = @import("../vdbe/vdbe_int.zig");

const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const FuncDestructor = int.FuncDestructor;
const RC = int.RC;
const ENC = vi.ENC;

/// FuncDef.func_flags (SQLITE_FUNC_*).
pub const FUNC = struct {
    pub const ENCMASK: u32 = 0x0003;
    pub const LIKE: u32 = 0x0004;
    pub const CASE: u32 = 0x0008;
    pub const EPHEM: u32 = 0x0010;
    pub const NEEDCOLL: u32 = 0x0020;
    pub const LENGTH: u32 = 0x0040;
    pub const TYPEOF: u32 = 0x0080;
    pub const BYTELEN: u32 = 0x00c0;
    pub const COUNT: u32 = 0x0100;
    pub const UNLIKELY: u32 = 0x0400;
    pub const CONSTANT: u32 = 0x0800;
    pub const MINMAX: u32 = 0x1000;
    pub const SLOCHNG: u32 = 0x2000;
    pub const TEST: u32 = 0x4000;
    pub const RUNONLY: u32 = 0x8000;
    pub const WINDOW: u32 = 0x00010000;
    pub const INTERNAL: u32 = 0x00040000;
    pub const DIRECT: u32 = 0x00080000;
    pub const SUBTYPE: u32 = 0x00100000;
    pub const UNSAFE: u32 = 0x00200000;
    pub const INLINE: u32 = 0x00400000;
    pub const BUILTIN: u32 = 0x00800000;
    pub const RESULT_SUBTYPE: u32 = 0x01000000;
    pub const SELFORDER1: u32 = 0x02000000;
    pub const ANYORDER: u32 = 0x08000000;
};

/// Flags of sqlite3_create_function() (SQLITE_DETERMINISTIC etc.), or'ed
/// into the encoding argument. Some share bits with FUNC.
pub const FNFLAG = struct {
    pub const DETERMINISTIC: u32 = 0x000000800;
    pub const DIRECTONLY: u32 = 0x000080000;
    pub const SUBTYPE: u32 = 0x000100000;
    /// The same bit as FUNC.UNSAFE, with the opposite meaning.
    pub const INNOCUOUS: u32 = 0x000200000;
    pub const RESULT_SUBTYPE: u32 = 0x001000000;
    pub const SELFORDER1: u32 = 0x002000000;
};

/// SQLITE_MAX_FUNCTION_ARG.
pub const max_function_arg = 1000;

// ============================================================== built-ins

/// SQLITE_FUNC_HASH_SZ.
pub const func_hash_sz = 23;

/// SQLITE_FUNC_HASH().
fn funcHash(c: u8, n: usize) usize {
    return (@as(usize, c) + n) % func_hash_sz;
}

/// sqlite3BuiltinFunctions: the hash table of built-in functions, chained
/// through FuncDef.hash_next. Read-only once built.
var builtin_functions: [func_hash_sz]?*FuncDef = @splat(null);

/// 0: not built, 1: being built, 2: ready.
var builtins_state: std.atomic.Value(u8) = .init(0);

/// Build the built-in function table if that has not happened yet (the
/// part of sqlite3_initialize() that calls sqlite3RegisterBuiltinFunctions()).
pub fn registerBuiltins() void {
    if (builtins_state.load(.acquire) == 2) return;
    if (builtins_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        func.registerBuiltinFunctions();
        builtins_state.store(2, .release);
        return;
    }
    while (builtins_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

/// The score of a perfect match in matchQuality().
const func_perfect_match = 6;

/// Port of matchQuality(): how well `p` fits a call with `n_arg`
/// arguments (-1 any, -2 any function with an implementation) in text
/// encoding `enc`, from 0 (no match) to 6 (perfect match).
fn matchQuality(p: *const FuncDef, n_arg: i32, enc: u8) i32 {
    std.debug.assert(p.n_arg >= -4 and p.n_arg != -2);
    std.debug.assert(n_arg >= -2);
    // Wrong number of arguments means "no match".
    if (p.n_arg != n_arg) {
        if (n_arg == -2) return if (p.x_sfunc == null) 0 else func_perfect_match;
        if (p.n_arg >= 0) return 0;
        // Built-ins only: -3 means 1 or more arguments, -4 2 or more.
        if (p.n_arg < -2 and n_arg < -2 - @as(i32, p.n_arg)) return 0;
    }
    // A specific number of arguments beats any number.
    var match: i32 = if (p.n_arg == n_arg) 4 else 1;
    // Bonus points if the text encoding matches.
    if (enc == p.func_flags & FUNC.ENCMASK) {
        match += 2;
    } else if (enc & p.func_flags & 2 != 0) {
        match += 1;
    }
    return match;
}

/// Port of sqlite3FunctionSearch(): the built-in named `name` in bucket
/// `h`, or null.
pub fn functionSearch(h: usize, name: []const u8) ?*FuncDef {
    var p = builtin_functions[h];
    while (p) |f| : (p = f.hash_next) {
        std.debug.assert(f.func_flags & FUNC.BUILTIN != 0);
        if (ctype.eqlNoCase(f.name, name)) return f;
    }
    return null;
}

/// Port of sqlite3InsertBuiltinFuncs(): add `defs` to the built-in table.
/// The array must stay alive for the life of the process.
pub fn insertBuiltinFuncs(defs: []FuncDef) void {
    for (defs) |*d| {
        const h = funcHash(if (d.name.len > 0) d.name[0] else 0, d.name.len);
        std.debug.assert(d.func_flags & FUNC.BUILTIN != 0);
        if (functionSearch(h, d.name)) |other| {
            std.debug.assert(other != d and other.next != d);
            d.next = other.next;
            other.next = d;
        } else {
            d.next = null;
            d.hash_next = builtin_functions[h];
            builtin_functions[h] = d;
        }
    }
}

// ================================================================ lookup

/// Port of sqlite3FindFunction(): the function `name` taking `n_arg`
/// arguments (-1 any; -2 the first with an implementation), preferring
/// text encoding `enc`. Application-defined functions come first, unless
/// DBFLAG.PreferBuiltin is set. With `create`, a blank FuncDef is added
/// to the connection when there is no exact match (null on OOM).
pub fn findFunction(db: *Sqlite3, name: []const u8, n_arg: i32, enc: u8, create: bool) ?*FuncDef {
    std.debug.assert(n_arg >= -2);
    std.debug.assert(n_arg >= -1 or !create);
    registerBuiltins();
    var best: ?*FuncDef = null;
    var best_score: i32 = 0;

    // First the application-defined functions.
    var p = db.funcs.get(name);
    while (p) |f| : (p = f.next) {
        const score = matchQuality(f, n_arg, enc);
        if (score > best_score) {
            best = f;
            best_score = score;
        }
    }

    // Then the built-ins, unless creating a new function: those are
    // read-only.
    if (!create and (best == null or db.m_db_flags & int.DBFLAG.PreferBuiltin != 0)) {
        best_score = 0;
        const h = funcHash(ctype.toLower(if (name.len > 0) name[0] else 0), name.len);
        p = functionSearch(h, name);
        while (p) |f| : (p = f.next) {
            const score = matchQuality(f, n_arg, enc);
            if (score > best_score) {
                best = f;
                best_score = score;
            }
        }
    }

    // Add a new entry if creating and there was no exact match.
    if (create and best_score < func_perfect_match) {
        const new = newFuncDef(db, name, n_arg, enc) orelse {
            db.malloc_failed = true;
            return null;
        };
        const gop = db.funcs.getOrPut(db.gpa, new.name) catch {
            freeFuncDef(db, new);
            db.malloc_failed = true;
            return null;
        };
        new.next = if (gop.found_existing) gop.value_ptr.* else null;
        gop.value_ptr.* = new;
        best = new;
    }

    if (best) |b| if (b.x_sfunc != null or create) return b;
    return null;
}

/// A blank application-defined FuncDef with a lower-cased copy of `name`.
fn newFuncDef(db: *Sqlite3, name: []const u8, n_arg: i32, enc: u8) ?*FuncDef {
    const z = db.gpa.allocSentinel(u8, name.len, 0) catch return null;
    for (name, 0..) |c, i| z[i] = ctype.toLower(c);
    const f = db.gpa.create(FuncDef) catch {
        db.gpa.free(z);
        return null;
    };
    f.* = .{ .n_arg = @intCast(n_arg), .func_flags = enc, .name = z };
    return f;
}

fn freeFuncDef(db: *Sqlite3, f: *FuncDef) void {
    db.gpa.free(@constCast(f.name));
    db.gpa.destroy(f);
}

/// Port of functionDestroy() (main.c): drop `p`'s reference to its
/// destructor, running it with the last one.
fn functionDestroy(db: *Sqlite3, p: *FuncDef) void {
    std.debug.assert(p.func_flags & FUNC.BUILTIN == 0);
    const d = p.destructor orelse return;
    d.n_ref -= 1;
    if (d.n_ref == 0) {
        d.x_destroy(d.user_data);
        db.gpa.destroy(d);
    }
    p.destructor = null;
}

/// Free every application-defined function of the connection, as
/// sqlite3_close() does (sqlite3LeaveMutexAndCloseZombie()).
pub fn freeFunctions(db: *Sqlite3) void {
    var it = db.funcs.valueIterator();
    while (it.next()) |head| {
        var p: ?*FuncDef = head.*;
        while (p) |f| {
            functionDestroy(db, f);
            p = f.next;
            freeFuncDef(db, f);
        }
    }
    db.funcs.deinit(db.gpa);
    db.funcs = .empty;
}

// ========================================================== registration

/// Port of sqlite3CreateFunc() (main.c): add, replace or (with no
/// implementation) delete the function `name` taking `n_arg` arguments.
/// `enc` is a text encoding or'ed with FNFLAG flags. A scalar function
/// has `x_sfunc`; an aggregate `x_step` and `x_final`, and a window
/// aggregate also `x_value` and `x_inverse`.
pub fn createFunc(
    db: *Sqlite3,
    name: ?[]const u8,
    n_arg: i32,
    enc_arg: u32,
    user_data: ?*anyopaque,
    x_sfunc: ?FuncDef.StepFn,
    x_step: ?FuncDef.StepFn,
    x_final: ?FuncDef.FinalFn,
    x_value: ?FuncDef.FinalFn,
    x_inverse: ?FuncDef.StepFn,
    destructor: ?*FuncDestructor,
) i32 {
    std.debug.assert(x_value == null or x_sfunc == null);
    const z_name = name orelse return RC.MISUSE;
    if ((x_sfunc != null and x_final != null) or
        ((x_final == null) != (x_step == null)) or
        ((x_value == null) != (x_inverse == null)) or
        (n_arg < -1 or n_arg > max_function_arg) or
        255 < z_name.len)
    {
        return RC.MISUSE;
    }

    var extra_flags = enc_arg & (FNFLAG.DETERMINISTIC | FNFLAG.DIRECTONLY |
        FNFLAG.SUBTYPE | FNFLAG.INNOCUOUS | FNFLAG.RESULT_SUBTYPE | FNFLAG.SELFORDER1);
    var enc = enc_arg & (FUNC.ENCMASK | ENC.ANY);

    // SQLITE_INNOCUOUS is the same bit as FUNC.UNSAFE with the opposite
    // meaning (tag-20230109-1).
    extra_flags ^= FUNC.UNSAFE;

    // SQLITE_UTF16 becomes the native byte order; SQLITE_ANY adds the
    // function in all three encodings.
    switch (enc) {
        ENC.UTF16 => enc = ENC.UTF16LE,
        ENC.ANY => {
            var rc = createFunc(db, z_name, n_arg, (ENC.UTF8 | extra_flags) ^ FUNC.UNSAFE, user_data, x_sfunc, x_step, x_final, x_value, x_inverse, destructor);
            if (rc == RC.OK) {
                rc = createFunc(db, z_name, n_arg, (ENC.UTF16LE | extra_flags) ^ FUNC.UNSAFE, user_data, x_sfunc, x_step, x_final, x_value, x_inverse, destructor);
            }
            if (rc != RC.OK) return rc;
            enc = ENC.UTF16BE;
        },
        ENC.UTF8, ENC.UTF16LE, ENC.UTF16BE => {},
        else => enc = ENC.UTF8,
    }

    // Overriding or deleting a function is refused while statements run;
    // otherwise prepared statements are expired.
    var p = findFunction(db, z_name, n_arg, @intCast(enc), false);
    if (p != null and p.?.func_flags & FUNC.ENCMASK == enc and p.?.n_arg == n_arg) {
        if (db.n_vdbe_active != 0) {
            @import("main.zig").errorWithMsg(db, RC.BUSY, "unable to delete/modify user-function due to active statements", .{});
            return RC.BUSY;
        }
        @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
    } else if (x_sfunc == null and x_final == null) {
        // Deleting a function that does not exist is a no-op.
        return RC.OK;
    }

    p = findFunction(db, z_name, n_arg, @intCast(enc), true);
    const f = p orelse return RC.NOMEM;

    // Run the destructor of the version being replaced.
    functionDestroy(db, f);

    if (destructor) |d| d.n_ref += 1;
    f.destructor = destructor;
    f.func_flags = (f.func_flags & FUNC.ENCMASK) | extra_flags;
    f.x_sfunc = x_sfunc orelse x_step;
    f.x_finalize = x_final;
    f.x_value = x_value;
    f.x_inverse = x_inverse;
    f.user_data = user_data;
    f.n_arg = @intCast(n_arg);
    return RC.OK;
}

/// Port of sqlite3_create_function() / sqlite3_create_window_function()
/// without a destructor. `x_sfunc` is the scalar function, or with
/// `x_final` the aggregate step.
pub fn createFunction(
    db: *Sqlite3,
    name: ?[]const u8,
    n_arg: i32,
    enc: u32,
    user_data: ?*anyopaque,
    x_sfunc: ?FuncDef.StepFn,
    x_final: ?FuncDef.FinalFn,
    x_value: ?FuncDef.FinalFn,
    x_inverse: ?FuncDef.StepFn,
) i32 {
    return createFunctionV2(db, name, n_arg, enc, user_data, x_sfunc, x_final, x_value, x_inverse, null);
}

/// Port of createFunctionApi() (sqlite3_create_function_v2() and
/// sqlite3_create_window_function()): createFunction() with a destructor
/// for `user_data`, called once no function uses it any more (or right
/// away if the registration fails).
pub fn createFunctionV2(
    db: *Sqlite3,
    name: ?[]const u8,
    n_arg: i32,
    enc: u32,
    user_data: ?*anyopaque,
    x_sfunc: ?FuncDef.StepFn,
    x_final: ?FuncDef.FinalFn,
    x_value: ?FuncDef.FinalFn,
    x_inverse: ?FuncDef.StepFn,
    x_destroy: ?*const fn (?*anyopaque) void,
) i32 {
    const scalar = if (x_final == null) x_sfunc else null;
    const step = if (x_final != null) x_sfunc else null;
    var arg: ?*FuncDestructor = null;
    if (x_destroy) |destroy| {
        arg = db.gpa.create(FuncDestructor) catch {
            db.malloc_failed = true;
            destroy(user_data);
            return apiExit(db, RC.OK);
        };
        arg.?.* = .{ .x_destroy = destroy, .user_data = user_data };
    }
    const rc = createFunc(db, name, n_arg, enc, user_data, scalar, step, x_final, x_value, x_inverse, arg);
    if (arg) |a| if (a.n_ref == 0) {
        a.x_destroy(user_data);
        db.gpa.destroy(a);
    };
    return apiExit(db, rc);
}

/// Port of sqlite3ApiExit(): NOMEM after an allocation failure.
const apiExit = @import("main.zig").apiExit;

/// Port of sqlite3InvalidFunction() (main.c): always fails, naming the
/// function (the user data).
fn invalidFunction(ctx: *vi.Context, argv: []*vi.Mem) void {
    _ = argv;
    const api = @import("../vdbe/api.zig");
    const z_name: [*:0]const u8 = @ptrCast(api.userData(ctx).?);
    const db = api.contextDbHandle(ctx);
    const msg = @import("printf.zig").mprintf(db.gpa, "unable to use function %s in the requested context", &.{.{ .str = std.mem.span(z_name) }}) catch {
        return api.resultErrorNomem(ctx);
    };
    defer db.gpa.free(msg);
    api.resultError(ctx, msg);
}

fn freeOverloadName(p: ?*anyopaque) void {
    const z: [*:0]u8 = @ptrCast(p.?);
    std.heap.smp_allocator.free(std.mem.span(z));
}

/// Port of sqlite3_overload_function(): make sure a function `name` with
/// `n_arg` arguments exists, so a virtual table can overload it; called
/// outside that context it fails.
pub fn overloadFunction(db: *Sqlite3, name: []const u8, n_arg: i32) i32 {
    if (findFunction(db, name, n_arg, ENC.UTF8, false) != null) return RC.OK;
    const copy = std.heap.smp_allocator.dupeSentinel(u8, name, 0) catch return RC.NOMEM;
    return createFunctionV2(db, name, n_arg, ENC.UTF8, @ptrCast(copy.ptr), invalidFunction, null, null, null, freeOverloadName);
}
