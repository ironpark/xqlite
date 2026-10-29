//! Schema building and statement-level helpers (port of build.c). This
//! part has the FROM-clause, identifier-list and WITH-clause builders the
//! parser uses; DDL code generation comes later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const ctype = @import("../util/ctype.zig");

const Allocator = std.mem.Allocator;
const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Select = int.Select;
const With = int.With;
const Cte = int.Cte;
const OnOrUsing = int.OnOrUsing;
const Token = int.Token;
const Oom = int.Oom;
const JT = int.JT;
const SF = int.SF;

/// SQLITE_MAX_SRCLIST: the most terms in one FROM clause.
pub const max_srclist = 200;

/// Port of sqlite3NameFromToken(): a dequoted, NUL-terminated copy.
pub fn nameFromToken(a: Allocator, t: ?Token) Oom!?[:0]u8 {
    const tok = t orelse return null;
    return util.dequote(try a.dupeSentinel(u8, tok.slice(), 0));
}

/// Port of sqlite3IdListAppend().
pub fn idListAppend(p: *Parse, list: ?*IdList, t: Token) Oom!*IdList {
    const l = list orelse blk: {
        const n = try p.arena.create(IdList);
        n.* = .{};
        break :blk n;
    };
    const name = (try nameFromToken(p.arena, t)).?;
    try l.names.append(p.arena, name);
    if (p.inRenameObject()) alter.renameTokenMap(p, name, t);
    return l;
}

/// Port of sqlite3IdListIndex(): the position of `name`, or null.
pub fn idListIndex(list: *const IdList, name: []const u8) ?usize {
    for (list.names.items, 0..) |n, i| if (ctype.eqlNoCase(n, name)) return i;
    return null;
}

/// Port of sqlite3SrcListEnlarge(): insert `n_extra` empty terms at
/// `start`. Null (with an error) if the list would grow too large.
pub fn srcListEnlarge(p: *Parse, src: *SrcList, n_extra: usize, start: usize) Oom!?*SrcList {
    std.debug.assert(start <= src.len() and n_extra >= 1);
    if (src.len() + n_extra >= max_srclist) {
        util.errorMsg(p, "too many FROM clause terms, max: {d}", .{max_srclist});
        return null;
    }
    try src.items.insertSlice(p.arena, start, blank: {
        const items = try p.arena.alloc(SrcItem, n_extra);
        @memset(items, .{});
        break :blank items;
    });
    return src;
}

/// Port of sqlite3SrcListAppend(): append a table, "db.table" if
/// `database` is given (then `table` holds the database name and
/// `database` the table, as the grammar passes them).
pub fn srcListAppend(p: *Parse, list: ?*SrcList, table: ?Token, database_arg: ?Token) Oom!?*SrcList {
    std.debug.assert(database_arg == null or table != null);
    const l = if (list) |l| (try srcListEnlarge(p, l, 1, l.len())) orelse return null else blk: {
        const n = try p.arena.create(SrcList);
        n.* = .{};
        try n.items.append(p.arena, .{});
        break :blk n;
    };
    const item = l.at(l.len() - 1);
    var database = database_arg;
    if (database) |d| if (d.z == null) {
        database = null;
    };
    if (database) |d| {
        item.name = try nameFromToken(p.arena, d);
        item.u4 = .{ .database = try nameFromToken(p.arena, table) };
    } else {
        item.name = try nameFromToken(p.arena, table);
        item.u4 = .{ .database = null };
    }
    return l;
}

/// Port of sqlite3SrcItemAttachSubquery().
pub fn srcItemAttachSubquery(p: *Parse, item: *SrcItem, sel: *Select) Oom!void {
    std.debug.assert(!item.fg.is_subquery);
    if (item.fg.fixed_schema) item.fg.fixed_schema = false;
    const sq = try p.arena.create(int.Subquery);
    sq.* = .{ .select = sel };
    item.u4 = .{ .subq = sq };
    item.fg.is_subquery = true;
}

/// Port of sqlite3SubqueryDetach(): take the subquery out of `item`,
/// which becomes an ordinary term.
pub fn subqueryDetach(item: *SrcItem) *Select {
    std.debug.assert(item.fg.is_subquery);
    const sel = item.u4.subq.?.select;
    item.u4 = .{ .database = null };
    item.fg.is_subquery = false;
    return sel;
}

/// Port of sqlite3SrcListAppendFromTerm(): add a FROM-clause term: a
/// table (with optional database), or a subquery, with its alias and
/// ON/USING clause.
pub fn srcListAppendFromTerm(
    p: *Parse,
    list: ?*SrcList,
    table: ?Token,
    database: ?Token,
    alias: Token,
    subquery: ?*Select,
    on_using: ?*const OnOrUsing,
) Oom!?*SrcList {
    if (list == null) if (on_using) |ou| if (ou.on != null or ou.using != null) {
        util.errorMsg(p, "a JOIN clause is required before {s}", .{if (ou.on != null) "ON" else "USING"});
        return null;
    };
    const l = (try srcListAppend(p, list, table, database)) orelse return null;
    const item = l.at(l.len() - 1);
    if (p.inRenameObject()) if (item.name) |name| {
        const tok = if (database != null and database.?.z != null) database.? else table.?;
        alter.renameTokenMap(p, name, tok);
    };
    if (alias.n != 0) item.alias = try nameFromToken(p.arena, alias);
    if (subquery) |sq| {
        try srcItemAttachSubquery(p, item, sq);
        if (sq.sel_flags.NestedFrom) item.fg.is_nested_from = true;
    }
    if (on_using) |ou| {
        if (ou.using) |u| {
            item.fg.is_using = true;
            item.u3 = .{ .using = u };
        } else {
            item.u3 = .{ .on = ou.on };
        }
    }
    return l;
}

/// Port of sqlite3SrcListIndexedBy(): INDEXED BY or NOT INDEXED on the
/// last term. NOT INDEXED arrives as a token with no text and length 1.
pub fn srcListIndexedBy(p: *Parse, list: ?*SrcList, indexed_by: Token) Oom!void {
    const l = list orelse return;
    if (indexed_by.n == 0) return;
    const item = l.at(l.len() - 1);
    std.debug.assert(!item.fg.not_indexed and !item.fg.is_indexed_by and !item.fg.is_tab_func);
    if (indexed_by.n == 1 and indexed_by.z == null) {
        item.fg.not_indexed = true;
    } else {
        item.u1 = .{ .indexed_by = try nameFromToken(p.arena, indexed_by) };
        item.fg.is_indexed_by = true;
    }
}

/// Port of sqlite3SrcListAppendList(): `p1` followed by the terms of `p2`.
pub fn srcListAppendList(p: *Parse, p1: *SrcList, p2_arg: ?*SrcList) Oom!*SrcList {
    const p2 = p2_arg orelse return p1;
    const n_old = p1.len();
    const l = (try srcListEnlarge(p, p1, p2.len(), n_old)) orelse return p1;
    @memcpy(l.items.items[n_old..], p2.items.items);
    if (p2.at(0).fg.jointype.LTORJ) l.at(0).fg.jointype.LTORJ = true;
    return l;
}

/// Port of sqlite3SrcListFuncArgs(): the arguments of a table-valued
/// function in the last term.
pub fn srcListFuncArgs(list: ?*SrcList, args: ?*ExprList) void {
    const l = list orelse return;
    const item = l.at(l.len() - 1);
    std.debug.assert(!item.fg.not_indexed and !item.fg.is_indexed_by and !item.fg.is_tab_func);
    item.u1 = .{ .func_arg = args };
    item.fg.is_tab_func = true;
}

/// Port of sqlite3SrcListShiftJoinType(): the parser attaches each join
/// operator to its left operand; move them to the right operand, and tag
/// every term left of the last RIGHT JOIN with JT_LTORJ.
pub fn srcListShiftJoinType(list: ?*SrcList) void {
    const l = list orelse return;
    const n = l.len();
    if (n <= 1) return;
    const a = l.items.items;
    var all: JT = .{};
    var i = n - 1;
    while (i > 0) : (i -= 1) {
        a[i].fg.jointype = a[i - 1].fg.jointype;
        all.set(a[i].fg.jointype);
    }
    a[0].fg.jointype = .{};
    if (all.RIGHT) {
        i = n - 1;
        while (i > 0 and !a[i].fg.jointype.RIGHT) i -= 1;
        while (i > 0) {
            i -= 1;
            a[i].fg.jointype.LTORJ = true;
        }
    }
}

/// Port of sqlite3CteNew().
pub fn cteNew(p: *Parse, name: Token, cols: ?*ExprList, query: ?*Select, e_m10d: int.M10d) Oom!*Cte {
    const c = try p.arena.create(Cte);
    c.* = .{
        .select = query,
        .cols = cols,
        .name = try nameFromToken(p.arena, name),
        .e_m10d = e_m10d,
    };
    return c;
}

/// Port of sqlite3WithAdd(): add a CTE to a WITH clause, checking that
/// its name is unique there.
pub fn withAdd(p: *Parse, with: ?*With, cte: *Cte) Oom!*With {
    if (cte.name) |name| if (with) |w| {
        for (w.ctes.items) |c| {
            if (ctype.eqlNoCase(name, c.name orelse "")) {
                util.errorMsg(p, "duplicate WITH table name: {s}", .{name});
            }
        }
    };
    const w = with orelse blk: {
        const n = try p.arena.create(With);
        n.* = .{};
        break :blk n;
    };
    try w.ctes.append(p.arena, cte.*);
    return w;
}

/// Port of sqlite3HasExplicitNulls(): reject NULLS FIRST/LAST where it is
/// not supported (index and upsert targets).
pub fn hasExplicitNulls(p: *Parse, list: ?*ExprList) bool {
    const l = list orelse return false;
    for (l.slice()) |item| {
        if (item.fg.nulls) {
            const sf = item.fg.sort_flags;
            util.errorMsg(p, "unsupported use of NULLS {s}", .{if (sf == 0 or sf == 3) "FIRST" else "LAST"});
            return true;
        }
    }
    return false;
}


// ======================================================= code generation

const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const expr_mod = @import("expr.zig");
const coll_mod = @import("coll.zig");
const main_mod = @import("main.zig");
const prepare = @import("prepare.zig");
const insert_mod = @import("insert.zig");
const trigger_mod = @import("trigger.zig");
const fkey_mod = @import("fkey.zig");
const delete_mod = @import("delete.zig");
const resolve = @import("resolve.zig");
const select_mod = @import("select.zig");
const attach = @import("attach.zig");
const alter = @import("alter.zig");
const vtab_mod = @import("vtab.zig");
const btree = @import("../btree/btree.zig");

const Sqlite3 = int.Sqlite3;
const Table = int.Table;
const Column = int.Column;
const Index = int.Index;
const Schema = int.Schema;
const Upsert = int.Upsert;
const Vdbe = vi.Vdbe;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;
const RC = int.RC;
const TK = int.TK;
const OE = int.OE;
const TF = int.TF;
const COLFLAG = int.COLFLAG;
const COLTYPE = int.COLTYPE;
const Aff = int.Aff;
const Pgno = int.Pgno;
const LogEst = int.LogEst;

/// BTREE_INTKEY and BTREE_BLOBKEY: P3 of OP_CreateBtree.
pub const BTREE_INTKEY = 1;
pub const BTREE_BLOBKEY = 2;

/// sqlite3MPrintf() into the statement's memory; too long a result is
/// reported as out of memory.
pub fn mprintf(p: *Parse, fmt: []const u8, args: []const @import("printf.zig").Arg) Oom![:0]u8 {
    const printf = @import("printf.zig");
    return printf.mprintfLimit(p.db, p.arena, printf.max_length, fmt, args) catch error.OutOfMemory;
}

/// Record that the statement ran out of memory.
pub fn oomFault(p: *Parse) void {
    p.db.oomFault();
    if (p.rc == RC.OK) p.rc = RC.NOMEM;
    p.n_err += 1;
}

/// sqlite3ParseToplevel().
pub fn toplevel(p: *Parse) *Parse {
    return p.toplevel orelse p;
}

/// Port of sqlite3GetVdbe() (select.c): the program of the statement,
/// created on first use. Null if out of memory.
pub fn getVdbe(p: *Parse) ?*Vdbe {
    if (p.vdbe) |v| return v;
    if (p.toplevel == null and !p.db.optDisabled(int.OPT.FactorOutConst)) p.ok_const_factor = true;
    return aux.create(p) catch {
        oomFault(p);
        return null;
    };
}

/// Port of sqlite3FinishCoding(): finish the program of a statement.
pub fn finishCoding(p: *Parse) void {
    std.debug.assert(p.toplevel == null);
    const db = p.db;
    if (p.nested != 0 or p.syntax_only) return;
    if (p.n_err != 0) {
        if (db.malloc_failed) p.rc = RC.NOMEM;
        return;
    }
    var v_opt = p.vdbe;
    if (v_opt == null) {
        if (db.init.busy) {
            p.rc = RC.DONE;
            return;
        }
        v_opt = getVdbe(p);
        if (v_opt == null) p.rc = RC.ERROR;
    }
    if (v_opt) |v| {
        if (p.returning) {
            // Return the rows the RETURNING trigger stored.
            const ret = p.u1.d.returning.?;
            if (ret.n_ret_col != 0) {
                _ = aux.addOp0(v, OP.FkCheck);
                const addr_rewind = aux.addOp1(v, OP.Rewind, ret.i_ret_cur);
                const reg = ret.i_ret_reg;
                var i: i32 = 0;
                while (i < ret.n_ret_col) : (i += 1) _ = aux.addOp3(v, OP.Column, ret.i_ret_cur, i, reg + i);
                _ = aux.addOp2(v, OP.ResultRow, reg, ret.n_ret_col);
                _ = aux.addOp2(v, OP.Next, ret.i_ret_cur, addr_rewind + 1);
                aux.jumpHere(v, addr_rewind);
            }
        }
        _ = aux.addOp0(v, OP.Halt);

        // Start a transaction on, and verify the schema cookie of, every
        // database the statement uses.
        aux.jumpHere(v, 0);
        for (db.dbs.items, 0..) |*d, i_db| {
            if (p.cookie_mask & (@as(u32, 1) << @intCast(i_db)) == 0) continue;
            aux.usesBtree(v, @intCast(i_db));
            _ = aux.addOp4Int(
                v,
                OP.Transaction,
                @intCast(i_db),
                @intFromBool(p.write_mask & (@as(u32, 1) << @intCast(i_db)) != 0),
                d.schema.schema_cookie,
                d.schema.i_generation,
            );
            if (!db.init.busy) aux.changeP5(v, 1);
        }
        for (p.vtab_lock.items) |t| {
            _ = aux.addOp4(v, OP.VBegin, 0, 0, 0, vtabP4(db, t));
        }
        p.vtab_lock = .empty;

        if (p.uses_ainc) insert_mod.autoincrementBegin(p);

        // Code the constant expressions factored out of loops.
        if (p.const_expr) |el| {
            p.ok_const_factor = false;
            for (el.slice()) |*item| {
                std.debug.assert(item.u.const_expr_reg > 0);
                @import("expr_code.zig").exprCode(p, item.expr, item.u.const_expr_reg);
            }
        }

        if (p.returning) {
            const ret = p.u1.d.returning.?;
            if (ret.n_ret_col != 0) _ = aux.addOp2(v, OP.OpenEphemeral, ret.i_ret_cur, ret.n_ret_col);
        }

        _ = aux.goto_(v, 1);
    }

    if (p.n_err == 0 and !db.malloc_failed) {
        aux.makeReady(p.vdbe.?, p);
        p.rc = RC.DONE;
    } else {
        if (db.malloc_failed) p.rc = RC.NOMEM else p.rc = RC.ERROR;
    }
}

/// Port of sqlite3NestedParse(): run the parser and code generator on the
/// formatted SQL, adding its code to the statement under construction.
pub fn nestedParse(p: *Parse, fmt: []const u8, args: []const @import("printf.zig").Arg) void {
    const db = p.db;
    if (p.n_err != 0) return;
    if (p.e_parse_mode != .normal) return;
    std.debug.assert(p.nested < 10);
    const sql = @import("printf.zig").mprintfLimit(db, p.arena, @intCast(db.limit(.length)), fmt, args) catch |err| {
        if (err == error.TooBig) p.rc = RC.TOOBIG else db.oomFault();
        p.n_err += 1;
        return;
    };
    const saved_db_flags = db.m_db_flags;
    p.nested += 1;
    // The part of Parse reset for each recursion (PARSE_TAIL).
    const saved = ParseTail.save(p);
    db.m_db_flags.PreferBuiltin = true;
    @import("../parse/tokenize.zig").runParser(p, sql) catch |err| switch (err) {
        error.OutOfMemory => oomFault(p),
        error.ParseFailed => {},
    };
    db.m_db_flags = saved_db_flags;
    saved.restore(p);
    p.nested -= 1;
}

/// The fields of Parse after PARSE_TAIL, which sqlite3NestedParse() saves
/// and clears around the nested parse.
const ParseTail = struct {
    last_token: Token,
    n_var: int.YnVar,
    vlist: std.ArrayList(int.VListEntry),
    explain: u8,
    e_parse_mode: int.ParseMode,
    n_height: i32,
    tail: []const u8,
    new_table: ?*Table,
    new_index: ?*Index,
    new_trigger: ?*int.Trigger,
    with: ?*With,

    fn save(p: *Parse) ParseTail {
        const t: ParseTail = .{
            .last_token = p.last_token,
            .n_var = p.n_var,
            .vlist = p.vlist,
            .explain = p.explain,
            .e_parse_mode = p.e_parse_mode,
            .n_height = p.n_height,
            .tail = p.tail,
            .new_table = p.new_table,
            .new_index = p.new_index,
            .new_trigger = p.new_trigger,
            .with = p.with,
        };
        p.last_token = .{};
        p.n_var = 0;
        p.vlist = .empty;
        p.explain = 0;
        p.e_parse_mode = .normal;
        p.n_height = 0;
        p.tail = "";
        p.new_table = null;
        p.new_index = null;
        p.new_trigger = null;
        p.with = null;
        return t;
    }

    fn restore(t: ParseTail, p: *Parse) void {
        p.last_token = t.last_token;
        p.n_var = t.n_var;
        p.vlist = t.vlist;
        p.explain = t.explain;
        p.e_parse_mode = t.e_parse_mode;
        p.n_height = t.n_height;
        p.tail = t.tail;
        p.new_table = t.new_table;
        p.new_index = t.new_index;
        p.new_trigger = t.new_trigger;
        p.with = t.with;
    }
};

/// Whether `name` (zName+7 of a "sqlite_" name) is `full` without its
/// "sqlite_" prefix.
fn suffixIs(name: []const u8, full: []const u8) bool {
    return name.len >= 7 and ctype.eqlNoCase(name[7..], full[7..]);
}

pub fn hasSqlitePrefix(name: []const u8) bool {
    return name.len >= 7 and ctype.eqlNoCase(name[0..7], "sqlite_");
}

/// Port of sqlite3FindTable(): the table named `name` in database
/// `database` (all databases, TEMP first, if null), or null.
pub fn findTable(db: *Sqlite3, name: []const u8, database: ?[]const u8) ?*Table {
    const dbs = db.dbs.items;
    if (database) |zdb| {
        var i: usize = 0;
        while (i < dbs.len) : (i += 1) {
            if (ctype.eqlNoCase(zdb, dbs[i].name)) break;
        }
        if (i >= dbs.len) {
            // "main" always names the main database.
            if (ctype.eqlNoCase(zdb, "main")) i = 0 else return null;
        }
        var p = dbs[i].schema.tbl_hash.get(name);
        if (p == null and hasSqlitePrefix(name)) {
            if (i == 1) {
                if (suffixIs(name, int.PREFERRED_TEMP_SCHEMA_TABLE) or
                    suffixIs(name, int.PREFERRED_SCHEMA_TABLE) or
                    suffixIs(name, int.LEGACY_SCHEMA_TABLE))
                {
                    p = dbs[1].schema.tbl_hash.get(int.LEGACY_TEMP_SCHEMA_TABLE);
                }
            } else if (suffixIs(name, int.PREFERRED_SCHEMA_TABLE)) {
                p = dbs[i].schema.tbl_hash.get(int.LEGACY_SCHEMA_TABLE);
            }
        }
        return p;
    }
    if (dbs[1].schema.tbl_hash.get(name)) |t| return t;
    if (dbs[0].schema.tbl_hash.get(name)) |t| return t;
    for (dbs[2..]) |*d| {
        if (d.schema.tbl_hash.get(name)) |t| return t;
    }
    if (hasSqlitePrefix(name)) {
        if (suffixIs(name, int.PREFERRED_SCHEMA_TABLE)) {
            return dbs[0].schema.tbl_hash.get(int.LEGACY_SCHEMA_TABLE);
        } else if (suffixIs(name, int.PREFERRED_TEMP_SCHEMA_TABLE)) {
            return dbs[1].schema.tbl_hash.get(int.LEGACY_TEMP_SCHEMA_TABLE);
        }
    }
    return null;
}

/// sqlite3LocateTable() flags.
pub const LOCATE_VIEW: u32 = 0x01;
pub const LOCATE_NOERR: u32 = 0x02;

/// Port of sqlite3LocateTable(): like findTable(), but reads the schema
/// first and leaves an error in `p` if the table is not found.
pub fn locateTable(p: *Parse, flags: u32, name: []const u8, database: ?[]const u8) ?*Table {
    const db = p.db;
    if (!db.m_db_flags.SchemaKnownOk) prepare.readSchema(p) catch return null;
    var t = findTable(db, name, database);
    if (t == null) {
        // Not a table made with CREATE: perhaps an eponymous virtual
        // table.
        if (p.prep_flags & aux.PREPARE_NO_VTAB == 0 and !db.init.busy) {
            var m = db.modules.get(name);
            if (m == null and name.len >= 7 and ctype.eqlNoCase(name[0..7], "pragma_")) {
                m = @import("pragma.zig").vtabRegister(db, name);
            }
            if (m == null and name.len >= 4 and ctype.eqlNoCase(name[0..4], "json")) {
                m = @import("json.zig").jsonVtabRegister(db, name);
            }
            if (m) |mod| if (vtab_mod.epoTableInit(p, mod)) return mod.epo_tab;
        }
        if (flags & LOCATE_NOERR != 0) return null;
        p.check_schema = true;
    } else if (t.?.isVirtual() and p.prep_flags & aux.PREPARE_NO_VTAB != 0) {
        t = null;
    }
    if (t == null) {
        const what = if (flags & LOCATE_VIEW != 0) "no such view" else "no such table";
        if (database) |zdb| {
            util.errorMsg(p, "{s}: {s}.{s}", .{ what, zdb, name });
        } else {
            util.errorMsg(p, "{s}: {s}", .{ what, name });
        }
    }
    return t;
}

/// Port of sqlite3LocateTableItem().
pub fn locateTableItem(p: *Parse, flags: u32, item: *SrcItem) ?*Table {
    const zdb: ?[]const u8 = if (item.fg.fixed_schema)
        p.db.dbs.items[@intCast(prepare.schemaToIndex(p.db, item.u4.schema))].name
    else
        item.u4.database;
    return locateTable(p, flags, item.name.?, zdb);
}

/// Port of sqlite3PreferredTableName().
pub fn preferredTableName(name: [:0]const u8) [:0]const u8 {
    if (hasSqlitePrefix(name)) {
        if (suffixIs(name, int.LEGACY_SCHEMA_TABLE)) return int.PREFERRED_SCHEMA_TABLE;
        if (suffixIs(name, int.LEGACY_TEMP_SCHEMA_TABLE)) return int.PREFERRED_TEMP_SCHEMA_TABLE;
    }
    return name;
}

/// sqlite3DbIsNamed().
pub fn dbIsNamed(db: *Sqlite3, i_db: usize, name: []const u8) bool {
    return ctype.eqlNoCase(db.dbs.items[i_db].name, name) or (i_db == 0 and ctype.eqlNoCase("main", name));
}

/// Port of sqlite3FindIndex(): the index named `name` in database `zdb`
/// (all, TEMP first, if null).
pub fn findIndex(db: *Sqlite3, name: []const u8, zdb: ?[]const u8) ?*Index {
    for (0..db.dbs.items.len) |i| {
        const j = if (i < 2) i ^ 1 else i;
        if (zdb) |n| if (!dbIsNamed(db, j, n)) continue;
        if (db.dbs.items[j].schema.idx_hash.get(name)) |idx| return idx;
    }
    return null;
}

/// Port of sqlite3UnlinkAndDeleteIndex(): remove a dropped index from
/// the schema. Its memory belongs to its table and is freed with it.
pub fn unlinkAndDeleteIndex(db: *Sqlite3, i_db: usize, name: [:0]const u8) void {
    const kv = db.dbs.items[i_db].schema.idx_hash.fetchRemove(name) orelse return;
    const idx = kv.value;
    const t = idx.table;
    if (t.index == idx) {
        t.index = idx.next;
    } else {
        var p = t.index;
        while (p) |q| : (p = q.next) {
            if (q.next == idx) {
                q.next = idx.next;
                break;
            }
        }
    }
    db.m_db_flags.SchemaChange = true;
}

/// Port of sqlite3SchemaClear() (callback.c): forget every object of a
/// schema.
pub fn schemaClear(db: *Sqlite3, s: *Schema) void {
    var trig_it = s.trig_hash.valueIterator();
    while (trig_it.next()) |trig| trigger_mod.deleteTrigger(db, trig.*);
    s.trig_hash.clearRetainingCapacity();
    var it = s.tbl_hash.valueIterator();
    while (it.next()) |t| {
        // A table still referenced outlives its triggers.
        t.*.trigger = null;
        deleteTable(db, t.*);
    }
    s.tbl_hash.clearRetainingCapacity();
    s.tbl_order.clear(db.gpa);
    s.idx_hash.clearRetainingCapacity();
    s.fkey_hash.clearRetainingCapacity();
    s.seq_tab = null;
    if (s.schema_flags.SchemaLoaded) {
        s.i_generation +%= 1;
    }
    s.schema_flags.SchemaLoaded = false;
    s.schema_flags.ResetWanted = false;
}

/// Free the maps of a schema whose objects are cleared.
pub fn schemaFree(db: *Sqlite3, s: *Schema) void {
    schemaClear(db, s);
    s.tbl_hash.deinit(db.gpa);
    s.idx_hash.deinit(db.gpa);
    s.trig_hash.deinit(db.gpa);
    s.fkey_hash.deinit(db.gpa);
}

/// Port of sqlite3ResetOneSchema(): forget the schema of database `i_db`
/// and of TEMP, so they are read again. With `i_db` null only the resets
/// deferred by n_schema_lock are done.
pub fn resetOneSchema(db: *Sqlite3, i_db: ?usize) void {
    if (i_db) |i| {
        db.dbs.items[i].schema.schema_flags.ResetWanted = true;
        db.dbs.items[1].schema.schema_flags.ResetWanted = true;
        db.m_db_flags.SchemaKnownOk = false;
    }
    if (db.n_schema_lock == 0) {
        for (db.dbs.items) |*d| {
            if (d.schema.schema_flags.ResetWanted) {
                schemaClear(db, d.schema);
                db.m_db_flags.SchemaKnownOk = false;
            }
        }
    }
}

/// Port of sqlite3ResetAllSchemasOfConnection(): forget every schema so
/// it is read again.
pub fn resetAllSchemasOfConnection(db: *Sqlite3) void {
    for (db.dbs.items) |*d| {
        if (db.n_schema_lock == 0) {
            schemaClear(db, d.schema);
        } else {
            d.schema.schema_flags.ResetWanted = true;
        }
    }
    db.m_db_flags.clear(.{ .SchemaChange = true, .SchemaKnownOk = true });
    vtab_mod.unlockList(db);
}

/// The allocator of `t`'s memory: its arena if it is a schema table,
/// else the statement's.
pub fn tableAlloc(p: *Parse, t: *Table) Allocator {
    return if (t.mem) |m| m.allocator() else p.arena;
}

/// Port of sqlite3ColumnSetExpr(): set the DEFAULT (or generated) value
/// of a column; `e` must already belong to the table's memory.
pub fn columnSetExpr(p: *Parse, t: *Table, col: *Column, e: ?*Expr) Oom!void {
    std.debug.assert(t.isOrdinary());
    const list = t.u.tab.dflt_list;
    if (col.i_dflt == 0 or list == null or list.?.len() < col.i_dflt) {
        col.i_dflt = if (list) |l| @intCast(l.len() + 1) else 1;
        t.u.tab.dflt_list = try expr_mod.listAppendIn(tableAlloc(p, t), list, e);
    } else {
        list.?.at(col.i_dflt - 1).expr = e;
    }
}

/// Port of sqlite3ColumnExpr(): the DEFAULT or generated value of a
/// column, or null.
pub fn columnExpr(t: *Table, col: *const Column) ?*Expr {
    if (col.i_dflt == 0) return null;
    if (!t.isOrdinary()) return null;
    const list = t.u.tab.dflt_list orelse return null;
    if (list.len() < col.i_dflt) return null;
    return list.at(col.i_dflt - 1).expr;
}

/// The string after the NUL that ends `z`: the declared type follows the
/// name in Column.cn_name, and the collation follows them.
fn afterNul(z: [*:0]const u8) [*:0]const u8 {
    return z + std.mem.len(z) + 1;
}

/// Port of sqlite3ColumnSetColl().
pub fn columnSetColl(a: Allocator, col: *Column, coll: []const u8) Oom!void {
    var end: [*:0]const u8 = afterNul(col.cn_name.ptr);
    if (col.col_flags.HASTYPE) end = afterNul(end);
    const n = @intFromPtr(end) - @intFromPtr(col.cn_name.ptr);
    const new = try a.allocSentinel(u8, n + coll.len, 0);
    @memcpy(new[0..n], col.cn_name.ptr[0..n]);
    @memcpy(new[n..], coll);
    col.cn_name = new[0..col.cn_name.len :0];
    col.col_flags.HASCOLL = true;
}

/// Port of sqlite3ColumnColl(): the declared collation of a column, or
/// null.
pub fn columnColl(col: *const Column) ?[:0]const u8 {
    if (!col.col_flags.HASCOLL) return null;
    var z = afterNul(col.cn_name.ptr);
    if (col.col_flags.HASTYPE) z = afterNul(z);
    return std.mem.span(z);
}

/// Port of sqlite3ColumnType(): the declared type of a column, or `dflt`.
pub fn columnType(col: *const Column, dflt: [:0]const u8) [:0]const u8 {
    if (col.col_flags.HASTYPE) return std.mem.span(afterNul(col.cn_name.ptr));
    if (col.e_ctype != .CUSTOM) return std_type[col.e_ctype.stdTypeIndex()];
    return dflt;
}

/// sqlite3StdType[] and sqlite3StdTypeAffinity[]: the type names of
/// STRICT tables.
pub const std_type = [_][:0]const u8{ "ANY", "BLOB", "INT", "INTEGER", "REAL", "TEXT" };
pub const std_type_affinity = [_]u8{ Aff.numeric, Aff.blob, Aff.integer, Aff.integer, Aff.real, Aff.text };

comptime {
    // In COLTYPE order from COLTYPE_ANY.
    for (std_type, 0..) |name, i| std.debug.assert(std.mem.eql(u8, @tagName(COLTYPE.fromStdTypeIndex(i)), name));
}

/// Take a reference to `t` for the parse trees of `p`, released by
/// releaseTableRefs(). (SQLite counts a reference per SrcItem and drops
/// it as the tree is freed; the trees here live in an arena.)
pub fn tableRef(p: *Parse, t: *Table) void {
    p.tab_refs.append(p.arena, t) catch return oomFault(p);
    t.n_tab_ref += 1;
}

/// Drop the references taken by tableRef().
pub fn releaseTableRefs(p: *Parse) void {
    for (p.tab_refs.items) |t| deleteTable(p.db, t);
    p.tab_refs = .empty;
}

/// Port of sqlite3DeleteTable(): free a table once nothing refers to it.
/// Tables of a single statement live in its arena and are not freed.
pub fn deleteTable(db: *Sqlite3, t: *Table) void {
    if (t.n_tab_ref > 1) {
        t.n_tab_ref -= 1;
        return;
    }
    const m = t.mem orelse return;
    // Unhook its indexes and foreign keys from the schema.
    var idx = t.index;
    while (idx) |ix| : (idx = ix.next) {
        if (ix.schema) |s| {
            if (s.idx_hash.get(ix.name)) |cur| if (cur == ix) {
                _ = s.idx_hash.remove(ix.name);
            };
        }
    }
    if (t.isOrdinary()) fkey_mod.fkDelete(db, t);
    if (t.isVirtual()) vtab_mod.clear(db, t);
    if (t.isView()) freeViewColumns(db, t);
    m.deinit();
    db.gpa.destroy(m);
}

/// Port of sqlite3UnlinkAndDeleteTable(): remove a dropped table from
/// the schema.
pub fn unlinkAndDeleteTable(db: *Sqlite3, i_db: usize, name: [:0]const u8) void {
    const kv = db.dbs.items[i_db].schema.tbl_hash.fetchRemove(name) orelse return;
    db.dbs.items[i_db].schema.tbl_order.remove(db.gpa, name);
    deleteTable(db, kv.value);
    db.m_db_flags.SchemaChange = true;
}

/// Port of sqlite3OpenSchemaTable(): open sqlite_schema of `i_db` for
/// writing on cursor 0.
pub fn openSchemaTable(p: *Parse, i_db: usize) void {
    const v = getVdbe(p) orelse return;
    _ = aux.addOp4Int(v, OP.OpenWrite, 0, int.SCHEMA_ROOT, @intCast(i_db), 5);
    if (p.n_tab == 0) p.n_tab = 1;
}

/// Port of sqlite3FindDbName(): the index of the database named `name`,
/// or null.
pub fn findDbName(db: *Sqlite3, name: ?[]const u8) ?usize {
    const z = name orelse return null;
    var i = db.dbs.items.len;
    while (i > 0) {
        i -= 1;
        if (ctype.eqlNoCase(db.dbs.items[i].name, z)) return i;
        if (i == 0 and ctype.eqlNoCase("main", z)) return 0;
    }
    return null;
}

/// Port of sqlite3FindDb().
pub fn findDb(p: *Parse, name: Token) ?usize {
    const z = (nameFromToken(p.arena, name) catch {
        oomFault(p);
        return null;
    }).?;
    return findDbName(p.db, z);
}

/// Port of sqlite3TwoPartName(): the database of "name1.name2" (or the
/// current one if `name2` is empty), with the unqualified name in `unqual`.
pub fn twoPartName(p: *Parse, name1: *const Token, name2: *const Token, unqual: **const Token) ?usize {
    const db = p.db;
    if (name2.n > 0) {
        if (db.init.busy) {
            util.errorMsg(p, "corrupt database", .{});
            return null;
        }
        unqual.* = name2;
        return findDb(p, name1.*) orelse {
            util.errorMsgAt(p, name1.z, "unknown database {s}", .{name1.slice()});
            return null;
        };
    }
    unqual.* = name1;
    return db.init.i_db;
}

/// Port of sqlite3WritableSchema(): PRAGMA writable_schema is on.
pub fn writableSchema(db: *Sqlite3) bool {
    return db.flags.WriteSchema and !db.flags.Defensive;
}

/// Port of sqlite3CheckObjectName(): names starting with "sqlite_" are
/// reserved; while reading the schema, the type, name and table must
/// agree with the sqlite_schema row. On error (C: SQLITE_ERROR) the error
/// is in `p`.
pub fn checkObjectName(p: *Parse, name: []const u8, typ: []const u8, tbl_name: []const u8) int.ParseError!void {
    const db = p.db;
    if (writableSchema(db) or db.init.imposter_table != 0) return;
    if (db.init.busy) {
        if (!ctype.eqlNoCase(typ, db.init.az_init[0]) or
            !ctype.eqlNoCase(name, db.init.az_init[1]) or
            !ctype.eqlNoCase(tbl_name, db.init.az_init[2]))
        {
            // corruptSchema() supplies the message.
            util.errorMsg(p, "", .{});
            return error.ParseFailed;
        }
    } else if (p.nested == 0 and hasSqlitePrefix(name)) {
        util.errorMsg(p, "object name reserved for internal use: {s}", .{name});
        return error.ParseFailed;
    }
}

/// Port of sqlite3PrimaryKeyIndex().
pub fn primaryKeyIndex(t: *Table) ?*Index {
    var p = t.index;
    while (p) |ix| : (p = ix.next) {
        if (ix.isPrimaryKey()) return ix;
    }
    return null;
}

/// Port of sqlite3TableColumnToIndex(): the first position of table
/// column `i_col` in `idx`, or -1.
pub fn tableColumnToIndex(idx: *const Index, i_col: i32) i32 {
    for (idx.ai_column[0..idx.n_column], 0..) |c, i| {
        if (c == i_col) return @intCast(i);
    }
    return -1;
}

/// Port of sqlite3StorageColumnToTable().
pub fn storageColumnToTable(t: *const Table, i_col_arg: i16) i16 {
    var i_col = i_col_arg;
    if (t.tab_flags.HasVirtual) {
        var i: usize = 0;
        while (i <= i_col) : (i += 1) {
            if (t.cols[i].col_flags.VIRTUAL) i_col += 1;
        }
    }
    return i_col;
}

/// Port of sqlite3TableColumnToStorage(): VIRTUAL columns are stored
/// after all the others.
pub fn tableColumnToStorage(t: *const Table, i_col: i16) i16 {
    if (!t.tab_flags.HasVirtual or i_col < 0) return i_col;
    var n: i16 = 0;
    var i: usize = 0;
    while (i < i_col) : (i += 1) {
        if (!t.cols[i].col_flags.VIRTUAL) n += 1;
    }
    if (t.cols[i].col_flags.VIRTUAL) {
        return t.n_nv_col + @as(i16, @intCast(i)) - n;
    }
    return n;
}

/// Port of sqlite3ColumnIndex(): the column of `t` named `name`, or -1.
pub fn columnIndex(t: *const Table, name: []const u8) i32 {
    for (t.cols, 0..) |*c, i| {
        if (ctype.eqlNoCase(c.name(), name)) return @intCast(i);
    }
    return -1;
}

/// Port of sqlite3ForceNotReadOnly(): make sqlite3_stmt_readonly() false.
fn forceNotReadOnly(p: *Parse) void {
    p.n_mem += 1;
    const reg = p.n_mem;
    const v = getVdbe(p) orelse return;
    _ = aux.addOp3(v, OP.JournalMode, 0, reg, -1);
    aux.usesBtree(v, 0);
}

/// Allocate a new schema table named `name` with its own arena.
pub fn newSchemaTable(db: *Sqlite3, name: []const u8) Oom!*Table {
    const m = try db.gpa.create(std.heap.ArenaAllocator);
    m.* = .init(db.gpa);
    errdefer {
        m.deinit();
        db.gpa.destroy(m);
    }
    const a = m.allocator();
    const t = try a.create(Table);
    t.* = .{ .name = try a.dupeSentinel(u8, name, 0), .mem = m };
    return t;
}

/// Port of sqlite3StartTable(): start building a new table (or view) in
/// p.new_table. Unless reading the schema, code a placeholder row in
/// sqlite_schema whose rowid and root page later code fills in.
pub fn startTable(p: *Parse, name1: Token, name2: Token, is_temp_arg: bool, is_view: bool, is_virtual: bool, no_err: bool) void {
    const db = p.db;
    var is_temp = is_temp_arg;
    var i_db: usize = undefined;
    var name_tok: *const Token = &name1;
    var name: []const u8 = undefined;
    if (p.syntax_only) return;
    if (db.init.busy and db.init.new_tnum == 1) {
        // Reading sqlite_schema or sqlite_temp_schema itself.
        i_db = db.init.i_db;
        name = int.schemaTable(i_db);
    } else {
        i_db = twoPartName(p, &name1, &name2, &name_tok) orelse return;
        if (is_temp and name2.n > 0 and i_db != 1) {
            util.errorMsg(p, "temporary table name must be unqualified", .{});
            return;
        }
        if (is_temp) i_db = 1;
        name = (nameFromToken(p.arena, name_tok.*) catch return oomFault(p)).?;
    }
    p.name_token = name_tok.*;
    checkObjectName(p, name, if (is_view) "view" else "table", name) catch {
        p.check_schema = true;
        return;
    };
    if (db.init.i_db == 1) is_temp = true;

    // The name must not collide with a table or index of the database.
    if (!p.inSpecialParse()) {
        const zdb = db.dbs.items[i_db].name;
        prepare.readSchema(p) catch {
            p.check_schema = true;
            return;
        };
        if (findTable(db, name, zdb)) |t| {
            if (!no_err) {
                util.errorMsgAt(p, name_tok.z, "{s} {s} already exists", .{ if (t.isView()) "view" else "table", name_tok.slice() });
            } else {
                std.debug.assert(!db.init.busy);
                codeVerifySchema(p, i_db);
                forceNotReadOnly(p);
            }
            p.check_schema = true;
            return;
        }
        if (findIndex(db, name, zdb) != null) {
            util.errorMsg(p, "there is already an index named {s}", .{name});
            p.check_schema = true;
            return;
        }
    }

    const t = newSchemaTable(db, name) catch return oomFault(p);
    if (p.inRenameObject()) alter.renameTokenMap(p, t.name, name_tok.*);
    t.schema = db.dbs.items[i_db].schema;
    t.n_row_log_est = 200;
    std.debug.assert(p.new_table == null);
    p.new_table = t;

    // Code a placeholder row in sqlite_schema now: the rowid of the
    // table's row must be allocated before those of any indexes the
    // PRIMARY KEY or UNIQUE constraints create.
    if (!db.init.busy) if (getVdbe(p)) |v| {
        const null_row = [_]u8{ 6, 0, 0, 0, 0, 0 };
        beginWriteOperation(p, true, i_db);
        if (is_virtual) _ = aux.addOp0(v, OP.VBegin);
        p.n_mem += 1;
        const reg1 = p.n_mem;
        p.n_mem += 1;
        const reg2 = p.n_mem;
        p.n_mem += 1;
        const reg3 = p.n_mem;
        p.u1 = .{ .cr = .{ .reg_rowid = reg1, .reg_root = reg2 } };
        _ = aux.addOp3(v, OP.ReadCookie, @intCast(i_db), reg3, @intFromEnum(btree.Meta.file_format));
        aux.usesBtree(v, @intCast(i_db));
        const addr1 = aux.addOp1(v, OP.If, reg3);
        const file_format: i32 = if (db.flags.LegacyFileFmt) 1 else int.MAX_FILE_FORMAT;
        _ = aux.addOp3(v, OP.SetCookie, @intCast(i_db), @intFromEnum(btree.Meta.file_format), file_format);
        _ = aux.addOp3(v, OP.SetCookie, @intCast(i_db), @intFromEnum(btree.Meta.text_encoding), db.enc);
        aux.jumpHere(v, addr1);
        if (is_view or is_virtual) {
            _ = aux.addOp2(v, OP.Integer, 0, reg2);
        } else {
            p.u1.cr.addr_cr_tab = aux.addOp3(v, OP.CreateBtree, @intCast(i_db), reg2, BTREE_INTKEY);
        }
        openSchemaTable(p, i_db);
        _ = aux.addOp2(v, OP.NewRowid, 0, reg1);
        const blob = aux.addOp3(v, OP.Blob, 6, reg3, 0);
        aux.changeP4Str(v, blob, &null_row);
        _ = aux.addOp3(v, OP.Insert, 0, reg3, reg1);
        aux.changeP5(v, OPFLAG.APPEND);
        _ = aux.addOp0(v, OP.Close);
    } else if (db.init.imposter_table != 0) {
        t.tab_flags.Imposter = true;
        if (db.init.imposter_table >= 2) t.tab_flags.Readonly = true;
    };
}

/// Port of sqlite3AddColumn(): add a column to the table under
/// construction.
pub fn addColumn(p: *Parse, name_arg: Token, type_arg: Token) void {
    addColumnImpl(p, name_arg, type_arg) catch oomFault(p);
}

fn addColumnImpl(p: *Parse, name_arg: Token, type_arg: Token) Oom!void {
    const t = p.new_table orelse return;
    const db = p.db;
    var s_name = name_arg;
    var s_type = type_arg;
    var e_type: COLTYPE = COLTYPE.CUSTOM;
    var sz_est: u8 = 1;
    var affinity: u8 = Aff.blob;
    if (t.cols.len + 1 > @as(usize, @intCast(db.limit(.column)))) {
        util.errorMsg(p, "too many columns on {s}", .{t.name});
        return;
    }
    if (!p.inRenameObject()) util.dequoteToken(&s_name);

    // "GENERATED ALWAYS" can end up at the end of the type name.
    if (s_type.n >= 16 and ctype.eqlNoCase(s_type.z.?[s_type.n - 6 .. s_type.n], "always")) {
        s_type.n -= 6;
        while (s_type.n > 0 and ctype.isSpace(s_type.z.?[s_type.n - 1])) s_type.n -= 1;
        if (s_type.n >= 9 and ctype.eqlNoCase(s_type.z.?[s_type.n - 9 .. s_type.n], "generated")) {
            s_type.n -= 9;
            while (s_type.n > 0 and ctype.isSpace(s_type.z.?[s_type.n - 1])) s_type.n -= 1;
        }
    }

    // Standard type names set e_ctype instead of being stored.
    if (s_type.n >= 3) {
        util.dequoteToken(&s_type);
        for (std_type, 0..) |st, i| {
            if (s_type.n == st.len and ctype.eqlNoCase(s_type.slice(), st)) {
                s_type.n = 0;
                e_type = .fromStdTypeIndex(i);
                affinity = std_type_affinity[i];
                if (affinity <= Aff.text) sz_est = 5;
                break;
            }
        }
    }

    const a = tableAlloc(p, t);
    const n_extra: usize = if (s_type.n > 0) s_type.n + 1 else 0;
    const z = try a.allocSentinel(u8, s_name.n + n_extra, 0);
    if (p.inRenameObject()) alter.renameTokenMap(p, z, s_name);
    @memcpy(z[0..s_name.n], s_name.slice());
    z[s_name.n] = 0;
    const name_len = util.dequote(z[0..s_name.n :0]).len;
    if (t.cols.len > 0 and columnIndex(t, z[0..name_len]) >= 0) {
        util.errorMsg(p, "duplicate column name: {s}", .{z[0..name_len]});
        return;
    }
    const cols = try a.realloc(t.cols, t.cols.len + 1);
    t.cols = cols;
    const col = &cols[cols.len - 1];
    col.* = .{ .cn_name = z[0..name_len :0] };
    if (s_type.n == 0) {
        col.affinity = affinity;
        col.e_ctype = e_type;
        col.sz_est = sz_est;
    } else {
        const zt = z[name_len + 1 ..];
        @memcpy(zt[0..s_type.n], s_type.slice());
        zt[s_type.n] = 0;
        const typ = util.dequote(zt[0..s_type.n :0]);
        col.affinity = affinityType(typ, col);
        col.col_flags.HASTYPE = true;
    }
    t.n_nv_col += 1;
    p.u1.cr.constraint_name.n = 0;
}

/// Port of sqlite3AddNotNull(): NOT NULL on the last column.
pub fn addNotNull(p: *Parse, on_error: OE) void {
    const t = p.new_table orelse return;
    if (t.cols.len < 1) return;
    const col = &t.cols[t.cols.len - 1];
    col.not_null = on_error;
    t.tab_flags.HasNotNull = true;
    // UNIQUE and PRIMARY KEY indexes already made on the column.
    if (col.col_flags.UNIQUE) {
        var idx = t.index;
        while (idx) |ix| : (idx = ix.next) {
            if (ix.ai_column[0] == t.cols.len - 1) ix.uniq_not_null = true;
        }
    }
}

/// Port of sqlite3AffinityType(): the affinity of a declared type name,
/// with the size estimate stored in `col` if given.
pub fn affinityType(z_in: []const u8, col: ?*Column) u8 {
    var h: u32 = 0;
    var aff: u8 = Aff.numeric;
    var z_char: ?usize = null;
    var i: usize = 0;
    while (i < z_in.len and z_in[i] != 0) {
        h = (h << 8) +% ctype.toLower(z_in[i]);
        i += 1;
        if (h == fourcc("char")) {
            aff = Aff.text;
            z_char = i;
        } else if (h == fourcc("clob")) {
            aff = Aff.text;
        } else if (h == fourcc("text")) {
            aff = Aff.text;
        } else if (h == fourcc("blob") and (aff == Aff.numeric or aff == Aff.real)) {
            aff = Aff.blob;
            if (i < z_in.len and z_in[i] == '(') z_char = i;
        } else if (h == fourcc("real") and aff == Aff.numeric) {
            aff = Aff.real;
        } else if (h == fourcc("floa") and aff == Aff.numeric) {
            aff = Aff.real;
        } else if (h == fourcc("doub") and aff == Aff.numeric) {
            aff = Aff.real;
        } else if (h & 0x00FFFFFF == (@as(u32, 'i') << 16) + (@as(u32, 'n') << 8) + 't') {
            aff = Aff.integer;
            break;
        }
    }
    if (col) |c| {
        var v: i32 = 0;
        if (aff < Aff.numeric) {
            if (z_char) |zc| {
                var j = zc;
                while (j < z_in.len and z_in[j] != 0) : (j += 1) {
                    if (ctype.isDigit(z_in[j])) {
                        v = util.getInt32(z_in[j..]) orelse 0;
                        break;
                    }
                }
            } else {
                v = 16;
            }
        }
        v = @divTrunc(v, 4) + 1;
        if (v > 255) v = 255;
        c.sz_est = @intCast(v);
    }
    return aff;
}

fn fourcc(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) + (@as(u32, s[1]) << 16) + (@as(u32, s[2]) << 8) + s[3];
}

/// Port of sqlite3AddDefaultValue(): DEFAULT on the last column. `e` is
/// copied into the table's memory, wrapped in a TK_SPAN with the text.
pub fn addDefaultValue(p: *Parse, e: ?*Expr, start: ?[*]const u8, end: ?[*]const u8) void {
    addDefaultValueImpl(p, e, start, end) catch oomFault(p);
}

fn addDefaultValueImpl(p: *Parse, e: ?*Expr, start: ?[*]const u8, end: ?[*]const u8) Oom!void {
    const db = p.db;
    const t = p.new_table orelse return;
    const is_init = db.init.busy and db.init.i_db != 1;
    const col = &t.cols[t.cols.len - 1];
    if (!expr_mod.isConstantOrFunction(e, is_init)) {
        util.errorMsg(p, "default value of column [{s}] is not constant", .{col.name()});
    } else if (col.col_flags.intersects(COLFLAG.GENERATED)) {
        util.errorMsg(p, "cannot use DEFAULT on a generated column", .{});
    } else {
        var x: Expr = .{ .op = TK.SPAN, .flags = .{ .Skip = true }, .left = e };
        x.u = .{ .token = try expr_mod.spanDup(p.arena, start.?, end.?) };
        const dflt = try expr_mod.exprDup(tableAlloc(p, t), &x);
        try columnSetExpr(p, t, col, dflt);
    }
    if (p.inRenameObject()) alter.renameExprUnmap(p, e);
}

/// Port of sqlite3StringToId(): accept 'name' for a column name in
/// PRIMARY KEY, UNIQUE and index definitions.
fn stringToId(e: *Expr) void {
    if (e.op == TK.STRING) {
        e.op = TK.ID;
    } else if (e.op == TK.COLLATE and e.left.?.op == TK.STRING) {
        e.left.?.op = TK.ID;
    }
}

/// Port of makeColumnPartOfPrimaryKey().
fn makeColumnPartOfPrimaryKey(p: *Parse, col: *Column) void {
    col.col_flags.PRIMKEY = true;
    if (col.col_flags.intersects(COLFLAG.GENERATED)) {
        util.errorMsg(p, "generated columns cannot be part of the PRIMARY KEY", .{});
    }
}

/// Port of sqlite3AddPrimaryKey(): the PRIMARY KEY of the table under
/// construction: the columns of `list`, or the last column. A single
/// INTEGER column (not DESC) becomes the rowid; anything else gets an
/// index.
pub fn addPrimaryKey(p: *Parse, list: ?*ExprList, on_error: OE, autoinc: bool, sort_order: i32) void {
    const t = p.new_table orelse return;
    if (t.tab_flags.HasPrimaryKey) {
        util.errorMsg(p, "table \"{s}\" has more than one primary key", .{t.name});
        return;
    }
    t.tab_flags.HasPrimaryKey = true;
    var col: ?*Column = null;
    var i_col: i32 = -1;
    var n_term: usize = undefined;
    if (list) |l| {
        n_term = l.len();
        for (l.slice()) |*item| {
            const ce = expr_mod.skipCollate(item.expr).?;
            stringToId(ce);
            if (ce.op == TK.ID) {
                i_col = columnIndex(t, ce.token());
                if (i_col >= 0) {
                    col = &t.cols[@intCast(i_col)];
                    makeColumnPartOfPrimaryKey(p, col.?);
                }
            }
        }
    } else {
        i_col = @as(i32, @intCast(t.cols.len)) - 1;
        col = &t.cols[@intCast(i_col)];
        makeColumnPartOfPrimaryKey(p, col.?);
        n_term = 1;
    }
    if (n_term == 1 and col != null and col.?.e_ctype == COLTYPE.INTEGER and sort_order != int.SortOrder.desc) {
        if (p.inRenameObject()) if (list) |l| {
            alter.renameTokenRemap(p, &t.i_pkey, expr_mod.skipCollate(l.at(0).expr));
        };
        t.i_pkey = @intCast(i_col);
        t.key_conf = on_error;
        if (autoinc) t.tab_flags.Autoincrement = true;
        if (list) |l| p.i_pk_sort_order = l.at(0).fg.sort_flags;
        _ = hasExplicitNulls(p, list);
    } else if (autoinc) {
        util.errorMsg(p, "AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY", .{});
    } else {
        createIndex(p, null, null, null, list, on_error, null, null, sort_order, false, .primarykey);
    }
}

/// Port of sqlite3AddCheckConstraint(): a CHECK constraint of the table
/// under construction, named by CONSTRAINT or by its text.
pub fn addCheckConstraint(p: *Parse, e: ?*Expr, start: ?[*]const u8, end: ?[*]const u8) void {
    addCheckConstraintImpl(p, e, start, end) catch oomFault(p);
}

fn addCheckConstraintImpl(p: *Parse, e: ?*Expr, start_arg: ?[*]const u8, end_arg: ?[*]const u8) Oom!void {
    const db = p.db;
    const t = p.new_table orelse return;
    if (p.inDeclareVtab()) return;
    if (db.dbs.items[db.init.i_db].bt) |bt| if (bt.read_only) return;
    const a = tableAlloc(p, t);
    // In rename mode the expression itself is kept: the rename map has
    // its nodes.
    const ce = if (p.inRenameObject()) e else try expr_mod.exprDup(a, e);
    t.check = try expr_mod.listAppendIn(a, t.check, ce);
    const item = t.check.?.last();
    var name = p.u1.cr.constraint_name;
    if (name.n == 0) {
        var start = start_arg.? + 1;
        while (ctype.isSpace(start[0])) start += 1;
        var end = end_arg.?;
        while (ctype.isSpace((end - 1)[0])) end -= 1;
        name = .{ .z = start, .n = @intCast(@intFromPtr(end) - @intFromPtr(start)) };
    }
    item.e_name = util.dequote(try a.dupeSentinel(u8, name.slice(), 0));
    if (p.inRenameObject()) alter.renameTokenMap(p, item.e_name, name);
}

/// Port of sqlite3AddCollateType(): COLLATE on the last column.
pub fn addCollateType(p: *Parse, tok: Token) void {
    const t = p.new_table orelse return;
    if (p.inRenameObject()) return;
    const i = t.cols.len - 1;
    const z = (nameFromToken(p.arena, tok) catch return oomFault(p)).?;
    if (coll_mod.locateCollSeq(p, z) != null) {
        columnSetColl(tableAlloc(p, t), &t.cols[i], z) catch return oomFault(p);
        // An index made by "<name> PRIMARY KEY COLLATE <type>" before
        // the collation was seen.
        var idx = t.index;
        while (idx) |ix| : (idx = ix.next) {
            if (ix.ai_column[0] == i) ix.coll[0] = columnColl(&t.cols[i]).?;
        }
    }
}

/// Port of sqlite3AddGenerated(): GENERATED ALWAYS AS on the last column.
pub fn addGenerated(p: *Parse, e_arg: ?*Expr, type_tok: ?Token) void {
    addGeneratedImpl(p, e_arg, type_tok) catch oomFault(p);
}

fn addGeneratedImpl(p: *Parse, e_arg: ?*Expr, type_tok: ?Token) Oom!void {
    const t = p.new_table orelse return;
    const col = &t.cols[t.cols.len - 1];
    var e_type: COLFLAG = .{ .VIRTUAL = true };
    if (p.inDeclareVtab()) {
        util.errorMsg(p, "virtual tables cannot use computed columns", .{});
        return;
    }
    if (col.i_dflt > 0) {
        util.errorMsg(p, "error in generated column \"{s}\"", .{col.name()});
        return;
    }
    if (type_tok) |tt| {
        if (tt.n == 7 and ctype.eqlNoCase("virtual", tt.slice())) {
            // no-op
        } else if (tt.n == 6 and ctype.eqlNoCase("stored", tt.slice())) {
            e_type = .{ .STORED = true };
        } else {
            util.errorMsg(p, "error in generated column \"{s}\"", .{col.name()});
            return;
        }
    }
    if (e_type == COLFLAG{ .VIRTUAL = true }) t.n_nv_col -= 1;
    col.col_flags.set(e_type);
    t.tab_flags.set(.ofColumn(e_type));
    if (col.col_flags.PRIMKEY) makeColumnPartOfPrimaryKey(p, col);
    var e = e_arg;
    if (e != null and e.?.op == TK.ID) {
        // A generated column must be an expression, not a bare column.
        e = try expr_mod.pExpr(p, TK.UPLUS, e, null);
    }
    if (e) |x| if (x.op != TK.RAISE) {
        x.aff_expr = col.affinity;
    };
    // In rename mode the expression itself is kept for the rename map.
    try columnSetExpr(p, t, col, if (p.inRenameObject()) e else try expr_mod.exprDup(tableAlloc(p, t), e));
}

/// Port of sqlite3ChangeCookie(): code an increment of the schema cookie.
pub fn changeCookie(p: *Parse, i_db: usize) void {
    const db = p.db;
    const v = p.vdbe.?;
    const cookie: u32 = @bitCast(db.dbs.items[i_db].schema.schema_cookie);
    _ = aux.addOp3(v, OP.SetCookie, @intCast(i_db), @intFromEnum(btree.Meta.schema_version), @bitCast(cookie +% 1));
}

/// Port of identPut(): append an identifier, quoted if it is not a plain
/// identifier.
fn identPut(out: *std.ArrayList(u8), a: Allocator, ident: []const u8) Oom!void {
    var j: usize = 0;
    while (j < ident.len) : (j += 1) {
        if (!ctype.isAlnum(ident[j]) and ident[j] != '_') break;
    }
    const need_quote = (ident.len > 0 and ctype.isDigit(ident[0])) or
        @import("../parse/tokenize.zig").keywordCode(ident[0..j]) != TK.ID or
        j != ident.len or j == 0;
    if (need_quote) try out.append(a, '"');
    for (ident) |c| {
        try out.append(a, c);
        if (c == '"') try out.append(a, '"');
    }
    if (need_quote) try out.append(a, '"');
}

/// Port of createTableStmt(): a CREATE TABLE statement for `t`, as for
/// "CREATE TABLE ... AS SELECT".
fn createTableStmt(a: Allocator, t: *Table) Oom![:0]u8 {
    var n: usize = 0;
    for (t.cols) |*c| n += c.name().len + 2 + 5;
    n += t.name.len + 2;
    const sep_first, const sep, const end = if (n < 50) .{ "", ",", ")" } else .{ "\n  ", ",\n  ", "\n)" };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "CREATE TABLE ");
    try identPut(&out, a, t.name);
    try out.append(a, '(');
    const types = [_][]const u8{ "", " TEXT", " NUM", " INT", " REAL", " NUM" };
    for (t.cols, 0..) |*c, i| {
        try out.appendSlice(a, if (i == 0) sep_first else sep);
        try identPut(&out, a, c.name());
        try out.appendSlice(a, types[c.affinity - Aff.blob]);
    }
    try out.appendSlice(a, end);
    return out.toOwnedSliceSentinel(a, 0);
}

/// Port of resizeIndexObject(): room for `n` columns in `idx`.
fn resizeIndexObject(a: Allocator, idx: *Index, n: usize) Oom!void {
    if (idx.n_column >= n) return;
    std.debug.assert(!idx.is_resized);
    const coll = try a.alloc([:0]const u8, n);
    @memcpy(coll[0..idx.n_column], idx.coll[0..idx.n_column]);
    const row_est = try a.alloc(LogEst, n + 1);
    @memset(row_est, 0);
    @memcpy(row_est[0 .. idx.n_key_col + 1], idx.ai_row_log_est[0 .. idx.n_key_col + 1]);
    const cols = try a.alloc(i16, n);
    @memcpy(cols[0..idx.n_column], idx.ai_column[0..idx.n_column]);
    const order = try a.alloc(u8, n);
    @memset(order, 0);
    @memcpy(order[0..idx.n_column], idx.sort_order[0..idx.n_column]);
    idx.coll = coll;
    idx.ai_row_log_est = row_est;
    idx.ai_column = cols;
    idx.sort_order = order;
    idx.n_column = @intCast(n);
    idx.is_resized = true;
}

/// Port of sqlite3IndexBloomable().
pub fn indexBloomable(idx: *const Index, n: usize) bool {
    for (idx.coll[0..n]) |c| if (!ctype.eqlNoCase(c, coll_mod.str_binary)) return false;
    return true;
}

/// Port of estimateTableWidth().
fn estimateTableWidth(t: *Table) void {
    var w: u64 = 0;
    for (t.cols) |c| w += c.sz_est;
    if (t.i_pkey < 0) w += 1;
    t.sz_tab_row = util.logEst(w * 4);
}

/// Port of estimateIndexWidth().
fn estimateIndexWidth(idx: *Index) void {
    var w: u64 = 0;
    const cols = idx.table.cols;
    for (idx.ai_column[0..idx.n_column]) |x| w += if (x < 0) 1 else cols[@intCast(x)].sz_est;
    idx.sz_idx_row = util.logEst(w * 4);
}

/// Port of hasColumn().
fn hasColumn(ai_col: []const i16, x: i32) bool {
    for (ai_col) |c| if (c == x) return true;
    return false;
}

/// Port of isDupColumn(): column `i_col` of the WITHOUT ROWID primary
/// key `pk` is among the first `n_key` columns of `idx`, with the same
/// collation.
fn isDupColumn(idx: *const Index, n_key: usize, pk: *const Index, i_col: usize) bool {
    const j = pk.ai_column[i_col];
    for (0..n_key) |i| {
        if (idx.ai_column[i] == j and ctype.eqlNoCase(idx.coll[i], pk.coll[i_col])) return true;
    }
    return false;
}

/// Port of recomputeColumnsNotIndexed().
fn recomputeColumnsNotIndexed(idx: *Index) void {
    var m: int.Bitmask = 0;
    const t = idx.table;
    var j = idx.n_column;
    while (j > 0) {
        j -= 1;
        const x = idx.ai_column[j];
        if (x >= 0 and !t.cols[@intCast(x)].col_flags.VIRTUAL) {
            if (x < int.bms - 1) m |= @as(int.Bitmask, 1) << @intCast(x);
        }
    }
    idx.col_not_idxed = ~m;
}

/// Port of convertToWithoutRowidTable(): finish a WITHOUT ROWID table:
/// its primary key columns are NOT NULL, its b-tree has blob keys, its
/// PRIMARY KEY index is the table's own b-tree and covers every column,
/// and its other indexes end with the primary key instead of a rowid.
fn convertToWithoutRowidTable(p: *Parse, t: *Table) Oom!void {
    const db = p.db;
    const v = p.vdbe;
    const a = tableAlloc(p, t);

    if (db.init.imposter_table == 0) {
        for (t.cols) |*c| {
            if (c.col_flags.PRIMKEY and c.not_null == OE.None) c.not_null = OE.Abort;
        }
        t.tab_flags.HasNotNull = true;
    }

    if (p.u1.cr.addr_cr_tab != 0) aux.changeP3(v.?, p.u1.cr.addr_cr_tab, BTREE_BLOBKEY);

    var pk: *Index = undefined;
    if (t.i_pkey >= 0) {
        // Formerly an INTEGER PRIMARY KEY: make a PRIMARY KEY index.
        const ipk = try expr_mod.exprAlloc(p.arena, TK.ID, Token.init(t.cols[@intCast(t.i_pkey)].name()), false);
        const list = try expr_mod.listAppend(p, null, ipk);
        if (p.inRenameObject()) alter.renameTokenRemap(p, ipk, &t.i_pkey);
        list.at(0).fg.sort_flags = p.i_pk_sort_order;
        t.i_pkey = -1;
        createIndex(p, null, null, null, list, t.key_conf, null, null, 0, false, .primarykey);
        if (p.n_err != 0) {
            t.tab_flags.WithoutRowid = false;
            return;
        }
        pk = primaryKeyIndex(t).?;
    } else {
        pk = primaryKeyIndex(t).?;
        // Remove repeated columns: "PRIMARY KEY(a,b,a)" is "(a,b)".
        var j: usize = 1;
        for (1..pk.n_key_col) |i| {
            if (isDupColumn(pk, j, pk, i)) {
                pk.n_column -= 1;
            } else {
                pk.coll[j] = pk.coll[i];
                pk.sort_order[j] = pk.sort_order[i];
                pk.ai_column[j] = pk.ai_column[i];
                j += 1;
            }
        }
        pk.n_key_col = @intCast(j);
    }
    pk.is_covering = true;
    if (db.init.imposter_table == 0) pk.uniq_not_null = true;
    pk.n_column = pk.n_key_col;
    const n_pk: usize = pk.n_key_col;

    // Skip creating the PRIMARY KEY b-tree and its sqlite_schema row.
    if (v != null and pk.tnum > 0) {
        std.debug.assert(!db.init.busy);
        aux.changeOpcode(v.?, @intCast(pk.tnum), OP.Goto);
    }
    pk.tnum = t.tnum;

    // Other indexes end with the primary key columns instead of a rowid.
    var idx_opt = t.index;
    while (idx_opt) |idx| : (idx_opt = idx.next) {
        if (idx.isPrimaryKey()) continue;
        var n: usize = 0;
        for (0..n_pk) |i| {
            if (!isDupColumn(idx, idx.n_key_col, pk, i)) n += 1;
        }
        if (n == 0) {
            // The index is a superset of the primary key.
            idx.n_column = idx.n_key_col;
            continue;
        }
        try resizeIndexObject(a, idx, idx.n_key_col + n);
        var j: usize = idx.n_key_col;
        for (0..n_pk) |i| {
            if (!isDupColumn(idx, idx.n_key_col, pk, i)) {
                idx.ai_column[j] = pk.ai_column[i];
                idx.coll[j] = pk.coll[i];
                if (pk.sort_order[i] != 0) idx.asc_key_bug = true;
                j += 1;
            }
        }
    }

    // The PRIMARY KEY index holds every column.
    var n_extra: usize = 0;
    for (t.cols, 0..) |*c, i| {
        if (!hasColumn(pk.ai_column[0..n_pk], @intCast(i)) and !c.col_flags.VIRTUAL) n_extra += 1;
    }
    try resizeIndexObject(a, pk, n_pk + n_extra);
    var j = n_pk;
    for (t.cols, 0..) |*c, i| {
        if (!hasColumn(pk.ai_column[0..j], @intCast(i)) and !c.col_flags.VIRTUAL) {
            pk.ai_column[j] = @intCast(i);
            pk.coll[j] = columnColl(c) orelse coll_mod.str_binary;
            j += 1;
        }
    }
    recomputeColumnsNotIndexed(pk);
}

/// Port of sqlite3IsShadowTableOf(): `name` is the name of a shadow
/// table of virtual table `t`.
pub fn isShadowTableOf(db: *Sqlite3, t: *Table, name: []const u8) bool {
    if (!t.isVirtual()) return false;
    const n_name = t.name.len;
    if (name.len < n_name or !ctype.eqlNoCase(name[0..n_name], t.name)) return false;
    if (name.len == n_name or name[n_name] != '_') return false;
    const m = db.modules.get(t.u.vtab.args[0]) orelse return false;
    if (m.module.i_version < 3) return false;
    const x = m.module.x_shadow_name orelse return false;
    return x(m.aux, name[n_name + 1 ..]);
}

/// Port of sqlite3MarkAllShadowTablesOf(): flag the shadow tables of
/// virtual table `t` TF_Shadow, if its module has xShadowName.
pub fn markAllShadowTablesOf(db: *Sqlite3, t: *Table) void {
    std.debug.assert(t.isVirtual());
    const m = db.modules.get(t.u.vtab.args[0]) orelse return;
    if (m.module.i_version < 3) return;
    const x = m.module.x_shadow_name orelse return;
    const n_name = t.name.len;
    var it = t.schema.?.tbl_hash.valueIterator();
    while (it.next()) |op| {
        const other = op.*;
        if (!other.isOrdinary()) continue;
        if (other.tab_flags.Shadow) continue;
        if (other.name.len > n_name and ctype.eqlNoCase(other.name[0..n_name], t.name) and
            other.name[n_name] == '_' and x(m.aux, other.name[n_name + 1 ..]))
        {
            other.tab_flags.Shadow = true;
        }
    }
}

/// Port of sqlite3ShadowTableName(): `name` is the name of a shadow table
/// of a virtual table of the connection.
pub fn shadowTableName(db: *Sqlite3, name: []const u8) bool {
    const tail = std.mem.lastIndexOfScalar(u8, name, '_') orelse return false;
    const t = findTable(db, name[0..tail], null) orelse return false;
    if (!t.isVirtual()) return false;
    return isShadowTableOf(db, t, name);
}

/// The P4 operand of a virtual table opcode: the VTable of `t` for `db`
/// (P4_VTAB; aux.changeP4() locks it for as long as the program refers
/// to it).
pub fn vtabP4(db: *Sqlite3, t: *Table) vi.P4 {
    return .{ .vtab = vtab_mod.getVTable(db, t).? };
}

/// Port of sqlite3EndTable(): the closing ")" (or AS SELECT) of a CREATE
/// TABLE. When reading the schema the table is added to it; otherwise
/// code fills in the table's sqlite_schema row and rereads the schema.
pub fn endTable(p: *Parse, cons: ?Token, end: ?Token, tab_opts: TF, sel: ?*Select) void {
    endTableImpl(p, cons, end, tab_opts, sel) catch oomFault(p);
}

fn endTableImpl(p: *Parse, cons_arg: ?Token, end_arg: ?Token, tab_opts: TF, sel: ?*Select) Oom!void {
    const db = p.db;
    if (end_arg == null and sel == null) return;
    const t = p.new_table orelse return;

    if (sel == null and shadowTableName(db, t.name)) t.tab_flags.Shadow = true;

    // While reading the schema the root page comes from sqlite_schema;
    // page 1 is sqlite_schema itself, which is read-only.
    if (db.init.busy) {
        if (sel != null or (!t.isOrdinary() and db.init.new_tnum != 0)) {
            util.errorMsg(p, "", .{});
            return;
        }
        t.tnum = db.init.new_tnum;
        if (t.tnum == 1) t.tab_flags.Readonly = true;
    }

    // STRICT: every column has a standard type; primary key columns
    // other than the INTEGER PRIMARY KEY are NOT NULL.
    if (tab_opts.Strict) {
        t.tab_flags.Strict = true;
        for (t.cols, 0..) |*c, ii| {
            if (c.e_ctype == COLTYPE.CUSTOM) {
                if (c.col_flags.HASTYPE) {
                    util.errorMsg(p, "unknown datatype for {s}.{s}: \"{s}\"", .{ t.name, c.name(), columnType(c, "") });
                } else {
                    util.errorMsg(p, "missing datatype for {s}.{s}", .{ t.name, c.name() });
                }
                return;
            } else if (c.e_ctype == COLTYPE.ANY) {
                c.affinity = Aff.blob;
            }
            if (c.col_flags.PRIMKEY and t.i_pkey != ii and c.not_null == OE.None) {
                c.not_null = OE.Abort;
                t.tab_flags.HasNotNull = true;
            }
        }
    }

    if (tab_opts.WithoutRowid) {
        if (t.tab_flags.Autoincrement) {
            util.errorMsg(p, "AUTOINCREMENT not allowed on WITHOUT ROWID tables", .{});
            return;
        }
        if (!t.tab_flags.HasPrimaryKey) {
            util.errorMsg(p, "PRIMARY KEY missing on table {s}", .{t.name});
            return;
        }
        t.tab_flags.set(.{ .WithoutRowid = true, .NoVisibleRowid = true });
        try convertToWithoutRowidTable(p, t);
    }
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));

    if (t.check) |check| {
        resolve.resolveSelfReference(p, t, .{ .IsCheck = true }, null, check) catch {};
        if (p.n_err != 0) t.check = null;
    }
    if (t.tab_flags.intersects(TF.HasGenerated)) {
        var n_ng: usize = 0;
        for (t.cols) |*c| {
            if (c.col_flags.intersects(COLFLAG.GENERATED)) {
                const x = columnExpr(t, c);
                resolve.resolveSelfReference(p, t, .{ .GenCol = true }, x, null) catch {
                    // Use NULL rather than a half-resolved expression.
                    try columnSetExpr(p, t, c, try expr_mod.exprAlloc(tableAlloc(p, t), TK.NULL, null, false));
                };
            } else {
                n_ng += 1;
            }
        }
        if (n_ng == 0) {
            util.errorMsg(p, "must have at least one non-generated column", .{});
            return;
        }
    }

    estimateTableWidth(t);
    var idx = t.index;
    while (idx) |ix| : (idx = ix.next) estimateIndexWidth(ix);

    // Unless reading the schema, code the table's sqlite_schema row.
    if (!db.init.busy) {
        const v = getVdbe(p) orelse return;
        _ = aux.addOp1(v, OP.Close, 0);
        const typ: []const u8, const typ2: []const u8 = if (t.isOrdinary()) .{ "table", "TABLE" } else .{ "view", "VIEW" };

        if (sel) |s| {
            // CREATE TABLE ... AS SELECT: fill the new table.
            try codeCreateTableAsSelect(p, t, s, i_db);
            if (p.n_err != 0) return;
        }

        var stmt: [:0]const u8 = undefined;
        if (sel != null) {
            stmt = try createTableStmt(p.arena, t);
        } else {
            const end2 = if (!tab_opts.isEmpty()) p.last_token else end_arg.?;
            var n = @intFromPtr(end2.z.?) - @intFromPtr(p.name_token.z.?);
            if (end2.z.?[0] != ';') n += end2.n;
            stmt = try std.fmt.allocPrintSentinel(p.arena, "CREATE {s} {s}", .{ typ2, p.name_token.z.?[0..n] }, 0);
        }

        // Fill in the placeholder row coded by startTable().
        nestedParse(p, "UPDATE %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " SET type='%s', name=%Q, tbl_name=%Q, rootpage=#%d, sql=%Q WHERE rowid=#%d", &.{
            .{ .str = db.dbs.items[i_db].name },
            .{ .str = typ },
            .{ .str = t.name },
            .{ .str = t.name },
            .{ .int = p.u1.cr.reg_root },
            .{ .str = stmt },
            .{ .int = p.u1.cr.reg_rowid },
        });
        changeCookie(p, i_db);

        // AUTOINCREMENT needs sqlite_sequence.
        if (t.tab_flags.Autoincrement and !p.inSpecialParse()) {
            if (db.dbs.items[i_db].schema.seq_tab == null) {
                nestedParse(p, "CREATE TABLE %Q.sqlite_sequence(name,seq)", &.{.{ .str = db.dbs.items[i_db].name }});
            }
        }

        // Reread the schema rows of the table.
        const where = try mprintf(p, "tbl_name='%q' AND type!='trigger'", &.{.{ .str = t.name }});
        aux.addParseSchemaOp(v, @intCast(i_db), where, 0);

        // Check generated columns for cycles and bad expressions.
        if (t.tab_flags.intersects(TF.HasGenerated)) {
            const q = try mprintf(p, "SELECT*FROM\"%w\".\"%w\"", &.{ .{ .str = db.dbs.items[i_db].name }, .{ .str = t.name } });
            _ = aux.addOp4Str(v, OP.SqlExec, 0x0001, 0, 0, q);
        }
    }

    // While reading the schema, add the table to it.
    if (db.init.busy) {
        const s = t.schema.?;
        const gop = try s.tbl_hash.getOrPut(db.gpa, t.name);
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = t;
        s.tbl_order.insert(db.gpa, t.name, t) catch |err| {
            s.tbl_hash.removeByPtr(gop.key_ptr);
            return err;
        };
        p.new_table = null;
        db.m_db_flags.SchemaChange = true;
        if (std.mem.eql(u8, t.name, "sqlite_sequence")) s.seq_tab = t;
    }

    // The offset ALTER TABLE ADD COLUMN (and sqlite_drop_column()) uses.
    // Only a table read from the schema or parsed in rename mode keeps it
    // (after a nested parse name_token is another statement's).
    if (sel == null and t.isOrdinary() and (db.init.busy or p.inRenameObject())) {
        var cons = cons_arg.?;
        if (cons.z == null) cons = end_arg.?;
        t.u.tab.add_col_offset = 13 + @as(i32, @intCast(@intFromPtr(cons.z.?) - @intFromPtr(p.name_token.z.?)));
    }
}

/// The CREATE TABLE ... AS SELECT part of sqlite3EndTable(): the SELECT
/// runs as a co-routine whose rows are inserted into the new table, whose
/// root page is in register u1.cr.reg_root. The columns of `t` are those
/// of the SELECT's result set.
fn codeCreateTableAsSelect(p: *Parse, t: *Table, sel: *Select, i_db: usize) Oom!void {
    const v = p.vdbe.?;
    if (p.inSpecialParse()) {
        p.rc = RC.ERROR;
        p.n_err += 1;
        return;
    }
    const i_csr = p.n_tab;
    p.n_tab += 1;
    p.n_mem += 1;
    const reg_yield = p.n_mem;
    p.n_mem += 1;
    const reg_rec = p.n_mem;
    p.n_mem += 1;
    const reg_rowid = p.n_mem;
    main_mod.mayAbort(p);
    _ = aux.addOp3(v, OP.OpenWrite, i_csr, p.u1.cr.reg_root, @intCast(i_db));
    aux.changeP5(v, vi.OPFLAG.P2ISREG);
    const addr_top = aux.currentAddr(v) + 1;
    _ = aux.addOp3(v, OP.InitCoroutine, reg_yield, 0, addr_top);
    if (p.n_err != 0) return;
    const sel_tab = (try select_mod.resultSetOfSelect(p, sel, Aff.blob)) orelse return;
    std.debug.assert(t.cols.len == 0);
    t.cols = sel_tab.cols;
    t.n_nv_col = @intCast(sel_tab.cols.len);
    sel_tab.cols = &.{};
    var dest = select_mod.selectDestInit(select_mod.SRT.Coroutine, reg_yield);
    select_mod.select(p, sel, &dest) catch {};
    if (p.n_err != 0) return;
    aux.endCoroutine(v, reg_yield);
    aux.jumpHere(v, addr_top - 1);
    const addr_ins_loop = aux.addOp1(v, OP.Yield, dest.i_sd_parm);
    _ = aux.addOp3(v, OP.MakeRecord, dest.i_sdst, dest.n_sdst, reg_rec);
    insert_mod.tableAffinity(p, t, 0);
    _ = aux.addOp2(v, OP.NewRowid, i_csr, reg_rowid);
    _ = aux.addOp3(v, OP.Insert, i_csr, reg_rec, reg_rowid);
    _ = aux.goto_(v, addr_ins_loop);
    aux.jumpHere(v, addr_ins_loop);
    _ = aux.addOp1(v, OP.Close, i_csr);
}

/// Port of sqlite3CreateForeignKey(): a REFERENCES clause or FOREIGN KEY
/// constraint of the table under construction.
pub fn createForeignKey(p: *Parse, from_col: ?*ExprList, to: Token, to_col: ?*ExprList, flags: i32) void {
    createForeignKeyImpl(p, from_col, to, to_col, flags) catch oomFault(p);
}

fn createForeignKeyImpl(p: *Parse, from_col: ?*ExprList, to: Token, to_col: ?*ExprList, flags: i32) Oom!void {
    const t = p.new_table orelse return;
    if (p.inDeclareVtab()) return;
    var n_col: usize = undefined;
    if (from_col) |fc| {
        if (to_col != null and to_col.?.len() != fc.len()) {
            util.errorMsg(p, "number of columns in foreign key does not match the number of columns in the referenced table", .{});
            return;
        }
        n_col = fc.len();
    } else {
        if (t.cols.len == 0) return;
        if (to_col != null and to_col.?.len() != 1) {
            util.errorMsgAt(p, to.z, "foreign key on {s} should reference only one column of table {s}", .{ t.cols[t.cols.len - 1].name(), to.slice() });
            return;
        }
        n_col = 1;
    }
    const a = tableAlloc(p, t);
    const fk = try a.create(int.FKey);
    fk.* = .{
        .from = t,
        .next_from = t.u.tab.fkey,
        .to = util.dequote(try a.dupeSentinel(u8, to.slice(), 0)),
        .cols = try a.alloc(int.FKeyCol, n_col),
    };
    if (p.inRenameObject()) alter.renameTokenMap(p, fk.to, to);
    if (from_col) |fc| {
        for (fc.slice(), 0..) |item, i| {
            const j = columnIndex(t, item.e_name.?);
            if (j < 0) {
                util.errorMsg(p, "unknown column \"{s}\" in foreign key definition", .{item.e_name.?});
                return;
            }
            fk.cols[i] = .{ .i_from = j, .col = null };
            if (p.inRenameObject()) alter.renameTokenRemap(p, &fk.cols[i], item.e_name);
        }
    } else {
        fk.cols[0] = .{ .i_from = @intCast(t.cols.len - 1), .col = null };
    }
    if (to_col) |tc| {
        for (tc.slice(), 0..) |item, i| {
            fk.cols[i].col = try a.dupeSentinel(u8, item.e_name.?, 0);
            if (p.inRenameObject()) alter.renameTokenRemap(p, fk.cols[i].col, item.e_name);
        }
    }
    fk.is_deferred = false;
    fk.a_action = .{ .fromInt(flags & 0xff), .fromInt((flags >> 8) & 0xff) };

    const s = t.schema.?;
    const gop = try s.fkey_hash.getOrPut(p.db.gpa, fk.to);
    if (gop.found_existing) {
        const next_to = gop.value_ptr.*;
        fk.next_to = next_to;
        next_to.prev_to = fk;
    }
    gop.key_ptr.* = fk.to;
    gop.value_ptr.* = fk;
    t.u.tab.fkey = fk;
}

/// Port of sqlite3DeferForeignKey(): INITIALLY DEFERRED or IMMEDIATE on
/// the last foreign key.
pub fn deferForeignKey(p: *Parse, is_deferred: bool) void {
    const t = p.new_table orelse return;
    if (!t.isOrdinary()) return;
    const fk = t.u.tab.fkey orelse return;
    fk.is_deferred = is_deferred;
}

/// Port of sqlite3AllocateIndexObject(): an index with room for `n_col`
/// columns, `n_col - 1` of them key columns.
pub fn allocateIndexObject(a: Allocator, n_col: usize, table: *Table, name: []const u8) Oom!*Index {
    const idx = try a.create(Index);
    idx.* = .{
        .name = try a.dupeSentinel(u8, name, 0),
        .table = table,
        .coll = try a.alloc([:0]const u8, n_col),
        .ai_row_log_est = try a.alloc(LogEst, n_col + 1),
        .ai_column = try a.alloc(i16, n_col),
        .sort_order = try a.alloc(u8, n_col),
        .n_column = @intCast(n_col),
        .n_key_col = @intCast(n_col - 1),
    };
    @memset(idx.coll, coll_mod.str_binary);
    @memset(idx.ai_row_log_est, 0);
    @memset(idx.ai_column, 0);
    @memset(idx.sort_order, 0);
    return idx;
}

/// Port of sqlite3DefaultRowEst(): row estimates for an index without
/// sqlite_stat1 data.
pub fn defaultRowEst(idx: *Index) void {
    const vals = [_]LogEst{ 33, 32, 30, 28, 26 };
    const a = idx.ai_row_log_est;
    var x = idx.table.n_row_log_est;
    if (x < 99) {
        idx.table.n_row_log_est = 99;
        x = 99;
    }
    if (idx.part_idx_where != null) x -= 10;
    a[0] = x;
    const n_copy = @min(vals.len, idx.n_key_col);
    @memcpy(a[1 .. 1 + n_copy], vals[0..n_copy]);
    // Not `n_copy + 1`'s type: @min narrows n_copy to the bound of vals.
    var i: usize = n_copy + 1;
    while (i <= idx.n_key_col) : (i += 1) a[i] = 23;
    if (idx.isUnique()) a[idx.n_key_col] = 0;
}

/// Port of sqlite3IndexHasDuplicateRootPage() (prepare.c).
pub fn indexHasDuplicateRootPage(idx: *Index) bool {
    var p = idx.table.index;
    while (p) |q| : (p = q.next) {
        if (q.tnum == idx.tnum and q != idx) return true;
    }
    return false;
}

/// Port of sqlite3CreateIndex(): CREATE INDEX, or the index of a PRIMARY
/// KEY or UNIQUE constraint of the table under construction (then
/// `tbl_name` is null).
pub fn createIndex(
    p: *Parse,
    name1: ?Token,
    name2: ?Token,
    tbl_name: ?*SrcList,
    list: ?*ExprList,
    on_error: OE,
    start: ?Token,
    where: ?*Expr,
    sort_order: i32,
    if_not_exist: bool,
    idx_type: int.IdxType,
) void {
    const n1 = name1 orelse Token{};
    const n2 = name2 orelse Token{};
    createIndexImpl(
        p,
        if (name1 != null) &n1 else null,
        if (name2 != null) &n2 else null,
        tbl_name,
        list,
        on_error,
        if (start != null and start.?.z != null) &start.? else null,
        where,
        sort_order,
        if_not_exist,
        idx_type,
    ) catch oomFault(p);
}

fn createIndexImpl(
    p: *Parse,
    name1: ?*const Token,
    name2: ?*const Token,
    tbl_name: ?*SrcList,
    list_arg: ?*ExprList,
    on_error: OE,
    start: ?*const Token,
    where_arg: ?*Expr,
    sort_order: i32,
    if_not_exist: bool,
    idx_type: int.IdxType,
) Oom!void {
    const db = p.db;
    var list = list_arg;
    var where = where_arg;
    if (p.n_err != 0 or p.syntax_only) return;
    if (p.inDeclareVtab() and idx_type != .primarykey) return;
    prepare.readSchema(p) catch return;
    if (hasExplicitNulls(p, list)) return;

    var t: *Table = undefined;
    var i_db: usize = undefined;
    var name_tok: ?*const Token = null;
    var pk: ?*Index = null;
    if (tbl_name) |tn| {
        // CREATE INDEX: find the table in the index's database.
        var unq: *const Token = undefined;
        i_db = twoPartName(p, name1.?, name2.?, &unq) orelse return;
        name_tok = unq;
        if (!db.init.busy) {
            const tab = srcListLookup(p, tn);
            if (name2.?.n == 0 and tab != null and tab.?.schema == db.dbs.items[1].schema) i_db = 1;
        }
        var fix: attach.DbFixer = undefined;
        attach.fixInit(&fix, p, i_db, "index", name_tok.?.slice());
        _ = attach.fixSrcList(&fix, tn);
        t = locateTableItem(p, 0, tn.at(0)) orelse return;
        if (i_db == 1 and db.dbs.items[i_db].schema != t.schema) {
            util.errorMsg(p, "cannot create a TEMP index on non-TEMP table \"{s}\"", .{t.name});
            return;
        }
        if (!t.hasRowid()) pk = primaryKeyIndex(t);
    } else {
        t = p.new_table orelse return;
        i_db = @intCast(prepare.schemaToIndex(db, t.schema));
    }
    const pdb = &db.dbs.items[i_db];

    if (hasSqlitePrefix(t.name) and !db.init.busy and tbl_name != null) {
        util.errorMsg(p, "table {s} may not be indexed", .{t.name});
        return;
    }
    if (t.isView()) {
        util.errorMsg(p, "views may not be indexed", .{});
        return;
    }
    if (t.isVirtual()) {
        util.errorMsg(p, "virtual tables may not be indexed", .{});
        return;
    }

    // The index name: given, or invented for a constraint.
    var name: [:0]const u8 = undefined;
    if (name_tok) |nt| {
        name = (try nameFromToken(p.arena, nt.*)).?;
        checkObjectName(p, name, "index", t.name) catch return;
        if (!p.inRenameObject()) {
            if (!db.init.busy and findTable(db, name, pdb.name) != null) {
                util.errorMsg(p, "there is already a table named {s}", .{name});
                return;
            }
            if (findIndex(db, name, pdb.name) != null) {
                if (!if_not_exist) {
                    util.errorMsg(p, "index {s} already exists", .{name});
                } else if (db.init.busy) {
                    util.errorMsg(p, "", .{});
                } else {
                    codeVerifySchema(p, i_db);
                    forceNotReadOnly(p);
                }
                return;
            }
        }
    } else {
        var n: usize = 1;
        var loop = t.index;
        while (loop) |l| : (loop = l.next) n += 1;
        const z = try std.fmt.allocPrintSentinel(p.arena, "sqlite_autoindex_{s}_{d}", .{ t.name, n }, 0);
        // Names made inside sqlite3_declare_vtab() differ.
        if (p.inSpecialParse()) z[7] += 1;
        name = z;
    }

    // Without a list, the index is on the last column added.
    if (list == null) {
        const col = &t.cols[t.cols.len - 1];
        col.col_flags.UNIQUE = true;
        const e = try expr_mod.exprAlloc(p.arena, TK.ID, Token.init(col.name()), false);
        list = try expr_mod.listAppend(p, null, e);
        expr_mod.listSetSortOrder(list, sort_order, int.SortOrder.undef);
    } else {
        expr_mod.listCheckLength(p, list, "index");
        if (p.n_err != 0) return;
    }
    const l = list.?;

    // An index that CREATE INDEX makes in rename mode only lives as long
    // as the statement.
    const a = if (tbl_name != null and p.inRenameObject()) p.arena else tableAlloc(p, t);
    const n_extra_col: usize = if (pk) |k| k.n_key_col else 1;
    const idx = try allocateIndexObject(a, l.len() + n_extra_col, t, name);
    idx.on_error = on_error;
    idx.uniq_not_null = on_error != OE.None;
    idx.idx_type = idx_type;
    idx.schema = db.dbs.items[i_db].schema;
    idx.n_key_col = @intCast(l.len());
    if (where) |w| {
        resolve.resolveSelfReference(p, t, .{ .PartIdx = true }, w, null) catch {};
        // In rename mode the expressions themselves are kept: the rename
        // map has their nodes.
        idx.part_idx_where = if (p.inRenameObject()) w else try expr_mod.exprDup(a, w);
        where = null;
    }

    // DESC is honored from file format 4.
    const sort_order_mask: u8 = if (pdb.schema.file_format >= 4) 0xff else 0;

    // Each term is a column, or an expression (XN_EXPR) kept in col_expr.
    var has_col_expr = false;
    for (l.slice(), 0..) |*item, i| {
        stringToId(item.expr.?);
        resolve.resolveSelfReference(p, t, .{ .IdxExpr = true }, item.expr, null) catch {};
        if (p.n_err != 0) return;
        const ce = expr_mod.skipCollate(item.expr).?;
        var j: i32 = undefined;
        if (ce.op != TK.COLUMN) {
            if (t == p.new_table) {
                util.errorMsg(p, "expressions prohibited in PRIMARY KEY and UNIQUE constraints", .{});
                return;
            }
            has_col_expr = true;
            j = int.XN_EXPR;
            idx.ai_column[i] = int.XN_EXPR;
            idx.uniq_not_null = false;
            idx.has_expr = true;
        } else {
            j = ce.i_column;
            if (j < 0) {
                j = t.i_pkey;
            } else {
                const c = &t.cols[@intCast(j)];
                if (c.not_null == .None) idx.uniq_not_null = false;
                if (c.col_flags.VIRTUAL) {
                    idx.has_vcol = true;
                    idx.has_expr = true;
                }
            }
            idx.ai_column[i] = @intCast(j);
        }
        var coll: ?[:0]const u8 = null;
        if (item.expr.?.op == TK.COLLATE) {
            coll = try a.dupeSentinel(u8, item.expr.?.token(), 0);
        } else if (j >= 0) {
            coll = columnColl(&t.cols[@intCast(j)]);
        }
        const zcoll = coll orelse coll_mod.str_binary;
        if (!db.init.busy and coll_mod.locateCollSeq(p, zcoll) == null) return;
        idx.coll[i] = zcoll;
        idx.sort_order[i] = item.fg.sort_flags & sort_order_mask;
    }
    if (p.inRenameObject()) {
        idx.col_expr = l;
    } else if (has_col_expr) {
        idx.col_expr = try expr_mod.listDup(a, l);
    }

    // The key of the table follows: the WITHOUT ROWID primary key, or
    // the rowid.
    var i: usize = l.len();
    if (pk) |k| {
        for (0..k.n_key_col) |jj| {
            const x = k.ai_column[jj];
            if (isDupColumn(idx, idx.n_key_col, k, jj)) {
                idx.n_column -= 1;
            } else {
                idx.ai_column[i] = x;
                idx.coll[i] = k.coll[jj];
                idx.sort_order[i] = k.sort_order[jj];
                i += 1;
            }
        }
    } else {
        idx.ai_column[i] = int.XN_ROWID;
        idx.coll[i] = coll_mod.str_binary;
    }
    defaultRowEst(idx);
    if (p.new_table == null) estimateIndexWidth(idx);

    // An index on every column is covering.
    recomputeColumnsNotIndexed(idx);
    if (tbl_name != null and idx.n_column >= t.cols.len) {
        idx.is_covering = true;
        for (0..t.cols.len) |jj| {
            if (jj == t.i_pkey) continue;
            if (tableColumnToIndex(idx, @intCast(jj)) >= 0) continue;
            idx.is_covering = false;
            break;
        }
    }

    if (t == p.new_table) {
        // A constraint index equal to an earlier one is not made twice.
        var prev = t.index;
        while (prev) |pi| : (prev = pi.next) {
            if (pi.n_key_col != idx.n_key_col) continue;
            var k: usize = 0;
            while (k < pi.n_key_col) : (k += 1) {
                if (pi.ai_column[k] != idx.ai_column[k]) break;
                if (!ctype.eqlNoCase(pi.coll[k], idx.coll[k])) break;
            }
            if (k == pi.n_key_col) {
                if (pi.on_error != idx.on_error) {
                    if (!(pi.on_error == OE.Default or idx.on_error == OE.Default)) {
                        util.errorMsg(p, "conflicting ON CONFLICT clauses specified", .{});
                    }
                    if (pi.on_error == OE.Default) pi.on_error = idx.on_error;
                }
                if (idx_type == .primarykey) pi.idx_type = idx_type;
                if (p.inRenameObject()) {
                    idx.next = p.new_index;
                    p.new_index = idx;
                }
                return reorderReplaceIndexes(t);
            }
        }
    }

    var linked = false;
    if (!p.inRenameObject()) {
        if (db.init.busy) {
            if (tbl_name != null) {
                idx.tnum = db.init.new_tnum;
                if (indexHasDuplicateRootPage(idx)) {
                    util.errorMsg(p, "invalid rootpage", .{});
                    p.rc = RC.CORRUPT;
                    return;
                }
            }
            const gop = try idx.schema.?.idx_hash.getOrPut(db.gpa, idx.name);
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = idx;
            db.m_db_flags.SchemaChange = true;
        } else if (t.hasRowid() or tbl_name != null) {
            // Code the index's b-tree and sqlite_schema row, unless this
            // is the PRIMARY KEY of a WITHOUT ROWID table.
            p.n_mem += 1;
            const i_mem = p.n_mem;
            const v = getVdbe(p) orelse return;
            beginWriteOperation(p, true, i_db);

            // convertToWithoutRowidTable() turns this OP_Noop into a jump
            // over the code below if the index is the primary key.
            idx.tnum = @intCast(aux.addOp0(v, OP.Noop));
            _ = aux.addOp3(v, OP.CreateBtree, @intCast(i_db), i_mem, BTREE_BLOBKEY);

            var stmt: ?[:0]const u8 = null;
            if (start != null) {
                const nt = name_tok.?;
                var n = @intFromPtr(p.last_token.z.?) - @intFromPtr(nt.z.?) + p.last_token.n;
                if (nt.z.?[n - 1] == ';') n -= 1;
                stmt = try std.fmt.allocPrintSentinel(p.arena, "CREATE{s} INDEX {s}", .{ if (on_error == OE.None) "" else " UNIQUE", nt.z.?[0..n] }, 0);
            }

            nestedParse(p, "INSERT INTO %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " VALUES('index',%Q,%Q,#%d,%Q);", &.{
                .{ .str = db.dbs.items[i_db].name },
                .{ .str = idx.name },
                .{ .str = t.name },
                .{ .int = i_mem },
                .{ .str = stmt },
            });

            // Fill the index and reread its schema row.
            if (tbl_name != null) {
                refillIndex(p, idx, i_mem);
                changeCookie(p, i_db);
                const w = try mprintf(p, "name='%q' AND type='index'", &.{.{ .str = idx.name }});
                aux.addParseSchemaOp(v, @intCast(i_db), w, 0);
                _ = aux.addOp2(v, OP.Expire, 0, 1);
            }
            aux.jumpHere(v, @intCast(idx.tnum));
        }
    }
    if (db.init.busy or tbl_name == null) {
        idx.next = t.index;
        t.index = idx;
        linked = true;
    } else if (p.inRenameObject()) {
        std.debug.assert(p.new_index == null);
        p.new_index = idx;
    }
    // An index of CREATE INDEX lives on only in the reread schema; its
    // memory stays in the table's arena until the table is freed.
    reorderReplaceIndexes(t);
}

/// The cleanup of sqlite3CreateIndex(): REPLACE indexes go last.
fn reorderReplaceIndexes(t: *Table) void {
    var from: *?*Index = &t.index;
    while (from.*) |this| : (from = &this.next) {
        if (this.on_error != OE.Replace) continue;
        while (this.next) |next| {
            if (next.on_error == OE.Replace) break;
            from.* = next;
            this.next = next.next;
            next.next = this;
            from = &next.next;
        }
        break;
    }
}

/// Port of sqlite3SrcListLookup() (delete.c): the table of the single
/// term of `src`, located (with an error if missing).
pub fn srcListLookup(p: *Parse, src: *SrcList) ?*Table {
    const item = src.at(0);
    const t = locateTableItem(p, 0, item);
    item.s_tab = t;
    item.fg.not_cte = true;
    if (t) |tab| tableRef(p, tab);
    return t;
}

/// Port of sqlite3ViewGetColumnNames(): make sure the columns of a view
/// are known (computed from its SELECT). On error (C: the number of
/// errors) the error is in `p`.
pub fn viewGetColumnNames(p: *Parse, t: *Table) int.ParseError!void {
    if (t.isVirtual()) {
        p.db.n_schema_lock += 1;
        defer p.db.n_schema_lock -= 1;
        return vtab_mod.callConnect(p, t);
    }
    if (!t.isView() or t.cols.len > 0) return;
    viewGetColumnNamesImpl(p, t) catch |err| switch (err) {
        error.OutOfMemory => {
            oomFault(p);
            return error.ParseFailed;
        },
        error.ParseFailed => |e| return e,
    };
}

fn viewGetColumnNamesImpl(p: *Parse, t: *Table) (Oom || int.ParseError)!void {
    const db = p.db;
    if (t.view_resolving) {
        util.errorMsg(p, "view {s} is circularly defined", .{t.name});
        return error.ParseFailed;
    }
    // Work on a copy: expanding "*" and assigning cursors must not change
    // the view's SELECT.
    var failed = false;
    if (try expr_mod.selectDup(p.arena, t.u.view.select)) |sel| {
        // The columns live with the view: not in lookaside.
        @import("malloc.zig").disableLookaside(db);
        defer @import("malloc.zig").enableLookaside(db);
        const parse_mode = p.e_parse_mode;
        const n_tab = p.n_tab;
        const n_select = p.n_select;
        defer p.e_parse_mode = parse_mode;
        p.e_parse_mode = .normal;
        select_mod.srcListAssignCursors(p, sel.src);
        t.view_resolving = true;
        const sel_tab = sel_tab: {
            defer {
                t.view_resolving = false;
                p.n_tab = n_tab;
                p.n_select = n_select;
            }
            break :sel_tab try select_mod.resultSetOfSelect(p, sel, Aff.none);
        };
        if (sel_tab == null) {
            failed = true;
        } else {
            // The columns live with the view: named by the list of
            // CREATE VIEW name(list) (kept in t.check), or as the result
            // set names them.
            const a = if (t.mem != null) try newViewColumnsMem(db, t) else p.arena;
            if (t.check) |check| {
                t.cols = try select_mod.columnsFromExprList(p, a, check);
                if (p.n_err == 0 and t.cols.len == sel.e_list.?.len()) {
                    try select_mod.subqueryColumnTypes(p, a, t, sel, Aff.none);
                }
            } else {
                // The columns of sel_tab: those of the leftmost SELECT of
                // a compound.
                var left = sel;
                while (left.prior) |pr| left = pr;
                t.cols = try select_mod.columnsFromExprList(p, a, left.e_list);
                try select_mod.subqueryColumnTypes(p, a, t, left, Aff.none);
                // C: tabFlags & COLFLAG_NOINSERT, the column bits.
                t.tab_flags.set(sel_tab.?.tab_flags.only(TF.HasGenerated.with(.{ .HasHidden = true })));
            }
        }
        t.n_nv_col = @intCast(t.cols.len);
    } else {
        failed = true;
    }
    t.schema.?.schema_flags.UnresetViews = true;
    if (db.malloc_failed) t.cols = &.{};
    if (failed or p.n_err != 0) return error.ParseFailed;
}

/// Fresh memory for the columns of schema view `t`, replacing the old.
fn newViewColumnsMem(db: *Sqlite3, t: *Table) Oom!Allocator {
    freeViewColumns(db, t);
    const m = try db.gpa.create(std.heap.ArenaAllocator);
    m.* = .init(db.gpa);
    t.u.view.cols_mem = m;
    return m.allocator();
}

/// Port of sqlite3DeleteColumnNames() for a view: forget its columns.
fn freeViewColumns(db: *Sqlite3, t: *Table) void {
    t.cols = &.{};
    const m = t.u.view.cols_mem orelse return;
    m.deinit();
    db.gpa.destroy(m);
    t.u.view.cols_mem = null;
}

/// Port of sqliteViewResetAll(): forget the columns of every view of
/// database `idx` (they are computed again when needed).
fn viewResetAll(db: *Sqlite3, idx: usize) void {
    if (!db.dbs.items[idx].schema.schema_flags.UnresetViews) return;
    var it = db.dbs.items[idx].schema.tbl_hash.valueIterator();
    while (it.next()) |t| {
        if (t.*.isView()) freeViewColumns(db, t.*);
    }
    db.dbs.items[idx].schema.schema_flags.UnresetViews = false;
}

/// Port of sqlite3RefillIndex(): code the (re)filling of an index from
/// its table, through a sorter. The root page is in register
/// `mem_root_page` if not negative (a new index), else idx.tnum (cleared
/// first).
fn refillIndex(p: *Parse, idx: *Index, mem_root_page: i32) void {
    const db = p.db;
    const t = idx.table;
    const i_tab = p.n_tab;
    const i_idx = p.n_tab + 1;
    p.n_tab += 2;
    const i_db: i32 = @intCast(prepare.schemaToIndex(db, idx.schema));
    const v = getVdbe(p) orelse return;
    const tnum: i32 = if (mem_root_page >= 0) mem_root_page else @intCast(idx.tnum);
    const key = keyInfoOfIndex(p, idx);
    const key_p4: vi.P4 = if (key) |k| .{ .keyinfo = k } else .notused;

    // The index records of all rows go to the sorter.
    const i_sorter = p.n_tab;
    p.n_tab += 1;
    _ = aux.addOp4(v, OP.SorterOpen, i_sorter, 0, idx.n_key_col, key_p4);
    insert_mod.openTable(p, i_tab, @intCast(i_db), t, OP.OpenRead);
    var addr1 = aux.addOp2(v, OP.Rewind, i_tab, 0);
    const reg_record = expr_mod.getTempReg(p);
    main_mod.multiWrite(p);
    var part_idx_label: i32 = 0;
    _ = delete_mod.generateIndexKey(p, idx, i_tab, reg_record, false, &part_idx_label, null, 0);
    _ = aux.addOp2(v, OP.SorterInsert, i_sorter, reg_record);
    delete_mod.resolvePartIdxLabel(p, part_idx_label);
    _ = aux.addOp2(v, OP.Next, i_tab, addr1 + 1);
    aux.jumpHere(v, addr1);
    if (mem_root_page < 0) _ = aux.addOp2(v, OP.Clear, tnum, i_db);
    _ = aux.addOp4(v, OP.OpenWrite, i_idx, tnum, i_db, key_p4);
    aux.changeP5(v, vi.OPFLAG.BULKCSR | (if (mem_root_page >= 0) vi.OPFLAG.P2ISREG else 0));

    // Then, sorted, to the index (checking uniqueness).
    addr1 = aux.addOp2(v, OP.SorterSort, i_sorter, 0);
    var addr2: i32 = undefined;
    if (idx.isUnique()) {
        const j2 = aux.goto_(v, 1);
        addr2 = aux.currentAddr(v);
        _ = aux.addOp4Int(v, OP.SorterCompare, i_sorter, j2, reg_record, idx.n_key_col);
        uniqueConstraint(p, OE.Abort, idx);
        aux.jumpHere(v, j2);
    } else {
        main_mod.mayAbort(p);
        addr2 = aux.currentAddr(v);
    }
    _ = aux.addOp3(v, OP.SorterData, i_sorter, reg_record, i_idx);
    if (!idx.asc_key_bug) _ = aux.addOp1(v, OP.SeekEnd, i_idx);
    _ = aux.addOp2(v, OP.IdxInsert, i_idx, reg_record);
    aux.changeP5(v, vi.OPFLAG.USESEEKRESULT);
    expr_mod.releaseTempReg(p, reg_record);
    _ = aux.addOp2(v, OP.SorterNext, i_sorter, addr2);
    aux.jumpHere(v, addr1);
    _ = aux.addOp1(v, OP.Close, i_tab);
    _ = aux.addOp1(v, OP.Close, i_idx);
    _ = aux.addOp1(v, OP.Close, i_sorter);
}

/// Port of sqlite3BeginTransaction(): BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE].
pub fn beginTransaction(p: *Parse, kind: i32) void {
    const db = p.db;
    if (p.syntax_only) return;
    const v = getVdbe(p) orelse return;
    if (kind != TK.DEFERRED) {
        for (db.dbs.items, 0..) |*d, i| {
            const txn: i32 = if (d.bt != null and d.bt.?.read_only) 0 else if (kind == TK.EXCLUSIVE) 2 else 1;
            _ = aux.addOp2(v, OP.Transaction, @intCast(i), txn);
            aux.usesBtree(v, @intCast(i));
        }
    }
    _ = aux.addOp0(v, OP.AutoCommit);
}

/// Port of sqlite3EndTransaction(): COMMIT, END or ROLLBACK.
pub fn endTransaction(p: *Parse, op: u16) void {
    std.debug.assert(op == TK.COMMIT or op == TK.END or op == TK.ROLLBACK);
    if (p.syntax_only) return;
    const v = getVdbe(p) orelse return;
    _ = aux.addOp2(v, OP.AutoCommit, 1, @intFromBool(op == TK.ROLLBACK));
}

/// SAVEPOINT_* operations.
pub const SAVEPOINT = aux.SAVEPOINT;

/// Port of sqlite3Savepoint().
pub fn savepoint(p: *Parse, op: SAVEPOINT, name: Token) void {
    if (p.syntax_only) return;
    const z = (nameFromToken(p.arena, name) catch return oomFault(p)) orelse return;
    const v = getVdbe(p) orelse return;
    _ = aux.addOp4Str(v, OP.Savepoint, op.int(), 0, 0, z);
}

/// Port of sqlite3OpenTempDatabase(): open the TEMP database if it is not
/// yet. On error (C: the number of errors) the error is in `p`, with the
/// code of the b-tree in Parse.rc.
pub fn openTempDatabase(p: *Parse) int.ParseError!void {
    const db = p.db;
    if (db.dbs.items[1].bt == null and p.explain == 0) {
        const bt = btree.Btree.open(@import("malloc.zig").allocator, db.vfs.?, null, .{
            .cell_size_check = db.flags.CellSizeCk,
            .n_vdbe_read = &db.n_vdbe_read,
        }) catch |err| {
            util.errorMsg(p, "unable to open a temporary database file for storing temporary tables", .{});
            p.rc = int.errorCode(err);
            return error.ParseFailed;
        };
        db.dbs.items[1].bt = bt;
        if (db.next_pagesize != 0) bt.setPageSize(db.next_pagesize, 0, false) catch {};
    }
}

/// Port of sqlite3CodeVerifySchema(): the statement checks the schema
/// cookie of `i_db` (coded by finishCoding()).
pub fn codeVerifySchema(p: *Parse, i_db: usize) void {
    const top = toplevel(p);
    const bit = @as(u32, 1) << @intCast(i_db);
    if (top.cookie_mask & bit == 0) {
        top.cookie_mask |= bit;
        if (i_db == 1) openTempDatabase(top) catch {};
    }
}

/// Port of sqlite3CodeVerifyNamedSchema().
pub fn codeVerifyNamedSchema(p: *Parse, zdb: ?[]const u8) void {
    for (p.db.dbs.items, 0..) |*d, i| {
        if (d.bt != null and (zdb == null or ctype.eqlNoCase(zdb.?, d.name))) codeVerifySchema(p, i);
    }
}

/// Port of sqlite3BeginWriteOperation(): the statement writes `i_db`;
/// `set_statement` if it may need a statement transaction.
pub fn beginWriteOperation(p: *Parse, set_statement: bool, i_db: usize) void {
    const top = toplevel(p);
    codeVerifySchema(top, i_db);
    top.write_mask |= @as(u32, 1) << @intCast(i_db);
    if (set_statement) top.is_multi_write = true;
}

/// Port of sqlite3HaltConstraint(): code an OP_Halt for a constraint
/// error.
pub fn haltConstraint(p: *Parse, err_code: i32, on_error: OE, msg: ?[]const u8, p5_errmsg: u16) void {
    const v = getVdbe(p) orelse return;
    if (on_error == OE.Abort) main_mod.mayAbort(p);
    _ = aux.addOp4Str(v, OP.Halt, err_code, on_error.int(), 0, msg);
    aux.changeP5(v, p5_errmsg);
}

/// Port of sqlite3UniqueConstraint(): halt for a UNIQUE or PRIMARY KEY
/// violation of `idx`.
pub fn uniqueConstraint(p: *Parse, on_error: OE, idx: *Index) void {
    uniqueConstraintImpl(p, on_error, idx) catch oomFault(p);
}

fn uniqueConstraintImpl(p: *Parse, on_error: OE, idx: *Index) Oom!void {
    const t = idx.table;
    var msg: std.ArrayList(u8) = .empty;
    if (idx.col_expr != null) {
        try msg.appendSlice(p.arena, try mprintf(p, "index '%q'", &.{.{ .str = idx.name }}));
    } else {
        for (0..idx.n_key_col) |j| {
            if (j != 0) try msg.appendSlice(p.arena, ", ");
            try msg.appendSlice(p.arena, t.name);
            try msg.append(p.arena, '.');
            try msg.appendSlice(p.arena, t.cols[@intCast(idx.ai_column[j])].name());
        }
    }
    haltConstraint(p, if (idx.isPrimaryKey()) RC.CONSTRAINT_PRIMARYKEY else RC.CONSTRAINT_UNIQUE, on_error, msg.items, vi.P5_ConstraintUnique);
}

/// Port of sqlite3RowidConstraint(): halt for a duplicate rowid.
pub fn rowidConstraint(p: *Parse, on_error: OE, t: *Table) void {
    const msg, const rc = if (t.i_pkey >= 0)
        .{ std.fmt.allocPrint(p.arena, "{s}.{s}", .{ t.name, t.cols[@intCast(t.i_pkey)].name() }) catch return oomFault(p), RC.CONSTRAINT_PRIMARYKEY }
    else
        .{ std.fmt.allocPrint(p.arena, "{s}.rowid", .{t.name}) catch return oomFault(p), RC.CONSTRAINT_ROWID };
    haltConstraint(p, rc, on_error, msg, vi.P5_ConstraintUnique);
}

/// Port of sqlite3KeyInfoOfIndex(): the KeyInfo of an index's b-tree,
/// allocated with the program. Null if a collation is missing.
pub fn keyInfoOfIndex(p: *Parse, idx: *Index) ?*vi.KeyInfo {
    if (p.n_err != 0) return null;
    const n_col: usize = idx.n_column;
    const n_key: usize = idx.n_key_col;
    const key = (if (idx.uniq_not_null)
        select_mod.keyInfoAlloc(p, n_key, n_col - n_key)
    else
        select_mod.keyInfoAlloc(p, n_col, 0)) orelse return null;
    for (0..n_col) |i| {
        const zcoll = idx.coll[i];
        key.coll[i] = if (zcoll.ptr == coll_mod.str_binary.ptr) null else coll_mod.locateCollSeq(p, zcoll);
        key.sort_flags[i] = idx.sort_order[i];
    }
    if (p.n_err != 0) {
        if (!idx.no_query and idx.schema != null and idx.schema.?.idx_hash.get(idx.name) != null) {
            // An index with an unknown collation is unusable until the
            // schema is reloaded.
            idx.no_query = true;
            p.rc = RC.ERROR_RETRY;
        }
        return null;
    }
    return key;
}

/// Port of destroyRootPage(): code the erase of b-tree `i_table`; if an
/// auto-vacuum database moves another b-tree into its place, fix that
/// one's sqlite_schema row.
fn destroyRootPage(p: *Parse, i_table: int.Pgno, i_db: usize) void {
    const v = getVdbe(p) orelse return;
    const r1 = expr_mod.getTempReg(p);
    if (i_table < 2) util.errorMsg(p, "corrupt schema", .{});
    _ = aux.addOp3(v, OP.Destroy, @intCast(i_table), r1, @intCast(i_db));
    main_mod.mayAbort(p);
    nestedParse(p, "UPDATE %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " SET rootpage=%d WHERE #%d AND rootpage=#%d", &.{
        .{ .str = p.db.dbs.items[i_db].name },
        .{ .int = @intCast(i_table) },
        .{ .int = r1 },
        .{ .int = r1 },
    });
    expr_mod.releaseTempReg(p, r1);
}

/// Port of destroyTable(): erase the b-trees of `t` and its indexes,
/// largest root page first (so that auto-vacuum never moves one still to
/// be erased).
fn destroyTable(p: *Parse, t: *Table) void {
    const i_tab = t.tnum;
    var i_destroyed: int.Pgno = 0;
    while (true) {
        var i_largest: int.Pgno = 0;
        if (i_destroyed == 0 or i_tab < i_destroyed) i_largest = i_tab;
        var idx = t.index;
        while (idx) |ix| : (idx = ix.next) {
            if ((i_destroyed == 0 or ix.tnum < i_destroyed) and ix.tnum > i_largest) i_largest = ix.tnum;
        }
        if (i_largest == 0) return;
        destroyRootPage(p, i_largest, @intCast(prepare.schemaToIndex(p.db, t.schema)));
        i_destroyed = i_largest;
    }
}

/// Port of sqlite3ClearStatTables(): delete the sqlite_statN rows of a
/// dropped table or index.
fn clearStatTables(p: *Parse, i_db: usize, typ: []const u8, name: []const u8) void {
    const db_name = p.db.dbs.items[i_db].name;
    for (1..5) |i| {
        var buf: [24]u8 = undefined;
        const tab = std.fmt.bufPrint(&buf, "sqlite_stat{d}", .{i}) catch unreachable;
        if (findTable(p.db, tab, db_name) != null) {
            nestedParse(p, "DELETE FROM %Q.%s WHERE %s=%Q", &.{ .{ .str = db_name }, .{ .str = tab }, .{ .str = typ }, .{ .str = name } });
        }
    }
}

/// Port of sqlite3CodeDropTable(): code the removal of `t` from the
/// schema and the file.
fn codeDropTable(p: *Parse, t: *Table, i_db: usize, is_view: bool) void {
    const db = p.db;
    const v = getVdbe(p) orelse return;
    beginWriteOperation(p, true, i_db);
    if (t.isVirtual()) _ = aux.addOp0(v, OP.VBegin);
    // Drop its triggers (TEMP triggers on it too).
    var trig = trigger_mod.triggerList(p, t);
    while (trig) |tr| : (trig = tr.next) trigger_mod.dropTriggerPtr(p, tr);
    const db_name = db.dbs.items[i_db].name;
    // Before the b-tree goes, in case auto-vacuum moves sqlite_sequence.
    if (t.tab_flags.Autoincrement) {
        nestedParse(p, "DELETE FROM %Q.sqlite_sequence WHERE name=%Q", &.{ .{ .str = db_name }, .{ .str = t.name } });
    }
    nestedParse(p, "DELETE FROM %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " WHERE tbl_name=%Q and type!='trigger'", &.{ .{ .str = db_name }, .{ .str = t.name } });
    if (!is_view and t.e_tab_type != .vtab) destroyTable(p, t);
    if (t.isVirtual()) {
        _ = aux.addOp4Str(v, OP.VDestroy, @intCast(i_db), 0, 0, t.name);
        main_mod.mayAbort(p);
    }
    _ = aux.addOp4Str(v, OP.DropTable, @intCast(i_db), 0, 0, t.name);
    changeCookie(p, i_db);
    viewResetAll(db, i_db);
}

/// Port of sqlite3ReadOnlyShadowTables(): shadow tables are read-only
/// to ordinary SQL in defensive mode.
pub fn readOnlyShadowTables(db: *Sqlite3) bool {
    return db.flags.Defensive and db.vtab_ctx == null and
        db.n_vdbe_exec == 0 and !vtab_mod.inSync(db);
}

/// Port of tableMayNotBeDropped().
fn tableMayNotBeDropped(db: *Sqlite3, t: *Table) bool {
    if (hasSqlitePrefix(t.name)) {
        const rest = t.name[7..];
        if (rest.len >= 4 and ctype.eqlNoCase(rest[0..4], "stat")) return false;
        if (rest.len >= 10 and ctype.eqlNoCase(rest[0..10], "parameters")) return false;
        return true;
    }
    if (t.tab_flags.Shadow and readOnlyShadowTables(db)) return true;
    if (t.tab_flags.Eponymous) return true;
    return false;
}

/// Port of sqlite3DropTable(): DROP TABLE or (`is_view`) DROP VIEW.
pub fn dropTable(p: *Parse, name: ?*SrcList, is_view: bool, no_err: bool) void {
    const db = p.db;
    if (p.syntax_only or db.malloc_failed) return;
    const src = name.?;
    prepare.readSchema(p) catch return;
    if (no_err) db.suppress_err += 1;
    const t_opt = locateTableItem(p, if (is_view) LOCATE_VIEW else 0, src.at(0));
    if (no_err) db.suppress_err -= 1;
    const t = t_opt orelse {
        if (no_err) {
            codeVerifyNamedSchema(p, src.at(0).u4.database);
            forceNotReadOnly(p);
        }
        return;
    };
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    // Make sure a virtual table is connected.
    if (t.isVirtual()) viewGetColumnNames(p, t) catch return;
    if (tableMayNotBeDropped(db, t)) {
        util.errorMsg(p, "table {s} may not be dropped", .{t.name});
        return;
    }
    if (is_view and !t.isView()) {
        util.errorMsg(p, "use DROP TABLE to delete table {s}", .{t.name});
        return;
    }
    if (!is_view and t.isView()) {
        util.errorMsg(p, "use DROP VIEW to delete view {s}", .{t.name});
        return;
    }
    if (getVdbe(p) == null) return;
    beginWriteOperation(p, true, i_db);
    if (!is_view) {
        clearStatTables(p, i_db, "tbl", t.name);
        fkey_mod.fkDropTable(p, src, t);
    }
    codeDropTable(p, t, i_db, is_view);
}

/// Port of sqlite3CreateView(): CREATE VIEW name[(cnames)] AS sel.
pub fn createView(p: *Parse, begin: Token, name1: Token, name2: Token, cnames: ?*ExprList, sel: ?*Select, is_temp: bool, no_err: bool) void {
    if (p.syntax_only) return;
    createViewImpl(p, begin, name1, name2, cnames, sel.?, is_temp, no_err) catch oomFault(p);
}

fn createViewImpl(p: *Parse, begin: Token, name1: Token, name2: Token, cnames: ?*ExprList, sel: *Select, is_temp: bool, no_err: bool) Oom!void {
    defer if (p.inRenameObject()) alter.renameExprlistUnmap(p, cnames);
    if (p.n_var > 0) {
        util.errorMsg(p, "parameters are not allowed in views", .{});
        return;
    }
    startTable(p, name1, name2, is_temp, true, false, no_err);
    const t = p.new_table orelse return;
    if (p.n_err != 0) return;
    // A view has no rowid.
    t.tab_flags.NoVisibleRowid = true;

    var unq: *const Token = undefined;
    _ = twoPartName(p, &name1, &name2, &unq);
    const i_db: usize = @intCast(prepare.schemaToIndex(p.db, t.schema));
    var fix: attach.DbFixer = undefined;
    attach.fixInit(&fix, p, i_db, "view", unq.slice());
    if (attach.fixSelect(&fix, sel)) return;

    // The view keeps a copy of its SELECT (with its own memory); in
    // rename mode the SELECT itself, whose nodes the rename map has.
    sel.sel_flags.View = true;
    const a = tableAlloc(p, t);
    t.u = .{ .view = .{ .select = if (p.inRenameObject()) sel else try expr_mod.selectDup(a, sel) } };
    t.check = try expr_mod.listDup(a, cnames);
    t.e_tab_type = .view;
    if (p.db.malloc_failed) return;

    // The statement ends at the last token, without trailing spaces.
    var end = p.last_token;
    if (end.z.?[0] != ';') end.z = end.z.? + end.n;
    var n = @intFromPtr(end.z.?) - @intFromPtr(begin.z.?);
    const z = begin.z.?;
    while (n > 0 and ctype.isSpace(z[n - 1])) n -= 1;
    end.z = z + n - 1;
    end.n = 1;
    endTable(p, null, end, .{}, null);
}

/// Port of sqlite3DropIndex(): DROP INDEX [IF EXISTS] name.
pub fn dropIndex(p: *Parse, name: ?*SrcList, if_exists: bool) void {
    const db = p.db;
    if (p.syntax_only or db.malloc_failed) return;
    const src = name.?;
    prepare.readSchema(p) catch return;
    const item = src.at(0);
    const idx = findIndex(db, item.name.?, item.u4.database) orelse {
        if (!if_exists) {
            util.errorMsg(p, "no such index: {s}", .{item.name.?});
        } else {
            codeVerifyNamedSchema(p, item.u4.database);
            forceNotReadOnly(p);
        }
        p.check_schema = true;
        return;
    };
    if (idx.idx_type != .appdef) {
        util.errorMsg(p, "index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped", .{});
        return;
    }
    const i_db: usize = @intCast(prepare.schemaToIndex(db, idx.schema));
    const v = getVdbe(p) orelse return;
    beginWriteOperation(p, true, i_db);
    nestedParse(p, "DELETE FROM %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " WHERE name=%Q AND type='index'", &.{ .{ .str = db.dbs.items[i_db].name }, .{ .str = idx.name } });
    clearStatTables(p, i_db, "idx", idx.name);
    changeCookie(p, i_db);
    destroyRootPage(p, idx.tnum, i_db);
    _ = aux.addOp4Str(v, OP.DropIndex, @intCast(i_db), 0, 0, idx.name);
}

/// Port of collationMatch(): whether a column of `idx` uses collation
/// `coll`.
fn collationMatch(coll: []const u8, idx: *const Index) bool {
    for (idx.coll[0..idx.n_column]) |z| {
        if (std.ascii.eqlIgnoreCase(z, coll)) return true;
    }
    return false;
}

/// Port of sqlite3Reindex(): REINDEX, REINDEX collation, or REINDEX
/// [database.]table-or-index, which rebuilds the indexes named.
pub fn reindex(p: *Parse, name1_arg: ?Token, name2_arg: ?Token) void {
    reindexImpl(p, name1_arg, name2_arg) catch oomFault(p);
}

fn reindexImpl(p: *Parse, name1_arg: ?Token, name2_arg: ?Token) Oom!void {
    const db = p.db;
    if (p.syntax_only or db.malloc_failed) return;
    prepare.readSchema(p) catch return;
    var z: ?[]const u8 = null;
    var zdb: ?[]const u8 = null;
    var i_re_db: ?usize = null;
    var all = false;
    var match = false;
    if (name1_arg) |name1| {
        const name2 = name2_arg.?;
        if (name2.z == null) {
            z = (try nameFromToken(p.arena, name1)) orelse return;
        } else {
            var obj: *const Token = undefined;
            i_re_db = twoPartName(p, &name1, &name2, &obj) orelse return;
            z = (try nameFromToken(p.arena, obj.*)) orelse return;
            zdb = db.dbs.items[i_re_db.?].name;
        }
    } else {
        all = true;
        match = true;
    }
    var is_expr_idx = false;
    var zcoll: ?[]const u8 = null;
    var re_tab: ?*Table = null;
    var re_index: ?*Index = null;
    if (!all) {
        if (zdb == null and std.ascii.eqlIgnoreCase(z.?, "expressions")) {
            is_expr_idx = true;
            match = true;
        }
        if (zdb == null and coll_mod.findCollSeq(db, z.?, false) != null) {
            zcoll = z;
            match = true;
        }
        if (zcoll == null) {
            re_tab = findTable(db, z.?, zdb);
            if (re_tab != null) match = true;
            re_index = findIndex(db, z.?, zdb);
            if (re_index != null) match = true;
        }
    }
    if (!match) {
        util.errorMsg(p, "unable to identify the object to be reindexed", .{});
        return;
    }
    for (db.dbs.items, 0..) |*d, i_db| {
        if (i_re_db != null and i_re_db.? != i_db) continue;
        var it = d.schema.tbl_hash.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            if (t.e_tab_type == .vtab) continue;
            var pidx = t.index;
            while (pidx) |idx| : (pidx = idx.next) {
                if (all or t == re_tab or idx == re_index or (is_expr_idx and idx.has_expr) or
                    (zcoll != null and collationMatch(zcoll.?, idx)))
                {
                    beginWriteOperation(p, false, i_db);
                    refillIndex(p, idx, -1);
                }
            }
        }
    }
}

/// Port of sqlite3DeleteReturning(): the parse cleanup that removes the
/// RETURNING trigger from the TEMP schema.
pub fn deleteReturning(p: *Parse) void {
    if (!p.returning) return;
    const ret = p.u1.d.returning orelse return;
    _ = p.db.dbs.items[1].schema.trig_hash.remove(ret.ret_trig.name);
}

/// Port of sqlite3AddReturning(): RETURNING becomes a TEMP trigger on
/// whatever table the statement turns out to change (see
/// trigger.triggerList()). Removed by deleteReturning() when the parse
/// ends.
pub fn addReturning(p: *Parse, list: ?*ExprList) void {
    addReturningImpl(p, list) catch oomFault(p);
}

fn addReturningImpl(p: *Parse, list: ?*ExprList) Oom!void {
    const db = p.db;
    if (p.syntax_only) return;
    if (p.new_trigger != null) {
        util.errorMsg(p, "cannot use RETURNING in a trigger", .{});
    } else {
        std.debug.assert(!p.returning or p.if_not_exists);
    }
    p.returning = true;
    const ret = try p.arena.create(int.Returning);
    const tmp_schema = db.dbs.items[1].schema;
    ret.* = .{
        .parse = p,
        .return_el = list,
        .ret_trig = .{
            .name = undefined,
            .table = @constCast(""),
            .op = TK.RETURNING,
            .tr_tm = int.TRIGGER_AFTER,
            .returning = true,
            .schema = tmp_schema,
            .tab_schema = tmp_schema,
        },
        .ret_tstep = .{ .op = TK.RETURNING, .expr_list = list },
    };
    const name = std.fmt.bufPrint(ret.name_buf[0 .. ret.name_buf.len - 1], "sqlite_returning_{x}", .{@intFromPtr(p)}) catch unreachable;
    ret.name_buf[name.len] = 0;
    ret.ret_trig.name = ret.name_buf[0..name.len :0];
    ret.ret_trig.step_list = &ret.ret_tstep;
    ret.ret_tstep.trig = &ret.ret_trig;
    p.u1 = .{ .d = .{ .returning = ret } };
    std.debug.assert(!tmp_schema.trig_hash.contains(ret.ret_trig.name) or p.n_err != 0 or p.if_not_exists);
    try tmp_schema.trig_hash.put(db.gpa, ret.ret_trig.name, &ret.ret_trig);
}

/// Port of sqlite3RootPageMoved(): an auto-vacuum DROP moved b-tree `from`
/// to page `to`.
pub fn rootPageMoved(db: *Sqlite3, i_db: usize, from: Pgno, to: Pgno) void {
    const s = db.dbs.items[i_db].schema;
    var it = s.tbl_hash.valueIterator();
    while (it.next()) |t| {
        if (t.*.tnum == from) t.*.tnum = to;
    }
    var it2 = s.idx_hash.valueIterator();
    while (it2.next()) |idx| {
        if (idx.*.tnum == from) idx.*.tnum = to;
    }
}
