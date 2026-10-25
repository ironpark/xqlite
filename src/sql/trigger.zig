//! Triggers (port of trigger.c). This part builds trigger steps during
//! parsing; creating and coding triggers comes later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const build = @import("build.zig");
const select_mod = @import("select.zig");
const ctype = @import("../util/ctype.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const Select = int.Select;
const Upsert = int.Upsert;
const TriggerStep = int.TriggerStep;
const Token = int.Token;
const Oom = int.Oom;
const OE = int.OE;
const SF = int.SF;
const TK = int.TK;

/// Port of triggerSpanDup(): the statement text, whitespace turned into
/// plain spaces.
fn spanDup(p: *Parse, start: [*]const u8, end: [*]const u8) Oom![:0]u8 {
    const z = try expr_mod.spanDup(p.arena, start, end);
    for (z) |*c| if (ctype.isSpace(c.*)) {
        c.* = ' ';
    };
    return z;
}

/// Port of sqlite3TriggerSelectStep().
pub fn selectStep(p: *Parse, sel: ?*Select, start: [*]const u8, end: [*]const u8) Oom!*TriggerStep {
    const s = try p.arena.create(TriggerStep);
    s.* = .{ .op = TK.SELECT, .select = sel, .orconf = OE.Default, .span = try spanDup(p, start, end) };
    return s;
}

/// Port of triggerStepAllocate(). Steps stay in the statement arena; the
/// trigger is copied into the schema when it is created.
fn stepAllocate(p: *Parse, op: u8, tab_list: *SrcList, start: [*]const u8, end: [*]const u8) Oom!?*TriggerStep {
    if (p.n_err != 0) return null;
    if (p.new_trigger) |t| {
        if (t.schema != p.db.dbs.items[1].schema and tab_list.at(0).u4.database != null) {
            util.errorMsg(p, "qualified table names are not allowed on INSERT, UPDATE, and DELETE statements within triggers", .{});
            return null;
        }
    }
    const s = try p.arena.create(TriggerStep);
    s.* = .{ .op = op, .src = tab_list, .span = try spanDup(p, start, end) };
    return s;
}

/// Port of sqlite3TriggerInsertStep().
pub fn insertStep(
    p: *Parse,
    tab_list: *SrcList,
    columns: ?*IdList,
    sel: ?*Select,
    orconf: u8,
    upsert: ?*Upsert,
    start: [*]const u8,
    end: [*]const u8,
) Oom!?*TriggerStep {
    const s = (try stepAllocate(p, TK.INSERT, tab_list, start, end)) orelse return null;
    s.select = sel;
    s.id_list = columns;
    s.upsert = upsert;
    s.orconf = orconf;
    if (upsert) |u| _ = build.hasExplicitNulls(p, u.target);
    return s;
}

/// Port of sqlite3TriggerUpdateStep(). A FROM clause becomes one nested
/// subquery term after the target table.
pub fn updateStep(
    p: *Parse,
    tab_list: *SrcList,
    from: ?*SrcList,
    e_list: ?*ExprList,
    where: ?*Expr,
    orconf: u8,
    start: [*]const u8,
    end: [*]const u8,
) Oom!?*TriggerStep {
    const s = (try stepAllocate(p, TK.UPDATE, tab_list, start, end)) orelse return null;
    s.expr_list = e_list;
    s.where = where;
    s.orconf = orconf;
    var from_list = from;
    if (from_list != null and !p.inRenameObject()) {
        const sub = try select_mod.selectNew(p, null, from_list, null, null, null, null, SF.NestedFrom, null);
        from_list = try build.srcListAppendFromTerm(p, null, null, null, .{}, sub, null);
    }
    if (from_list) |f| if (s.src) |src| {
        s.src = try build.srcListAppendList(p, src, f);
    };
    return s;
}

/// Port of sqlite3TriggerDeleteStep().
pub fn deleteStep(p: *Parse, tab_list: *SrcList, where: ?*Expr, start: [*]const u8, end: [*]const u8) Oom!?*TriggerStep {
    const s = (try stepAllocate(p, TK.DELETE, tab_list, start, end)) orelse return null;
    s.where = where;
    s.orconf = OE.Default;
    return s;
}

// ============================================= statements (not ported yet)

const pending = @import("pending.zig");

/// Port of sqlite3BeginTrigger().
pub fn beginTrigger(p: *Parse, name1: Token, name2: Token, tr_tm: i32, op: i32, columns: ?*IdList, table_name: ?*SrcList, when: ?*Expr, is_temp: bool, no_err: bool) void {
    _ = .{ name1, name2, tr_tm, op, columns, table_name, when, is_temp, no_err };
    pending.notYet(p, "CREATE TRIGGER");
}

/// Port of sqlite3FinishTrigger().
pub fn finishTrigger(p: *Parse, step_list: ?*TriggerStep, all: Token) void {
    _ = .{ p, step_list, all };
}

/// Port of sqlite3DropTrigger().
pub fn dropTrigger(p: *Parse, name: ?*SrcList, no_err: bool) void {
    _ = .{ name, no_err };
    pending.notYet(p, "DROP TRIGGER");
}

/// Port of sqlite3UnlinkAndDeleteTrigger(). Not ported yet.
pub fn unlinkAndDeleteTrigger(db: *int.Sqlite3, i_db: usize, name: [:0]const u8) void {
    _ = .{ db, i_db, name };
}
