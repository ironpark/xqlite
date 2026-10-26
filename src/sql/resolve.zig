//! Name resolution: bind identifiers to table columns, result-set
//! aliases and functions (port of resolve.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const build = @import("build.zig");
const select_mod = @import("select.zig");
const window = @import("window.zig");
const walker = @import("walker.zig");
const callback = @import("callback.zig");
const numeric = @import("numeric.zig");
const ctype = @import("../util/ctype.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const ExprListItem = int.ExprListItem;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Select = int.Select;
const Table = int.Table;
const Schema = int.Schema;
const NameContext = int.NameContext;
const Walker = walker.Walker;
const WRC = walker.WRC;
const TK = int.TK;
const EP = int.EP;
const SF = int.SF;
const JT = int.JT;
const TF = int.TF;
const COLFLAG = int.COLFLAG;
const Aff = int.Aff;
const Bitmask = int.Bitmask;
const FUNC = callback.FUNC;
const Oom = int.Oom;

pub const NC = int.NC;

/// The cursor number meaning the EXCLUDED table of an upsert.
pub const EXCLUDED_TABLE_NUMBER = 2;

/// A compile error that quotes an expression (%#T in C): also record its
/// offset for sqlite3_error_offset().
fn errorAtExpr(p: *Parse, e: *const Expr, comptime fmt: []const u8, args: anytype) void {
    util.errorMsg(p, fmt, args);
    expr_mod.recordErrorOffsetOfExpr(p, e);
}

fn incrAggDepth(w: *Walker, e: *Expr) u8 {
    if (e.op == TK.AGG_FUNCTION) e.op2 +%= @intCast(w.u.n);
    return WRC.Continue;
}

/// Port of incrAggFunctionDepth(): add `n` to the depth (op2) of every
/// TK_AGG_FUNCTION in `e`, which moves into `n` levels of subquery.
fn incrAggFunctionDepth(e: *Expr, n: i32) void {
    if (n > 0) {
        var w: Walker = .{ .expr_callback = incrAggDepth, .u = .{ .n = n } };
        _ = walker.walkExpr(&w, e);
    }
}

/// Port of resolveAlias(): turn `e` into a copy of result column `i_col`
/// of `e_list`, keeping a COLLATE on `e`.
fn resolveAlias(p: *Parse, e_list: *ExprList, i_col: usize, e: *Expr, n_subquery: i32) Oom!void {
    const orig = e_list.at(i_col).expr.?;
    if (e.agg_info != null) return;
    var dup = (try expr_mod.exprDup(p.arena, orig)).?;
    incrAggFunctionDepth(dup, n_subquery);
    if (e.op == TK.COLLATE) dup = try expr_mod.addCollateString(p, dup, e.token());
    std.mem.swap(Expr, dup, e);
    if (e.has(EP.WinFunc)) {
        if (e.y.win) |win| win.owner = e;
    }
}

/// Port of sqlite3MatchEName(): whether a result column of a subquery
/// (named "DB.TABLE.COLUMN", ENAME_TAB) matches the given names; null
/// names match anything. ENAME_ROWID columns match rowid aliases and set
/// `rowid`.
pub fn matchEName(item: *const ExprListItem, col: ?[]const u8, tab: ?[]const u8, zdb: ?[]const u8, rowid: ?*bool) bool {
    const e_ename = item.fg.e_ename;
    if (e_ename != .tab and (e_ename != .rowid or rowid == null)) return false;
    var span: []const u8 = item.e_name.?;
    var n = std.mem.indexOfScalar(u8, span, '.') orelse span.len;
    if (zdb) |d| if (!ctype.eqlNoCase(span[0..n], d)) return false;
    span = span[@min(n + 1, span.len)..];
    n = std.mem.indexOfScalar(u8, span, '.') orelse span.len;
    if (tab) |t| if (!ctype.eqlNoCase(span[0..n], t)) return false;
    span = span[@min(n + 1, span.len)..];
    if (col) |c| {
        if (e_ename == .tab and !ctype.eqlNoCase(span, c)) return false;
        if (e_ename == .rowid and !isRowid(c)) return false;
    }
    if (e_ename == .rowid) rowid.?.* = true;
    return true;
}

/// Port of sqlite3IsRowid(): "rowid", "oid" or "_rowid_".
pub fn isRowid(z: []const u8) bool {
    return ctype.eqlNoCase(z, "_ROWID_") or ctype.eqlNoCase(z, "ROWID") or ctype.eqlNoCase(z, "OID");
}

/// Port of areDoubleQuotedStringsEnabled().
fn areDoubleQuotedStringsEnabled(db: *int.Sqlite3, top: *NameContext) bool {
    if (db.init.busy) return true;
    if (top.nc_flags & NC.IsDDL != 0) {
        if (build.writableSchema(db) and db.flags & int.DbFlag.DqsDML != 0) return true;
        return db.flags & int.DbFlag.DqsDDL != 0;
    }
    return db.flags & int.DbFlag.DqsDML != 0;
}

/// Port of sqlite3ExprColUsed(): the colUsed bit of a TK_COLUMN; every
/// column for a generated column.
pub fn exprColUsed(e: *const Expr) Bitmask {
    var n: i32 = e.i_column;
    const t = e.y.tab.?;
    if (t.tab_flags & TF.HasGenerated != 0 and t.cols[@intCast(n)].col_flags & COLFLAG.GENERATED != 0) {
        return if (t.cols.len >= int.bms) ~@as(Bitmask, 0) else (@as(Bitmask, 1) << @intCast(t.cols.len)) - 1;
    }
    if (n >= int.bms) n = int.bms - 1;
    return @as(Bitmask, 1) << @intCast(n);
}

/// Port of extendFJMatch(): add the column to the FULL JOIN match list.
fn extendFJMatch(p: *Parse, list: *?*ExprList, match: *SrcItem, i_column: i16) Oom!void {
    const new = try expr_mod.exprAlloc(p.arena, TK.COLUMN, null, false);
    new.i_table = match.i_cursor;
    new.i_column = i_column;
    new.y = .{ .tab = match.s_tab };
    new.set(EP.CanBeNull);
    list.* = try expr_mod.listAppend(p, list.*, new);
}

/// Port of isValidSchemaTableName(): `tab` names the schema table `t`.
fn isValidSchemaTableName(tab: []const u8, t: *Table, zdb: ?[]const u8) bool {
    if (!build.hasSqlitePrefix(tab)) return false;
    const legacy = t.name;
    if (std.mem.eql(u8, legacy[7..], int.LEGACY_TEMP_SCHEMA_TABLE[7..])) {
        if (ctype.eqlNoCase(tab[7..], int.PREFERRED_TEMP_SCHEMA_TABLE[7..])) return true;
        if (zdb == null) return false;
        if (ctype.eqlNoCase(tab[7..], int.LEGACY_SCHEMA_TABLE[7..])) return true;
        if (ctype.eqlNoCase(tab[7..], int.PREFERRED_SCHEMA_TABLE[7..])) return true;
    } else {
        if (ctype.eqlNoCase(tab[7..], int.PREFERRED_SCHEMA_TABLE[7..])) return true;
    }
    return false;
}

/// VisibleRowid().
fn visibleRowid(t: *const Table) bool {
    return t.tab_flags & TF.NoVisibleRowid == 0;
}

/// Port of lookupName(): resolve the column name of "X.Y.Z", "Y.Z" or
/// "Z" (`right` holds Z) against the name contexts from `nc` outward,
/// turning `e` into a TK_COLUMN (or an alias's expression, a TK_TRIGGER
/// or TK_REGISTER). Returns WRC_Prune, or WRC_Abort on error.
fn lookupName(p: *Parse, zdb_arg: ?[]const u8, tab: ?[]const u8, right: *const Expr, nc_arg: *NameContext, e: *Expr) Oom!u8 {
    const db = p.db;
    var zdb = zdb_arg;
    var cnt: i32 = 0;
    var cnt_tab: i32 = 0;
    var n_subquery: i32 = 0;
    var match: ?*SrcItem = null;
    const top_nc = nc_arg;
    var nc: ?*NameContext = nc_arg;
    var schema: ?*Schema = null;
    var e_new_op: u8 = TK.COLUMN;
    var t: ?*Table = null;
    var fj_match: ?*ExprList = null;
    const col = right.token();

    e.i_table = -1;

    // The schema of the database name; none matches if it is unknown.
    if (zdb) |d| {
        if (nc_arg.nc_flags & (NC.PartIdx | NC.IsCheck) != 0) {
            // Database names are ignored in CHECK constraints and partial
            // index WHERE clauses.
            zdb = null;
        } else {
            for (db.dbs.items) |*dd| {
                if (ctype.eqlNoCase(dd.name, d)) {
                    schema = dd.schema;
                    break;
                }
            } else if (ctype.eqlNoCase("main", d)) {
                schema = db.dbs.items[0].schema;
                zdb = db.dbs.items[0].name;
            }
        }
    }

    // From the innermost context outward until a match is found.
    var cur_nc: *NameContext = undefined;
    while (nc) |n| {
        cur_nc = n;
        if (n.src_list) |src_list| {
            for (src_list.slice()) |*item| {
                const tb = item.s_tab.?;
                t = tb;
                if (item.fg.is_nested_from) {
                    // A parenthesized group of FROM terms.
                    var hit = false;
                    const sel = item.u4.subq.?.select;
                    const e_list = sel.e_list.?;
                    for (e_list.slice(), 0..) |*el, j| {
                        var b_rowid = false;
                        if (!matchEName(el, col, tab, zdb, &b_rowid)) continue;
                        if (!b_rowid) {
                            if (cnt > 0) {
                                if (!item.fg.is_using or build.idListIndex(item.u3.using.?, col) == null or match == item) {
                                    // Ambiguous.
                                    fj_match = null;
                                } else if (item.fg.jointype & JT.RIGHT == 0) {
                                    continue;
                                } else if (item.fg.jointype & JT.LEFT == 0) {
                                    cnt = 0;
                                    fj_match = null;
                                } else {
                                    try extendFJMatch(p, &fj_match, match.?, e.i_column);
                                }
                            }
                            cnt += 1;
                            hit = true;
                        } else if (cnt > 0) {
                            continue;
                        }
                        cnt_tab += 1;
                        match = item;
                        e.i_column = @intCast(j);
                        el.fg.used = true;
                        if (el.fg.using_term) break;
                    }
                    if (hit or tab == null) continue;
                }
                if (tab) |tz| {
                    if (zdb) |d| {
                        if (tb.schema != schema) continue;
                        if (schema == null and !std.mem.eql(u8, d, "*")) continue;
                    }
                    if (item.alias) |alias| {
                        if (!ctype.eqlNoCase(tz, alias)) continue;
                    } else if (!ctype.eqlNoCase(tz, tb.name)) {
                        if (tb.tnum != 1) continue;
                        if (!isValidSchemaTableName(tz, tb, zdb)) continue;
                    }
                }
                const j = build.columnIndex(tb, col);
                if (j >= 0) {
                    if (cnt > 0) {
                        if (!item.fg.is_using or build.idListIndex(item.u3.using.?, col) == null) {
                            fj_match = null;
                        } else if (item.fg.jointype & JT.RIGHT == 0) {
                            continue;
                        } else if (item.fg.jointype & JT.LEFT == 0) {
                            cnt = 0;
                            fj_match = null;
                        } else {
                            try extendFJMatch(p, &fj_match, match.?, e.i_column);
                        }
                    }
                    cnt += 1;
                    match = item;
                    // The INTEGER PRIMARY KEY is the rowid (column -1).
                    e.i_column = if (j == tb.i_pkey) -1 else @intCast(j);
                    if (item.fg.is_nested_from) select_mod.srcItemColumnUsed(item, j);
                }
                if (cnt == 0 and visibleRowid(tb)) {
                    // A possible rowid match; only one may be a candidate.
                    cnt_tab += 1;
                    match = item;
                }
            }
            if (match) |m| {
                e.i_table = m.i_cursor;
                e.y = .{ .tab = m.s_tab };
                if (m.fg.jointype & (JT.LEFT | JT.LTORJ) != 0) e.set(EP.CanBeNull);
                schema = m.s_tab.?.schema;
            }
        }

        // new.* or old.* in a trigger, excluded.* in an upsert, or a
        // column of the table a RETURNING clause is on.
        if (cnt == 0 and zdb == null) {
            t = null;
            if (p.trigger_tab) |tt| {
                const op = p.e_trigger_op;
                if (p.returning) {
                    if (n.nc_flags & NC.UBaseReg != 0 and
                        (tab == null or ctype.eqlNoCase(tab.?, tt.name) or isValidSchemaTableName(tab.?, tt, null)))
                    {
                        e.i_table = @intFromBool(op != TK.DELETE);
                        t = tt;
                    }
                } else if (op != TK.DELETE and tab != null and ctype.eqlNoCase("new", tab.?)) {
                    e.i_table = 1;
                    t = tt;
                } else if (op != TK.INSERT and tab != null and ctype.eqlNoCase("old", tab.?)) {
                    e.i_table = 0;
                    t = tt;
                }
            }
            if (n.nc_flags & NC.UUpsert != 0 and tab != null) {
                if (n.u_nc.upsert) |up| if (ctype.eqlNoCase("excluded", tab.?)) {
                    t = up.src.?.at(0).s_tab;
                    e.i_table = EXCLUDED_TABLE_NUMBER;
                };
            }
            if (t) |tb| {
                schema = tb.schema;
                cnt_tab += 1;
                var i_col = build.columnIndex(tb, col);
                if (i_col >= 0) {
                    if (tb.i_pkey == i_col) i_col = -1;
                } else if (isRowid(col) and visibleRowid(tb)) {
                    i_col = -1;
                } else {
                    i_col = @intCast(tb.cols.len);
                }
                if (i_col < tb.cols.len) {
                    cnt += 1;
                    match = null;
                    if (e.i_table == EXCLUDED_TABLE_NUMBER) {
                        if (p.inRenameObject()) {
                            e.i_column = @intCast(i_col);
                            e.y = .{ .tab = tb };
                            e_new_op = TK.COLUMN;
                        } else {
                            e.i_table = n.u_nc.upsert.?.reg_data + build.tableColumnToStorage(tb, @intCast(i_col));
                            e_new_op = TK.REGISTER;
                        }
                    } else {
                        e.y = .{ .tab = tb };
                        if (p.returning) {
                            e_new_op = TK.REGISTER;
                            e.op2 = TK.COLUMN;
                            e.i_column = @intCast(i_col);
                            e.i_table = n.u_nc.i_base_reg + (@as(i32, @intCast(tb.cols.len)) + 1) * e.i_table +
                                build.tableColumnToStorage(tb, @intCast(i_col)) + 1;
                        } else {
                            e.i_column = @intCast(i_col);
                            e_new_op = TK.TRIGGER;
                            if (i_col < 0) {
                                e.aff_expr = Aff.integer;
                            } else if (e.i_table == 0) {
                                p.oldmask |= if (i_col >= 32) 0xffffffff else @as(u32, 1) << @intCast(i_col);
                            } else {
                                p.newmask |= if (i_col >= 32) 0xffffffff else @as(u32, 1) << @intCast(i_col);
                            }
                        }
                    }
                }
            }
        }

        // The rowid.
        if (cnt == 0 and cnt_tab >= 1 and match != null and n.nc_flags & (NC.IdxExpr | NC.GenCol) == 0 and isRowid(col)) {
            cnt = cnt_tab;
            if (!match.?.fg.is_nested_from) e.i_column = -1;
            e.aff_expr = Aff.integer;
        }

        // A bare name may be an alias of the result set (a legacy
        // extension, as in "SELECT a+b AS x FROM t WHERE x<10").
        if (cnt == 0 and n.nc_flags & NC.UEList != 0 and tab == null) {
            const e_list = n.u_nc.e_list.?;
            for (e_list.slice(), 0..) |*el, j| {
                if (el.fg.e_ename == .name and el.e_name != null and ctype.eqlNoCase(el.e_name.?, col)) {
                    const orig = el.expr.?;
                    if (n.nc_flags & NC.AllowAgg == 0 and orig.has(EP.Agg)) {
                        util.errorMsg(p, "misuse of aliased aggregate {s}", .{el.e_name.?});
                        return WRC.Abort;
                    }
                    if (orig.has(EP.Win) and (n.nc_flags & NC.AllowWin == 0 or n != top_nc)) {
                        util.errorMsg(p, "misuse of aliased window function {s}", .{el.e_name.?});
                        return WRC.Abort;
                    }
                    if (expr_mod.vectorSize(orig) != 1) {
                        util.errorMsg(p, "row value misused", .{});
                        return WRC.Abort;
                    }
                    try resolveAlias(p, e_list, j, e, n_subquery);
                    cnt = 1;
                    match = null;
                    return lookupNameEnd(p, top_nc, cur_nc, cnt);
                }
            }
        }

        if (cnt != 0) break;
        nc = n.next;
        n_subquery += 1;
    }

    // An unmatched double-quoted bare name is a string literal.
    if (cnt == 0 and tab == null) {
        std.debug.assert(e.op == TK.ID);
        if (e.has(EP.DblQuoted) and areDoubleQuotedStringsEnabled(db, top_nc)) {
            e.op = TK.STRING;
            e.y = .{ .tab = null };
            return WRC.Prune;
        }
        if (expr_mod.idToTrueFalse(e)) return WRC.Prune;
    }

    // No match is an error; so are several, except for an outer join
    // USING column, which becomes coalesce() of its matches.
    if (cnt != 1) {
        if (fj_match) |fj| {
            if (fj.len() == cnt - 1) {
                if (e.has(EP.Leaf)) {
                    e.clear(EP.Leaf);
                } else {
                    e.left = null;
                    e.right = null;
                }
                try extendFJMatch(p, &fj_match, match.?, e.i_column);
                e.op = TK.FUNCTION;
                e.u = .{ .token = try p.arena.dupeSentinel(u8, "coalesce", 0) };
                e.x = .{ .list = fj_match };
                e.aff_expr = Aff.@"defer";
                cnt = 1;
                return lookupNameEnd(p, top_nc, cur_nc, cnt);
            }
            fj_match = null;
        }
        const err = if (cnt == 0) "no such column" else "ambiguous column name";
        if (zdb) |d| {
            util.errorMsg(p, "{s}: {s}.{s}.{s}", .{ err, d, tab.?, col });
        } else if (tab) |tz| {
            util.errorMsg(p, "{s}: {s}.{s}", .{ err, tz, col });
        } else if (cnt == 0 and right.has(EP.DblQuoted)) {
            util.errorMsg(p, "{s}: \"{s}\" - should this be a string literal in single-quotes?", .{ err, col });
        } else {
            util.errorMsg(p, "{s}: {s}", .{ err, col });
        }
        expr_mod.recordErrorOffsetOfExpr(p, e);
        p.check_schema = true;
        top_nc.n_nc_err += 1;
        e_new_op = TK.NULL;
    }

    // Remove all substructure.
    if (!e.has(EP.TokenOnly | EP.Leaf)) {
        e.left = null;
        e.right = null;
        e.set(EP.Leaf);
    }

    // Record the column in colUsed.
    if (match) |m| {
        if (e.i_column >= 0) {
            m.col_used |= exprColUsed(e);
        } else {
            m.fg.rowid_used = true;
        }
    }

    e.op = e_new_op;
    return lookupNameEnd(p, top_nc, cur_nc, cnt);
}

/// The lookupname_end part of lookupName(): count the reference in every
/// context from the top to the one that matched.
fn lookupNameEnd(p: *Parse, top: *NameContext, matched: *NameContext, cnt: i32) u8 {
    _ = p;
    if (cnt != 1) return WRC.Abort;
    var it = top;
    while (true) {
        it.n_ref += 1;
        if (it == matched) break;
        it = it.next.?;
    }
    return WRC.Prune;
}

/// Port of sqlite3CreateColumnExpr(): a TK_COLUMN for column `i_col` of
/// FROM term `i_src`.
pub fn createColumnExpr(p: *Parse, src: *SrcList, i_src: usize, i_col: i32) Oom!*Expr {
    const e = try expr_mod.exprAlloc(p.arena, TK.COLUMN, null, false);
    const item = src.at(i_src);
    const t = item.s_tab.?;
    e.y = .{ .tab = t };
    e.i_table = item.i_cursor;
    if (t.i_pkey == i_col) {
        e.i_column = -1;
    } else {
        e.i_column = @intCast(i_col);
        if (t.tab_flags & TF.HasGenerated != 0 and t.cols[@intCast(i_col)].col_flags & COLFLAG.GENERATED != 0) {
            item.col_used = if (t.cols.len >= 64) ~@as(Bitmask, 0) else (@as(Bitmask, 1) << @intCast(t.cols.len)) - 1;
        } else {
            item.col_used |= @as(Bitmask, 1) << @intCast(if (i_col >= int.bms) int.bms - 1 else i_col);
        }
    }
    return e;
}

/// Port of notValidImpl(): `msg` is not allowed in the self-referencing
/// context of `nc`.
fn notValidImpl(p: *Parse, nc: *NameContext, msg: []const u8, e: ?*Expr, err_expr: ?*Expr) void {
    var in: []const u8 = "partial index WHERE clauses";
    if (nc.nc_flags & NC.IdxExpr != 0) {
        in = "index expressions";
    } else if (nc.nc_flags & NC.IsCheck != 0) {
        in = "CHECK constraints";
    } else if (nc.nc_flags & NC.GenCol != 0) {
        in = "generated columns";
    }
    util.errorMsg(p, "{s} prohibited in {s}", .{ msg, in });
    if (e) |x| x.op = TK.NULL;
    expr_mod.recordErrorOffsetOfExpr(p, err_expr);
}

/// sqlite3ResolveNotValid().
fn resolveNotValid(p: *Parse, nc: *NameContext, msg: []const u8, valid_mask: u32, e: ?*Expr, err_expr: ?*Expr) void {
    if (nc.nc_flags & valid_mask != 0) notValidImpl(p, nc, msg, e, err_expr);
}

/// Port of exprProbability(): 2^27 times a constant probability, or -1.
fn exprProbability(e: *Expr) i32 {
    var r: f64 = -1.0;
    if (e.op != TK.FLOAT) return -1;
    _ = numeric.atoF(e.token().ptr, &r);
    if (r > 1.0) return -1;
    return @intFromFloat(r * 134217728.0);
}

/// Port of resolveSetExprSubtypeArg().
fn resolveSetExprSubtypeArg(list: ?*ExprList) void {
    const l = list orelse return;
    for (l.slice()) |item| {
        var e = item.expr.?;
        while (true) {
            e.set(EP.SubtArg);
            if (e.op == TK.SELECT) {
                resolveSetExprSubtypeArg(e.x.select.?.e_list);
                break;
            }
            if (e.op == TK.UPLUS) {
                e = e.left.?;
            } else {
                break;
            }
        }
    }
}

/// Port of resolveExprStep(): the expression callback of the resolver.
fn resolveExprStep(w: *Walker, e: *Expr) u8 {
    return resolveExprStepImpl(w, e) catch {
        build.oomFault(w.parse.?);
        return WRC.Abort;
    };
}

fn resolveExprStepImpl(w: *Walker, e: *Expr) Oom!u8 {
    const nc = w.u.nc.?;
    const p = nc.parse;
    switch (e.op) {
        // The rowid of the first FROM term (UPDATE and DELETE).
        TK.ROW => {
            const item = nc.src_list.?.at(0);
            e.op = TK.COLUMN;
            e.y = .{ .tab = item.s_tab };
            e.i_table = item.i_cursor;
            e.i_column -= 1;
            e.aff_expr = Aff.integer;
        },

        // "x IS NOT NULL" is TRUE and "x IS NULL" FALSE if x can never be
        // NULL, but only within a WHERE clause.
        TK.NOTNULL, TK.ISNULL => {
            var an_ref: [8]i32 = undefined;
            {
                var it: ?*NameContext = nc;
                var i: usize = 0;
                while (it) |q| : (it = q.next) {
                    if (i >= an_ref.len) break;
                    an_ref[i] = q.n_ref;
                    i += 1;
                }
            }
            _ = walker.walkExpr(w, e.left);
            if (p.inRenameObject()) return WRC.Prune;
            if (expr_mod.canBeNull(e.left.?)) return WRC.Prune;
            {
                var it: ?*NameContext = nc;
                while (it) |q| : (it = q.next) {
                    if (q.nc_flags & NC.Where == 0) return WRC.Prune;
                }
            }
            e.u = .{ .value = @intFromBool(e.op == TK.NOTNULL) };
            e.flags |= EP.IntValue;
            e.op = TK.INTEGER;
            {
                var it: ?*NameContext = nc;
                var i: usize = 0;
                while (it) |q| : (it = q.next) {
                    if (i >= an_ref.len) break;
                    q.n_ref = an_ref[i];
                    i += 1;
                }
            }
            e.left = null;
            return WRC.Prune;
        },

        // ID, ID.ID or ID.ID.ID.
        TK.ID, TK.DOT => {
            var zdb: ?[]const u8 = null;
            var tab: ?[]const u8 = null;
            var right: *Expr = undefined;
            if (e.op == TK.ID) {
                right = e;
            } else {
                var left = e.left.?;
                resolveNotValid(p, nc, "the \".\" operator", NC.IdxExpr | NC.GenCol, null, e);
                right = e.right.?;
                if (right.op != TK.ID) {
                    std.debug.assert(right.op == TK.DOT);
                    zdb = left.token();
                    left = right.left.?;
                    right = right.right.?;
                }
                tab = left.token();
            }
            return lookupName(p, zdb, tab, right, nc, e);
        },

        // Functions.
        TK.FUNCTION => {
            const list = e.x.list;
            const n: i32 = if (list) |l| @intCast(l.len()) else 0;
            var no_such_func: u8 = 0;
            var wrong_num_args = false;
            var is_agg = false;
            const id = e.token();
            const saved_allow_flags = nc.nc_flags & (NC.AllowAgg | NC.AllowWin);
            const win: ?*int.Window = if (e.isWindowFunc()) e.y.win else null;
            var def = callback.findFunction(p.db, id, n, p.db.enc, false);
            if (def == null) {
                def = callback.findFunction(p.db, id, -2, p.db.enc, false);
                if (def == null) {
                    no_such_func = 1;
                } else {
                    wrong_num_args = true;
                }
            } else {
                const d = def.?;
                is_agg = d.x_finalize != null;
                if (d.func_flags & FUNC.UNLIKELY != 0) {
                    e.set(EP.Unlikely);
                    if (n == 2) {
                        e.i_table = exprProbability(list.?.at(1).expr.?);
                        if (e.i_table < 0) {
                            errorAtExpr(p, e, "second argument to {s}() must be a constant between 0.0 and 1.0", .{id});
                            nc.n_nc_err += 1;
                        }
                    } else {
                        // unlikely(X) is likelihood(X,0.0625); likely(X)
                        // is likelihood(X,0.9375).
                        e.i_table = if (d.name[0] == 'u') 8388608 else 125829120;
                    }
                }
                if (d.func_flags & FUNC.SUBTYPE != 0 or e.has(EP.SubtArg)) resolveSetExprSubtypeArg(list);
                if (d.func_flags & (FUNC.CONSTANT | FUNC.SLOCHNG) != 0) {
                    // Constant for the duration of one query.
                    e.set(EP.ConstFunc);
                }
                if (d.func_flags & FUNC.CONSTANT == 0) {
                    resolveNotValid(p, nc, "non-deterministic functions", NC.IdxExpr | NC.PartIdx | NC.GenCol, null, e);
                } else {
                    e.op2 = @intCast(nc.nc_flags & NC.SelfRef);
                }
                if (d.func_flags & FUNC.INTERNAL != 0 and p.nested == 0 and p.db.m_db_flags & int.DBFLAG.InternalFunc == 0) {
                    // Internal functions are unknown outside nested parses.
                    no_such_func = 2;
                    def = null;
                } else if (d.func_flags & (FUNC.DIRECT | FUNC.UNSAFE) != 0 and !p.inRenameObject()) {
                    if (nc.nc_flags & NC.FromDDL != 0) e.set(EP.FromDDL);
                    expr_mod.functionUsable(p, e, d);
                }
            }

            if (!p.inRenameObject()) {
                if (def != null and def.?.x_value == null and win != null) {
                    errorAtExpr(p, e, "{s}() may not be used as a window function", .{id});
                    nc.n_nc_err += 1;
                } else if ((is_agg and nc.nc_flags & NC.AllowAgg == 0) or
                    (is_agg and def.?.func_flags & FUNC.WINDOW != 0 and win == null) or
                    (is_agg and win != null and nc.nc_flags & NC.AllowWin == 0))
                {
                    const typ = if (def.?.func_flags & FUNC.WINDOW != 0 or win != null) "window" else "aggregate";
                    errorAtExpr(p, e, "misuse of {s} function {s}()", .{ typ, id });
                    nc.n_nc_err += 1;
                    is_agg = false;
                } else if (no_such_func != 0 and (!p.db.init.busy or (no_such_func == 2 and false))) {
                    // Unknown functions are tolerated while reading the
                    // schema.
                    errorAtExpr(p, e, "no such function: {s}", .{id});
                    nc.n_nc_err += 1;
                } else if (wrong_num_args) {
                    errorAtExpr(p, e, "wrong number of arguments to function {s}()", .{id});
                    nc.n_nc_err += 1;
                } else if (!is_agg and e.has(EP.WinFunc)) {
                    errorAtExpr(p, e, "FILTER may not be used with non-aggregate {s}()", .{id});
                    nc.n_nc_err += 1;
                } else if (!is_agg and e.left != null) {
                    expr_mod.orderByAggregateError(p, e);
                    nc.n_nc_err += 1;
                }
                if (is_agg) {
                    // Window functions may not be arguments of aggregates,
                    // nor aggregates of aggregates.
                    nc.nc_flags &= ~(NC.AllowWin | (if (win == null) NC.AllowAgg else 0));
                }
            } else if (e.has(EP.WinFunc) or e.left != null) {
                is_agg = true;
            }
            _ = walker.walkExprList(w, list);
            if (is_agg) {
                if (e.left) |l| _ = walker.walkExprList(w, l.x.list);
                if (win != null and p.n_err == 0) {
                    const sel = nc.win_select;
                    if (!p.inRenameObject()) {
                        try window.windowUpdate(p, if (sel) |s| s.win_defn else null, win.?, def.?);
                        if (p.db.malloc_failed) return WRC.Abort;
                    }
                    _ = walker.walkExprList(w, win.?.partition);
                    _ = walker.walkExprList(w, win.?.order_by);
                    _ = walker.walkExpr(w, win.?.filter);
                    window.windowLink(sel, win.?);
                    nc.nc_flags |= NC.HasWin;
                } else {
                    e.op = TK.AGG_FUNCTION;
                    e.op2 = 0;
                    if (e.has(EP.WinFunc)) _ = walker.walkExpr(w, e.y.win.?.filter);
                    var nc2: ?*NameContext = nc;
                    while (nc2) |q| {
                        if (expr_mod.referencesSrcList(p, e, q.src_list) != 0) break;
                        e.op2 +%= @intCast(1 + q.n_nested_select);
                        nc2 = q.next;
                    }
                    if (nc2) |q| if (def) |d| {
                        e.op2 +%= @intCast(q.n_nested_select);
                        q.nc_flags |= NC.HasAgg | ((d.func_flags ^ FUNC.ANYORDER) & (FUNC.MINMAX | FUNC.ANYORDER));
                    };
                }
                nc.nc_flags |= saved_allow_flags;
            }
            return WRC.Prune;
        },

        TK.EXISTS, TK.SELECT, TK.IN => {
            if (e.useXSelect()) {
                const n_ref = nc.n_ref;
                if (e.op == TK.EXISTS) p.bhas_exists = true;
                if (nc.nc_flags & NC.SelfRef != 0) {
                    notValidImpl(p, nc, "subqueries", e, e);
                } else {
                    _ = walker.walkSelect(w, e.x.select);
                }
                if (n_ref != nc.n_ref) {
                    e.set(EP.VarSelect);
                    e.x.select.?.sel_flags |= SF.Correlated;
                }
                nc.nc_flags |= NC.Subquery;
            }
        },

        TK.VARIABLE => {
            resolveNotValid(p, nc, "parameters", NC.IsCheck | NC.PartIdx | NC.IdxExpr | NC.GenCol, e, e);
        },

        else => {
            if (e.op == TK.IS or e.op == TK.ISNOT) {
                // "x IS TRUE", "x IS FALSE" and their negations.
                const right = expr_mod.skipCollateAndLikely(e.right);
                if (right) |r| if (r.op == TK.ID or r.op == TK.TRUEFALSE) {
                    const rc = resolveExprStep(w, r);
                    if (rc == WRC.Abort) return WRC.Abort;
                    if (r.op == TK.TRUEFALSE) {
                        e.op2 = e.op;
                        e.op = TK.TRUTH;
                        return WRC.Continue;
                    }
                };
            }
            switch (e.op) {
                TK.IS, TK.ISNOT, TK.BETWEEN, TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE => {
                    if (p.db.malloc_failed) return if (p.n_err != 0) WRC.Abort else WRC.Continue;
                    const n_left = expr_mod.vectorSize(e.left.?);
                    var n_right: usize = undefined;
                    if (e.op == TK.BETWEEN) {
                        n_right = expr_mod.vectorSize(e.x.list.?.at(0).expr.?);
                        if (n_right == n_left) n_right = expr_mod.vectorSize(e.x.list.?.at(1).expr.?);
                    } else {
                        n_right = expr_mod.vectorSize(e.right.?);
                    }
                    if (n_left != n_right) {
                        util.errorMsg(p, "row value misused", .{});
                        expr_mod.recordErrorOffsetOfExpr(p, e);
                    }
                },
                else => {},
            }
        },
    }
    return if (p.n_err != 0) WRC.Abort else WRC.Continue;
}

/// Port of resolveAsName(): the 1-based result column whose AS name is
/// the identifier `e`, or 0.
fn resolveAsName(e_list: *ExprList, e: *Expr) usize {
    if (e.op == TK.ID) {
        const col = e.token();
        for (e_list.slice(), 0..) |*item, i| {
            if (item.fg.e_ename == .name and item.e_name != null and ctype.eqlNoCase(item.e_name.?, col)) return i + 1;
        }
    }
    return 0;
}

/// Port of resolveOrderByTermToExprList(): the 1-based result column
/// equal to ORDER BY term `e` of a compound SELECT, or 0.
fn resolveOrderByTermToExprList(p: *Parse, sel: *Select, e: *Expr) usize {
    const e_list = sel.e_list.?;
    var nc: NameContext = .{
        .parse = p,
        .src_list = sel.src,
        .u_nc = .{ .e_list = e_list },
        .nc_flags = NC.AllowAgg | NC.UEList | NC.NoSelect,
    };
    const db = p.db;
    const saved = db.suppress_err;
    db.suppress_err = 1;
    const rc = resolveExprNames(&nc, e);
    db.suppress_err = saved;
    if (rc != 0) return 0;
    for (e_list.slice(), 0..) |*item, i| {
        if (expr_mod.compare(null, item.expr, e, -1) < 2) return i + 1;
    }
    return 0;
}

/// Port of resolveOutOfRangeError().
fn resolveOutOfRangeError(p: *Parse, typ: []const u8, i: usize, mx: usize, err_expr: ?*Expr) void {
    util.errorMsg(p, "{f} {s} BY term out of range - should be between 1 and {d}", .{ util.ordinal(i), typ, mx });
    expr_mod.recordErrorOffsetOfExpr(p, err_expr);
}

/// Port of resolveCompoundOrderBy(): turn every ORDER BY term of a
/// compound SELECT into a result column number. Returns the number of
/// errors.
fn resolveCompoundOrderBy(p: *Parse, sel_arg: *Select) Oom!u32 {
    var sel: ?*Select = sel_arg;
    const order_by = sel_arg.order_by orelse return 0;
    const db = p.db;
    if (order_by.len() > @as(usize, @intCast(db.limit(.column)))) {
        util.errorMsg(p, "too many terms in ORDER BY clause", .{});
        return 1;
    }
    for (order_by.slice()) |*item| item.fg.done = false;
    var s = sel_arg;
    s.next = null;
    while (s.prior) |prior| {
        prior.next = s;
        s = prior;
    }
    sel = s;
    var more_to_do = true;
    while (sel != null and more_to_do) {
        const cur = sel.?;
        more_to_do = false;
        const e_list = cur.e_list.?;
        for (order_by.slice(), 0..) |*item, i| {
            var i_col: usize = 0;
            if (item.fg.done) continue;
            const e = expr_mod.skipCollateAndLikely(item.expr) orelse continue;
            if (expr_mod.isInteger(e, null)) |v| {
                if (v <= 0 or v > e_list.len()) {
                    resolveOutOfRangeError(p, "ORDER", i + 1, e_list.len(), e);
                    return 1;
                }
                i_col = @intCast(v);
            } else {
                i_col = resolveAsName(e_list, e);
                if (i_col == 0) {
                    // Resolve a copy and compare it with the result set.
                    const dup = (try expr_mod.exprDup(p.arena, e)).?;
                    i_col = resolveOrderByTermToExprList(p, cur, dup);
                    if (p.inRenameObject() and i_col > 0) _ = resolveOrderByTermToExprList(p, cur, e);
                }
            }
            if (i_col > 0) {
                // Replace the term by the column number, keeping COLLATE.
                if (!p.inRenameObject()) {
                    const new = try expr_mod.exprInt32(p.arena, @intCast(i_col));
                    if (item.expr == e) {
                        item.expr = new;
                    } else {
                        var parent = item.expr.?;
                        std.debug.assert(parent.op == TK.COLLATE);
                        while (parent.left.?.op == TK.COLLATE) parent = parent.left.?;
                        parent.left = new;
                    }
                    item.u = .{ .x = .{ .order_by_col = @intCast(i_col) } };
                }
                item.fg.done = true;
            } else {
                more_to_do = true;
            }
        }
        sel = cur.next;
    }
    for (order_by.slice(), 0..) |*item, i| {
        if (!item.fg.done) {
            util.errorMsg(p, "{f} ORDER BY term does not match any column in the result set", .{util.ordinal(i + 1)});
            return 1;
        }
    }
    return 0;
}

/// Port of sqlite3ResolveOrderGroupBy(): replace each ORDER BY or GROUP
/// BY term that refers to a result column (order_by_col) by a copy of
/// that column's expression. Returns nonzero on error.
pub fn resolveOrderGroupBy(p: *Parse, sel: *Select, order_by_arg: ?*ExprList, typ: []const u8) u32 {
    const order_by = order_by_arg orelse return 0;
    const db = p.db;
    if (db.malloc_failed or p.inRenameObject()) return 0;
    if (order_by.len() > @as(usize, @intCast(db.limit(.column)))) {
        util.errorMsg(p, "too many terms in {s} BY clause", .{typ});
        return 1;
    }
    const e_list = sel.e_list.?;
    for (order_by.slice(), 0..) |*item, i| {
        const col = item.u.x.order_by_col;
        if (col != 0) {
            if (col > e_list.len()) {
                resolveOutOfRangeError(p, typ, i + 1, e_list.len(), null);
                return 1;
            }
            resolveAlias(p, e_list, col - 1, item.expr.?, 0) catch {
                build.oomFault(p);
                return 1;
            };
        }
    }
    return 0;
}

fn resolveRemoveWindowsCb(_: *Walker, e: *Expr) u8 {
    if (e.has(EP.WinFunc)) window.windowUnlinkFromSelect(e.y.win.?);
    return WRC.Continue;
}

/// Port of windowRemoveExprFromSelect(): unlink the windows of `e` from
/// sel.win.
fn windowRemoveExprFromSelect(sel: *Select, e: *Expr) void {
    if (sel.win != null) {
        var w: Walker = .{ .expr_callback = resolveRemoveWindowsCb, .u = .{ .select = sel } };
        _ = walker.walkExpr(&w, e);
    }
}

/// Port of resolveOrderGroupBy(): resolve each ORDER BY or GROUP BY term:
/// a result column number or AS name refers to that column, anything
/// else is an expression (which may equal a result column). Returns the
/// number of errors.
fn resolveOrderGroupByTerms(nc: *NameContext, sel: *Select, order_by: *ExprList, typ: []const u8) u32 {
    const n_result = sel.e_list.?.len();
    const p = nc.parse;
    for (order_by.slice(), 0..) |*item, i| {
        const e = item.expr.?;
        const e2 = expr_mod.skipCollateAndLikely(e) orelse continue;
        if (typ[0] != 'G') {
            const i_col = resolveAsName(sel.e_list.?, e2);
            if (i_col > 0) {
                item.u = .{ .x = .{ .order_by_col = @intCast(i_col) } };
                continue;
            }
        }
        if (expr_mod.isInteger(e2, null)) |v| {
            if (v < 1 or v > 0xffff) {
                resolveOutOfRangeError(p, typ, i + 1, n_result, e2);
                return 1;
            }
            item.u = .{ .x = .{ .order_by_col = @intCast(v) } };
            continue;
        }
        // An ordinary expression.
        item.u = .{ .x = .{} };
        if (resolveExprNames(nc, e) != 0) return 1;
        for (sel.e_list.?.slice(), 0..) |*r, j| {
            if (expr_mod.compare(null, e, r.expr, -1) == 0) {
                windowRemoveExprFromSelect(sel, e);
                item.u = .{ .x = .{ .order_by_col = @intCast(j + 1) } };
            }
        }
    }
    return resolveOrderGroupBy(p, sel, order_by, typ);
}

/// Port of resolveSelectStep(): resolve the names of a SELECT (and its
/// compound terms and FROM subqueries).
fn resolveSelectStep(w: *Walker, s: *Select) u8 {
    return resolveSelectStepImpl(w, s) catch {
        build.oomFault(w.parse.?);
        return WRC.Abort;
    };
}

fn resolveSelectStepImpl(w: *Walker, s_arg: *Select) Oom!u8 {
    if (s_arg.sel_flags & SF.Resolved != 0) return WRC.Prune;
    const outer_nc = w.u.nc;
    const p = w.parse.?;
    const db = p.db;

    // A subquery in an expression is not expanded yet: let selectPrep()
    // expand and resolve it.
    if (s_arg.sel_flags & SF.Expanded == 0) {
        select_mod.selectPrep(p, s_arg, outer_nc);
        return if (p.n_err != 0) WRC.Abort else WRC.Prune;
    }

    const is_compound = s_arg.prior != null;
    var n_compound: usize = 0;
    const leftmost = s_arg;
    var s_opt: ?*Select = s_arg;
    while (s_opt) |s| {
        std.debug.assert(s.sel_flags & SF.Expanded != 0);
        s.sel_flags |= SF.Resolved;

        // LIMIT and OFFSET may not refer to any names.
        var nc: NameContext = .{ .parse = p, .win_select = s };
        if (resolveExprNames(&nc, s.limit) != 0) return WRC.Abort;

        // A Select made by convertCompoundSelectToSubquery() resolves its
        // ORDER BY as part of the subquery.
        if (s.sel_flags & SF.Converted != 0) {
            const sub = s.src.?.at(0).u4.subq.?.select;
            sub.order_by = s.order_by;
            s.order_by = null;
        }

        // Subqueries of the FROM clause.
        if (outer_nc) |o| o.n_nested_select += 1;
        for (s.src.?.slice()) |*item| {
            if (item.fg.is_subquery and item.u4.subq.?.select.sel_flags & SF.Resolved == 0) {
                const n_ref = if (outer_nc) |o| o.n_ref else 0;
                resolveSelectNames(p, item.u4.subq.?.select, outer_nc);
                if (p.n_err != 0) return WRC.Abort;
                // A changed reference count of the outer context means the
                // subquery is correlated.
                if (outer_nc) |o| item.fg.is_correlated = o.n_ref > n_ref;
            }
        }
        if (outer_nc) |o| if (o.n_nested_select > 0) {
            o.n_nested_select -= 1;
        };

        nc.nc_flags = NC.AllowAgg | NC.AllowWin;
        nc.src_list = s.src;
        nc.next = outer_nc;

        // The result set.
        if (resolveExprListNames(&nc, s.e_list) != 0) return WRC.Abort;
        nc.nc_flags &= ~NC.AllowWin;

        // Without aggregates in the result set or a GROUP BY, aggregates
        // are not allowed anywhere else either.
        const group_by = s.group_by;
        if (group_by != null or nc.nc_flags & NC.HasAgg != 0) {
            s.sel_flags |= SF.Aggregate | (nc.nc_flags & (NC.MinMaxAgg | NC.OrderAgg));
        } else {
            nc.nc_flags &= ~NC.AllowAgg;
        }

        // Other clauses may use the result columns' AS names.
        nc.u_nc = .{ .e_list = s.e_list };
        nc.nc_flags |= NC.UEList;
        if (s.having) |h| {
            if (s.sel_flags & SF.Aggregate == 0) {
                util.errorMsg(p, "HAVING clause on a non-aggregate query", .{});
                return WRC.Abort;
            }
            if (resolveExprNames(&nc, h) != 0) return WRC.Abort;
        }
        nc.nc_flags |= NC.Where;
        if (resolveExprNames(&nc, s.where) != 0) return WRC.Abort;
        nc.nc_flags &= ~NC.Where;

        // Arguments of table-valued functions.
        for (s.src.?.slice()) |*item| {
            if (item.fg.is_tab_func and resolveExprListNames(&nc, item.u1.func_arg) != 0) return WRC.Abort;
        }

        if (p.inRenameObject()) {
            var win = s.win_defn;
            while (win) |wd| : (win = wd.next_win) {
                if (resolveExprListNames(&nc, wd.order_by) != 0 or resolveExprListNames(&nc, wd.partition) != 0) return WRC.Abort;
            }
        }

        nc.nc_flags |= NC.AllowAgg | NC.AllowWin;

        // Move the ORDER BY of a converted compound back up.
        if (s.sel_flags & SF.Converted != 0) {
            const sub = s.src.?.at(0).u4.subq.?.select;
            s.order_by = sub.order_by;
            sub.order_by = null;
        }

        // The ORDER BY of a simple SELECT; that of a compound comes after
        // all its terms are resolved.
        if (s.order_by) |ob| {
            if (@intFromBool(is_compound) <= n_compound and resolveOrderGroupByTerms(&nc, s, ob, "ORDER") != 0) return WRC.Abort;
        }
        if (db.malloc_failed) return WRC.Abort;
        nc.nc_flags &= ~NC.AllowWin;

        // GROUP BY, which may not hold aggregates.
        if (group_by) |gb| {
            if (resolveOrderGroupByTerms(&nc, s, gb, "GROUP") != 0 or db.malloc_failed) return WRC.Abort;
            for (gb.slice()) |item| {
                if (item.expr.?.has(EP.Agg)) {
                    util.errorMsg(p, "aggregate functions are not allowed in the GROUP BY clause", .{});
                    return WRC.Abort;
                }
            }
        }

        // The terms of a compound have equal numbers of columns.
        if (s.next) |next| if (s.e_list.?.len() != next.e_list.?.len()) {
            select_mod.selectWrongNumTermsError(p, next);
            return WRC.Abort;
        };

        // ON clauses moved into the WHERE clause may not refer to tables
        // on their right.
        if (s.sel_flags & SF.OnToWhere != 0) {
            select_mod.selectCheckOnClauses(p, s);
            if (p.n_err != 0) return WRC.Abort;
        }

        s_opt = s.prior;
        n_compound += 1;
    }

    if (is_compound and try resolveCompoundOrderBy(p, leftmost) != 0) return WRC.Abort;
    return WRC.Prune;
}

/// Port of sqlite3ResolveExprNames(): resolve the names of `e` (column
/// references, result-set aliases and functions) in `nc`. Aggregates set
/// EP_Agg. Returns nonzero if there were errors.
pub fn resolveExprNames(nc: *NameContext, e_arg: ?*Expr) u32 {
    const e = e_arg orelse return 0;
    const saved_has_agg = nc.nc_flags & (NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg);
    nc.nc_flags &= ~(NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg);
    const p = nc.parse;
    var w: Walker = .{
        .parse = p,
        .expr_callback = resolveExprStep,
        .select_callback = if (nc.nc_flags & NC.NoSelect != 0) null else resolveSelectStep,
        .u = .{ .nc = nc },
    };
    p.n_height += e.n_height;
    if (!expr_mod.checkHeight(p, p.n_height)) return 1;
    _ = walker.walkExprNN(&w, e);
    p.n_height -= e.n_height;
    e.set(nc.nc_flags & (NC.HasAgg | NC.HasWin));
    nc.nc_flags |= saved_has_agg;
    return @intFromBool(nc.n_nc_err > 0 or p.n_err > 0);
}

/// Port of sqlite3ResolveExprListNames().
pub fn resolveExprListNames(nc: *NameContext, list_arg: ?*ExprList) u32 {
    const list = list_arg orelse return 0;
    const p = nc.parse;
    var w: Walker = .{
        .parse = p,
        .expr_callback = resolveExprStep,
        .select_callback = resolveSelectStep,
        .u = .{ .nc = nc },
    };
    var saved_has_agg = nc.nc_flags & (NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg);
    nc.nc_flags &= ~(NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg);
    for (list.slice()) |item| {
        const e = item.expr orelse continue;
        p.n_height += e.n_height;
        if (!expr_mod.checkHeight(p, p.n_height)) return 1;
        _ = walker.walkExprNN(&w, e);
        p.n_height -= e.n_height;
        if (nc.nc_flags & (NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg) != 0) {
            e.set(nc.nc_flags & (NC.HasAgg | NC.HasWin));
            saved_has_agg |= nc.nc_flags & (NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg);
            nc.nc_flags &= ~(NC.HasAgg | NC.MinMaxAgg | NC.HasWin | NC.OrderAgg);
        }
        if (p.n_err > 0) return 1;
    }
    nc.nc_flags |= saved_has_agg;
    return 0;
}

/// Port of sqlite3ResolveSelectNames(): resolve every name of a SELECT
/// already expanded by selectExpand().
pub fn resolveSelectNames(p: *Parse, s: *Select, outer_nc: ?*NameContext) void {
    var w: Walker = .{
        .parse = p,
        .expr_callback = resolveExprStep,
        .select_callback = resolveSelectStep,
        .u = .{ .nc = outer_nc },
    };
    _ = walker.walkSelect(&w, s);
}

/// Port of sqlite3ResolveSelfReference(): resolve an expression that can
/// only refer to columns of `t` (CHECK constraints, partial index WHERE
/// clauses, index expressions, generated columns), or to none if `t` is
/// null. Column references get i_table -1. Returns nonzero on error.
pub fn resolveSelfReference(p: *Parse, t: ?*Table, type_arg: u32, e: ?*Expr, list: ?*ExprList) u32 {
    var typ = type_arg;
    var src: SrcList = .{};
    var item: [1]SrcItem = .{.{}};
    if (t) |tab| {
        item[0].name = tab.name;
        item[0].s_tab = tab;
        item[0].i_cursor = -1;
        src.items = .initBuffer(&item);
        src.items.items.len = 1;
        // Functions of non-TEMP schema objects get EP_FromDDL.
        if (tab.schema != p.db.dbs.items[1].schema) typ |= NC.FromDDL;
    }
    var nc: NameContext = .{ .parse = p, .src_list = &src, .nc_flags = typ | NC.IsDDL };
    const rc = resolveExprNames(&nc, e);
    if (rc != 0) return rc;
    if (list != null) return resolveExprListNames(&nc, list);
    return 0;
}
