//! ANALYZE (port of analyze.c). Only reading sqlite_stat1 is ported;
//! ANALYZE itself and sqlite_stat4 (SQLITE_ENABLE_STAT4) are not.

const std = @import("std");
const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");
const build = @import("build.zig");
const legacy = @import("legacy.zig");
const util = @import("util.zig");
const printf = @import("printf.zig");

const Parse = int.Parse;
const Index = int.Index;
const LogEst = int.LogEst;

/// Port of sqlite3Analyze().
pub fn analyze(p: *Parse, name1: ?int.Token, name2: ?int.Token) void {
    _ = .{ name1, name2 };
    pending.notYet(p, "ANALYZE");
}

/// Port of decodeIntArray() (without STAT4): the first aLog.len integers
/// of the space-separated list `z` into `a_log` as LogEst, then the
/// "unordered", "sz=N" and "noskipscan" keywords into `idx`.
fn decodeIntArray(z_arg: []const u8, a_log: []LogEst, idx: *Index) void {
    var z = z_arg;
    var i: usize = 0;
    while (z.len > 0 and i < a_log.len) : (i += 1) {
        var v: u64 = 0;
        while (z.len > 0 and z[0] >= '0' and z[0] <= '9') : (z = z[1..]) v = v *% 10 +% (z[0] - '0');
        a_log[i] = util.logEst(v);
        if (z.len > 0 and z[0] == ' ') z = z[1..];
    }
    idx.unordered = false;
    idx.no_skip_scan = false;
    while (z.len > 0) {
        if (std.mem.startsWith(u8, z, "unordered")) {
            idx.unordered = true;
        } else if (std.mem.startsWith(u8, z, "sz=") and z.len > 3 and z[3] >= '0' and z[3] <= '9') {
            const sz = util.getInt32(z[3..]) orelse 0;
            idx.sz_idx_row = util.logEst(@intCast(@max(sz, 2)));
        } else if (std.mem.startsWith(u8, z, "noskipscan")) {
            idx.no_skip_scan = true;
        }
        while (z.len > 0 and z[0] != ' ') z = z[1..];
        while (z.len > 0 and z[0] == ' ') z = z[1..];
    }
}

const LoadInfo = struct {
    db: *int.Sqlite3,
    database: []const u8,
};

/// Port of analysisLoader(): one row (tbl, idx, stat) of sqlite_stat1.
fn analysisLoader(ctx: ?*anyopaque, values: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
    const info: *LoadInfo = @ptrCast(@alignCast(ctx.?));
    if (values.len < 3) return false;
    const tbl = std.mem.span(values[0] orelse return false);
    const stat = std.mem.span(values[2] orelse return false);
    const t = build.findTable(info.db, tbl, info.database) orelse return false;
    const idx: ?*Index = if (values[1]) |iname| blk: {
        const name = std.mem.span(iname);
        if (std.ascii.eqlIgnoreCase(tbl, name)) break :blk build.primaryKeyIndex(t);
        break :blk build.findIndex(info.db, name, info.database);
    } else null;
    if (idx) |ix| {
        ix.unordered = false;
        decodeIntArray(stat, ix.ai_row_log_est[0 .. @as(usize, ix.n_key_col) + 1], ix);
        ix.has_stat1 = true;
        if (ix.part_idx_where == null) {
            t.n_row_log_est = ix.ai_row_log_est[0];
            t.tab_flags |= int.TF.HasStat1;
        }
    } else {
        var fake: Index = .{ .name = undefined, .table = t, .sz_idx_row = t.sz_tab_row };
        decodeIntArray(stat, (&t.n_row_log_est)[0..1], &fake);
        t.sz_tab_row = fake.sz_idx_row;
        t.tab_flags |= int.TF.HasStat1;
    }
    return false;
}

/// Port of sqlite3AnalysisLoad(): read sqlite_stat1 of database `i_db`
/// into the row estimates of its tables and indexes, and give the
/// default estimates to indexes without statistics.
pub fn analysisLoad(db: *int.Sqlite3, i_db: usize) i32 {
    const schema = db.dbs.items[i_db].schema;
    var rc: i32 = int.RC.OK;

    // Clear any prior statistics.
    var tit = schema.tbl_hash.valueIterator();
    while (tit.next()) |t| t.*.tab_flags &= ~int.TF.HasStat1;
    var iit = schema.idx_hash.valueIterator();
    while (iit.next()) |ix| ix.*.has_stat1 = false;

    // Load new statistics out of the sqlite_stat1 table.
    var info: LoadInfo = .{ .db = db, .database = db.dbs.items[i_db].name };
    if (build.findTable(db, "sqlite_stat1", info.database)) |stat1| if (stat1.isOrdinary()) {
        const sql = printf.mprintf(db.gpa, "SELECT tbl,idx,stat FROM %Q.sqlite_stat1", &.{.{ .str = info.database }}) catch {
            db.malloc_failed = true;
            return int.RC.NOMEM;
        };
        defer db.gpa.free(sql);
        rc = legacy.exec(db, sql, analysisLoader, &info, null);
    };

    // Set appropriate defaults on all indexes not in sqlite_stat1.
    iit = schema.idx_hash.valueIterator();
    while (iit.next()) |ix| if (!ix.*.has_stat1) build.defaultRowEst(ix.*);

    if (rc == int.RC.NOMEM) db.malloc_failed = true;
    return rc;
}
