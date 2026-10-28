//! Function and collation lookup (port of callback.c), plus the
//! registration of application-defined functions (sqlite3CreateFunc() and
//! friends of main.c).
//!
//! Built-in functions live in one read-only hash table
//! (sqlite3BuiltinFunctions), built at compile time from the FuncDef
//! arrays that `builtin_defs` lists. Application-defined functions belong
//! to the connection (Sqlite3.funcs).

const std = @import("std");
const int = @import("sqlite_int.zig");
const ctype = @import("../util/ctype.zig");
const func = @import("func.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const flags = @import("../util/flags.zig");

const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const FuncDestructor = int.FuncDestructor;
const RC = int.RC;
const ENC = vi.ENC;

/// FuncDef.func_flags (SQLITE_FUNC_*). C keeps the text encoding of the
/// implementation in the low bits (SQLITE_FUNC_ENCMASK); here it is the
/// field `enc`.
pub const FUNC = packed struct(u32) {
    /// SQLITE_UTF8, SQLITE_UTF16LE or SQLITE_UTF16BE (see ENC).
    enc: u2 = 0,
    LIKE: bool = false,
    CASE: bool = false,
    EPHEM: bool = false,
    NEEDCOLL: bool = false,
    LENGTH: bool = false,
    TYPEOF: bool = false,
    COUNT: bool = false,
    _9: u1 = 0,
    UNLIKELY: bool = false,
    CONSTANT: bool = false,
    MINMAX: bool = false,
    SLOCHNG: bool = false,
    TEST: bool = false,
    RUNONLY: bool = false,
    WINDOW: bool = false,
    _17: u1 = 0,
    INTERNAL: bool = false,
    DIRECT: bool = false,
    SUBTYPE: bool = false,
    UNSAFE: bool = false,
    INLINE: bool = false,
    BUILTIN: bool = false,
    RESULT_SUBTYPE: bool = false,
    SELFORDER1: bool = false,
    _26: u1 = 0,
    ANYORDER: bool = false,
    _28: u4 = 0,

    /// octet_length(): LENGTH and TYPEOF.
    pub const BYTELEN: FUNC = .{ .LENGTH = true, .TYPEOF = true };

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        // length(), typeof() and octet_length() pass these bits on as the
        // P5 of OP_Column.
        std.debug.assert(FUNC.int(.{ .LENGTH = true }) == vi.OPFLAG.LENGTHARG);
        std.debug.assert(FUNC.int(.{ .TYPEOF = true }) == vi.OPFLAG.TYPEOFARG);
        std.debug.assert(BYTELEN.int() == vi.OPFLAG.BYTELENARG);
        flags.checkBits(FUNC, .{
            .enc = 0x00000003,
            .LIKE = 0x00000004,
            .CASE = 0x00000008,
            .EPHEM = 0x00000010,
            .NEEDCOLL = 0x00000020,
            .LENGTH = 0x00000040,
            .TYPEOF = 0x00000080,
            .COUNT = 0x00000100,
            .UNLIKELY = 0x00000400,
            .CONSTANT = 0x00000800,
            .MINMAX = 0x00001000,
            .SLOCHNG = 0x00002000,
            .TEST = 0x00004000,
            .RUNONLY = 0x00008000,
            .WINDOW = 0x00010000,
            .INTERNAL = 0x00040000,
            .DIRECT = 0x00080000,
            .SUBTYPE = 0x00100000,
            .UNSAFE = 0x00200000,
            .INLINE = 0x00400000,
            .BUILTIN = 0x00800000,
            .RESULT_SUBTYPE = 0x01000000,
            .SELFORDER1 = 0x02000000,
            .ANYORDER = 0x08000000,
        });
    }
};

/// Flags of sqlite3_create_function() (SQLITE_DETERMINISTIC etc.), or'ed
/// into the encoding argument at the C-shaped API. Each is the FUNC flag
/// at the same bit, so they go into FuncDef.func_flags as they are.
pub const FNFLAG = struct {
    pub const DETERMINISTIC: FUNC = .{ .CONSTANT = true };
    pub const DIRECTONLY: FUNC = .{ .DIRECT = true };
    pub const SUBTYPE: FUNC = .{ .SUBTYPE = true };
    /// The same bit as FUNC.UNSAFE, with the opposite meaning.
    pub const INNOCUOUS: FUNC = .{ .UNSAFE = true };
    pub const RESULT_SUBTYPE: FUNC = .{ .RESULT_SUBTYPE = true };
    pub const SELFORDER1: FUNC = .{ .SELFORDER1 = true };

    /// All of them.
    pub const mask: FUNC = .{
        .CONSTANT = true,
        .DIRECT = true,
        .SUBTYPE = true,
        .UNSAFE = true,
        .RESULT_SUBTYPE = true,
        .SELFORDER1 = true,
    };

    comptime {
        // The values of SQLITE_DETERMINISTIC etc. in sqlite3.h.
        std.debug.assert(DETERMINISTIC.int() == 0x000000800);
        std.debug.assert(DIRECTONLY.int() == 0x000080000);
        std.debug.assert(SUBTYPE.int() == 0x000100000);
        std.debug.assert(INNOCUOUS.int() == 0x000200000);
        std.debug.assert(RESULT_SUBTYPE.int() == 0x001000000);
        std.debug.assert(SELFORDER1.int() == 0x002000000);
        std.debug.assert(mask.int() == DETERMINISTIC.int() | DIRECTONLY.int() | SUBTYPE.int() |
            INNOCUOUS.int() | RESULT_SUBTYPE.int() | SELFORDER1.int());
    }
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

/// The built-in functions, in the order sqlite3RegisterBuiltinFunctions()
/// adds them to the table.
const builtin_defs = @import("alter.zig").funcs ++ @import("window.zig").funcs ++
    @import("date.zig").funcs ++ @import("json.zig").funcs ++ func.funcs;

/// sqlite3BuiltinFunctions: the hash table of the built-in functions,
/// built at compile time as sqlite3InsertBuiltinFuncs() builds it at
/// startup. Instead of the u.pHash and pNext links, each name has a slice
/// of its definitions in the order of its pNext chain, and the names of a
/// bucket are next to each other in the order of its u.pHash chain.
pub const builtins: Builtins = Builtins.build(&builtin_defs);

pub const Builtins = struct {
    /// The definitions of each name, bucket by bucket.
    names: []const []const FuncDef,
    /// The names in bucket h are names[buckets[h]..buckets[h + 1]].
    buckets: [func_hash_sz + 1]u16,

    /// Port of sqlite3InsertBuiltinFuncs(), run on `defs` at compile time.
    fn build(comptime defs: []const FuncDef) Builtins {
        @setEvalBranchQuota(100_000);
        // The table as C links it, by index into `defs`.
        var head: [func_hash_sz]?usize = @splat(null);
        var hash_next: [defs.len]?usize = @splat(null);
        var next: [defs.len]?usize = @splat(null);
        for (defs, 0..) |d, i| {
            std.debug.assert(d.func_flags.BUILTIN);
            const h = funcHash(if (d.name.len > 0) d.name[0] else 0, d.name.len);
            var other = head[h];
            while (other) |o| : (other = hash_next[o]) {
                if (ctype.eqlNoCase(defs[o].name, d.name)) break;
            }
            if (other) |o| {
                next[i] = next[o];
                next[o] = i;
            } else {
                hash_next[i] = head[h];
                head[h] = i;
            }
        }
        // Lay the chains out in order.
        var order: [defs.len]FuncDef = undefined;
        var ends: [defs.len]usize = undefined;
        var buckets: [func_hash_sz + 1]u16 = undefined;
        var n_def: usize = 0;
        var n_name: usize = 0;
        for (head, 0..) |first, h| {
            buckets[h] = @intCast(n_name);
            var name = first;
            while (name) |k| : (name = hash_next[k]) {
                var p: ?usize = k;
                while (p) |j| : (p = next[j]) {
                    order[n_def] = defs[j];
                    n_def += 1;
                }
                ends[n_name] = n_def;
                n_name += 1;
            }
        }
        buckets[func_hash_sz] = @intCast(n_name);
        const laid_out = order;
        var names: [n_name][]const FuncDef = undefined;
        for (&names, 0..) |*n, i| n.* = laid_out[if (i == 0) 0 else ends[i - 1]..ends[i]];
        const final = names;
        return .{ .names = &final, .buckets = buckets };
    }
};

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
    if (enc == p.func_flags.enc) {
        match += 2;
    } else if (enc & @as(u8, p.func_flags.enc) & 2 != 0) {
        match += 1;
    }
    return match;
}

/// Port of sqlite3FunctionSearch(): the definitions of the built-in named
/// `name` in bucket `h`, or none.
pub fn functionSearch(h: usize, name: []const u8) []const FuncDef {
    for (builtins.names[builtins.buckets[h]..builtins.buckets[h + 1]]) |defs| {
        if (ctype.eqlNoCase(defs[0].name, name)) return defs;
    }
    return &.{};
}

// ================================================================ lookup

/// Port of sqlite3FindFunction(): the function `name` taking `n_arg`
/// arguments (-1 any; -2 the first with an implementation), preferring
/// text encoding `enc`. Application-defined functions come first, unless
/// DBFLAG.PreferBuiltin is set. With `create`, only those of the
/// connection are looked at, and a blank FuncDef is added to it when there
/// is no exact match (null on OOM); a built-in is read-only.
pub fn findFunction(db: *Sqlite3, name: []const u8, n_arg: i32, enc: u8, comptime create: bool) if (create) ?*FuncDef else ?*const FuncDef {
    std.debug.assert(n_arg >= -2);
    std.debug.assert(n_arg >= -1 or !create);
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

    // Add a new entry if creating and there was no exact match.
    if (create) {
        if (best_score == func_perfect_match) return best;
        const new = newFuncDef(db, name, n_arg, enc) orelse {
            db.oomFault();
            return null;
        };
        const gop = db.funcs.getOrPut(db.gpa, new.name) catch {
            freeFuncDef(db, new);
            db.oomFault();
            return null;
        };
        new.next = if (gop.found_existing) gop.value_ptr.* else null;
        gop.value_ptr.* = new;
        return new;
    }

    // Then the built-ins.
    var found: ?*const FuncDef = best;
    if (best == null or db.m_db_flags.PreferBuiltin) {
        best_score = 0;
        const h = funcHash(ctype.toLower(if (name.len > 0) name[0] else 0), name.len);
        for (functionSearch(h, name)) |*f| {
            const score = matchQuality(f, n_arg, enc);
            if (score > best_score) {
                found = f;
                best_score = score;
            }
        }
    }
    if (found) |f| if (f.x_sfunc != null) return f;
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
    f.* = .{ .n_arg = @intCast(n_arg), .func_flags = .{ .enc = @intCast(enc) }, .name = z };
    return f;
}

fn freeFuncDef(db: *Sqlite3, f: *FuncDef) void {
    db.gpa.free(@constCast(f.name));
    db.gpa.destroy(f);
}

/// Port of functionDestroy() (main.c): drop `p`'s reference to its
/// destructor, running it with the last one.
fn functionDestroy(db: *Sqlite3, p: *FuncDef) void {
    std.debug.assert(!p.func_flags.BUILTIN);
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
/// `enc` is a text encoding (ENC, or ENC.ANY for all three) and
/// `fn_flags` the FNFLAG flags, as passed (C: the two or'ed into `enc`).
/// A scalar function has `x_sfunc`; an aggregate `x_step` and `x_final`,
/// and a window aggregate also `x_value` and `x_inverse`.
pub fn createFunc(
    db: *Sqlite3,
    name: ?[]const u8,
    n_arg: i32,
    enc_arg: u8,
    fn_flags: FUNC,
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

    std.debug.assert(FNFLAG.mask.contains(fn_flags));
    // The FNFLAG flags are FUNC flags (see FNFLAG).
    var extra_flags = fn_flags;
    // C: enc & (SQLITE_FUNC_ENCMASK|SQLITE_ANY).
    var enc = enc_arg & 0x7;

    // SQLITE_INNOCUOUS is the same bit as FUNC.UNSAFE with the opposite
    // meaning (tag-20230109-1).
    extra_flags.UNSAFE = !extra_flags.UNSAFE;

    // SQLITE_UTF16 becomes the native byte order; SQLITE_ANY adds the
    // function in all three encodings.
    switch (enc) {
        ENC.UTF16 => enc = ENC.UTF16LE,
        ENC.ANY => {
            var rc = createFunc(db, z_name, n_arg, ENC.UTF8, fn_flags, user_data, x_sfunc, x_step, x_final, x_value, x_inverse, destructor);
            if (rc == RC.OK) {
                rc = createFunc(db, z_name, n_arg, ENC.UTF16LE, fn_flags, user_data, x_sfunc, x_step, x_final, x_value, x_inverse, destructor);
            }
            if (rc != RC.OK) return rc;
            enc = ENC.UTF16BE;
        },
        ENC.UTF8, ENC.UTF16LE, ENC.UTF16BE => {},
        else => enc = ENC.UTF8,
    }

    // Overriding or deleting a function is refused while statements run;
    // otherwise prepared statements are expired.
    const old = findFunction(db, z_name, n_arg, @intCast(enc), false);
    if (old != null and old.?.func_flags.enc == enc and old.?.n_arg == n_arg) {
        if (db.n_vdbe_active != 0) {
            @import("main.zig").errorWithMsg(db, RC.BUSY, "unable to delete/modify user-function due to active statements", .{});
            return RC.BUSY;
        }
        @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
    } else if (x_sfunc == null and x_final == null) {
        // Deleting a function that does not exist is a no-op.
        return RC.OK;
    }

    const f = findFunction(db, z_name, n_arg, @intCast(enc), true) orelse return RC.NOMEM;

    // Run the destructor of the version being replaced.
    functionDestroy(db, f);

    if (destructor) |d| d.n_ref += 1;
    f.destructor = destructor;
    f.func_flags = extra_flags.with(.{ .enc = f.func_flags.enc });
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
    x_destroy: ?int.DestructorFn,
) i32 {
    const scalar = if (x_final == null) x_sfunc else null;
    const step = if (x_final != null) x_sfunc else null;
    var arg: ?*FuncDestructor = null;
    if (x_destroy) |destroy| {
        arg = db.gpa.create(FuncDestructor) catch {
            db.oomFault();
            destroy(user_data);
            return apiExit(db, RC.OK);
        };
        arg.?.* = .{ .x_destroy = destroy, .user_data = user_data };
    }
    // The C-shaped `enc`: the encoding or'ed with the FNFLAG flags.
    const rc = createFunc(db, name, n_arg, @intCast(enc & 0x7), .fromInt(enc & FNFLAG.mask.int()), user_data, scalar, step, x_final, x_value, x_inverse, arg);
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
fn invalidFunction(ctx: *vi.Context, argv: []*vi.Mem, z_name: [*:0]const u8) void {
    _ = argv;
    const api = @import("../vdbe/api.zig");
    const db = api.contextDbHandle(ctx);
    const msg = @import("printf.zig").mprintf(db.gpa, "unable to use function %s in the requested context", &.{.{ .str = std.mem.span(z_name) }}) catch {
        return api.resultErrorNomem(ctx);
    };
    defer db.gpa.free(msg);
    api.resultError(ctx, msg);
}

/// The name of an overload function is from sqlite3_mprintf(), freed with
/// sqlite3_free().
const freeOverloadName = @import("malloc.zig").free;

/// Port of sqlite3_overload_function(): make sure a function `name` with
/// `n_arg` arguments exists, so a virtual table can overload it; called
/// outside that context it fails.
pub fn overloadFunction(db: *Sqlite3, name: []const u8, n_arg: i32) i32 {
    if (findFunction(db, name, n_arg, ENC.UTF8, false) != null) return RC.OK;
    const copy = @import("malloc.zig").allocator.dupeSentinel(u8, name, 0) catch return RC.NOMEM;
    return createFunctionV2(db, name, n_arg, ENC.UTF8, FuncDef.userDataFor(invalidFunction, copy.ptr), FuncDef.withUserData(invalidFunction), null, null, null, freeOverloadName);
}
