//! ALTER TABLE (port of alter.c): RENAME TO, ADD, DROP and RENAME COLUMN,
//! DROP and ADD CONSTRAINT and ALTER COLUMN SET/DROP NOT NULL.
//!
//! Each command is coded as nested statements that rewrite the CREATE
//! statements in sqlite_schema with the internal SQL functions at the end
//! of this file, then reread the schema. The rewriting functions parse a
//! CREATE statement in rename mode (PARSE_MODE_RENAME), in which the
//! parser records for each identifier the parse-tree element it became
//! (the rename-token map, Parse.rename); after name resolution the tokens
//! of the elements to change are found through the map and replaced in
//! the text.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const build = @import("build.zig");
const prepare = @import("prepare.zig");
const main_mod = @import("main.zig");
const expr_mod = @import("expr.zig");
const ec = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const select_mod = @import("select.zig");
const insert_mod = @import("insert.zig");
const update_mod = @import("update.zig");
const walker = @import("walker.zig");
const callback = @import("callback.zig");
const func = @import("func.zig");
const printf = @import("printf.zig");
const ctype = @import("../util/ctype.zig");
const tokenize = @import("../parse/tokenize.zig");
const btree = @import("../btree/btree.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const vtab = @import("vtab.zig");
const api = @import("../vdbe/api.zig");
const vi_mem = @import("../vdbe/mem.zig");

const Allocator = std.mem.Allocator;
const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const Token = int.Token;
const SrcList = int.SrcList;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const Select = int.Select;
const With = int.With;
const Table = int.Table;
const Column = int.Column;
const Index = int.Index;
const Trigger = int.Trigger;
const NameContext = int.NameContext;
const RenameToken = int.RenameToken;
const FuncDef = int.FuncDef;
const Oom = int.Oom;
const RC = int.RC;
const TK = int.TK;
const TF = int.TF;
const SF = int.SF;
const NC = int.NC;
const EP = int.EP;
const COLFLAG = int.COLFLAG;
const Aff = int.Aff;
const OP = vi.OP;
const Context = vi.Context;
const Mem = vi.Mem;
const Walker = walker.Walker;
const WRC = walker.WRC;
const FUNC = callback.FUNC;

// ================================================================ commands

/// Port of isAlterableTable(): system tables (and read-only shadow tables)
/// may not be altered. Leaves an error and returns true if `t` is one.
fn isAlterableTable(p: *Parse, t: *Table) bool {
    if (build.hasSqlitePrefix(t.name) or t.tab_flags & TF.Eponymous != 0 or
        (t.tab_flags & TF.Shadow != 0 and build.readOnlyShadowTables(p.db)))
    {
        util.errorMsg(p, "table {s} may not be altered", .{t.name});
        return true;
    }
    return false;
}

/// Port of renameTestSchema(): code a check that the schema of `zdb` (and
/// of TEMP unless `b_temp`) still parses; `when` goes into the error
/// message. `b_no_dqs` disables double-quoted strings while checking.
fn renameTestSchema(p: *Parse, zdb: []const u8, b_temp: bool, when: []const u8, b_no_dqs: bool) void {
    p.col_names_set = true;
    build.nestedParse(p, "SELECT 1 FROM \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " " ++
        "WHERE name NOT LIKE 'sqliteX_%%' ESCAPE 'X'" ++
        " AND sql NOT LIKE 'create virtual%%'" ++
        " AND sqlite_rename_test(%Q, sql, type, name, %d, %Q, %d)=NULL ", &.{
        .{ .str = zdb },
        .{ .str = zdb },
        .{ .int = @intFromBool(b_temp) },
        .{ .str = when },
        .{ .int = @intFromBool(b_no_dqs) },
    });
    if (!b_temp) {
        build.nestedParse(p, "SELECT 1 FROM temp." ++ int.LEGACY_SCHEMA_TABLE ++ " " ++
            "WHERE name NOT LIKE 'sqliteX_%%' ESCAPE 'X'" ++
            " AND sql NOT LIKE 'create virtual%%'" ++
            " AND sqlite_rename_test(%Q, sql, type, name, 1, %Q, %d)=NULL ", &.{
            .{ .str = zdb },
            .{ .str = when },
            .{ .int = @intFromBool(b_no_dqs) },
        });
    }
}

/// Port of renameFixQuotes(): code the replacement of double-quoted
/// strings (not identifiers) in the schema of `zdb` (and of TEMP unless
/// `b_temp`) by single-quoted ones.
fn renameFixQuotes(p: *Parse, zdb: []const u8, b_temp: bool) void {
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++
        " SET sql = sqlite_rename_quotefix(%Q, sql)" ++
        "WHERE name NOT LIKE 'sqliteX_%%' ESCAPE 'X'" ++
        " AND sql NOT LIKE 'create virtual%%'", &.{ .{ .str = zdb }, .{ .str = zdb } });
    if (!b_temp) {
        build.nestedParse(p, "UPDATE temp." ++ int.LEGACY_SCHEMA_TABLE ++
            " SET sql = sqlite_rename_quotefix('temp', sql)" ++
            "WHERE name NOT LIKE 'sqliteX_%%' ESCAPE 'X'" ++
            " AND sql NOT LIKE 'create virtual%%'", &.{});
    }
}

/// Port of renameReloadSchema(): code the rereading of the schema of
/// `i_db`, and of TEMP if that is another database.
fn renameReloadSchema(p: *Parse, i_db: usize, p5: u16) void {
    const v = p.vdbe orelse return;
    build.changeCookie(p, i_db);
    aux.addParseSchemaOp(v, @intCast(i_db), null, p5);
    if (i_db != 1) aux.addParseSchemaOp(v, 1, null, p5);
}

/// Port of sqlite3AlterRenameTable(): ALTER TABLE src RENAME TO name.
pub fn renameTable(p: *Parse, src: ?*SrcList, name: Token) void {
    renameTableImpl(p, src orelse return, name) catch build.oomFault(p);
}

fn renameTableImpl(p: *Parse, src: *SrcList, name: Token) Oom!void {
    const db = p.db;
    if (p.syntax_only or db.malloc_failed) return;
    std.debug.assert(src.len() == 1);
    const t = build.locateTableItem(p, 0, src.at(0)) orelse return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    const zdb = db.dbs.items[i_db].name;

    // The new name may not be that of another table or index.
    const z_name = (try build.nameFromToken(p.arena, name)).?;
    if (build.findTable(db, z_name, zdb) != null or build.findIndex(db, z_name, zdb) != null or
        build.isShadowTableOf(db, t, z_name))
    {
        util.errorMsg(p, "there is already another table or index with this name: {s}", .{z_name});
        return;
    }

    // Not a system table, nor a reserved new name.
    if (isAlterableTable(p, t)) return;
    if (build.checkObjectName(p, z_name, "table", z_name) != RC.OK) return;

    if (t.isView()) {
        util.errorMsg(p, "view {s} may not be altered", .{t.name});
        return;
    }
    if (build.viewGetColumnNames(p, t) != 0) return;
    // A virtual table with xRename is told of its new name.
    var vt: ?*int.VTable = null;
    if (t.isVirtual()) {
        vt = vtab.getVTable(db, t);
        if (vt.?.vtab.?.module.x_rename == null) vt = null;
    }

    // The internal functions the nested statements call may raise
    // errors, so the statement needs a statement journal.
    const v = build.getVdbe(p) orelse return;
    main_mod.mayAbort(p);

    const tab_name = t.name;
    const n_tab_name = func.utf8CharLen(tab_name.ptr, -1);

    // Rewrite the CREATE statements of the schema that refer to the table.
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_rename_table(%Q, type, name, sql, %Q, %Q, %d) " ++
        "WHERE (type!='index' OR tbl_name=%Q COLLATE nocase)" ++
        "AND   name NOT LIKE 'sqliteX_%%' ESCAPE 'X'", &.{
        .{ .str = zdb },
        .{ .str = zdb },
        .{ .str = tab_name },
        .{ .str = z_name },
        .{ .int = @intFromBool(i_db == 1) },
        .{ .str = tab_name },
    });

    // The tbl_name and name columns of sqlite_schema.
    build.nestedParse(p, "UPDATE %Q." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "tbl_name = %Q, " ++
        "name = CASE " ++
        "WHEN type='table' THEN %Q " ++
        "WHEN name LIKE 'sqliteX_autoindex%%' ESCAPE 'X' " ++
        "     AND type='index' THEN " ++
        "'sqlite_autoindex_' || %Q || substr(name,%d+18) " ++
        "ELSE name END " ++
        "WHERE tbl_name=%Q COLLATE nocase AND " ++
        "(type='table' OR type='index' OR type='trigger');", &.{
        .{ .str = zdb },
        .{ .str = z_name },
        .{ .str = z_name },
        .{ .str = z_name },
        .{ .int = n_tab_name },
        .{ .str = tab_name },
    });

    // The AUTOINCREMENT counter of the table.
    if (build.findTable(db, "sqlite_sequence", zdb) != null) {
        build.nestedParse(p, "UPDATE \"%w\".sqlite_sequence set name = %Q WHERE name = %Q", &.{
            .{ .str = zdb },
            .{ .str = z_name },
            .{ .str = t.name },
        });
    }

    // Views and triggers of TEMP that refer to a table of another
    // database.
    if (i_db != 1) {
        build.nestedParse(p, "UPDATE sqlite_temp_schema SET " ++
            "sql = sqlite_rename_table(%Q, type, name, sql, %Q, %Q, 1), " ++
            "tbl_name = " ++
            "CASE WHEN tbl_name=%Q COLLATE nocase AND " ++
            "  sqlite_rename_test(%Q, sql, type, name, 1, 'after rename', 0) " ++
            "THEN %Q ELSE tbl_name END " ++
            "WHERE type IN ('view', 'trigger')", &.{
            .{ .str = zdb },
            .{ .str = tab_name },
            .{ .str = z_name },
            .{ .str = tab_name },
            .{ .str = zdb },
            .{ .str = z_name },
        });
    }

    // xRename renames what the virtual table keeps under its name (its
    // shadow tables, say).
    if (vt) |pv| {
        p.n_mem += 1;
        const i = p.n_mem;
        _ = aux.loadString(v, i, z_name);
        _ = aux.addOp4(v, OP.VRename, i, 0, 0, .{ .vtab = pv });
    }

    renameReloadSchema(p, i_db, prepare.INITFLAG_AlterRename);
    renameTestSchema(p, zdb, i_db == 1, "after rename", false);
}

/// Port of sqlite3ErrorIfNotEmpty(): code an error `err` if the table
/// is not empty.
fn errorIfNotEmpty(p: *Parse, zdb: []const u8, tab: []const u8, err: []const u8) void {
    build.nestedParse(p, "SELECT raise(ABORT,%Q) FROM \"%w\".\"%w\"", &.{
        .{ .str = err },
        .{ .str = zdb },
        .{ .str = tab },
    });
}

/// Port of isRowidAlias(): a rowid alias of a rowid table may not be the
/// column of `op` ("drop", "add", "rename to", "rename from").
fn isRowidAlias(p: *Parse, t: *Table, col: []const u8, op: []const u8) bool {
    if (t.hasRowid() and resolve.isRowid(col)) {
        util.errorMsg(p, "cannot {s} rowid alias: {s}", .{ op, col });
        return true;
    }
    return false;
}

/// Port of sqlite3AlterFinishAddColumn(): the end of ALTER TABLE ADD
/// COLUMN, once the column definition `col_def` has been parsed into the
/// copy of the table in p.new_table.
pub fn finishAddColumn(p: *Parse, col_def: Token) void {
    finishAddColumnImpl(p, col_def) catch build.oomFault(p);
}

fn finishAddColumnImpl(p: *Parse, col_def: Token) Oom!void {
    const db = p.db;
    if (p.n_err != 0 or p.syntax_only) return;
    const new = p.new_table orelse return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, new.schema));
    const zdb = db.dbs.items[i_db].name;
    // Skip the "sqlite_altertab_" prefix of the copy's name.
    const z_tab = new.name[16..];
    const col = &new.cols[new.cols.len - 1];
    var dflt = build.columnExpr(new, col);
    const t = build.findTable(db, z_tab, zdb).?;

    // Not a PRIMARY KEY, UNIQUE or rowid alias; NOT NULL needs a default
    // that is not NULL.
    if (col.col_flags & COLFLAG.PRIMKEY != 0) {
        util.errorMsg(p, "Cannot add a PRIMARY KEY column", .{});
        return;
    }
    if (new.index != null) {
        util.errorMsg(p, "Cannot add a UNIQUE column", .{});
        return;
    }
    if (isRowidAlias(p, t, col.name(), "add")) return;
    if (col.col_flags & COLFLAG.GENERATED == 0) {
        // A literal NULL default is no default.
        std.debug.assert(dflt == null or dflt.?.op == TK.SPAN);
        if (dflt) |d| if (d.left.?.op == TK.NULL) {
            dflt = null;
        };
        if (db.flags & int.DbFlag.ForeignKeys != 0 and new.u.tab.fkey != null and dflt != null) {
            errorIfNotEmpty(p, zdb, z_tab, "Cannot add a REFERENCES column with non-NULL default value");
        }
        if (col.not_null != 0 and dflt == null) {
            errorIfNotEmpty(p, zdb, z_tab, "Cannot add a NOT NULL column with default value NULL");
        }

        // The default must be something sqlite3ValueFromExpr() can
        // compute (not CURRENT_TIME etc.).
        if (dflt) |d| {
            const v = build.getVdbe(p) orelse return;
            const val = update_mod.valueFromExpr(v, d, Aff.blob) catch return error.OutOfMemory;
            if (val) |m| {
                vi_mem.release(m);
            } else {
                errorIfNotEmpty(p, zdb, z_tab, "Cannot add a column with non-constant default");
            }
        }
    } else if (col.col_flags & COLFLAG.STORED != 0) {
        errorIfNotEmpty(p, zdb, z_tab, "cannot add a STORED column");
    }

    // Insert the column definition into the CREATE TABLE statement.
    // substr() counts characters but add_col_offset is in bytes, hence
    // printf().
    var n = col_def.n;
    const z = col_def.z.?;
    while (n > 1 and (z[n - 1] == ';' or ctype.isSpace(z[n - 1]))) n -= 1;
    std.debug.assert(t.isOrdinary() and new.isOrdinary());
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = printf('%%.%ds, ',sql) || %Q" ++
        " || substr(sql,1+length(printf('%%.%ds',sql))) " ++
        "WHERE type = 'table' AND name = %Q", &.{
        .{ .str = zdb },
        .{ .int = new.u.tab.add_col_offset },
        .{ .str = z[0..n] },
        .{ .int = new.u.tab.add_col_offset },
        .{ .str = z_tab },
    });

    const v = build.getVdbe(p) orelse return;
    // The schema format must be at least 3, but one below 3 is not raised
    // to 4, which would corrupt existing DESC indexes.
    const r1 = expr_mod.getTempReg(p);
    _ = aux.addOp3(v, OP.ReadCookie, @intCast(i_db), r1, @intFromEnum(btree.Meta.file_format));
    aux.usesBtree(v, @intCast(i_db));
    _ = aux.addOp2(v, OP.AddImm, r1, -2);
    _ = aux.addOp2(v, OP.IfPos, r1, aux.currentAddr(v) + 2);
    _ = aux.addOp3(v, OP.SetCookie, @intCast(i_db), @intFromEnum(btree.Meta.file_format), 3);
    expr_mod.releaseTempReg(p, r1);

    // Reload the table definition.
    renameReloadSchema(p, i_db, prepare.INITFLAG_AlterAdd);

    // The existing rows must satisfy the constraints the column adds.
    if (new.check != null or (col.not_null != 0 and col.col_flags & COLFLAG.GENERATED != 0) or
        t.tab_flags & TF.Strict != 0)
    {
        p.col_names_set = true;
        build.nestedParse(p, "SELECT CASE WHEN quick_check GLOB 'CHECK*'" ++
            " THEN raise(ABORT,'CHECK constraint failed')" ++
            " WHEN quick_check GLOB 'non-* value in*'" ++
            " THEN raise(ABORT,'type mismatch on DEFAULT')" ++
            " ELSE raise(ABORT,'NOT NULL constraint failed')" ++
            " END" ++
            "  FROM pragma_quick_check(%Q,%Q)" ++
            " WHERE quick_check GLOB 'CHECK*'" ++
            " OR quick_check GLOB 'NULL*'" ++
            " OR quick_check GLOB 'non-* value in*'", &.{
            .{ .str = z_tab },
            .{ .str = zdb },
        });
    }
}

/// Port of sqlite3AlterBeginAddColumn(): the start of ALTER TABLE ADD
/// COLUMN, after the table name. A copy of the table, named with an
/// "sqlite_altertab_" prefix that no user table can have, goes to
/// p.new_table for addColumn() and the column constraints to extend; it
/// is freed at the end of the parse.
pub fn beginAddColumn(p: *Parse, src: ?*SrcList) void {
    beginAddColumnImpl(p, src orelse return) catch build.oomFault(p);
}

fn beginAddColumnImpl(p: *Parse, src: *SrcList) Oom!void {
    const db = p.db;
    std.debug.assert(p.new_table == null);
    if (p.syntax_only or db.malloc_failed) return;
    const t = build.locateTableItem(p, 0, src.at(0)) orelse return;

    if (t.e_tab_type == .vtab) {
        util.errorMsg(p, "virtual tables may not be altered", .{});
        return;
    }
    if (t.isView()) {
        util.errorMsg(p, "Cannot add a column to a view", .{});
        return;
    }
    if (isAlterableTable(p, t)) return;

    main_mod.mayAbort(p);
    std.debug.assert(t.isOrdinary() and t.u.tab.add_col_offset > 0);
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));

    const name = try std.fmt.allocPrint(p.arena, "sqlite_altertab_{s}", .{t.name});
    const new = try build.newSchemaTable(db, name);
    p.new_table = new;
    const a = new.mem.?.allocator();
    new.cols = try a.alloc(Column, t.cols.len);
    for (new.cols, t.cols) |*nc, *oc| {
        nc.* = oc.*;
        // The name with the declared type and collation that follow it.
        var end: usize = oc.cn_name.len + 1;
        if (oc.col_flags & COLFLAG.HASTYPE != 0) end += std.mem.len(oc.cn_name.ptr + end) + 1;
        if (oc.col_flags & COLFLAG.HASCOLL != 0) end += std.mem.len(oc.cn_name.ptr + end) + 1;
        const z = try a.dupeSentinel(u8, oc.cn_name.ptr[0 .. end - 1], 0);
        nc.cn_name = z[0..oc.cn_name.len :0];
    }
    new.u = .{ .tab = .{
        .dflt_list = try expr_mod.listDup(a, t.u.tab.dflt_list),
        .add_col_offset = t.u.tab.add_col_offset,
    } };
    new.schema = db.dbs.items[i_db].schema;
}

/// Port of isRealTable(): the columns of views and virtual tables cannot
/// be changed. `op` indexes the operation for the message.
fn isRealTable(p: *Parse, t: *Table, op: usize) bool {
    var typ: ?[]const u8 = null;
    if (t.isView()) typ = "view";
    if (t.e_tab_type == .vtab) typ = "virtual table";
    if (typ) |ty| {
        const msgs = [_][]const u8{ "rename columns of", "drop column from", "edit constraints of" };
        util.errorMsg(p, "cannot {s} {s} \"{s}\"", .{ msgs[op], ty, t.name });
        return true;
    }
    return false;
}

/// Port of sqlite3AlterRenameColumn(): ALTER TABLE src RENAME COLUMN old
/// TO new.
pub fn renameColumn(p: *Parse, src: ?*SrcList, old: Token, new: Token) void {
    renameColumnImpl(p, src orelse return, old, new) catch build.oomFault(p);
}

fn renameColumnImpl(p: *Parse, src: *SrcList, old: Token, new: Token) Oom!void {
    const db = p.db;
    if (p.syntax_only or db.malloc_failed) return;
    const t = build.locateTableItem(p, 0, src.at(0)) orelse return;

    if (isAlterableTable(p, t)) return;
    if (isRealTable(p, t, 0)) return;

    const i_schema: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    const zdb = db.dbs.items[i_schema].name;

    // The old name must be a column of the table.
    const z_old = (try build.nameFromToken(p.arena, old)).?;
    const i_col = build.columnIndex(t, z_old);
    if (i_col < 0) {
        util.errorMsgAt(p, old.z, "no such column: \"{s}\"", .{old.slice()});
        return;
    }

    // The schema must not contain double-quoted strings.
    renameTestSchema(p, zdb, i_schema == 1, "", false);
    renameFixQuotes(p, zdb, i_schema == 1);

    // Rewrite the CREATE statements with sqlite_rename_column().
    main_mod.mayAbort(p);
    const z_new = (try build.nameFromToken(p.arena, new)).?;
    if (isRowidAlias(p, t, z_old, "rename from")) return;
    if (isRowidAlias(p, t, z_new, "rename to")) return;
    std.debug.assert(new.n > 0);
    // sqlite3Isquote() is the ctype bit, 0x80, which goes into the SQL.
    const b_quote: i64 = if (ctype.isQuote(new.z.?[0])) 0x80 else 0;
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_rename_column(sql, type, name, %Q, %Q, %d, %Q, %d, %d) " ++
        "WHERE name NOT LIKE 'sqliteX_%%' ESCAPE 'X' " ++
        " AND (type != 'index' OR tbl_name = %Q)", &.{
        .{ .str = zdb },
        .{ .str = zdb },
        .{ .str = t.name },
        .{ .int = i_col },
        .{ .str = z_new },
        .{ .int = b_quote },
        .{ .int = @intFromBool(i_schema == 1) },
        .{ .str = t.name },
    });

    build.nestedParse(p, "UPDATE temp." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_rename_column(sql, type, name, %Q, %Q, %d, %Q, %d, 1) " ++
        "WHERE type IN ('trigger', 'view')", &.{
        .{ .str = zdb },
        .{ .str = t.name },
        .{ .int = i_col },
        .{ .str = z_new },
        .{ .int = b_quote },
    });

    // Reload the schema and check it.
    renameReloadSchema(p, i_schema, prepare.INITFLAG_AlterRename);
    renameTestSchema(p, zdb, i_schema == 1, "after rename", true);
}

// ====================================================== the rename map

/// The key of `x` in the rename-token map: the address of the parse-tree
/// element (for slices, of their first byte), as the void* of the C code.
pub fn key(x: anytype) ?*const anyopaque {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (x) |v| key(v) else null,
        .pointer => |ptr| switch (ptr.size) {
            .slice => return @ptrCast(x.ptr),
            else => return @ptrCast(x),
        },
        else => @compileError("not a pointer: " ++ @typeName(T)),
    }
}

/// The key of &pExpr->y.pTab, which the C code maps to the table name of
/// a "table.column" reference. One byte into the Expr: no other element
/// can have that address.
pub fn yTabKey(e: *const Expr) *const anyopaque {
    return @ptrFromInt(@intFromPtr(e) + 1);
}

/// A RENAME TABLE or RENAME COLUMN operation, for the Walker (RenameCtx).
const RenameCtx = struct {
    /// The tokens to replace.
    list: ?*RenameToken = null,
    n_list: usize = 0,
    /// The column being renamed (-1 for the INTEGER PRIMARY KEY).
    i_col: i32 = 0,
    /// The table being altered.
    tab: ?*Table = null,
};

/// Port of sqlite3RenameTokenMap(): remember that parse-tree element `ptr`
/// came from token `t`. Only called in rename mode.
pub fn renameTokenMap(p: *Parse, ptr: anytype, t: Token) void {
    const k = key(ptr);
    std.debug.assert(k != null or p.db.malloc_failed);
    if (p.e_parse_mode != .unmap) {
        const tok = p.arena.create(RenameToken) catch return build.oomFault(p);
        tok.* = .{ .p = k, .t = t, .next = p.rename };
        p.rename = tok;
    }
}

/// Port of sqlite3RenameTokenRemap(): the token of element `from` now
/// belongs to `to` (null to forget it).
pub fn renameTokenRemap(p: *Parse, to: anytype, from: anytype) void {
    const kf = key(from) orelse return;
    var it = p.rename;
    while (it) |tok| : (it = tok.next) {
        if (tok.p == kf) {
            tok.p = key(to);
            break;
        }
    }
}

/// Port of renameUnmapExprCb().
fn renameUnmapExprCb(w: *Walker, e: *Expr) u8 {
    const p = w.parse.?;
    renameTokenRemap(p, null, e);
    if (e.useYTab()) renameTokenRemap(p, null, yTabKey(e));
    return WRC.Continue;
}

/// Port of renameWalkWith(): walk the SELECTs of the WITH clause of `sel`.
fn renameWalkWith(w: *Walker, sel: *Select) void {
    const with = sel.with orelse return;
    const p = w.parse.?;
    std.debug.assert(with.ctes.items.len > 0);
    var copy: ?*With = null;
    if (with.ctes.items[0].select.?.sel_flags & SF.Expanded == 0) {
        // Push a copy of the WITH clause: the original is about to be
        // expanded and resolved, and the parser code that reads the WITH
        // stack fails on SELECTs that already are.
        copy = expr_mod.withDup(p.arena, with) catch return build.oomFault(p);
        copy = select_mod.withPush(p, copy);
    }
    for (with.ctes.items) |*cte| {
        const s = cte.select.?;
        var nc: NameContext = .{ .parse = p };
        if (copy != null) select_mod.selectPrep(p, s, &nc);
        if (p.db.malloc_failed) return;
        _ = walker.walkSelect(w, s);
        renameExprlistUnmap(p, cte.cols);
    }
    if (copy != null and p.with == copy) p.with = copy.?.outer;
}

/// Port of unmapColumnIdlistNames().
fn unmapColumnIdlistNames(p: *Parse, list: *const IdList) void {
    for (list.names.items) |name| renameTokenRemap(p, null, name);
}

/// Port of renameUnmapSelectCb().
fn renameUnmapSelectCb(w: *Walker, s: *Select) u8 {
    const p = w.parse.?;
    if (p.n_err != 0) return WRC.Abort;
    if (s.sel_flags & (SF.View | SF.CopyCte) != 0) return WRC.Prune;
    if (s.e_list) |list| {
        for (list.slice()) |*item| {
            if (item.e_name != null and item.fg.e_ename == .name) renameTokenRemap(p, null, item.e_name);
        }
    }
    if (s.src) |src| {
        for (src.slice()) |*item| {
            renameTokenRemap(p, null, item.name);
            if (!item.fg.is_using) {
                _ = walker.walkExpr(w, item.u3.on);
            } else if (item.u3.using) |u| {
                unmapColumnIdlistNames(p, u);
            }
        }
    }
    renameWalkWith(w, s);
    return WRC.Continue;
}

/// Port of sqlite3RenameExprUnmap(): forget the tokens of every node of
/// `e`.
pub fn renameExprUnmap(p: *Parse, e: ?*Expr) void {
    const mode = p.e_parse_mode;
    var w: Walker = .{ .parse = p, .expr_callback = renameUnmapExprCb, .select_callback = renameUnmapSelectCb };
    p.e_parse_mode = .unmap;
    _ = walker.walkExpr(&w, e);
    p.e_parse_mode = mode;
}

/// Port of sqlite3RenameExprlistUnmap(): forget the tokens of `list`.
pub fn renameExprlistUnmap(p: *Parse, list: ?*ExprList) void {
    const l = list orelse return;
    var w: Walker = .{ .parse = p, .expr_callback = renameUnmapExprCb };
    _ = walker.walkExprList(&w, l);
    for (l.slice()) |*item| {
        if (item.fg.e_ename == .name) renameTokenRemap(p, null, item.e_name);
    }
}

/// Port of renameTokenFind(): the token of element `ptr`, moved to the
/// list of `ctx` if given.
fn renameTokenFind(p: *Parse, ctx: ?*RenameCtx, ptr: ?*const anyopaque) ?*RenameToken {
    const k = ptr orelse return null;
    var pp: *?*RenameToken = &p.rename;
    while (pp.*) |tok| : (pp = &tok.next) {
        if (tok.p == k) {
            if (ctx) |c| {
                pp.* = tok.next;
                tok.next = c.list;
                c.list = tok;
                c.n_list += 1;
            }
            return tok;
        }
    }
    return null;
}

/// Port of renameColumnSelectCb(): a select callback that makes the
/// walker descend into subqueries (and WITH clauses).
fn renameColumnSelectCb(w: *Walker, s: *Select) u8 {
    if (s.sel_flags & (SF.View | SF.CopyCte) != 0) return WRC.Prune;
    renameWalkWith(w, s);
    return WRC.Continue;
}

fn renameCtx(w: *Walker) *RenameCtx {
    return @ptrCast(@alignCast(w.u.ptr.?));
}

/// Port of renameColumnExprCb(): collect the tokens of references to the
/// column being renamed.
fn renameColumnExprCb(w: *Walker, e: *Expr) u8 {
    const ctx = renameCtx(w);
    if (e.op == TK.TRIGGER and e.i_column == ctx.i_col and w.parse.?.trigger_tab == ctx.tab) {
        _ = renameTokenFind(w.parse.?, ctx, e);
    } else if (e.op == TK.COLUMN and e.i_column == ctx.i_col and e.useYTab() and ctx.tab == e.y.tab) {
        _ = renameTokenFind(w.parse.?, ctx, e);
    }
    return WRC.Continue;
}

/// Port of renameColumnTokenNext(): take the token of `ctx` that comes
/// last in the SQL text.
fn renameColumnTokenNext(ctx: *RenameCtx) *RenameToken {
    var best = ctx.list.?;
    var it = best.next;
    while (it) |tok| : (it = tok.next) {
        if (@intFromPtr(tok.t.z.?) > @intFromPtr(best.t.z.?)) best = tok;
    }
    var pp: *?*RenameToken = &ctx.list;
    while (pp.* != best) pp = &pp.*.?.next;
    pp.* = best.next;
    return best;
}

/// Port of errorMPrintf(): fail the function with a formatted message.
fn errorMPrintf(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    const db = api.contextDbHandle(ctx);
    const msg = std.fmt.allocPrint(db.gpa, fmt, args) catch return api.resultErrorNomem(ctx);
    defer db.gpa.free(msg);
    api.resultError(ctx, msg);
}

/// Port of renameColumnParseError(): fail the function with the error of
/// `p`, in which the object of type `typ` named `obj` was being parsed.
fn renameColumnParseError(ctx: *Context, when: []const u8, typ: *Mem, obj: *Mem, p: *Parse) void {
    const zt = api.valueText(typ) orelse "";
    const zn = api.valueText(obj) orelse "";
    errorMPrintf(ctx, "error in {s} {s}{s}{s}: {s}", .{
        zt,
        zn,
        if (when.len > 0) " " else "",
        when,
        p.err_msg orelse "",
    });
}

/// Port of renameColumnElistNames(): collect the tokens of the names of
/// `list` that are `old`.
fn renameColumnElistNames(p: *Parse, ctx: *RenameCtx, list: ?*ExprList, old: []const u8) void {
    const l = list orelse return;
    for (l.slice()) |*item| {
        const name = item.e_name orelse continue;
        if (item.fg.e_ename == .name and ctype.eqlNoCase(name, old)) {
            _ = renameTokenFind(p, ctx, key(name));
        }
    }
}

/// Port of renameColumnIdlistNames(): the same for an IdList.
fn renameColumnIdlistNames(p: *Parse, ctx: *RenameCtx, list: ?*IdList, old: []const u8) void {
    const l = list orelse return;
    for (l.names.items) |name| {
        if (ctype.eqlNoCase(name, old)) _ = renameTokenFind(p, ctx, key(name));
    }
}

/// A Parse of its own for the CREATE statement an internal function
/// rewrites (the C code's stack Parse with sqlite3ParseObjectInit()).
const RenameParse = struct {
    arena_state: std.heap.ArenaAllocator,
    p: Parse,

    fn init(rp: *RenameParse, db: *Sqlite3) void {
        rp.arena_state = .init(db.gpa);
        rp.p = .{ .db = db, .arena = rp.arena_state.allocator() };
        rp.p.outer_parse = db.parse;
        db.parse = &rp.p;
    }
};

/// Port of renameParseSql(): parse the CREATE statement `sql` of schema
/// `zdb` (TEMP if `b_temp`) in rename mode.
fn renameParseSql(p: *Parse, zdb: ?[]const u8, db: *Sqlite3, sql_arg: ?[:0]const u8, b_temp: bool) i32 {
    const sql = sql_arg orelse return RC.NOMEM;
    if (sql.len < 7 or !ctype.eqlNoCase(sql[0..7], "CREATE ")) return RC.CORRUPT;
    if (b_temp) {
        db.init.i_db = 1;
    } else {
        db.init.i_db = @intCast(build.findDbName(db, zdb) orelse 0);
    }
    p.e_parse_mode = .rename;
    p.n_query_loop = 1;
    const flags = db.flags;
    db.flags |= int.DbFlag.Comments;
    const n_err = tokenize.runParser(p, sql) catch blk: {
        db.oomFault();
        break :blk 1;
    };
    db.flags = flags;
    var rc: i32 = @intCast(n_err);
    if (db.malloc_failed) rc = RC.NOMEM;
    if (rc == RC.OK and p.new_table == null and p.new_index == null and p.new_trigger == null) {
        rc = RC.CORRUPT;
    }
    db.init.i_db = 0;
    return rc;
}

/// Port of renameEditSql(): the result is `sql` with each token of
/// `rename` replaced by `new` (quoted if `b_quote` or needed), or, if
/// `new` is null, each double-quoted string token single-quoted.
fn renameEditSql(ctx: *Context, rename: *RenameCtx, sql: [:0]const u8, new: ?[]const u8, b_quote: bool) i32 {
    const db = api.contextDbHandle(ctx);
    const gpa = db.gpa;
    var quot: ?[:0]u8 = null;
    defer if (quot) |q| gpa.free(q);
    var n_quot: usize = 0;
    if (new) |z| {
        // The quoted name, for tokens that were quoted (or must be). It
        // ends with a space, used if the token is followed by a quote.
        quot = printf.mprintf(gpa, "\"%w\" ", &.{.{ .str = z }}) catch return RC.NOMEM;
        n_quot = quot.?.len - 1;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, sql) catch return RC.NOMEM;
    // The tokens come last to first, so the offsets of those still to be
    // replaced do not move.
    while (rename.list != null) {
        const best = renameColumnTokenNext(rename);
        const tz = best.t.z.?;
        var tmp: ?[:0]u8 = null;
        defer if (tmp) |t| gpa.free(t);
        var replace: []const u8 = undefined;
        if (new) |z| {
            if (!b_quote and ctype.isIdChar(tz[0])) {
                replace = z;
            } else {
                var n = n_quot;
                if (tz[best.t.n] == '"') n += 1;
                replace = quot.?[0..n];
            }
        } else {
            // Dequote the double-quoted token and quote it again with
            // single quotes. If a single quote follows, add a space, so
            // (SELECT "string"'alias') becomes (SELECT 'string' 'alias').
            const buf = gpa.dupeSentinel(u8, tz[0..best.t.n], 0) catch return RC.NOMEM;
            defer gpa.free(buf);
            const d = util.dequote(buf);
            tmp = printf.mprintf(gpa, "%Q%s", &.{
                .{ .str = d },
                .{ .str = if (tz[best.t.n] == '\'') " " else "" },
            }) catch return RC.NOMEM;
            replace = tmp.?;
        }
        const off = @intFromPtr(tz) - @intFromPtr(sql.ptr);
        out.replaceRange(gpa, off, best.t.n, replace) catch return RC.NOMEM;
    }
    api.resultText(ctx, out.items, .transient);
    return RC.OK;
}

/// Port of renameSetENames(): set the e_ename of every entry of `list`.
fn renameSetENames(list: ?*ExprList, val: int.EName) void {
    const l = list orelse return;
    for (l.slice()) |*item| item.fg.e_ename = val;
}

/// Port of renameResolveTrigger(): resolve the names of the trigger in
/// p.new_trigger. Returns an SQLite result code; errors are left in `p`.
fn renameResolveTrigger(p: *Parse) Oom!i32 {
    const db = p.db;
    const new = p.new_trigger.?;
    var nc: NameContext = .{ .parse = p };
    var rc: i32 = RC.OK;
    std.debug.assert(new.tab_schema != null);
    const i_tab_db: usize = @intCast(prepare.schemaToIndex(db, new.tab_schema));
    p.trigger_tab = build.findTable(db, new.table, db.dbs.items[i_tab_db].name);
    p.e_trigger_op = new.op;
    // The table exists, or the parse would have failed.
    if (p.trigger_tab) |tt| rc = @intFromBool(build.viewGetColumnNames(p, tt) != 0);

    // The WHEN clause.
    if (rc == RC.OK and new.when != null) rc = @intCast(resolve.resolveExprNames(&nc, new.when));

    var step_opt = new.step_list;
    while (rc == RC.OK) {
        const step = step_opt orelse break;
        step_opt = step.next;
        if (step.select) |sel| {
            select_mod.selectPrep(p, sel, &nc);
            if (p.n_err != 0) rc = p.rc;
        }
        if (rc == RC.OK and step.src != null) {
            const src = (try expr_mod.srcListDup(p.arena, step.src)).?;
            const sel = try select_mod.selectNew(p, step.expr_list, src, null, null, null, null, 0, null);
            // The names of step.expr_list are the columns an UPDATE sets:
            // they must not resolve the ids of ON clauses as aliases.
            renameSetENames(step.expr_list, .span);
            select_mod.selectPrep(p, sel, null);
            renameSetENames(step.expr_list, .name);
            rc = if (p.n_err != 0) RC.ERROR else RC.OK;
            for (step.src.?.slice()) |*item| {
                if (rc != RC.OK) break;
                if (item.fg.is_subquery) select_mod.selectPrep(p, item.u4.subq.?.select, null);
            }
            if (db.malloc_failed) rc = RC.NOMEM;
            nc.src_list = src;
            if (rc == RC.OK and step.where != null) rc = @intCast(resolve.resolveExprNames(&nc, step.where));
            if (rc == RC.OK) rc = @intCast(resolve.resolveExprListNames(&nc, step.expr_list));
            std.debug.assert(step.upsert == null or (step.where == null and step.expr_list == null));
            if (step.upsert) |up| if (rc == RC.OK) {
                up.src = src;
                nc.u_nc = .{ .upsert = up };
                nc.nc_flags = NC.UUpsert;
                rc = @intCast(resolve.resolveExprListNames(&nc, up.target));
                if (rc == RC.OK) rc = @intCast(resolve.resolveExprListNames(&nc, up.set));
                if (rc == RC.OK) rc = @intCast(resolve.resolveExprNames(&nc, up.where));
                if (rc == RC.OK) rc = @intCast(resolve.resolveExprNames(&nc, up.target_where));
                nc.nc_flags = 0;
            };
            nc.src_list = null;
        }
    }
    return rc;
}

/// Port of renameWalkTrigger(): walk the expressions and SELECTs of a
/// trigger.
fn renameWalkTrigger(w: *Walker, trig: *Trigger) void {
    _ = walker.walkExpr(w, trig.when);
    var it = trig.step_list;
    while (it) |step| : (it = step.next) {
        _ = walker.walkSelect(w, step.select);
        _ = walker.walkExpr(w, step.where);
        _ = walker.walkExprList(w, step.expr_list);
        if (step.upsert) |up| {
            _ = walker.walkExprList(w, up.target);
            _ = walker.walkExprList(w, up.set);
            _ = walker.walkExpr(w, up.where);
            _ = walker.walkExpr(w, up.target_where);
        }
        if (step.src) |src| {
            for (src.slice()) |*item| {
                if (item.fg.is_subquery) _ = walker.walkSelect(w, item.u4.subq.?.select);
            }
        }
    }
}

/// Port of renameParseCleanup(): free what parsing the statement made.
fn renameParseCleanup(rp: *RenameParse) void {
    const p = &rp.p;
    const db = p.db;
    if (p.vdbe) |v| _ = aux.finalize(v);
    if (p.new_table) |t| build.deleteTable(db, t);
    p.new_table = null;
    build.releaseTableRefs(p);
    build.deleteReturning(p);
    @import("prepare.zig").parseObjectResetLookaside(p);
    db.parse = p.outer_parse;
    rp.arena_state.deinit();
}

/// The error result of a rewriting function whose parse or resolution
/// failed with `rc`: the input unchanged with PRAGMA writable_schema=ON,
/// else the error of the parse.
fn renameFuncError(ctx: *Context, rc: i32, argv: []*Mem, i_sql: usize, p: *Parse) void {
    const db = api.contextDbHandle(ctx);
    if (rc == RC.ERROR and build.writableSchema(db)) {
        api.resultValue(ctx, argv[i_sql]);
    } else if (p.err_msg != null) {
        renameColumnParseError(ctx, "", argv[1], argv[2], p);
    } else {
        api.resultErrorCode(ctx, rc);
    }
}

/// Port of renameColumnFunc(): the SQL function
///
///     sqlite_rename_column(SQL,TYPE,OBJ,DB,TABLE,COL,NEWNAME,QUOTE,TEMP)
///
/// SQL with column COL (0 is the leftmost) of table DB.TABLE renamed to
/// NEWNAME, quoted if QUOTE. TEMP says SQL is from the TEMP schema. Used
/// by ALTER TABLE RENAME COLUMN.
fn renameColumnFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const sql = api.valueText(argv[0]);
    const zdb = api.valueText(argv[3]);
    const table = api.valueText(argv[4]);
    const i_col = api.valueInt(argv[5]);
    const new = api.valueText(argv[6]);
    const b_quote = api.valueInt(argv[7]) != 0;
    const b_temp = api.valueInt(argv[8]) != 0;
    if (sql == null or table == null or new == null or i_col < 0) return;
    const t = build.findTable(db, table.?, zdb) orelse return;
    if (i_col >= t.cols.len) return;
    const old = t.cols[@intCast(i_col)].name();
    var rctx: RenameCtx = .{ .i_col = if (i_col == t.i_pkey) -1 else i_col };

    var rp: RenameParse = undefined;
    rp.init(db);
    defer renameParseCleanup(&rp);
    const p = &rp.p;
    var rc = renameParseSql(p, zdb, db, sql, b_temp);
    var w: Walker = .{
        .parse = p,
        .expr_callback = renameColumnExprCb,
        .select_callback = renameColumnSelectCb,
        .u = .{ .ptr = &rctx },
    };
    rctx.tab = t;
    if (rc == RC.OK) rc = renameColumnFind(p, &w, &rctx, t, table.?, i_col, old) catch RC.NOMEM;
    if (rc == RC.OK) rc = renameEditSql(ctx, &rctx, sql.?, new.?, b_quote);
    if (rc != RC.OK) renameFuncError(ctx, rc, argv, 0, p);
}

/// The part of renameColumnFunc() that finds the tokens to replace.
fn renameColumnFind(p: *Parse, w: *Walker, rctx: *RenameCtx, t: *Table, table: []const u8, i_col: i32, old: []const u8) Oom!i32 {
    const db = p.db;
    var rc: i32 = RC.OK;
    if (p.new_table) |nt| {
        if (nt.isView()) {
            const sel = nt.u.view.select.?;
            sel.sel_flags &= ~SF.View;
            p.rc = RC.OK;
            select_mod.selectPrep(p, sel, null);
            rc = if (db.malloc_failed) RC.NOMEM else p.rc;
            if (rc == RC.OK) _ = walker.walkSelect(w, sel);
            return rc;
        } else if (nt.isOrdinary()) {
            // A table: its own definition, or only its foreign keys if it
            // is another table.
            const b_fk_only = !ctype.eqlNoCase(table, nt.name);
            rctx.tab = nt;
            if (!b_fk_only) {
                if (i_col < nt.cols.len) {
                    _ = renameTokenFind(p, rctx, key(nt.cols[@intCast(i_col)].cn_name));
                }
                if (rctx.i_col < 0) _ = renameTokenFind(p, rctx, key(&nt.i_pkey));
                _ = walker.walkExprList(w, nt.check);
                var idx = nt.index;
                while (idx) |ix| : (idx = ix.next) _ = walker.walkExprList(w, ix.col_expr);
                idx = p.new_index;
                while (idx) |ix| : (idx = ix.next) _ = walker.walkExprList(w, ix.col_expr);
                for (nt.cols) |*c| _ = walker.walkExpr(w, build.columnExpr(nt, c));
            }
            var fk_opt = nt.u.tab.fkey;
            while (fk_opt) |fk| : (fk_opt = fk.next_from) {
                for (fk.cols) |*fc| {
                    if (!b_fk_only and fc.i_from == i_col) _ = renameTokenFind(p, rctx, key(fc));
                    if (ctype.eqlNoCase(fk.to, table) and fc.col != null and ctype.eqlNoCase(fc.col.?, old)) {
                        _ = renameTokenFind(p, rctx, key(fc.col));
                    }
                }
            }
        }
    } else if (p.new_index) |idx| {
        _ = walker.walkExprList(w, idx.col_expr);
        _ = walker.walkExpr(w, idx.part_idx_where);
    } else {
        // A trigger.
        rc = try renameResolveTrigger(p);
        if (rc != RC.OK) return rc;
        const trig = p.new_trigger.?;
        var it = trig.step_list;
        while (it) |step| : (it = step.next) {
            const src = step.src orelse continue;
            const target = build.locateTableItem(p, 0, src.at(0));
            if (target == t) {
                if (step.upsert) |up| renameColumnElistNames(p, rctx, up.set, old);
                renameColumnIdlistNames(p, rctx, step.id_list, old);
                renameColumnElistNames(p, rctx, step.expr_list, old);
            }
        }
        // The UPDATE OF columns.
        if (p.trigger_tab == t) renameColumnIdlistNames(p, rctx, trig.columns, old);
        renameWalkTrigger(w, trig);
    }
    return rc;
}

/// Port of renameTableExprCb(): collect the table names of "table.column"
/// references to the table being renamed.
fn renameTableExprCb(w: *Walker, e: *Expr) u8 {
    const ctx = renameCtx(w);
    if (e.op == TK.COLUMN and e.useYTab() and ctx.tab == e.y.tab) {
        _ = renameTokenFind(w.parse.?, ctx, yTabKey(e));
    }
    return WRC.Continue;
}

/// Port of renameTableSelectCb(): collect the FROM-clause terms that name
/// the table being renamed.
fn renameTableSelectCb(w: *Walker, s: *Select) u8 {
    const ctx = renameCtx(w);
    if (s.sel_flags & (SF.View | SF.CopyCte) != 0) return WRC.Prune;
    const src = s.src orelse return WRC.Abort;
    for (src.slice()) |*item| {
        if (item.s_tab == ctx.tab) _ = renameTokenFind(w.parse.?, ctx, key(item.name));
    }
    renameWalkWith(w, s);
    return WRC.Continue;
}

/// Port of renameTableFunc(): the SQL function
///
///     sqlite_rename_table(DB,TYPE,OBJ,SQL,OLD,NEW,TEMP)
///
/// SQL with references to table DB.OLD (as the table defined, the parent
/// of a foreign key, or in views, triggers and CHECK constraints) changed
/// to NEW. TEMP says SQL is from the TEMP schema. Used by ALTER TABLE
/// RENAME TO.
fn renameTableFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const zdb = api.valueText(argv[0]);
    const input = api.valueText(argv[3]);
    const old = api.valueText(argv[4]);
    const new = api.valueText(argv[5]);
    const b_temp = api.valueInt(argv[6]) != 0;
    if (input == null or old == null or new == null) return;

    var rctx: RenameCtx = .{ .tab = build.findTable(db, old.?, zdb) };
    var rp: RenameParse = undefined;
    rp.init(db);
    defer renameParseCleanup(&rp);
    const p = &rp.p;
    var w: Walker = .{
        .parse = p,
        .expr_callback = renameTableExprCb,
        .select_callback = renameTableSelectCb,
        .u = .{ .ptr = &rctx },
    };
    var rc = renameParseSql(p, zdb, db, input, b_temp);
    if (rc == RC.OK) rc = renameTableFind(p, &w, &rctx, old.?) catch RC.NOMEM;
    if (rc == RC.OK) rc = renameEditSql(ctx, &rctx, input.?, new.?, true);
    if (rc != RC.OK) renameFuncError(ctx, rc, argv, 3, p);
}

/// The part of renameTableFunc() that finds the tokens to replace.
fn renameTableFind(p: *Parse, w: *Walker, rctx: *RenameCtx, old: []const u8) Oom!i32 {
    const db = p.db;
    var rc: i32 = RC.OK;
    const is_legacy = db.flags & int.DbFlag.LegacyAlter != 0;
    if (p.new_table) |t| {
        if (t.isView()) {
            if (!is_legacy) {
                const sel = t.u.view.select.?;
                var nc: NameContext = .{ .parse = p };
                std.debug.assert(sel.sel_flags & SF.View != 0);
                sel.sel_flags &= ~SF.View;
                select_mod.selectPrep(p, sel, &nc);
                if (p.n_err != 0) {
                    rc = p.rc;
                } else {
                    _ = walker.walkSelect(w, sel);
                }
            }
        } else {
            // Foreign keys that refer to the renamed table.
            if ((!is_legacy or db.flags & int.DbFlag.ForeignKeys != 0) and t.e_tab_type != .vtab) {
                std.debug.assert(t.isOrdinary());
                var fk_opt = t.u.tab.fkey;
                while (fk_opt) |fk| : (fk_opt = fk.next_from) {
                    if (ctype.eqlNoCase(fk.to, old)) _ = renameTokenFind(p, rctx, key(fk.to));
                }
            }
            // The table itself: its name after "CREATE TABLE", and the
            // table names in its CHECK constraints.
            if (ctype.eqlNoCase(old, t.name)) {
                rctx.tab = t;
                if (!is_legacy) _ = walker.walkExprList(w, t.check);
                _ = renameTokenFind(p, rctx, key(t.name));
            }
        }
    } else if (p.new_index) |idx| {
        _ = renameTokenFind(p, rctx, key(idx.name));
        if (!is_legacy) _ = walker.walkExpr(w, idx.part_idx_where);
    } else {
        const trig = p.new_trigger.?;
        if (ctype.eqlNoCase(trig.table, old) and rctx.tab != null and rctx.tab.?.schema == trig.tab_schema) {
            _ = renameTokenFind(p, rctx, key(trig.table));
        }
        if (!is_legacy) {
            rc = try renameResolveTrigger(p);
            if (rc == RC.OK) {
                renameWalkTrigger(w, trig);
                var it = trig.step_list;
                while (it) |step| : (it = step.next) {
                    const src = step.src orelse continue;
                    for (src.slice()) |*item| {
                        if (item.name) |n| if (ctype.eqlNoCase(n, old)) {
                            _ = renameTokenFind(p, rctx, key(n));
                        };
                    }
                }
            }
        }
    }
    return rc;
}

/// Port of renameQuotefixExprCb().
fn renameQuotefixExprCb(w: *Walker, e: *Expr) u8 {
    if (e.op == TK.STRING and e.has(EP.DblQuoted)) _ = renameTokenFind(w.parse.?, renameCtx(w), e);
    return WRC.Continue;
}

/// Port of renameQuotefixFunc(): the SQL function
///
///     sqlite_rename_quotefix(DB,SQL)
///
/// SQL with its double-quoted string literals (not identifiers) single-
/// quoted. After an error the result is SQL unchanged with PRAGMA
/// writable_schema=ON, else the error.
fn renameQuotefixFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const zdb = api.valueText(argv[0]);
    const input = api.valueText(argv[1]);
    if (zdb == null or input == null) return;
    var rp: RenameParse = undefined;
    rp.init(db);
    defer renameParseCleanup(&rp);
    const p = &rp.p;
    var rc = renameParseSql(p, zdb, db, input, false);
    if (rc == RC.OK) {
        var rctx: RenameCtx = .{};
        var w: Walker = .{
            .parse = p,
            .expr_callback = renameQuotefixExprCb,
            .select_callback = renameColumnSelectCb,
            .u = .{ .ptr = &rctx },
        };
        if (p.new_table) |t| {
            if (t.isView()) {
                const sel = t.u.view.select.?;
                sel.sel_flags &= ~SF.View;
                p.rc = RC.OK;
                select_mod.selectPrep(p, sel, null);
                rc = if (db.malloc_failed) RC.NOMEM else p.rc;
                if (rc == RC.OK) _ = walker.walkSelect(&w, sel);
            } else {
                _ = walker.walkExprList(&w, t.check);
                for (t.cols) |*c| _ = walker.walkExpr(&w, build.columnExpr(t, c));
            }
        } else if (p.new_index) |idx| {
            _ = walker.walkExprList(&w, idx.col_expr);
            _ = walker.walkExpr(&w, idx.part_idx_where);
        } else {
            rc = renameResolveTrigger(p) catch RC.NOMEM;
            if (rc == RC.OK) renameWalkTrigger(&w, p.new_trigger.?);
        }
        if (rc == RC.OK) rc = renameEditSql(ctx, &rctx, input.?, null, false);
    }
    if (rc != RC.OK) {
        if (build.writableSchema(db) and rc == RC.ERROR) {
            api.resultValue(ctx, argv[1]);
        } else {
            api.resultErrorCode(ctx, rc);
        }
    }
}

/// Port of renameTableTest(): the SQL function
///
///     sqlite_rename_test(DB,SQL,TYPE,NAME,ISTEMP,WHEN,DQS)
///
/// Check that the CREATE statement SQL of object NAME of type TYPE still
/// parses and resolves after an ALTER TABLE. If not (and PRAGMA
/// writable_schema is off) raise an error mentioning WHEN; else the
/// result is 1 for a trigger on a table of DB, otherwise NULL. ISTEMP
/// says SQL is from the TEMP schema; DQS disables double-quoted strings.
fn renameTableTest(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const zdb = api.valueText(argv[0]);
    const input = api.valueText(argv[1]);
    const b_temp = api.valueInt(argv[4]) != 0;
    const is_legacy = db.flags & int.DbFlag.LegacyAlter != 0;
    const when = api.valueText(argv[5]);
    const b_no_dqs = api.valueInt(argv[6]) != 0;
    if (zdb == null or input == null) return;

    var rp: RenameParse = undefined;
    rp.init(db);
    defer renameParseCleanup(&rp);
    const p = &rp.p;
    const flags = db.flags;
    if (b_no_dqs) db.flags &= ~(int.DbFlag.DqsDML | int.DbFlag.DqsDDL);
    var rc = renameParseSql(p, zdb, db, input, b_temp);
    db.flags = flags;
    if (rc == RC.OK) {
        if (!is_legacy and p.new_table != null and p.new_table.?.isView()) {
            var nc: NameContext = .{ .parse = p };
            select_mod.selectPrep(p, p.new_table.?.u.view.select.?, &nc);
            if (p.n_err != 0) rc = p.rc;
        } else if (p.new_trigger) |trig| {
            if (!is_legacy) rc = renameResolveTrigger(p) catch RC.NOMEM;
            if (rc == RC.OK) {
                const i_1 = prepare.schemaToIndex(db, trig.tab_schema);
                const i_2: i32 = if (build.findDbName(db, zdb)) |i| @intCast(i) else -1;
                // A trigger on a table of DB.
                if (i_1 == i_2) api.resultInt(ctx, 1);
            }
        }
    }
    if (rc != RC.OK and when != null and !build.writableSchema(db)) {
        renameColumnParseError(ctx, when.?, argv[2], argv[3], p);
    }
}

// ====================================================== DROP COLUMN

/// Port of getConstraintToken(): the bytes up to the end of the next
/// token that is not white space or a comment, with its type in `tk`. A
/// "(" token extends to its matching ")" (or the first illegal token).
fn getConstraintToken(z: [*:0]const u8, tk: *u8) usize {
    var off: usize = 0;
    var t: u8 = 0;
    while (true) {
        const s = tokenize.getToken(z + off);
        off += s.len;
        t = s.tk;
        if (t != TK.SPACE and t != TK.COMMENT) break;
    }
    if (t == TK.LP) {
        var nest: i32 = 1;
        while (nest > 0) {
            const s = tokenize.getToken(z + off);
            off += s.len;
            t = s.tk;
            if (t == TK.LP) {
                nest += 1;
            } else if (t == TK.RP) {
                t = TK.LP;
                nest -= 1;
            } else if (t == TK.ILLEGAL) {
                break;
            }
        }
    }
    tk.* = t;
    return off;
}

/// Port of dropColumnFunc(): the SQL function
///
///     sqlite_drop_column(SCHEMA,SQL,COL)
///
/// The CREATE TABLE statement SQL of database number SCHEMA without
/// column COL. Used by ALTER TABLE DROP COLUMN.
fn dropColumnFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const i_schema = api.valueInt(argv[0]);
    const sql = api.valueText(argv[1]);
    const i_col = api.valueInt(argv[2]);
    const zdb = db.dbs.items[@intCast(i_schema)].name;

    var rp: RenameParse = undefined;
    rp.init(db);
    defer renameParseCleanup(&rp);
    const p = &rp.p;
    var rc = renameParseSql(p, zdb, db, sql, i_schema == 1);
    if (rc == RC.OK) rc = dropColumnEdit(ctx, p, sql.?, i_col);
    if (rc != RC.OK) api.resultErrorCode(ctx, rc);
}

fn dropColumnEdit(ctx: *Context, p: *Parse, sql: [:0]const u8, i_col_arg: i32) i32 {
    const db = p.db;
    const t = p.new_table orelse return RC.CORRUPT;
    // A corrupt sqlite_schema.
    if (t.cols.len == 1 or i_col_arg < 0 or i_col_arg >= t.cols.len) return RC.CORRUPT;
    const i_col: usize = @intCast(i_col_arg);

    var start: [*]const u8 = undefined;
    var end: [*]const u8 = undefined;
    if (i_col < t.cols.len - 1) {
        // From the name of the column to that of the next.
        const col = renameTokenFind(p, null, key(t.cols[i_col].cn_name)).?;
        const next = renameTokenFind(p, null, key(t.cols[i_col + 1].cn_name)).?;
        start = col.t.z.?;
        end = next.t.z.?;
    } else {
        // The last column: from the "," before it, found by tokenizing
        // from the name of the previous column, to the end of the column
        // definitions.
        std.debug.assert(t.isOrdinary() and i_col != 0);
        const col = renameTokenFind(p, null, key(t.cols[i_col - 1].cn_name)).?;
        var tk: u8 = 0;
        var z: [*:0]const u8 = @ptrCast(col.t.z.?);
        while (true) {
            z += getConstraintToken(z, &tk);
            if (tk == TK.COMMA) break;
        }
        start = z - 1;
        end = sql.ptr + @as(usize, @intCast(t.u.tab.add_col_offset));
    }
    const n_start = @intFromPtr(start) - @intFromPtr(sql.ptr);
    const rest = std.mem.span(@as([*:0]const u8, @ptrCast(end)));
    const new = std.mem.concat(db.gpa, u8, &.{ sql[0..n_start], rest }) catch return RC.NOMEM;
    defer db.gpa.free(new);
    api.resultText(ctx, new, .transient);
    return RC.OK;
}

/// Port of sqlite3AlterDropColumn(): ALTER TABLE src DROP COLUMN name.
pub fn dropColumn(p: *Parse, src: ?*SrcList, name: Token) void {
    dropColumnImpl(p, src orelse return, name) catch build.oomFault(p);
}

fn dropColumnImpl(p: *Parse, src: *SrcList, name: Token) Oom!void {
    const db = p.db;
    std.debug.assert(p.new_table == null);
    if (p.syntax_only or db.malloc_failed) return;
    const t = build.locateTableItem(p, 0, src.at(0)) orelse return;

    // Not a view, virtual table or system table.
    if (isAlterableTable(p, t)) return;
    if (isRealTable(p, t, 1)) return;

    // The column.
    const z_col = (try build.nameFromToken(p.arena, name)).?;
    const i_col_i = build.columnIndex(t, z_col);
    if (i_col_i < 0) {
        util.errorMsgAt(p, name.z, "no such column: \"{s}\"", .{name.slice()});
        return;
    }
    const i_col: usize = @intCast(i_col_i);
    if (isRowidAlias(p, t, z_col, "drop")) return;

    // Not a PRIMARY KEY or UNIQUE column.
    const flags = t.cols[i_col].col_flags;
    if (flags & (COLFLAG.PRIMKEY | COLFLAG.UNIQUE) != 0) {
        util.errorMsg(p, "cannot drop {s} column: \"{s}\"", .{
            if (flags & COLFLAG.PRIMKEY != 0) "PRIMARY KEY" else "UNIQUE",
            z_col,
        });
        return;
    }

    // Nor the last column.
    if (t.cols.len <= 1) {
        util.errorMsg(p, "cannot drop column \"{s}\": no other columns exist", .{z_col});
        return;
    }

    // Edit the sqlite_schema table.
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    const zdb = db.dbs.items[i_db].name;
    renameTestSchema(p, zdb, i_db == 1, "", false);
    renameFixQuotes(p, zdb, i_db == 1);
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_drop_column(%d, sql, %d) " ++
        "WHERE (type=='table' AND tbl_name=%Q COLLATE nocase)", &.{
        .{ .str = zdb },
        .{ .int = @intCast(i_db) },
        .{ .int = @intCast(i_col) },
        .{ .str = t.name },
    });

    // Reload the schema and check it.
    renameReloadSchema(p, i_db, prepare.INITFLAG_AlterDrop);
    renameTestSchema(p, zdb, i_db == 1, "after drop column", true);

    // Rewrite every row without the column (a VIRTUAL column is not
    // stored).
    if (p.n_err == 0 and t.cols[i_col].col_flags & COLFLAG.VIRTUAL == 0) {
        const v = build.getVdbe(p) orelse return;
        var pk: ?*Index = null;
        var n_field: i32 = 0;
        const i_cur = p.n_tab;
        p.n_tab += 1;
        insert_mod.openTable(p, i_cur, i_db, t, OP.OpenWrite);
        const addr = aux.addOp1(v, OP.Rewind, i_cur);
        p.n_mem += 1;
        const reg = p.n_mem;
        if (t.hasRowid()) {
            _ = aux.addOp2(v, OP.Rowid, i_cur, reg);
            p.n_mem += @intCast(t.cols.len);
        } else {
            pk = build.primaryKeyIndex(t);
            p.n_mem += pk.?.n_column;
            for (0..pk.?.n_key_col) |i| {
                _ = aux.addOp3(v, OP.Column, i_cur, @intCast(i), reg + @as(i32, @intCast(i)) + 1);
            }
            n_field = pk.?.n_key_col;
        }
        p.n_mem += 1;
        const reg_rec = p.n_mem;
        for (t.cols, 0..) |*c, i| {
            if (i == i_col or c.col_flags & COLFLAG.VIRTUAL != 0) continue;
            var reg_out: i32 = undefined;
            if (pk) |k| {
                const i_pos = build.tableColumnToIndex(k, @intCast(i));
                const i_col_pos = build.tableColumnToIndex(k, @intCast(i_col));
                if (i_pos < k.n_key_col) continue;
                reg_out = reg + 1 + i_pos - @intFromBool(i_pos > i_col_pos);
            } else {
                reg_out = reg + 1 + n_field;
            }
            if (i == t.i_pkey) {
                _ = aux.addOp2(v, OP.Null, 0, reg_out);
            } else {
                // The value as stored: a REAL column would be given REAL
                // affinity.
                const aff = c.affinity;
                if (aff == Aff.real) c.affinity = Aff.numeric;
                ec.codeGetColumnOfTable(v, t, i_cur, @intCast(i), reg_out);
                c.affinity = aff;
            }
            n_field += 1;
        }
        if (n_field == 0) {
            // dbsqlfuzz 5f09e7bcc78b4954d06bf9f2400d7715f48d1fef
            p.n_mem += 1;
            _ = aux.addOp2(v, OP.Null, 0, reg + 1);
            n_field = 1;
        }
        _ = aux.addOp3(v, OP.MakeRecord, reg + 1, n_field, reg_rec);
        if (pk) |k| {
            _ = aux.addOp4Int(v, OP.IdxInsert, i_cur, reg_rec, reg + 1, k.n_key_col);
        } else {
            _ = aux.addOp3(v, OP.Insert, i_cur, reg_rec, reg);
        }
        aux.changeP5(v, vi.OPFLAG.SAVEPOSITION);
        _ = aux.addOp2(v, OP.Next, i_cur, addr + 1);
        aux.jumpHere(v, addr);
    }
}

// ======================================================= constraints

/// Port of getWhitespace(): the bytes of white space and comments at the
/// start of `z`.
fn getWhitespace(z: [*:0]const u8) usize {
    var n: usize = 0;
    while (true) {
        const s = tokenize.getToken(z + n);
        if (s.tk != TK.SPACE and s.tk != TK.COMMENT) break;
        n += s.len;
    }
    return n;
}

/// Port of getConstraint(): the bytes to the end of the constraint whose
/// second token starts `z` (for an unnamed NOT NULL, the token after
/// NOT). `tk`, the type of its first token, enables parsing a foreign key
/// for TK_REFERENCES and TK_FOREIGN.
fn getConstraint(z: [*:0]const u8, tk_arg: u8) usize {
    var off: usize = 0;
    var t: u8 = 0;
    var tk = tk_arg;
    if (tk == TK.FOREIGN) {
        // Up to REFERENCES, then REFERENCES itself.
        off = getConstraint(z, 0);
        off += getConstraintToken(z + off, &tk);
    }
    if (tk == TK.REFERENCES) {
        // The table name, which may be a fallback token like GENERATED.
        off += getConstraintToken(z + off, &t);
    }
    // The constraint ends at the next CONSTRAINT, PRIMARY, NOT, UNIQUE,
    // CHECK, DEFAULT, COLLATE, REFERENCES, FOREIGN, GENERATED, AS, ")" or
    // ",", or at an illegal token.
    while (true) {
        const n = getConstraintToken(z + off, &t);
        switch (t) {
            TK.CONSTRAINT, TK.PRIMARY, TK.NOT, TK.UNIQUE, TK.CHECK, TK.DEFAULT, TK.COLLATE, TK.REFERENCES, TK.FOREIGN, TK.RP, TK.COMMA, TK.ILLEGAL, TK.AS, TK.GENERATED => break,
            else => {},
        }
        off += n;
    }
    return off;
}

/// Port of quotedCompare(): whether the possibly quoted constraint name
/// `quote` differs from `cmp` (case-insensitively).
fn quotedCompare(ctx: *Context, t: u8, quote: []const u8, cmp: []const u8, res: *bool) i32 {
    if (t == TK.ILLEGAL) {
        res.* = true;
        return RC.OK;
    }
    const gpa = api.contextDbHandle(ctx).gpa;
    const copy = gpa.dupeSentinel(u8, quote, 0) catch {
        api.resultErrorNomem(ctx);
        return RC.NOMEM;
    };
    defer gpa.free(copy);
    res.* = !ctype.eqlNoCase(util.dequote(copy), cmp);
    return RC.OK;
}

/// Port of skipCreateTable(): the offset just past the first "(" of the
/// CREATE TABLE statement `sql`, or null (with SQLITE_CORRUPT as the
/// result) if there is none.
fn skipCreateTable(ctx: *Context, sql_arg: ?[:0]const u8) ?usize {
    const sql = sql_arg orelse return null;
    var off: usize = 0;
    while (true) {
        const s = tokenize.getToken(sql.ptr + off);
        off += s.len;
        if (s.tk == TK.LP) break;
        if (s.tk == TK.ILLEGAL) {
            api.resultErrorCode(ctx, RC.CORRUPT);
            return null;
        }
    }
    return off;
}

/// Port of dropConstraintFunc(): the SQL functions
///
///     sqlite_drop_constraint(SQL, INT)   -- the NOT NULL of column INT
///     sqlite_drop_constraint(SQL, TEXT)  -- the constraint named TEXT
///
/// The CREATE TABLE statement SQL without a constraint. Column 0 is the
/// leftmost.
fn dropConstraintFunc(ctx: *Context, argv: []*Mem) void {
    const sql = api.valueText(argv[0]) orelse return;
    var cons: ?[:0]const u8 = null;
    var i_not_null: i32 = -1;
    var start: usize = 0;
    var end: isize = 0;
    var t: u8 = 0;

    // Past "CREATE TABLE ... (".
    var off = skipCreateTable(ctx, sql) orelse return;

    if (api.valueType(argv[1]) == vi.SQLITE_INTEGER) {
        i_not_null = api.valueInt(argv[1]);
    } else {
        cons = api.valueText(argv[1]);
    }
    const z = sql.ptr;

    // Search the column definitions and table constraints: for CONSTRAINT
    // for DROP CONSTRAINT, or NOT in the right column for DROP NOT NULL.
    var ii: i32 = 0;
    while (end == 0) : (ii += 1) {
        while (true) {
            start = off;
            off += getConstraintToken(z + off, &t);
            if (t == TK.CONSTRAINT and (cons != null or i_not_null == ii)) {
                var cmp = true;
                // The name, which may be quoted.
                off += getWhitespace(z + off);
                var n_tok = getConstraintToken(z + off, &t);
                if (cons) |c| {
                    if (quotedCompare(ctx, t, z[off .. off + n_tok], c, &cmp) != RC.OK) return;
                }
                off += n_tok;

                // The next token is usually the first of the constraint,
                // which tells its type: TK_NOT for NOT NULL, TK_CHECK...
                // It may also be CONSTRAINT (or DEFAULT or COLLATE), as in
                //
                //    CREATE TABLE t1(cols, CONSTRAINT one CONSTRAINT two NOT NULL);
                //
                // Then "CONSTRAINT one" alone may be dropped, or the search
                // goes on from the next CONSTRAINT.
                n_tok = getConstraintToken(z + off, &t);
                if (t == TK.CONSTRAINT or t == TK.DEFAULT or t == TK.COLLATE or
                    t == TK.COMMA or t == TK.RP or t == TK.GENERATED or t == TK.AS)
                {
                    t = TK.CHECK;
                } else {
                    off += n_tok;
                    off += getConstraint(z + off, t);
                }

                if (!cmp or (i_not_null >= 0 and t == TK.NOT)) {
                    if (t != TK.NOT and t != TK.CHECK and t != TK.REFERENCES and t != TK.FOREIGN) {
                        errorMPrintf(ctx, "constraint may not be dropped: {s}", .{cons orelse ""});
                        return;
                    }
                    end = @intCast(off);
                    break;
                }
            } else if (t == TK.NOT and i_not_null == ii) {
                end = @intCast(off + getConstraint(z + off, 0));
                break;
            } else if (t == TK.RP or t == TK.ILLEGAL) {
                end = -1;
                break;
            } else if (t == TK.COMMA) {
                break;
            }
        }
    }

    if (end <= 0) {
        if (cons) |c| {
            errorMPrintf(ctx, "no such constraint: {s}", .{c});
        } else {
            // As in PostgreSQL, DROP NOT NULL on a column without NOT NULL
            // is not an error.
            api.resultText(ctx, sql, .transient);
        }
        return;
    }

    // A space where the constraint was, unless a "," or ")" follows,
    // which then also takes the place of a "," before the constraint.
    var e: usize = @intCast(end);
    var space: []const u8 = " ";
    e += getWhitespace(z + e);
    t = tokenize.getToken(z + e).tk;
    if (t == TK.RP or t == TK.COMMA) {
        space = "";
        if (z[start - 1] == ',') start -= 1;
    }
    const db = api.contextDbHandle(ctx);
    const new = std.mem.concat(db.gpa, u8, &.{ sql[0..start], space, sql[e..] }) catch return api.resultErrorNomem(ctx);
    defer db.gpa.free(new);
    api.resultText(ctx, new, .transient);
}

/// Port of addConstraintFunc(): the SQL function
///
///     sqlite_add_constraint(SQL, CONSTRAINT-TEXT, ICOL)
///
/// The CREATE TABLE statement SQL with CONSTRAINT-TEXT at the end of the
/// definition of column ICOL (0 is the leftmost), or as a table
/// constraint if ICOL is negative.
fn addConstraintFunc(ctx: *Context, argv: []*Mem) void {
    const sql = api.valueText(argv[0]);
    const cons = api.valueText(argv[1]) orelse "";
    const i_col = api.valueInt(argv[2]);
    var t: u8 = 0;
    var off = skipCreateTable(ctx, sql) orelse return;
    const z = sql.?.ptr;

    var ii: i32 = 0;
    while (ii <= i_col or (i_col < 0 and t != TK.RP)) : (ii += 1) {
        off += getConstraintToken(z + off, &t);
        while (true) {
            const n_tok = getConstraintToken(z + off, &t);
            if (t == TK.COMMA or t == TK.RP) break;
            if (t == TK.ILLEGAL) {
                api.resultErrorCode(ctx, RC.CORRUPT);
                return;
            }
            off += n_tok;
        }
    }
    off += getWhitespace(z + off);

    const db = api.contextDbHandle(ctx);
    const new = std.mem.concat(db.gpa, u8, &.{
        sql.?[0..off],
        if (i_col < 0) "," else "",
        " ",
        cons,
        sql.?[off..],
    }) catch return api.resultErrorNomem(ctx);
    defer db.gpa.free(new);
    api.resultText(ctx, new, .transient);
}

/// Port of alterFindCol(): the column of `t` named by `col`, or null with
/// an error.
fn alterFindCol(p: *Parse, t: *Table, col: Token) Oom!?usize {
    const name = (try build.nameFromToken(p.arena, col)).?;
    const i_col = build.columnIndex(t, name);
    if (i_col < 0) {
        util.errorMsg(p, "no such column: {s}", .{name});
        return null;
    }
    return @intCast(i_col);
}

/// Port of alterFindTable(): the table of `src`, and its database, unless
/// it is a view, virtual table or system table (then null, with an
/// error).
fn alterFindTable(p: *Parse, src: *SrcList, i_db: *usize) ?*Table {
    const db = p.db;
    const t = build.locateTableItem(p, 0, src.at(0)) orelse return null;
    i_db.* = @intCast(prepare.schemaToIndex(db, t.schema));
    if (isRealTable(p, t, 2) or isAlterableTable(p, t)) return null;
    return t;
}

/// Port of sqlite3AlterDropConstraint(): one of
///
///     ALTER TABLE src DROP CONSTRAINT cons
///     ALTER TABLE src ALTER col DROP NOT NULL
pub fn dropConstraint(p: *Parse, src: ?*SrcList, cons: ?Token, col: ?Token) void {
    dropConstraintImpl(p, src orelse return, cons, col) catch build.oomFault(p);
}

fn dropConstraintImpl(p: *Parse, src: *SrcList, cons: ?Token, col: ?Token) Oom!void {
    const db = p.db;
    std.debug.assert((col == null) != (cons == null));
    std.debug.assert(src.len() == 1);
    if (p.syntax_only or db.malloc_failed) return;
    var i_db: usize = 0;
    const t = alterFindTable(p, src, &i_db) orelse return;
    const zdb = db.dbs.items[i_db].name;

    var arg: [:0]const u8 = undefined;
    if (cons) |c| {
        const z = (try build.nameFromToken(p.arena, c)).?;
        arg = try build.mprintf(p, "%Q", &.{.{ .str = z }});
    } else {
        const i_col = (try alterFindCol(p, t, col.?)) orelse return;
        arg = try build.mprintf(p, "%d", &.{.{ .int = @intCast(i_col) }});
    }

    // Edit the CREATE TABLE statement.
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_drop_constraint(sql, %s) " ++
        "WHERE type='table' AND tbl_name=%Q COLLATE nocase", &.{
        .{ .str = zdb },
        .{ .str = arg },
        .{ .str = t.name },
    });

    // Reload the schema.
    renameReloadSchema(p, i_db, prepare.INITFLAG_AlterDropCons);
}

/// Port of failConstraintFunc(): the SQL function sqlite_fail(MSG, ERR),
/// which fails with message MSG and error code ERR.
fn failConstraintFunc(ctx: *Context, argv: []*Mem) void {
    const text = api.valueText(argv[0]) orelse "";
    const err = api.valueInt(argv[1]);
    api.resultError(ctx, text);
    api.resultErrorCode(ctx, err);
}

/// Port of alterRtrimConstraint(): the length of the constraint text
/// `cons` without trailing white space and "--" comments (whose end might
/// be the end of the string, and so would not end when the text is put
/// in the middle of a statement). C-style comments are kept.
fn alterRtrimConstraint(gpa: Allocator, cons: []const u8) Oom!usize {
    const tmp = try gpa.dupeSentinel(u8, cons, 0);
    defer gpa.free(tmp);
    var off: usize = 0;
    var end: usize = 0;
    while (true) {
        const s = tokenize.getToken(tmp.ptr + off);
        if (s.tk == TK.ILLEGAL) break;
        if (s.tk != TK.SPACE and (s.tk != TK.COMMENT or tmp[off] != '-')) end = off + s.len;
        off += s.len;
    }
    return end;
}

/// Port of sqlite3AlterSetNotNull(): ALTER TABLE src ALTER col SET NOT
/// NULL, whose NOT token is `first`.
pub fn setNotNull(p: *Parse, src: ?*SrcList, col: Token, first: Token) void {
    setNotNullImpl(p, src orelse return, col, first) catch build.oomFault(p);
}

fn setNotNullImpl(p: *Parse, src: *SrcList, col: Token, first: Token) Oom!void {
    const db = p.db;
    std.debug.assert(src.len() == 1);
    if (p.syntax_only or db.malloc_failed) return;
    var i_db: usize = 0;
    const t = alterFindTable(p, src, &i_db) orelse return;
    const zdb = db.dbs.items[i_db].name;
    const i_col = (try alterFindCol(p, t, col)) orelse return;

    // The text of the constraint, up to the end of the statement.
    const cons = first.z.?;
    const n_cons = try alterRtrimConstraint(p.arena, cons[0 .. @intFromPtr(p.last_token.z.?) - @intFromPtr(cons)]);

    // Fail if a row breaks the constraint.
    build.nestedParse(p, "SELECT sqlite_fail('constraint failed', %d) " ++
        "FROM %Q.%Q AS x WHERE x.%.*s IS NULL", &.{
        .{ .int = RC.CONSTRAINT },
        .{ .str = zdb },
        .{ .str = t.name },
        .{ .int = col.n },
        .{ .str = col.slice() },
    });

    // Edit the CREATE TABLE statement.
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_add_constraint(sqlite_drop_constraint(sql, %d), %.*Q, %d) " ++
        "WHERE type='table' AND tbl_name=%Q COLLATE nocase", &.{
        .{ .str = zdb },
        .{ .int = @intCast(i_col) },
        .{ .int = @intCast(n_cons) },
        .{ .str = cons[0..n_cons] },
        .{ .int = @intCast(i_col) },
        .{ .str = t.name },
    });

    // Reload the schema.
    renameReloadSchema(p, i_db, prepare.INITFLAG_AlterDropCons);
}

/// Port of findConstraintFunc(): the SQL function
///
///     sqlite_find_constraint(SQL, CONSTRAINT-NAME)
///
/// Whether the CREATE TABLE statement SQL has a constraint named
/// CONSTRAINT-NAME.
fn findConstraintFunc(ctx: *Context, argv: []*Mem) void {
    const sql = api.valueText(argv[0]) orelse return;
    const cons = api.valueText(argv[1]) orelse return;
    const z = sql.ptr;
    var off: usize = 0;
    var t: u8 = 0;
    while (t != TK.LP and t != TK.ILLEGAL) {
        const s = tokenize.getToken(z + off);
        off += s.len;
        t = s.tk;
    }
    while (true) {
        off += getConstraintToken(z + off, &t);
        if (t == TK.CONSTRAINT) {
            var cmp = false;
            off += getWhitespace(z + off);
            const n_tok = getConstraintToken(z + off, &t);
            if (quotedCompare(ctx, t, z[off .. off + n_tok], cons, &cmp) != RC.OK) return;
            if (!cmp) {
                api.resultInt(ctx, 1);
                return;
            }
        } else if (t == TK.ILLEGAL) {
            break;
        }
    }
    api.resultInt(ctx, 0);
}

/// Port of sqlite3AlterAddConstraint(): ALTER TABLE src ADD [CONSTRAINT
/// name] CHECK(e), where `first` is the first token of the constraint and
/// `text` that of `e`. Any ON CONFLICT up to the end of the statement is
/// part of the constraint.
pub fn addConstraint(p: *Parse, src: ?*SrcList, first: Token, name: ?Token, text: [*]const u8, n: usize, e: ?*Expr) void {
    addConstraintImpl(p, src orelse return, first, name, text[0..n], e) catch build.oomFault(p);
}

fn addConstraintImpl(p: *Parse, src: *SrcList, first: Token, name: ?Token, text: []const u8, e: ?*Expr) Oom!void {
    const db = p.db;
    std.debug.assert(src.len() == 1);
    if (p.syntax_only or db.malloc_failed) return;
    var i_db: usize = 0;
    const t = alterFindTable(p, src, &i_db) orelse return;
    const zdb = db.dbs.items[i_db].name;

    // The constraint may not use internal functions (forum post
    // 2026-05-10T01:11:28Z).
    if (resolve.resolveSelfReference(p, t, NC.IsCheck, e, null) != 0) return;

    // A named constraint must not exist already.
    if (name) |nm| {
        const z_name = (try build.nameFromToken(p.arena, nm)).?;
        build.nestedParse(p, "SELECT sqlite_fail('constraint %q already exists', %d) " ++
            "FROM \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " " ++
            "WHERE type='table' AND tbl_name=%Q COLLATE nocase " ++
            "AND sqlite_find_constraint(sql, %Q)", &.{
            .{ .str = z_name },
            .{ .int = RC.ERROR },
            .{ .str = zdb },
            .{ .str = t.name },
            .{ .str = z_name },
        });
    }

    // Fail if a row breaks the constraint.
    build.nestedParse(p, "SELECT sqlite_fail('constraint failed', %d) " ++
        "FROM %Q.%Q WHERE (%.*s) IS FALSE", &.{
        .{ .int = RC.CONSTRAINT },
        .{ .str = zdb },
        .{ .str = t.name },
        .{ .int = @intCast(text.len) },
        .{ .str = text },
    });

    // Edit the CREATE TABLE statement.
    const cons = first.z.?;
    const n_cons = try alterRtrimConstraint(p.arena, cons[0 .. @intFromPtr(p.last_token.z.?) - @intFromPtr(cons)]);
    build.nestedParse(p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET " ++
        "sql = sqlite_add_constraint(sql, %.*Q, -1) " ++
        "WHERE type='table' AND tbl_name=%Q COLLATE nocase", &.{
        .{ .str = zdb },
        .{ .int = @intCast(n_cons) },
        .{ .str = cons[0..n_cons] },
        .{ .str = t.name },
    });

    // Reload the schema.
    renameReloadSchema(p, i_db, prepare.INITFLAG_AlterDropCons);
}

// ========================================================= registration

/// INTERNAL_FUNCTION(): a built-in that only nested statements may call.
fn internalFunction(name: [:0]const u8, n_arg: i16, x: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = FUNC.BUILTIN | FUNC.INTERNAL | vi.ENC.UTF8 | FUNC.CONSTANT,
        .x_sfunc = x,
        .name = name,
    };
}

var alter_table_funcs = [_]FuncDef{
    internalFunction("sqlite_rename_column", 9, renameColumnFunc),
    internalFunction("sqlite_rename_table", 7, renameTableFunc),
    internalFunction("sqlite_rename_test", 7, renameTableTest),
    internalFunction("sqlite_drop_column", 3, dropColumnFunc),
    internalFunction("sqlite_rename_quotefix", 2, renameQuotefixFunc),
    internalFunction("sqlite_drop_constraint", 2, dropConstraintFunc),
    internalFunction("sqlite_fail", 2, failConstraintFunc),
    internalFunction("sqlite_add_constraint", 3, addConstraintFunc),
    internalFunction("sqlite_find_constraint", 2, findConstraintFunc),
};

/// Port of sqlite3AlterFunctions(): register the built-in functions of
/// ALTER TABLE.
pub fn alterFunctions() void {
    callback.insertBuiltinFuncs(&alter_table_funcs);
}
