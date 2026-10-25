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
    try l.names.append(p.arena, (try nameFromToken(p.arena, t)).?);
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
    if (alias.n != 0) item.alias = try nameFromToken(p.arena, alias);
    if (subquery) |sq| {
        try srcItemAttachSubquery(p, item, sq);
        if (sq.sel_flags & SF.NestedFrom != 0) item.fg.is_nested_from = true;
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
    l.at(0).fg.jointype |= JT.LTORJ & p2.at(0).fg.jointype;
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
    var all: u8 = 0;
    var i = n - 1;
    while (i > 0) : (i -= 1) {
        a[i].fg.jointype = a[i - 1].fg.jointype;
        all |= a[i].fg.jointype;
    }
    a[0].fg.jointype = 0;
    if (all & JT.RIGHT != 0) {
        i = n - 1;
        while (i > 0 and a[i].fg.jointype & JT.RIGHT == 0) i -= 1;
        while (i > 0) {
            i -= 1;
            a[i].fg.jointype |= JT.LTORJ;
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

// =========================================== statements (not ported yet)

const pending = @import("pending.zig");
const Upsert = int.Upsert;

/// Port of sqlite3FinishCoding(): finish the program of a statement.
pub fn finishCoding(p: *Parse) void {
    _ = p;
}

/// Port of sqlite3BeginTransaction().
pub fn beginTransaction(p: *Parse, kind: i32) void {
    _ = kind;
    pending.notYet(p, "BEGIN");
}

/// Port of sqlite3EndTransaction(): COMMIT, END or ROLLBACK.
pub fn endTransaction(p: *Parse, op: u16) void {
    _ = op;
    pending.notYet(p, "COMMIT/ROLLBACK");
}

/// SAVEPOINT_* operations.
pub const SAVEPOINT_BEGIN = 0;
pub const SAVEPOINT_RELEASE = 1;
pub const SAVEPOINT_ROLLBACK = 2;

/// Port of sqlite3Savepoint().
pub fn savepoint(p: *Parse, op: i32, name: Token) void {
    _ = op;
    _ = name;
    pending.notYet(p, "SAVEPOINT");
}

/// Port of sqlite3StartTable().
pub fn startTable(p: *Parse, name1: Token, name2: Token, is_temp: bool, is_view: bool, is_virtual: bool, no_err: bool) void {
    _ = .{ name1, name2, is_temp, is_view, is_virtual, no_err };
    pending.notYet(p, "CREATE TABLE");
}

/// Port of sqlite3AddColumn().
pub fn addColumn(p: *Parse, name: Token, type_tok: Token) void {
    _ = .{ p, name, type_tok };
}

/// Port of sqlite3AddDefaultValue().
pub fn addDefaultValue(p: *Parse, e: ?*Expr, start: ?[*]const u8, end: ?[*]const u8) void {
    _ = .{ p, e, start, end };
}

/// Port of sqlite3AddNotNull().
pub fn addNotNull(p: *Parse, on_error: i32) void {
    _ = .{ p, on_error };
}

/// Port of sqlite3AddPrimaryKey().
pub fn addPrimaryKey(p: *Parse, list: ?*ExprList, on_error: i32, autoinc: bool, sort_order: i32) void {
    _ = .{ p, list, on_error, autoinc, sort_order };
}

/// Port of sqlite3CreateIndex().
pub fn createIndex(
    p: *Parse,
    name1: ?Token,
    name2: ?Token,
    tbl_name: ?*SrcList,
    list: ?*ExprList,
    on_error: i32,
    start: ?Token,
    where: ?*Expr,
    sort_order: i32,
    if_not_exist: bool,
    idx_type: int.IdxType,
) void {
    _ = .{ name1, name2, tbl_name, list, on_error, start, where, sort_order, if_not_exist, idx_type };
    pending.notYet(p, "CREATE INDEX");
}

/// Port of sqlite3AddCheckConstraint().
pub fn addCheckConstraint(p: *Parse, e: ?*Expr, start: ?[*]const u8, end: ?[*]const u8) void {
    _ = .{ p, e, start, end };
}

/// Port of sqlite3CreateForeignKey().
pub fn createForeignKey(p: *Parse, from_col: ?*ExprList, to: Token, to_col: ?*ExprList, flags: i32) void {
    _ = .{ p, from_col, to, to_col, flags };
}

/// Port of sqlite3DeferForeignKey().
pub fn deferForeignKey(p: *Parse, is_deferred: bool) void {
    _ = .{ p, is_deferred };
}

/// Port of sqlite3AddCollateType().
pub fn addCollateType(p: *Parse, t: Token) void {
    _ = .{ p, t };
}

/// Port of sqlite3AddGenerated().
pub fn addGenerated(p: *Parse, e: ?*Expr, type_tok: ?Token) void {
    _ = .{ p, e, type_tok };
}

/// Port of sqlite3EndTable().
pub fn endTable(p: *Parse, cons: ?Token, end: ?Token, tab_opts: u32, sel: ?*Select) void {
    _ = .{ p, cons, end, tab_opts, sel };
}

/// Port of sqlite3DropTable().
pub fn dropTable(p: *Parse, name: ?*SrcList, is_view: bool, no_err: bool) void {
    _ = .{ name, is_view, no_err };
    pending.notYet(p, "DROP TABLE");
}

/// Port of sqlite3CreateView().
pub fn createView(p: *Parse, begin: Token, name1: Token, name2: Token, cnames: ?*ExprList, sel: ?*Select, is_temp: bool, no_err: bool) void {
    _ = .{ begin, name1, name2, cnames, sel, is_temp, no_err };
    pending.notYet(p, "CREATE VIEW");
}

/// Port of sqlite3DropIndex().
pub fn dropIndex(p: *Parse, name: ?*SrcList, if_exists: bool) void {
    _ = .{ name, if_exists };
    pending.notYet(p, "DROP INDEX");
}

/// Port of sqlite3Reindex().
pub fn reindex(p: *Parse, name1: ?Token, name2: ?Token) void {
    _ = .{ name1, name2 };
    pending.notYet(p, "REINDEX");
}

/// Port of sqlite3AddReturning().
pub fn addReturning(p: *Parse, list: ?*ExprList) void {
    _ = list;
    pending.notYet(p, "RETURNING");
}

/// Port of sqlite3ResetAllSchemasOfConnection(): forget every schema so it
/// is read again. Not ported yet.
pub fn resetAllSchemasOfConnection(db: *int.Sqlite3) void {
    _ = db;
}

/// Port of sqlite3ResetOneSchema(): forget the schema of database `i_db`
/// (and TEMP's triggers on it). Not ported yet.
pub fn resetOneSchema(db: *int.Sqlite3, i_db: usize) void {
    _ = .{ db, i_db };
}

/// Port of sqlite3UnlinkAndDeleteTable(): remove a dropped table from the
/// schema. Not ported yet.
pub fn unlinkAndDeleteTable(db: *int.Sqlite3, i_db: usize, name: [:0]const u8) void {
    _ = .{ db, i_db, name };
}

/// Port of sqlite3UnlinkAndDeleteIndex(). Not ported yet.
pub fn unlinkAndDeleteIndex(db: *int.Sqlite3, i_db: usize, name: [:0]const u8) void {
    _ = .{ db, i_db, name };
}

/// Port of sqlite3RootPageMoved(): an auto-vacuum DROP moved b-tree `from`
/// to page `to`. Not ported yet.
pub fn rootPageMoved(db: *int.Sqlite3, i_db: usize, from: int.Pgno, to: int.Pgno) void {
    _ = .{ db, i_db, from, to };
}
