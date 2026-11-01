//! Triggers (port of trigger.c): CREATE and DROP TRIGGER, and the code
//! that runs a trigger's steps as a sub-program (OP_Program) for each row
//! an INSERT, UPDATE or DELETE writes, and the transient trigger of a
//! RETURNING clause, which is coded in line.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const build = @import("build.zig");
const select_mod = @import("select.zig");
const attach = @import("attach.zig");
const prepare = @import("prepare.zig");
const auth = @import("auth.zig");
const resolve = @import("resolve.zig");
const ec = @import("expr_code.zig");
const upsert_mod = @import("upsert.zig");
const insert_mod = @import("insert.zig");
const update_mod = @import("update.zig");
const delete_mod = @import("delete.zig");
const ctype = @import("xqlite_base").ctype;
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");

const Parse = int.Parse;
const Table = int.Table;
const Trigger = int.Trigger;
const NameContext = int.NameContext;
const RC = int.RC;
const OP = vi.OP;
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
const NC = int.NC;
const EP = int.EP;
const Aff = int.Aff;
const walker = @import("walker.zig");
const WRC = walker.WRC;
const Walker = walker.Walker;

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
    orconf: OE,
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
    orconf: OE,
    start: [*]const u8,
    end: [*]const u8,
) Oom!?*TriggerStep {
    const s = (try stepAllocate(p, TK.UPDATE, tab_list, start, end)) orelse return null;
    s.expr_list = e_list;
    s.where = where;
    s.orconf = orconf;
    var from_list = from;
    if (from_list != null and !p.inRenameObject()) {
        const sub = try select_mod.selectNew(p, null, from_list, null, null, null, null, .{ .NestedFrom = true }, null);
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

// ========================================================= statements

/// Port of sqlite3TriggerList(): the triggers of `t`, with the TEMP
/// triggers on it first (linked in front of t.trigger).
pub fn triggerList(p: *Parse, t: *Table) ?*Trigger {
    std.debug.assert(!p.disable_triggers);
    const tmp_schema = p.db.dbs.items[1].schema;
    var list = t.trigger;
    var it = tmp_schema.trig_hash.valueIterator();
    while (it.next()) |tp| {
        const trig = tp.*;
        if (trig.tab_schema == t.schema and trig.table.len > 0 and ctype.eqlNoCase(trig.table, t.name) and
            (trig.tab_schema != tmp_schema or trig.returning))
        {
            trig.next = list;
            list = trig;
        } else if (trig.op == TK.RETURNING) {
            // The RETURNING trigger of this statement, seen for the first
            // time: it is on `t`.
            std.debug.assert(p.returning and trig == &p.u1.d.returning.?.ret_trig);
            trig.table = t.name;
            trig.tab_schema = t.schema;
            trig.next = list;
            list = trig;
        }
    }
    return list;
}

/// Port of sqlite3BeginTrigger(): start a CREATE TRIGGER, up to the BEGIN
/// before its steps. The trigger goes to p.new_trigger.
pub fn beginTrigger(p: *Parse, name1: Token, name2: Token, tr_tm_arg: i32, op: i32, columns: ?*IdList, table_name: ?*SrcList, when: ?*Expr, is_temp: bool, no_err: bool) void {
    if (p.syntax_only) return;
    beginTriggerImpl(p, name1, name2, tr_tm_arg, op, columns, table_name, when, is_temp, no_err) catch build.oomFault(p);
}

fn beginTriggerImpl(p: *Parse, name1: Token, name2: Token, tr_tm_arg: i32, op: i32, columns: ?*IdList, table_name: ?*SrcList, when: ?*Expr, is_temp: bool, no_err: bool) Oom!void {
    const db = p.db;
    std.debug.assert(op == TK.INSERT or op == TK.UPDATE or op == TK.DELETE);
    var tr_tm = tr_tm_arg;
    var i_db: usize = undefined;
    var name: *const Token = undefined;
    if (is_temp) {
        // A TEMP trigger may not have a qualified name.
        if (name2.n > 0) {
            util.errorMsg(p, "temporary trigger may not have qualified name", .{});
            return;
        }
        i_db = 1;
        name = &name1;
    } else {
        i_db = build.twoPartName(p, &name1, &name2, &name) orelse return;
    }
    const tab_list = table_name orelse return;
    if (db.malloc_failed) return;

    // A long-standing parser bug allowed "CREATE TRIGGER aux.x ... ON
    // aux.t": ignore the database of the table when reading the schema.
    if (db.init.busy and i_db != 1) tab_list.at(0).u4 = .{ .database = null };

    // An unqualified trigger on a TEMP table is a TEMP trigger.
    var t_opt = build.srcListLookup(p, tab_list);
    if (!db.init.busy and name2.n == 0 and t_opt != null and t_opt.?.schema == db.dbs.items[1].schema) {
        i_db = 1;
    }

    if (db.malloc_failed) return;
    var fix: attach.DbFixer = undefined;
    attach.fixInit(&fix, p, i_db, "trigger", name.slice());
    if (attach.fixSrcList(&fix, tab_list)) return;
    t_opt = build.srcListLookup(p, tab_list);
    const t = t_opt orelse return orphanError(db);
    if (t.e_tab_type == .vtab) {
        util.errorMsg(p, "cannot create triggers on virtual tables", .{});
        return orphanError(db);
    }
    if (t.tab_flags.Shadow and build.readOnlyShadowTables(db)) {
        util.errorMsg(p, "cannot create triggers on shadow tables", .{});
        return orphanError(db);
    }

    // The name must be free and not reserved.
    const z_name = (try build.nameFromToken(p.arena, name.*)) orelse return;
    build.checkObjectName(p, z_name, "trigger", t.name) catch return;
    if (!p.inRenameObject()) {
        if (db.dbs.items[i_db].schema.trig_hash.get(z_name) != null) {
            if (!no_err) {
                util.errorMsgState(p, name.z, .of("42710"), "trigger {s} already exists", .{name.slice()});
            } else if (db.init.busy) {
                // The message comes from corruptSchema().
                util.errorMsg(p, "", .{});
            } else {
                build.codeVerifySchema(p, i_db);
            }
            return;
        }
    }

    // No triggers on system tables.
    if (build.hasSqlitePrefix(t.name)) {
        util.errorMsg(p, "cannot create trigger on system table", .{});
        return;
    }

    // INSTEAD OF triggers are for views, and views have only those.
    if (t.isView() and tr_tm != TK.INSTEAD) {
        util.errorMsg(p, "cannot create {s} trigger on view: {f}", .{ if (tr_tm == TK.BEFORE) "BEFORE" else "AFTER", util.srcItemName(tab_list.at(0)) });
        return orphanError(db);
    }
    if (!t.isView() and tr_tm == TK.INSTEAD) {
        util.errorMsg(p, "cannot create INSTEAD OF trigger on table: {f}", .{util.srcItemName(tab_list.at(0))});
        return orphanError(db);
    }

    if (db.auth != null and !p.inRenameObject()) {
        const i_tab_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
        const code = if (i_tab_db == 1 or is_temp) auth.Code.CREATE_TEMP_TRIGGER else auth.Code.CREATE_TRIGGER;
        const zdb = db.dbs.items[i_tab_db].name;
        const zdb_trig = if (is_temp) db.dbs.items[1].name else zdb;
        if (auth.check(p, code, z_name, t.name, zdb_trig) != auth.OK) return;
        if (auth.check(p, auth.Code.INSERT, int.schemaTable(i_tab_db), null, zdb) != auth.OK) return;
    }

    // INSTEAD OF works as BEFORE (views have no other kind).
    if (tr_tm == TK.INSTEAD) tr_tm = TK.BEFORE;

    const trig = try p.arena.create(Trigger);
    trig.* = .{
        .name = z_name,
        .table = try p.arena.dupeSentinel(u8, tab_list.at(0).name.?, 0),
        .schema = db.dbs.items[i_db].schema,
        .tab_schema = t.schema,
        .op = @intCast(op),
        .tr_tm = if (tr_tm == TK.BEFORE) int.TRIGGER_BEFORE else int.TRIGGER_AFTER,
        .when = when,
        .columns = columns,
    };
    if (p.inRenameObject()) @import("alter.zig").renameTokenRemap(p, trig.table, tab_list.at(0).name);
    std.debug.assert(p.new_trigger == null);
    p.new_trigger = trig;
}

/// trigger_orphan_error of sqlite3BeginTrigger(): a TEMP trigger whose
/// table is gone (dropped by another connection) is skipped while the
/// schema is read.
fn orphanError(db: *int.Sqlite3) void {
    if (db.init.i_db == 1) db.init.orphan_trigger = true;
}

/// Port of sqlite3FinishTrigger(): complete the CREATE TRIGGER once its
/// steps are parsed. `all` is its text from the name to END.
pub fn finishTrigger(p: *Parse, step_list: ?*TriggerStep, all: Token) void {
    if (p.syntax_only) return;
    finishTriggerImpl(p, step_list, all) catch build.oomFault(p);
}

fn finishTriggerImpl(p: *Parse, step_list: ?*TriggerStep, all: Token) Oom!void {
    const db = p.db;
    const trig = p.new_trigger orelse return;
    p.new_trigger = null;
    if (p.n_err != 0) return;
    const z_name = trig.name;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, trig.schema));
    trig.step_list = step_list;
    var n: i64 = 0;
    var it = step_list;
    while (it) |step| : (it = step.next) {
        step.trig = trig;
        n += 1;
    }
    if (n > db.limit(.trigger_steps)) {
        util.errorMsg(p, "trigger \"{s}\" contains too many steps", .{z_name});
        return;
    }
    var fix: attach.DbFixer = undefined;
    attach.fixInit(&fix, p, i_db, "trigger", z_name);
    if (attach.fixTriggerStep(&fix, trig.step_list) or attach.fixExpr(&fix, trig.when)) return;

    if (p.inRenameObject()) {
        p.new_trigger = trig;
        return;
    }

    if (!db.init.busy) {
        // A trigger may not write shadow tables while they are read-only.
        if (build.readOnlyShadowTables(db)) {
            var s_it = trig.step_list;
            while (s_it) |step| : (s_it = step.next) {
                if (step.src) |src| if (build.shadowTableName(db, src.at(0).name.?)) {
                    util.errorMsg(p, "trigger \"{s}\" may not write to shadow table \"{s}\"", .{ z_name, src.at(0).name.? });
                    return;
                };
            }
        }

        // The sqlite_schema entry; the trigger itself is made when the
        // schema row is read back.
        const v = build.getVdbe(p) orelse return;
        build.beginWriteOperation(p, false, i_db);
        build.nestedParse(p, "INSERT INTO %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " VALUES('trigger',%Q,%Q,0,'CREATE TRIGGER %q')", &.{
            .{ .str = db.dbs.items[i_db].name },
            .{ .str = z_name },
            .{ .str = trig.table },
            .{ .str = all.slice() },
        });
        build.changeCookie(p, i_db);
        const where = try build.mprintf(p, "type='trigger' AND name='%q'", &.{.{ .str = z_name }});
        aux.addParseSchemaOp(v, @intCast(i_db), where, 0);
        return;
    }

    // Reading the schema: the trigger moves to memory of its own and
    // joins the schema and its table.
    const link = try copyTrigger(db, trig);
    const s = db.dbs.items[i_db].schema;
    s.trig_hash.put(db.gpa, link.name, link) catch {
        deleteTrigger(db, link);
        return error.OutOfMemory;
    };
    if (link.schema == link.tab_schema) {
        const t = tableOfTrigger(link).?;
        link.next = t.trigger;
        t.trigger = link;
    }
}

/// A copy of `src` (built in a statement's arena) in memory of its own.
fn copyTrigger(db: *int.Sqlite3, src: *const Trigger) Oom!*Trigger {
    const m = try db.gpa.create(std.heap.ArenaAllocator);
    m.* = .init(db.gpa);
    errdefer {
        m.deinit();
        db.gpa.destroy(m);
    }
    const a = m.allocator();
    const t = try a.create(Trigger);
    t.* = .{
        .name = try a.dupeSentinel(u8, src.name, 0),
        .table = try a.dupeSentinel(u8, src.table, 0),
        .op = src.op,
        .tr_tm = src.tr_tm,
        .when = try expr_mod.exprDup(a, src.when),
        .columns = try expr_mod.idListDup(a, src.columns),
        .schema = src.schema,
        .tab_schema = src.tab_schema,
        .mem = m,
    };
    var last: ?*TriggerStep = null;
    var it = src.step_list;
    while (it) |step| : (it = step.next) {
        const n = try a.create(TriggerStep);
        n.* = .{
            .op = step.op,
            .orconf = step.orconf,
            .trig = t,
            .select = try expr_mod.selectDup(a, step.select),
            .src = try expr_mod.srcListDup(a, step.src),
            .where = try expr_mod.exprDup(a, step.where),
            .expr_list = try expr_mod.listDup(a, step.expr_list),
            .id_list = try expr_mod.idListDup(a, step.id_list),
            .upsert = try upsert_mod.upsertDup(a, step.upsert),
            .span = try expr_mod.dupZ(a, step.span),
        };
        if (last) |l| l.next = n else t.step_list = n;
        last = n;
    }
    if (t.step_list) |first| first.last = last;
    return t;
}

/// Port of sqlite3DeleteTrigger(): free a schema trigger.
pub fn deleteTrigger(db: *int.Sqlite3, t: *Trigger) void {
    if (t.returning) return;
    const m = t.mem orelse return;
    m.deinit();
    db.gpa.destroy(m);
}

/// Port of sqlite3DropTrigger(): DROP TRIGGER, the trigger found by name
/// (TEMP before MAIN).
pub fn dropTrigger(p: *Parse, name: ?*SrcList, no_err: bool) void {
    const db = p.db;
    if (p.syntax_only or db.malloc_failed) return;
    prepare.readSchema(p) catch return;
    const item = name.?.at(0);
    const zdb = item.u4.database;
    const z_name = item.name.?;
    var found: ?*Trigger = null;
    for (0..db.dbs.items.len) |i| {
        const j = if (i < 2) i ^ 1 else i;
        if (zdb) |d| if (!build.dbIsNamed(db, j, d)) continue;
        if (db.dbs.items[j].schema.trig_hash.get(z_name)) |trig| {
            found = trig;
            break;
        }
    }
    const trig = found orelse {
        if (!no_err) {
            util.errorMsgState(p, null, .of("42704"), "no such trigger: {f}", .{util.srcItemName(item)});
        } else {
            build.codeVerifyNamedSchema(p, zdb);
        }
        p.check_schema = true;
        return;
    };
    dropTriggerPtr(p, trig);
}

/// Port of tableOfTrigger().
fn tableOfTrigger(trig: *const Trigger) ?*Table {
    return trig.tab_schema.?.tbl_hash.get(trig.table);
}

/// Port of sqlite3DropTriggerPtr(): code the removal of a trigger.
pub fn dropTriggerPtr(p: *Parse, trig: *Trigger) void {
    const db = p.db;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, trig.schema));
    if (db.auth != null) if (tableOfTrigger(trig)) |t| {
        const code = if (i_db == 1) auth.Code.DROP_TEMP_TRIGGER else auth.Code.DROP_TRIGGER;
        const zdb = db.dbs.items[i_db].name;
        if (auth.check(p, code, trig.name, t.name, zdb) != auth.OK or
            auth.check(p, auth.Code.DELETE, int.schemaTable(i_db), null, zdb) != auth.OK) return;
    };
    const v = build.getVdbe(p) orelse return;
    build.nestedParse(p, "DELETE FROM %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " WHERE name=%Q AND type='trigger'", &.{
        .{ .str = db.dbs.items[i_db].name },
        .{ .str = trig.name },
    });
    build.changeCookie(p, i_db);
    _ = aux.addOp4Str(v, OP.DropTrigger, @intCast(i_db), 0, 0, trig.name);
}

/// Port of sqlite3UnlinkAndDeleteTrigger(): remove a dropped trigger
/// from its schema and table.
pub fn unlinkAndDeleteTrigger(db: *int.Sqlite3, i_db: usize, name: [:0]const u8) void {
    const kv = db.dbs.items[i_db].schema.trig_hash.fetchRemove(name) orelse return;
    const trig = kv.value;
    if (trig.schema == trig.tab_schema) {
        if (tableOfTrigger(trig)) |t| {
            var pp: *?*Trigger = &t.trigger;
            while (pp.*) |cur| : (pp = &cur.next) {
                if (cur == trig) {
                    pp.* = cur.next;
                    break;
                }
            }
        }
    }
    deleteTrigger(db, trig);
    db.m_db_flags.SchemaChange = true;
}

/// Port of checkColumnOverlap(): whether an UPDATE setting `changes`
/// fires a trigger UPDATE OF `columns` (null matches anything).
fn checkColumnOverlap(columns: ?*IdList, changes: ?*ExprList) bool {
    const cols = columns orelse return true;
    const list = changes orelse return true;
    for (list.slice()) |item| {
        if (build.idListIndex(cols, item.e_name.?) != null) return true;
    }
    return false;
}

/// Port of tempTriggersExist().
fn tempTriggersExist(db: *int.Sqlite3) bool {
    return db.dbs.items[1].schema.trig_hash.count() != 0;
}

/// Port of sqlite3TriggersExist(): the triggers of `t` (see
/// triggerList()) if one fires for `op` (and, for an UPDATE, `changes`),
/// with their TRIGGER_BEFORE/AFTER mask in `mask`.
pub fn triggersExist(p: *Parse, t: *Table, op: u8, changes: ?*ExprList, mask: ?*u8) ?*Trigger {
    if ((t.trigger == null and !tempTriggersExist(p.db)) or p.disable_triggers) {
        if (mask) |m| m.* = 0;
        return null;
    }
    return triggersReallyExist(p, t, op, changes, mask);
}

/// Port of triggersReallyExist().
fn triggersReallyExist(p: *Parse, t: *Table, op: u8, changes: ?*ExprList, mask_out: ?*u8) ?*Trigger {
    var mask: u8 = 0;
    var list = triggerList(p, t);
    if (list) |first| {
        if (!p.db.flags.EnableTrigger and t.trigger != null and
            prepare.schemaToIndex(p.db, t.trigger.?.schema) != 1)
        {
            // Triggers are disabled: only the TEMP ones are kept.
            if (first == t.trigger) {
                list = null;
            } else {
                var it = first;
                while (it.next != null and it.next != t.trigger) it = it.next.?;
                it.next = null;
            }
        }
        var it = list;
        while (it) |trig| : (it = trig.next) {
            if (trig.op == op and checkColumnOverlap(trig.columns, changes)) {
                mask |= trig.tr_tm;
            } else if (trig.op == TK.RETURNING) {
                // The first time a RETURNING trigger is seen, `op` says
                // what kind of trigger it is.
                std.debug.assert(p.toplevel == null);
                trig.op = op;
                if (t.e_tab_type == .vtab) {
                    if (op != TK.INSERT) {
                        util.errorMsg(p, "{s} RETURNING is not available on virtual tables", .{if (op == TK.DELETE) "DELETE" else "UPDATE"});
                    }
                    trig.tr_tm = int.TRIGGER_BEFORE;
                } else {
                    trig.tr_tm = int.TRIGGER_AFTER;
                }
                mask |= trig.tr_tm;
            } else if (trig.returning and trig.op == TK.INSERT and op == TK.UPDATE and p.toplevel == null) {
                // The RETURNING of an upsert fires for its UPDATE too.
                mask |= trig.tr_tm;
            }
        }
    }
    if (mask_out) |m| m.* = mask;
    return if (mask != 0) list else null;
}

/// TriggerPrg: the sub-program of a trigger for an ON CONFLICT policy,
/// coded once per statement.
pub const TriggerPrg = struct {
    trigger: *Trigger,
    next: ?*TriggerPrg,
    program: *vi.SubProgram,
    orconf: OE,
    /// The OLD.* and NEW.* columns the program reads.
    colmask: [2]u32,
};

/// Port of codeTriggerProgram(): code the steps of a trigger.
fn codeTriggerProgram(p: *Parse, step_list: *TriggerStep, orconf: OE) Oom!void {
    const v = p.vdbe.?;
    const a = p.arena;
    std.debug.assert(p.trigger_tab != null and p.toplevel != null);
    var it: ?*TriggerStep = step_list;
    while (it) |step| : (it = step.next) {
        // The policy of the statement that fired the trigger, unless it
        // has none: then that of the step.
        p.e_orconf = if (orconf == OE.Default) step.orconf else orconf;
        std.debug.assert(!p.ok_const_factor);
        if (step.span) |span| {
            const z = try std.fmt.allocPrint(a, "-- {s}", .{span});
            _ = aux.addOp4Str(v, OP.Trace, 0x7fffffff, 1, 0, z);
        }
        switch (step.op) {
            TK.UPDATE => {
                update_mod.update(p, try expr_mod.srcListDup(a, step.src), try expr_mod.listDup(a, step.expr_list), try expr_mod.exprDup(a, step.where), p.e_orconf, null, null, null);
                _ = aux.addOp0(v, OP.ResetCount);
            },
            TK.INSERT => {
                insert_mod.insert(p, try expr_mod.srcListDup(a, step.src), try expr_mod.selectDup(a, step.select), try expr_mod.idListDup(a, step.id_list), p.e_orconf, try upsert_mod.upsertDup(a, step.upsert));
                _ = aux.addOp0(v, OP.ResetCount);
            },
            TK.DELETE => {
                delete_mod.deleteFrom(p, try expr_mod.srcListDup(a, step.src), try expr_mod.exprDup(a, step.where), null, null);
                _ = aux.addOp0(v, OP.ResetCount);
            },
            else => {
                std.debug.assert(step.op == TK.SELECT);
                var dest = select_mod.selectDestInit(select_mod.SRT.Discard, 0);
                if (try expr_mod.selectDup(a, step.select)) |sel| select_mod.select(p, sel, &dest) catch {};
            },
        }
    }
}

/// Port of transferParseError(): the error of the Parse `from` of a
/// trigger program goes to `to`.
fn transferParseError(to: *Parse, from: *Parse) void {
    if (to.n_err == 0) {
        to.err_msg = if (from.err_msg) |m| (to.arena.dupeSentinel(u8, m, 0) catch null) else null;
        to.n_err = from.n_err;
        to.rc = from.rc;
    }
}

/// Port of codeRowTrigger() (static in trigger.c): a new TriggerPrg with
/// the program of `trig` for ON CONFLICT policy `orconf`.
fn codeTriggerPrg(p: *Parse, trig: *Trigger, t: *Table, orconf: OE) ?*TriggerPrg {
    return codeTriggerPrgImpl(p, trig, t, orconf) catch {
        build.oomFault(p);
        return null;
    };
}

fn codeTriggerPrgImpl(p: *Parse, trig: *Trigger, t: *Table, orconf: OE) Oom!?*TriggerPrg {
    const db = p.db;

    // Bound how deeply triggers code each other.
    var depth: i32 = 0;
    var outer = p;
    while (outer.outer_parse) |o| : (outer = o) depth += 1;
    if (depth >= db.limit(.trigger_depth)) {
        util.errorMsg(p, "triggers nested too deep", .{});
        return null;
    }

    const top = build.toplevel(p);
    const top_v = top.vdbe.?;

    // Linked into the top-level Parse at once, so a recursive coding of
    // the same trigger finds it.
    const program = try top_v.alloc().create(vi.SubProgram);
    program.* = .{ .ops = &.{}, .n_mem = 0, .n_csr = 0, .once = &.{}, .token = trig };
    aux.linkSubProgram(top_v, program);
    const prg = try top.arena.create(TriggerPrg);
    prg.* = .{ .trigger = trig, .next = top.trigger_prg, .program = program, .orconf = orconf, .colmask = .{ 0xffffffff, 0xffffffff } };
    top.trigger_prg = prg;

    // A Parse of its own for the program (sqlite3ParseObjectInit()).
    var arena_state = std.heap.ArenaAllocator.init(db.gpa);
    defer arena_state.deinit();
    var sub: Parse = .{
        .db = db,
        .arena = arena_state.allocator(),
        .trigger_tab = t,
        .toplevel = top,
        .auth_context = trig.name.ptr,
        .e_trigger_op = trig.op,
        .n_query_loop = p.n_query_loop,
        .prep_flags = p.prep_flags,
        // xqlite: the schema's text (sql/typing.zig).
        .xq_schema_text = 1,
    };
    defer build.releaseTableRefs(&sub);
    sub.outer_parse = db.parse;
    db.parse = &sub;
    defer db.parse = sub.outer_parse;
    var nc: NameContext = .{ .parse = &sub };

    const v = build.getVdbe(&sub) orelse {
        transferParseError(p, &sub);
        return prg;
    };
    defer aux.delete(v);
    if (!trig.is_fk_action) aux.changeP4Str(v, -1, try std.fmt.allocPrint(sub.arena, "-- TRIGGER {s}", .{trig.name}));

    // A false (or NULL) WHEN clause jumps to the OP_Halt at the end.
    var end_trigger: i32 = 0;
    if (trig.when) |when| {
        const w = try expr_mod.exprDup(sub.arena, when);
        if (!db.malloc_failed) if (resolve.resolveExprNames(&nc, w)) |_| {
            end_trigger = aux.makeLabel(&sub);
            ec.exprIfFalse(&sub, w, end_trigger, vi.SQLITE_JUMPIFNULL);
        } else |_| {};
    }

    try codeTriggerProgram(&sub, trig.step_list.?, orconf);

    if (end_trigger != 0) aux.resolveLabel(v, end_trigger);
    _ = aux.addOp0(v, OP.Halt);
    transferParseError(p, &sub);

    if (p.n_err == 0) {
        aux.takeProgram(v, program, &top.n_max_arg);
    }
    program.n_mem = sub.n_mem;
    program.n_csr = sub.n_tab;
    prg.colmask = .{ sub.oldmask, sub.newmask };
    return prg;
}

/// Port of getRowTrigger(): the TriggerPrg of `trig` and `orconf`, coded
/// now unless the statement already has it.
fn getRowTrigger(p: *Parse, trig: *Trigger, t: *Table, orconf: OE) ?*TriggerPrg {
    const root = build.toplevel(p);
    var it = root.trigger_prg;
    while (it) |prg| : (it = prg.next) {
        if (prg.trigger == trig and prg.orconf == orconf) return prg;
    }
    const prg = codeTriggerPrg(p, trig, t, orconf);
    p.db.err_byte_offset = -1;
    return prg;
}

/// Port of sqlite3CodeRowTriggerDirect(): call the program of `trig`.
/// See codeRowTrigger() for the arguments.
pub fn codeRowTriggerDirect(p: *Parse, trig: *Trigger, t: *Table, reg: i32, orconf: OE, ignore_jump: i32) void {
    const v = build.getVdbe(p) orelse return;
    const prg = getRowTrigger(p, trig, t, orconf) orelse return;
    // Unless recursive triggers are on, a running trigger does not fire
    // again (foreign key actions always may).
    const recursive = !trig.is_fk_action and !p.db.flags.RecTriggers;
    p.n_mem += 1;
    _ = aux.addOp4(v, OP.Program, reg, ignore_jump, p.n_mem, .{ .subprogram = prg.program });
    aux.changeP5(v, @intFromBool(recursive));
}

/// Port of sqlite3CodeRowTrigger(): call the triggers in `trigger` that
/// fire for `op` at time `tr_tm` (TRIGGER_BEFORE or TRIGGER_AFTER).
/// OLD.rowid, OLD.* columns, NEW.rowid and NEW.* columns are in the
/// registers from `reg` (the OLD ones unused for an INSERT, the NEW ones
/// for a DELETE). RAISE(IGNORE) jumps to `ignore_jump`.
pub fn codeRowTrigger(p: *Parse, trigger: ?*Trigger, op: u8, changes: ?*ExprList, tr_tm: u8, t: *Table, reg: i32, orconf: OE, ignore_jump: i32) void {
    std.debug.assert(op == TK.UPDATE or op == TK.INSERT or op == TK.DELETE);
    std.debug.assert((op == TK.UPDATE) == (changes != null));
    var it = trigger;
    while (it) |trig| : (it = trig.next) {
        // The triggers for `op`, and the RETURNING of an INSERT for the
        // UPDATE of its upsert.
        if ((trig.op == op or (trig.returning and trig.op == TK.INSERT and op == TK.UPDATE)) and
            trig.tr_tm == tr_tm and checkColumnOverlap(trig.columns, changes))
        {
            if (!trig.returning) {
                codeRowTriggerDirect(p, trig, t, reg, orconf, ignore_jump);
            } else if (p.toplevel == null) {
                codeReturningTrigger(p, trig, t, reg) catch build.oomFault(p);
            }
        }
    }
}

/// Port of isAsteriskTerm(): whether `term` of a RETURNING list is "*".
/// "table.*" is an error.
fn isAsteriskTerm(p: *Parse, term: *Expr) bool {
    if (term.op == TK.ASTERISK) return true;
    if (term.op != TK.DOT) return false;
    if (term.right.?.op != TK.ASTERISK) return false;
    util.errorMsg(p, "RETURNING may not use \"TABLE.*\" wildcards", .{});
    return true;
}

/// Port of sqlite3ExpandReturning(): a copy of the RETURNING list with
/// "*" expanded to the columns of `t`.
fn expandReturning(p: *Parse, list: *ExprList, t: *Table) Oom!?*ExprList {
    const a = p.arena;
    var new: ?*ExprList = null;
    for (list.slice()) |*item| {
        const old = item.expr orelse continue;
        if (isAsteriskTerm(p, old)) {
            for (t.cols) |*col| {
                if (col.col_flags.HIDDEN) continue;
                new = try expr_mod.listAppend(p, new, try expr_mod.expr(a, TK.ID, col.cn_name));
                const ni = new.?.at(new.?.len() - 1);
                ni.e_name = try a.dupeSentinel(u8, col.cn_name, 0);
                ni.fg.e_ename = .name;
            }
        } else {
            new = try expr_mod.listAppend(p, new, try expr_mod.exprDup(a, old));
            if (item.e_name) |name| {
                const ni = new.?.at(new.?.len() - 1);
                ni.e_name = try a.dupeSentinel(u8, name, 0);
                ni.fg.e_ename = item.fg.e_ename;
            }
        }
    }
    return new;
}

/// Port of sqlite3ReturningSubqueryVarSelect().
fn returningSubqueryVarSelect(_: *Walker, e: *Expr) WRC {
    if (e.useXSelect() and e.x.select.?.sel_flags.Correlated) e.flags.VarSelect = true;
    return WRC.Continue;
}

/// Port of sqlite3ReturningSubqueryCorrelated(): a SELECT reading the
/// table being changed is correlated.
fn returningSubqueryCorrelated(w: *Walker, s: *Select) WRC {
    for (s.src.?.slice()) |*item| {
        if (item.s_tab == w.u.tab) {
            s.sel_flags.Correlated = true;
            w.e_code = 1;
            break;
        }
    }
    return WRC.Continue;
}

/// Port of sqlite3ProcessReturningSubqueries(): the subqueries of the
/// RETURNING list that read `t` are correlated, since `t` changes from
/// row to row; so are the expressions holding them.
fn processReturningSubqueries(list: *ExprList, t: *Table) void {
    var w: Walker = .{
        .expr_callback = walker.exprWalkNoop,
        .select_callback = returningSubqueryCorrelated,
        .u = .{ .tab = t },
    };
    _ = walker.walkExprList(&w, list);
    if (w.e_code != 0) {
        w.expr_callback = returningSubqueryVarSelect;
        w.select_callback = walker.selectWalkNoop;
        _ = walker.walkExprList(&w, list);
    }
}

/// Port of codeReturningTrigger(): code, in line, the computation of a
/// row of RETURNING results from the registers at `reg_in` (as for a
/// trigger's OLD.* and NEW.*) and its insertion into the results table.
fn codeReturningTrigger(p: *Parse, trig: *Trigger, t: *Table, reg_in: i32) Oom!void {
    const v = p.vdbe.?;
    const db = p.db;
    const a = p.arena;
    // A RETURNING trigger of another statement (an outer one).
    if (!p.returning) return;
    const ret = p.u1.d.returning.?;
    if (trig != &ret.ret_trig) return;

    // Name the result columns as a SELECT of the list from `t` would.
    var from: SrcList = .{};
    try from.items.append(a, .{ .s_tab = t, .name = t.name, .i_cursor = -1 });
    var sel: Select = .{ .e_list = try expr_mod.listDup(a, ret.return_el), .src = &from };
    select_mod.selectPrep(p, &sel, null);
    if (p.n_err == 0) select_mod.generateColumnNames(p, &sel);

    const new = (try expandReturning(p, ret.return_el.?, t)) orelse return;
    if (p.n_err == 0) {
        var nc: NameContext = .{ .parse = p, .u_nc = .{ .i_base_reg = reg_in }, .nc_flags = .{ .UBaseReg = true } };
        if (ret.n_ret_col == 0) {
            ret.n_ret_col = @intCast(new.len());
            ret.i_ret_cur = p.n_tab;
            p.n_tab += 1;
        }
        p.e_trigger_op = trig.op;
        p.trigger_tab = t;
        const resolved = if (resolve.resolveExprListNames(&nc, new)) |_| true else |_| false;
        if (resolved and !db.malloc_failed) {
            const n_col: i32 = @intCast(new.len());
            const reg = p.n_mem + 1;
            processReturningSubqueries(new, t);
            p.n_mem += n_col + 2;
            ret.i_ret_reg = reg;
            for (new.slice(), 0..) |*item, i| {
                const col = item.expr.?;
                const r = reg + @as(i32, @intCast(i));
                ec.codeFactorable(p, col, r);
                if (expr_mod.affinity(col) == Aff.real) _ = aux.addOp1(v, OP.RealAffinity, r);
            }
            _ = aux.addOp3(v, OP.MakeRecord, reg, n_col, reg + n_col);
            _ = aux.addOp2(v, OP.NewRowid, ret.i_ret_cur, reg + n_col + 1);
            _ = aux.addOp3(v, OP.Insert, ret.i_ret_cur, reg + n_col, reg + n_col + 1);
        }
    }
    p.e_trigger_op = 0;
    p.trigger_tab = null;
}

/// Port of sqlite3TriggerColmask(): the OLD.* (`is_new` false) or NEW.*
/// columns the triggers firing at `tr_tm` read, bit i for column i
/// (all bits if one past the 32nd is read).
pub fn triggerColmask(p: *Parse, trigger: ?*Trigger, changes: ?*ExprList, is_new: bool, tr_tm: u8, t: *Table, orconf: OE) u32 {
    const op: u8 = if (changes != null) TK.UPDATE else TK.DELETE;
    if (t.isView()) return 0xffffffff;
    var mask: u32 = 0;
    var it = trigger;
    while (it) |trig| : (it = trig.next) {
        if (trig.op == op and tr_tm & trig.tr_tm != 0 and checkColumnOverlap(trig.columns, changes)) {
            if (trig.returning) {
                mask = 0xffffffff;
            } else if (getRowTrigger(p, trig, t, orconf)) |prg| {
                mask |= prg.colmask[@intFromBool(is_new)];
            }
        }
    }
    return mask;
}
