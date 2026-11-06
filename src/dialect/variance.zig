//! The variance aggregates xq_var_samp(x), xq_var_pop(),
//! xq_stddev_samp() and xq_stddev_pop() that MariaDB, SQL Server and
//! Oracle lower VARIANCE, STDDEV and the like to: a double, NULL with no
//! rows (and the sample ones with one). Engine functions outside the
//! dialect directories, so that a build with any set of dialects
//! (-Ddialects) has them.

const api = @import("../vdbe/api.zig");
const int = @import("../sql/sqlite_int.zig");
const dfunc = @import("func.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const isNull = dfunc.isNull;

const det: dfunc.Options = .{ .deterministic = true };

/// Hooks.engine_functions of no dialect: dialect.zig adds them.
pub const engine_functions = [_]int.FuncDef{
    dfunc.aggregate("xq_stddev_pop", 1, det, varStep, stddevPopFinal),
    dfunc.aggregate("xq_stddev_samp", 1, det, varStep, stddevSampFinal),
    dfunc.aggregate("xq_var_pop", 1, det, varStep, varPopFinal),
    dfunc.aggregate("xq_var_samp", 1, det, varStep, varSampFinal),
};

const Moments = struct { n: f64 = 0, mean: f64 = 0, m2: f64 = 0 };

/// Welford's running variance.
fn varStep(ctx: *Context, argv: []*Mem) void {
    const m = dfunc.aggState(Moments, ctx, true) orelse return;
    if (isNull(argv[0])) return;
    const x = api.valueDouble(argv[0]);
    m.n += 1;
    const d = x - m.mean;
    m.mean += d / m.n;
    m.m2 += d * (x - m.mean);
}

fn varFinal(comptime sample: bool, comptime root: bool) dfunc.FinalFn {
    return struct {
        fn call(ctx: *Context) void {
            const m = dfunc.aggState(Moments, ctx, false) orelse return api.resultNull(ctx);
            const div = if (sample) m.n - 1 else m.n;
            if (div <= 0) return api.resultNull(ctx);
            const v = m.m2 / div;
            api.resultDouble(ctx, if (root) @sqrt(v) else v);
        }
    }.call;
}

const stddevPopFinal = varFinal(false, true);
const stddevSampFinal = varFinal(true, true);
const varPopFinal = varFinal(false, false);
const varSampFinal = varFinal(true, false);
