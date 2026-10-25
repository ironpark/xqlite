//! INSERT statements (port of insert.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const select_mod = @import("select.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const Select = int.Select;
const Upsert = int.Upsert;
const Oom = int.Oom;
const SF = int.SF;
const TK = int.TK;

/// Port of sqlite3MultiValuesEnd().
pub fn multiValuesEnd(p: *Parse, val: ?*Select) void {
    _ = .{ p, val };
}

/// Port of sqlite3MultiValues(): add a row to a multi-row VALUES clause.
/// Only the "UNION ALL" method is ported; SQLite codes most VALUES lists
/// as a co-routine instead, which the code generator will do.
pub fn multiValues(p: *Parse, left_arg: *Select, row: ?*ExprList) Oom!*Select {
    var left = left_arg;
    var f: u32 = SF.Values | SF.MultiValue;
    if (left.src.?.len() != 0) {
        multiValuesEnd(p, left);
        f = SF.Values;
    } else if (left.prior != null) {
        f &= left.sel_flags;
    }
    const s = try select_mod.selectNew(p, row, null, null, null, null, null, f, null);
    left.sel_flags &= ~SF.MultiValue;
    s.op = TK.ALL;
    s.prior = left;
    left = s;
    return left;
}

/// Port of sqlite3Insert().
pub fn insert(p: *Parse, tab_list: ?*SrcList, sel: ?*Select, column: ?*IdList, on_error: i32, upsert: ?*Upsert) void {
    _ = .{ tab_list, sel, column, on_error, upsert };
    pending.notYet(p, "INSERT");
}
