//! sqlite3_test_control() (port of the switch of main.c). The C shim
//! (varargs.c) takes the arguments of each op out of the varargs; this
//! applies them. The ops are those of a release build of SQLite: what
//! only SQLITE_DEBUG or coverage builds do (TUNE, TRACEFLAGS,
//! JSON_SELFCHECK, VDBE_COVERAGE, PARSER_COVERAGE) does nothing here
//! either. See docs/c-api.md for the ops that are accepted but have no
//! effect.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("common.zig");

const Handle = c.Handle;
const RC = c.RC;
const global = @import("../sql/global.zig");
const build = @import("../sql/build.zig");
const numeric = @import("xqlite_base").numeric;

/// XqTestArgs of varargs.c.
const Args = extern struct {
    p: [3]?*anyopaque,
    i: [3]i64,
    r: f64,
};

// SQLITE_TESTCTRL_* codes.
const PRNG_SAVE = 5;
const PRNG_RESTORE = 6;
const FK_NO_ACTION = 7;
const BITVEC_TEST = 8;
const FAULT_INSTALL = 9;
const BENIGN_MALLOC_HOOKS = 10;
const PENDING_BYTE = 11;
const ASSERT = 12;
const ALWAYS = 13;
const JSON_SELFCHECK = 14;
const OPTIMIZATIONS = 15;
const GETOPT = 16;
const INTERNAL_FUNCTIONS = 17;
const LOCALTIME_FAULT = 18;
const ONCE_RESET_THRESHOLD = 19;
const NEVER_CORRUPT = 20;
const VDBE_COVERAGE = 21;
const BYTEORDER = 22;
const ISINIT = 23;
const SORTER_MMAP = 24;
const IMPOSTER = 25;
const PARSER_COVERAGE = 26;
const RESULT_INTREAL = 27;
const PRNG_SEED = 28;
const EXTRA_SCHEMA_CHECKS = 29;
const SEEK_COUNT = 30;
const TRACEFLAGS = 31;
const TUNE = 32;
const LOGEST = 33;
const ATOF = 34;

fn dbArg(p: ?*anyopaque) ?*Handle {
    return @ptrCast(@alignCast(p));
}

fn out(comptime T: type, p: ?*anyopaque) ?*T {
    return @ptrCast(@alignCast(p));
}

/// sqlite3_test_control() with its arguments taken out of the varargs.
pub fn xq_test_control(op: c_int, a: *const Args) callconv(.c) c_int {
    const tc = &global.testctrl;
    switch (op) {
        PRNG_SAVE => {
            const prng = &global.prng;
            while (prng.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
            defer prng.lock.store(false, .release);
            tc.saved_s = prng.s;
            tc.saved_out = prng.out;
            tc.saved_n = prng.n;
        },
        PRNG_RESTORE => {
            const prng = &global.prng;
            while (prng.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
            defer prng.lock.store(false, .release);
            prng.s = tc.saved_s;
            prng.out = tc.saved_out;
            prng.n = tc.saved_n;
        },
        PRNG_SEED => {
            // The schema cookie of the database, if it has one, else x.
            var x: u32 = @truncate(@as(u64, @bitCast(a.i[0])));
            if (dbArg(a.p[0])) |db| {
                const lk = c.lock(db);
                defer lk.unlock();
                const y: u32 = @bitCast(db.dbs.items[0].schema.schema_cookie);
                if (y != 0) x = y;
            }
            tc.prng_seed = x;
            @import("../sql/func/func.zig").randomness(null, &.{});
        },
        FK_NO_ACTION => {
            const db = dbArg(a.p[0]) orelse return 0;
            db.flags.FkNoAction = a.i[0] != 0;
        },
        FAULT_INSTALL => {
            // sqlite3FaultSim(0): the engine has no fault-simulation
            // points that would call it later.
            const f: ?*const fn (c_int) callconv(.c) c_int = @ptrCast(@alignCast(a.p[0]));
            if (f) |x| return x(0);
        },
        PENDING_BYTE => {
            // The pending byte is fixed (vfs.pending_byte): a new value
            // is not taken.
            return @intCast(c.vfs.pending_byte);
        },
        // assert() and ALWAYS() of a release build.
        ASSERT => return 0,
        ALWAYS => return @truncate(a.i[0]),
        BYTEORDER => return if (builtin.cpu.arch.endian() == .little) 1234 * 100 + 10 else 4321 * 100 + 1,
        OPTIMIZATIONS => {
            const db = dbArg(a.p[0]) orelse return 0;
            db.db_opt_flags = @truncate(@as(u64, @bitCast(a.i[0])));
        },
        GETOPT => {
            const db = dbArg(a.p[0]) orelse return 0;
            if (out(c_int, a.p[1])) |n| n.* = @bitCast(db.db_opt_flags);
        },
        LOCALTIME_FAULT => {
            tc.localtime_fault = @truncate(a.i[0]);
            tc.alt_localtime = if (tc.localtime_fault == 2) @ptrCast(@alignCast(a.p[0])) else null;
        },
        INTERNAL_FUNCTIONS => {
            const db = dbArg(a.p[0]) orelse return 0;
            db.m_db_flags.InternalFunc = !db.m_db_flags.InternalFunc;
        },
        ONCE_RESET_THRESHOLD => tc.once_reset_threshold = @truncate(a.i[0]),
        // The storage layer's checks of a valid file, in builds with
        // runtime safety (SQLite's CORRUPT_DB asserts).
        NEVER_CORRUPT => @import("xqlite_storage").corrupt.never_corrupt = a.i[0] != 0,
        ISINIT => {
            if (!@atomicLoad(bool, &c.state.initialized, .acquire)) return RC.ERROR;
        },
        IMPOSTER => {
            const db = dbArg(a.p[0]) orelse return 0;
            const lk = c.lock(db);
            defer lk.unlock();
            const name: ?[*:0]const u8 = @ptrCast(a.p[1]);
            if (build.findDbName(db, c.span(name))) |i_db| {
                db.init.i_db = @intCast(i_db);
                const on: u2 = @truncate(@as(u64, @bitCast(a.i[0])));
                db.init.imposter_table = on;
                db.init.busy = on != 0;
                db.init.new_tnum = @truncate(@as(u64, @bitCast(a.i[1])));
                if (!db.init.busy and db.init.new_tnum > 0) build.resetAllSchemasOfConnection(db);
            }
        },
        RESULT_INTREAL => {
            // sqlite3ResultIntReal().
            const ctx: *c.Context = @ptrCast(@alignCast(a.p[0] orelse return 0));
            if (ctx.out.flags.Int) {
                ctx.out.flags.Int = false;
                ctx.out.flags.IntReal = true;
            }
        },
        SEEK_COUNT => {
            // Seeks are counted only by SQLITE_DEBUG builds.
            if (out(u64, a.p[1])) |n| n.* = 0;
        },
        TRACEFLAGS => {
            // sqlite3TreeTrace and sqlite3WhereTrace: debugging builds.
            if (@mod(a.i[0], 2) == 0) if (out(u32, a.p[0])) |p| {
                p.* = 0;
            };
        },
        LOGEST => {
            const util = c.util;
            const est = util.logEstFromDouble(a.r);
            if (out(c_int, a.p[0])) |p| p.* = est;
            const n = util.logEstToInt(est);
            if (out(u64, a.p[1])) |p| p.* = n;
            if (out(c_int, a.p[2])) |p| p.* = util.logEst(n);
        },
        ATOF => {
            const z: [*:0]const u8 = @ptrCast(a.p[0] orelse return 0);
            var r: f64 = 0;
            const rc = numeric.atoF(z, &r);
            if (out(f64, a.p[1])) |p| p.* = r;
            return rc;
        },
        // Accepted without effect: what a release build ignores
        // (JSON_SELFCHECK, VDBE_COVERAGE, PARSER_COVERAGE, TUNE), and the hooks the engine
        // has no counterpart for (BITVEC_TEST,
        // BENIGN_MALLOC_HOOKS, SORTER_MMAP, EXTRA_SCHEMA_CHECKS).
        else => {},
    }
    return 0;
}

comptime {
    @export(&xq_test_control, .{ .name = "xq_test_control", .visibility = .hidden });
}
