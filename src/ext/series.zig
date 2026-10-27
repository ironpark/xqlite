//! The generate_series() table-valued function (port of ext/misc/series.c),
//! which the sqlite3 shell registers.
//!
//! generate_series(start, stop, step) is the eponymous virtual table
//!
//!     CREATE TABLE x(value, start HIDDEN, stop HIDDEN, step HIDDEN)
//!
//! whose rows are start, start+step, ... up to stop (4294967295 if
//! omitted; step defaults to 1, and 0 means 1). Its rowid is the value.
//! Constraints on the value column narrow the range, and LIMIT and OFFSET
//! are applied by the table itself.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const vtab = @import("../sql/vtab.zig");
const api = @import("../vdbe/api.zig");

const Sqlite3 = int.Sqlite3;
const Mem = vi.Mem;
const RC = int.RC;
const IC = vtab.INDEX_CONSTRAINT;

/// The virtual table object: the base and the connection.
const SeriesVtab = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
};

/// A cursor (series_cursor). i_obase, i_oterm and i_ostep are the start,
/// stop and step constraints of the query, which the hidden columns
/// report; i_base, i_term, i_step and b_desc are the sequence actually
/// generated. The step is unsigned so that it can be
/// +9223372036854775808.
const SeriesCursor = struct {
    base: vtab.VtabCursor = .{},
    gpa: std.mem.Allocator,
    /// Original starting value ("start").
    i_obase: i64 = 0,
    /// Original terminal value ("stop").
    i_oterm: i64 = 0,
    /// Original step value.
    i_ostep: i64 = 0,
    /// Starting value to actually use.
    i_base: i64 = 0,
    /// Terminal value to actually use.
    i_term: i64 = 0,
    /// The step size.
    i_step: u64 = 0,
    /// Current value.
    i_value: i64 = 0,
    /// i_step is really negative.
    b_desc: bool = false,
    /// Stepped past the last element.
    b_done: bool = false,

    fn of(cur: *vtab.VtabCursor) *SeriesCursor {
        return @fieldParentPtr("base", cur);
    }
};

/// Column numbers.
const COLUMN_ROWID = -1;
const COLUMN_VALUE = 0;
const COLUMN_START = 1;
const COLUMN_STOP = 2;
const COLUMN_STEP = 3;

const LARGEST_INT64: i64 = std.math.maxInt(i64);
const SMALLEST_INT64: i64 = std.math.minInt(i64);

/// Port of span64(): a-b, for a>=b, without overflow.
fn span64(a: i64, b: i64) u64 {
    std.debug.assert(a >= b);
    return @as(u64, @bitCast(a)) -% @as(u64, @bitCast(b));
}

/// Port of add64().
fn add64(a: i64, b: u64) i64 {
    return @bitCast(@as(u64, @bitCast(a)) +% b);
}

/// Port of sub64().
fn sub64(a: i64, b: u64) i64 {
    return @bitCast(@as(u64, @bitCast(a)) -% b);
}

/// Port of seriesConnect().
fn seriesConnect(db: *Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const rc = vtab.declareVtab(db, "CREATE TABLE x(value,start hidden,stop hidden,step hidden)");
    if (rc == RC.OK) {
        const new = db.gpa.create(SeriesVtab) catch return RC.NOMEM;
        new.* = .{ .db = db };
        pp_vtab.* = &new.base;
        _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
    }
    return rc;
}

/// Port of seriesDisconnect().
fn seriesDisconnect(p: *vtab.Vtab) i32 {
    const t: *SeriesVtab = @fieldParentPtr("base", p);
    t.db.gpa.destroy(t);
    return RC.OK;
}

/// Port of seriesOpen().
fn seriesOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t: *SeriesVtab = @fieldParentPtr("base", p);
    const cur = t.db.gpa.create(SeriesCursor) catch return RC.NOMEM;
    cur.* = .{ .gpa = t.db.gpa };
    pp_cursor.* = &cur.base;
    return RC.OK;
}

/// Port of seriesClose().
fn seriesClose(cur: *vtab.VtabCursor) i32 {
    const c = SeriesCursor.of(cur);
    c.gpa.destroy(c);
    return RC.OK;
}

/// Port of seriesNext().
fn seriesNext(cur: *vtab.VtabCursor) i32 {
    const c = SeriesCursor.of(cur);
    if (c.i_value == c.i_term) {
        c.b_done = true;
    } else if (c.b_desc) {
        c.i_value = sub64(c.i_value, c.i_step);
        std.debug.assert(c.i_value >= c.i_term);
    } else {
        c.i_value = add64(c.i_value, c.i_step);
        std.debug.assert(c.i_value <= c.i_term);
    }
    return RC.OK;
}

/// Port of seriesColumn().
fn seriesColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i: i32) i32 {
    const c = SeriesCursor.of(cur);
    const x: i64 = switch (i) {
        COLUMN_START => c.i_obase,
        COLUMN_STOP => c.i_oterm,
        COLUMN_STEP => c.i_ostep,
        else => c.i_value,
    };
    api.resultInt64(ctx, x);
    return RC.OK;
}

/// Port of seriesRowid(): the rowid is the value.
fn seriesRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = SeriesCursor.of(cur).i_value;
    return RC.OK;
}

/// Port of seriesEof().
fn seriesEof(cur: *vtab.VtabCursor) bool {
    return SeriesCursor.of(cur).b_done;
}

/// Port of seriesSteps(): the steps from i_base to i_term.
fn seriesSteps(c: *const SeriesCursor) u64 {
    if (c.b_desc) {
        std.debug.assert(c.i_base >= c.i_term);
        return span64(c.i_base, c.i_term) / c.i_step;
    } else {
        std.debug.assert(c.i_base <= c.i_term);
        return span64(c.i_term, c.i_base) / c.i_step;
    }
}

/// Port of seriesRealToI64(): the closest integer to `r`.
fn seriesRealToI64(r: f64) i64 {
    if (r < -9223372036854774784.0) return SMALLEST_INT64;
    if (r > 9223372036854774784.0) return LARGEST_INT64;
    return @intFromFloat(r);
}

/// Port of seriesFilter(): start a scan. idx_num is the plan of
/// seriesBestIndex():
///
///   0x0001 start=VALUE    0x0020 LIMIT VALUE     0x0200 value>VALUE
///   0x0002 stop=VALUE     0x0040 OFFSET VALUE    0x1000 value<=VALUE
///   0x0004 step=VALUE     0x0080 value=VALUE     0x2000 value<VALUE
///   0x0008 descending     0x0100 value>=VALUE
///   0x0010 ascending
fn seriesFilter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c = SeriesCursor.of(cur);
    filter(c, idx_num, argv) catch {
        // series_no_rows:
        c.i_base = 0;
        c.i_term = 0;
        c.i_step = 1;
        c.b_desc = false;
        c.b_done = true;
    };
    return RC.OK;
}

/// The body of seriesFilter(); error.NoRows is "goto series_no_rows".
fn filter(c: *SeriesCursor, idx_num: i32, argv: []*Mem) error{NoRows}!void {
    var i_arg: usize = 0;
    var i_min: i64 = SMALLEST_INT64;
    var i_max: i64 = LARGEST_INT64;
    var i_limit: i64 = 0;
    var i_offset: i64 = 0;

    // A NULL constraint means no rows (ticket fac496b61722daf2).
    for (argv) |a| {
        if (api.valueType(a) == vi.SQLITE_NULL) return error.NoRows;
    }

    // The three HIDDEN parameters, with defaults for those omitted.
    if (idx_num & 0x01 != 0) {
        c.i_obase = api.valueInt64(argv[i_arg]);
        i_arg += 1;
    } else {
        c.i_obase = 0;
    }
    if (idx_num & 0x02 != 0) {
        c.i_oterm = api.valueInt64(argv[i_arg]);
        i_arg += 1;
    } else {
        c.i_oterm = 0xffffffff;
    }
    if (idx_num & 0x04 != 0) {
        c.i_ostep = api.valueInt64(argv[i_arg]);
        i_arg += 1;
        if (c.i_ostep == 0) c.i_ostep = 1;
    } else {
        c.i_ostep = 1;
    }

    // With constraints on value but not on start, stop and step, the
    // default range is all 64-bit integers, which they narrow below.
    if (idx_num & 0x05 == 0 and idx_num & 0x0380 != 0) c.i_obase = SMALLEST_INT64;
    if (idx_num & 0x06 == 0 and idx_num & 0x3080 != 0) c.i_oterm = LARGEST_INT64;
    c.i_base = c.i_obase;
    c.i_term = c.i_oterm;
    if (c.i_ostep > 0) {
        c.i_step = @intCast(c.i_ostep);
    } else if (c.i_ostep > SMALLEST_INT64) {
        c.i_step = @intCast(-c.i_ostep);
    } else {
        c.i_step = @as(u64, @intCast(LARGEST_INT64)) + 1;
    }
    c.b_desc = c.i_ostep < 0;
    if (!c.b_desc and c.i_base > c.i_term) return error.NoRows;
    if (c.b_desc and c.i_base < c.i_term) return error.NoRows;

    // LIMIT and OFFSET, applied after the value constraints.
    if (idx_num & 0x20 != 0) {
        i_limit = api.valueInt64(argv[i_arg]);
        i_arg += 1;
        if (idx_num & 0x40 != 0) {
            i_offset = api.valueInt64(argv[i_arg]);
            i_arg += 1;
        }
    }

    // Narrow [i_min, i_max] by the constraints on the value column.
    if (idx_num & 0x3380 != 0) {
        if (idx_num & 0x0080 != 0) {
            // value=X
            if (api.valueNumericType(argv[i_arg]) == vi.SQLITE_FLOAT) {
                const r = api.valueDouble(argv[i_arg]);
                i_arg += 1;
                if (r == @ceil(r) and r >= @as(f64, @floatFromInt(SMALLEST_INT64)) and r <= @as(f64, @floatFromInt(LARGEST_INT64))) {
                    i_min = seriesRealToI64(r);
                    i_max = i_min;
                } else {
                    return error.NoRows;
                }
            } else {
                i_min = api.valueInt64(argv[i_arg]);
                i_max = i_min;
                i_arg += 1;
            }
        } else {
            if (idx_num & 0x0300 != 0) {
                // value>X (0x200) or value>=X (0x100)
                if (api.valueNumericType(argv[i_arg]) == vi.SQLITE_FLOAT) {
                    const r = api.valueDouble(argv[i_arg]);
                    i_arg += 1;
                    if (r <= @as(f64, @floatFromInt(SMALLEST_INT64))) {
                        i_min = SMALLEST_INT64;
                    } else if (r > @as(f64, @floatFromInt(LARGEST_INT64))) {
                        return error.NoRows;
                    } else {
                        i_min = seriesRealToI64(@ceil(r));
                        if (idx_num & 0x0200 != 0 and r == @ceil(r)) {
                            if (i_min == LARGEST_INT64) return error.NoRows;
                            i_min += 1;
                        }
                    }
                } else {
                    i_min = api.valueInt64(argv[i_arg]);
                    i_arg += 1;
                    if (idx_num & 0x0200 != 0) {
                        if (i_min == LARGEST_INT64) return error.NoRows;
                        i_min += 1;
                    }
                }
            }
            if (idx_num & 0x3000 != 0) {
                // value<X (0x2000) or value<=X (0x1000)
                if (api.valueNumericType(argv[i_arg]) == vi.SQLITE_FLOAT) {
                    const r = api.valueDouble(argv[i_arg]);
                    i_arg += 1;
                    if (r >= @as(f64, @floatFromInt(LARGEST_INT64))) {
                        i_max = LARGEST_INT64;
                    } else if (r <= @as(f64, @floatFromInt(SMALLEST_INT64))) {
                        return error.NoRows;
                    } else {
                        i_max = seriesRealToI64(@floor(r));
                        if (idx_num & 0x2000 != 0 and r == @floor(r)) {
                            if (i_max == SMALLEST_INT64) return error.NoRows;
                            i_max -= 1;
                        }
                    }
                } else {
                    i_max = api.valueInt64(argv[i_arg]);
                    i_arg += 1;
                    if (idx_num & 0x2000 != 0) {
                        if (i_max == SMALLEST_INT64) return error.NoRows;
                        i_max -= 1;
                    }
                }
            }
            if (i_min > i_max) return error.NoRows;
        }

        // Reduce the range generated by the constraints on value.
        if (!c.b_desc) {
            if (c.i_base < i_min) {
                const span = span64(i_min, c.i_base);
                c.i_base = add64(c.i_base, (span / c.i_step) *% c.i_step);
                if (c.i_base < i_min) {
                    if (c.i_base > sub64(LARGEST_INT64, c.i_step)) return error.NoRows;
                    c.i_base = add64(c.i_base, c.i_step);
                }
            }
            if (c.i_term > i_max) c.i_term = i_max;
        } else {
            if (c.i_base > i_max) {
                const span = span64(c.i_base, i_max);
                c.i_base = sub64(c.i_base, (span / c.i_step) *% c.i_step);
                if (c.i_base > i_max) {
                    if (c.i_base < add64(SMALLEST_INT64, c.i_step)) return error.NoRows;
                    c.i_base = sub64(c.i_base, c.i_step);
                }
            }
            if (c.i_term < i_min) c.i_term = i_min;
        }
    }

    // Make i_term exactly the last value of the series.
    if (!c.b_desc) {
        if (c.i_base > c.i_term) return error.NoRows;
        c.i_term = sub64(c.i_term, span64(c.i_term, c.i_base) % c.i_step);
    } else {
        if (c.i_base < c.i_term) return error.NoRows;
        c.i_term = add64(c.i_term, span64(c.i_base, c.i_term) % c.i_step);
    }

    // Output in the order requested.
    if ((idx_num & 0x0008 != 0 and !c.b_desc) or (idx_num & 0x0010 != 0 and c.b_desc)) {
        std.mem.swap(i64, &c.i_base, &c.i_term);
        c.b_desc = !c.b_desc;
    }

    // Apply LIMIT and OFFSET.
    std.debug.assert(c.i_step != 0);
    if (idx_num & 0x20 != 0) {
        if (i_offset > 0) {
            if (seriesSteps(c) < @as(u64, @bitCast(i_offset))) {
                return error.NoRows;
            } else if (c.b_desc) {
                c.i_base = sub64(c.i_base, c.i_step *% @as(u64, @bitCast(i_offset)));
            } else {
                c.i_base = add64(c.i_base, c.i_step *% @as(u64, @bitCast(i_offset)));
            }
        }
        if (i_limit >= 0 and seriesSteps(c) > @as(u64, @bitCast(i_limit))) {
            c.i_term = add64(c.i_base, @as(u64, @bitCast(i_limit -% 1)) *% c.i_step);
        }
    }
    c.i_value = c.i_base;
    c.b_done = false;
}

/// Port of seriesBestIndex(). The plan bits of idx_num are those of
/// seriesFilter(); xFilter takes, in this order, the arguments of start=,
/// stop=, step=, LIMIT, OFFSET, value= (or value>=, value>) and value<=
/// (or value<) when the plan has them.
fn seriesBestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    var idx_num: i32 = 0;
    var b_start_seen = false;
    var unusable_mask: i32 = 0;
    var n_arg: i32 = 0;
    // The constraints on start, stop, step, LIMIT, OFFSET and value:
    // a_idx[5] is value=, value>= or value>; a_idx[6] value<= or value<.
    var a_idx: [7]i32 = @splat(-1);

    for (info.constraints, 0..) |cons, ci| {
        const i: i32 = @intCast(ci);
        const op = cons.op;
        if (op >= IC.LIMIT and op <= IC.OFFSET) {
            if (!cons.usable) {
                // Nothing.
            } else if (op == IC.LIMIT) {
                a_idx[3] = i;
                idx_num |= 0x20;
            } else {
                std.debug.assert(op == IC.OFFSET);
                a_idx[4] = i;
                idx_num |= 0x40;
            }
            continue;
        }
        if (cons.i_column < COLUMN_START) {
            if ((cons.i_column == COLUMN_VALUE or cons.i_column == COLUMN_ROWID) and cons.usable) {
                switch (op) {
                    IC.EQ, IC.IS => {
                        idx_num |= 0x0080;
                        idx_num &= ~@as(i32, 0x3300);
                        a_idx[5] = i;
                        a_idx[6] = -1;
                        b_start_seen = true;
                    },
                    IC.GE => if (idx_num & 0x0080 == 0) {
                        idx_num |= 0x0100;
                        idx_num &= ~@as(i32, 0x0200);
                        a_idx[5] = i;
                        b_start_seen = true;
                    },
                    IC.GT => if (idx_num & 0x0080 == 0) {
                        idx_num |= 0x0200;
                        idx_num &= ~@as(i32, 0x0100);
                        a_idx[5] = i;
                        b_start_seen = true;
                    },
                    IC.LE => if (idx_num & 0x0080 == 0) {
                        idx_num |= 0x1000;
                        idx_num &= ~@as(i32, 0x2000);
                        a_idx[6] = i;
                    },
                    IC.LT => if (idx_num & 0x0080 == 0) {
                        idx_num |= 0x2000;
                        idx_num &= ~@as(i32, 0x1000);
                        a_idx[6] = i;
                    },
                    else => {},
                }
            }
            continue;
        }
        const i_col = cons.i_column - COLUMN_START;
        std.debug.assert(i_col >= 0 and i_col <= 2);
        const i_mask = @as(i32, 1) << @intCast(i_col);
        if (i_col == 0 and op == IC.EQ) b_start_seen = true;
        if (!cons.usable) {
            unusable_mask |= i_mask;
            continue;
        } else if (op == IC.EQ) {
            idx_num |= i_mask;
            a_idx[@intCast(i_col)] = i;
        }
    }
    if (a_idx[3] == 0) {
        // OFFSET without LIMIT is ignored.
        idx_num &= ~@as(i32, 0x60);
        a_idx[4] = 0;
    }
    for (a_idx) |j| {
        if (j >= 0) {
            n_arg += 1;
            info.usage[@intCast(j)].argv_index = n_arg;
            // SQLITE_SERIES_CONSTRAINT_VERIFY is 0.
            info.usage[@intCast(j)].omit = true;
        }
    }
    // At least the start argument is required (without
    // ZERO_ARGUMENT_GENERATE_SERIES).
    if (!b_start_seen) {
        const t: *SeriesVtab = @fieldParentPtr("base", p);
        vtab.setErrMsg(t.db, p, "first argument to \"generate_series()\" missing or unusable", .{});
        return RC.ERROR;
    }
    if (unusable_mask & ~idx_num != 0) {
        // start, stop and step are inputs: unusable constraints on them
        // make the plan unusable.
        return RC.CONSTRAINT;
    }
    if (idx_num & 0x03 == 0x03) {
        // Both start= and stop=: the preferred case.
        info.estimated_cost = @floatFromInt(2 - @as(i32, @intFromBool(idx_num & 4 != 0)));
        info.estimated_rows = 1000;
        if (info.order_by.len >= 1 and info.order_by[0].i_column == 0) {
            if (info.order_by[0].desc) {
                idx_num |= 0x08;
            } else {
                idx_num |= 0x10;
            }
            info.order_by_consumed = true;
        }
    } else if (idx_num & 0x21 == 0x21) {
        // start= and LIMIT.
        info.estimated_rows = 2500;
    } else {
        // A bound is missing: a huge span of numbers, made very expensive
        // so that the planner works hard to avoid it.
        info.estimated_rows = 2147483647;
    }
    info.idx_num = idx_num;
    info.idx_flags = vtab.INDEX_SCAN_HEX;
    return RC.OK;
}

/// The generate_series module (seriesModule).
pub const module: vtab.Module = .{
    .i_version = 0,
    .x_create = null,
    .x_connect = seriesConnect,
    .x_best_index = seriesBestIndex,
    .x_disconnect = seriesDisconnect,
    .x_destroy = null,
    .x_open = seriesOpen,
    .x_close = seriesClose,
    .x_filter = seriesFilter,
    .x_next = seriesNext,
    .x_eof = seriesEof,
    .x_column = seriesColumn,
    .x_rowid = seriesRowid,
};

/// Port of sqlite3_series_init(): register generate_series on `db`.
pub fn init(db: *Sqlite3) i32 {
    return vtab.createModule(db, "generate_series", &module, null);
}
