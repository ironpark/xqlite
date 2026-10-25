//! ANALYZE (port of analyze.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3Analyze().
pub fn analyze(p: *Parse, name1: ?int.Token, name2: ?int.Token) void {
    _ = .{ name1, name2 };
    pending.notYet(p, "ANALYZE");
}

/// Port of sqlite3AnalysisLoad(): read sqlite_stat1. Not ported yet.
pub fn analysisLoad(db: *int.Sqlite3, i_db: usize) i32 {
    _ = .{ db, i_db };
    return int.RC.OK;
}
