//! percentile_cont(float8[]) and percentile_disc(float8[]) WITHIN GROUP
//! (ORDER BY x): the percentiles of an array of fractions, an array of
//! the same shape (NULL for a NULL fraction), over stats.zig's sorted
//! rows. overload.zig (repr/numeric.zig) calls them for an array:
//!
//!   xq_pg_percentile_cont_arr(fractions, x)   x a double
//!   xq_pg_percentile_disc_arr(fractions, x)   the values' text (array.zig)

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const int = @import("../../sql/sqlite_int.zig");
const stats = @import("../stats.zig");
const array = @import("array.zig");
const valuetext = @import("../valuetext.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

const det: dfunc.Options = .{ .deterministic = true };

pub const engine_functions = [_]int.FuncDef{
    dfunc.aggregate("xq_pg_percentile_cont_arr", 2, det, stats.contStep, dfunc_final(true)),
    dfunc.aggregate("xq_pg_percentile_disc_arr", 2, det, stats.discStep, dfunc_final(false)),
};

fn dfunc_final(comptime cont: bool) dfunc.FinalFn {
    return struct {
        fn f(ctx: *Context) void {
            final(ctx, cont);
        }
    }.f;
}

fn final(ctx: *Context, cont: bool) void {
    const g = stats.finalGroup(ctx) orelse return;
    defer g.deinit(ctx);
    const fm = g.fraction() orelse return api.resultNull(ctx);
    var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
    defer arena.deinit();
    const a = arena.allocator();
    const z = dfunc.text(ctx, fm) orelse return;
    var detail: ?[]const u8 = null;
    var x = array.parseWith(a, z, false, &detail) catch |err| {
        if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
        return array.malformedError(ctx, a, z, detail);
    };
    const out = a.alloc(?[]const u8, x.elems.len) catch return api.resultErrorNomem(ctx);
    // PostgreSQL checks every fraction first.
    const ps = a.alloc(?f64, x.elems.len) catch return api.resultErrorNomem(ctx);
    for (x.elems, ps) |e, *p| {
        p.* = null;
        const t = e orelse continue;
        const v = array.parseFloat(t) orelse {
            const msg = std.fmt.allocPrint(a, "invalid input syntax for type double precision: \"{s}\"", .{t}) catch return api.resultErrorNomem(ctx);
            return api.resultErrorState(ctx, .of("22P02"), msg);
        };
        if (!stats.checkFraction(ctx, v)) return;
        p.* = v;
    }
    for (ps, out) |p, *o| {
        const v = p orelse {
            o.* = null;
            continue;
        };
        if (cont) {
            var buf: [64]u8 = undefined;
            o.* = a.dupe(u8, valuetext.floatText(&buf, stats.contOf(g.doubles(), v), false)) catch return api.resultErrorNomem(ctx);
        } else {
            const vs = g.values();
            var fail: array.Fail = undefined;
            o.* = array.valueElem(a, .{}, vs[stats.discIndex(vs.len, v)], &fail) catch |err| switch (err) {
                error.OutOfMemory => return api.resultErrorNomem(ctx),
                error.Invalid => return api.resultErrorState(ctx, .{ .sqlstate = fail.state.* }, fail.msg),
            };
        }
    }
    x.elems = out;
    const text = array.write(a, &x) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, text, .transient);
}
