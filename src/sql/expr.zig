//! Expression trees (port of expr.c): construction during parsing, deep
//! copies, and constant analysis. Code generation for expressions lives
//! in expr_code.zig.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const walker = @import("walker.zig");
const ctype = @import("../util/ctype.zig");
const select_mod = @import("select.zig");
const window = @import("window.zig");
const callback = @import("callback.zig");

const Allocator = std.mem.Allocator;
const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const ExprListItem = int.ExprListItem;
const IdList = int.IdList;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Select = int.Select;
const With = int.With;
const Token = int.Token;
const Oom = int.Oom;
const EP = int.EP;
const SF = int.SF;
const TK = int.TK;
const Walker = walker.Walker;
const WRC = walker.WRC;

// ============================================================ allocation

/// Port of sqlite3ExprAlloc(): a node with a copy of `token`, dequoted if
/// asked and quoted.
pub fn exprAlloc(a: Allocator, op: u8, token: ?Token, dequote: bool) Oom!*Expr {
    const e = try a.create(Expr);
    e.* = .{ .op = op, .i_agg = -1, .n_height = 1 };
    if (token) |t| {
        e.u = .{ .token = try a.dupeSentinel(u8, t.slice(), 0) };
        if (dequote and t.n > 0 and ctype.isQuote(e.u.token.?[0])) util.dequoteExpr(e);
    }
    return e;
}

/// Port of sqlite3Expr(): a node whose token is the already dequoted `z`.
pub fn expr(a: Allocator, op: u8, z: ?[]const u8) Oom!*Expr {
    return exprAlloc(a, op, if (z) |s| Token.init(s) else null, false);
}

/// Port of sqlite3ExprInt32(): an integer literal.
pub fn exprInt32(a: Allocator, v: i32) Oom!*Expr {
    const e = try a.create(Expr);
    e.* = .{
        .op = TK.INTEGER,
        .i_agg = -1,
        .flags = EP.IntValue | EP.Leaf | (if (v != 0) EP.IsTrue else EP.IsFalse),
        .u = .{ .value = v },
        .n_height = 1,
    };
    return e;
}

/// Port of sqlite3ExprAttachSubtrees().
pub fn attachSubtrees(root: *Expr, left: ?*Expr, right: ?*Expr) void {
    std.debug.assert(root.useXList() and root.x.list == null);
    if (right) |r| {
        root.right = r;
        root.flags |= EP.Propagate & r.flags;
        root.n_height = r.n_height + 1;
    } else {
        root.n_height = 1;
    }
    if (left) |l| {
        root.left = l;
        root.flags |= EP.Propagate & l.flags;
        if (l.n_height >= root.n_height) root.n_height = l.n_height + 1;
    }
}

/// Port of sqlite3PExpr(): a node joining up to two subtrees.
pub fn pExpr(p: *Parse, op: u8, left: ?*Expr, right: ?*Expr) Oom!*Expr {
    const e = try p.arena.create(Expr);
    e.* = .{ .op = op, .i_agg = -1 };
    attachSubtrees(e, left, right);
    _ = checkHeight(p, e.n_height);
    return e;
}

/// Port of sqlite3PExprAddSelect().
pub fn pExprAddSelect(p: *Parse, e: *Expr, sel: ?*Select) void {
    e.x = .{ .select = sel };
    e.set(EP.xIsSelect | EP.Subquery);
    setHeightAndFlags(p, e);
}

/// Port of sqlite3ExprCheckHeight(): false (with an error) if `n` is past
/// SQLITE_LIMIT_EXPR_DEPTH.
pub fn checkHeight(p: *Parse, n: i32) bool {
    const mx = p.db.limit(.expr_depth);
    if (n > mx) {
        util.errorMsg(p, "Expression tree is too large (maximum depth {d})", .{mx});
        return false;
    }
    return true;
}

fn heightOfExpr(e: ?*const Expr, h: *i32) void {
    if (e) |x| h.* = @max(h.*, x.n_height);
}

fn heightOfExprList(l: ?*ExprList, h: *i32) void {
    if (l) |list| for (list.slice()) |item| heightOfExpr(item.expr, h);
}

fn heightOfSelect(s_arg: ?*Select, h: *i32) void {
    var s = s_arg;
    while (s) |x| : (s = x.prior) {
        heightOfExpr(x.where, h);
        heightOfExpr(x.having, h);
        heightOfExpr(x.limit, h);
        heightOfExprList(x.e_list, h);
        heightOfExprList(x.group_by, h);
        heightOfExprList(x.order_by, h);
    }
}

/// Port of exprSetHeight(): one more than the tallest child, and the
/// propagating flags of the argument list.
fn exprSetHeight(e: *Expr) void {
    var h: i32 = if (e.left) |l| l.n_height else 0;
    if (e.right) |r| h = @max(h, r.n_height);
    if (e.useXSelect()) {
        heightOfSelect(e.x.select, &h);
    } else if (e.x.list) |l| {
        heightOfExprList(l, &h);
        e.flags |= EP.Propagate & listFlags(l);
    }
    e.n_height = h + 1;
}

/// Port of sqlite3ExprSetHeightAndFlags().
pub fn setHeightAndFlags(p: *Parse, e: *Expr) void {
    if (p.n_err != 0) return;
    exprSetHeight(e);
    _ = checkHeight(p, e.n_height);
}

/// Port of sqlite3SelectExprHeight().
pub fn selectExprHeight(s: *Select) i32 {
    var h: i32 = 0;
    heightOfSelect(s, &h);
    return h;
}

/// Port of sqlite3ExprListFlags(): the OR of the flags of every entry.
pub fn listFlags(l: *ExprList) u32 {
    var m: u32 = 0;
    for (l.slice()) |item| m |= item.expr.?.flags;
    return m;
}

/// Port of sqlite3ExprSetErrorOffset().
pub fn setErrorOffset(e: ?*Expr, ofst: i32) void {
    const x = e orelse return;
    if (x.useWJoin()) return;
    x.w = .{ .ofst = ofst };
}

/// Port of sqlite3ExprAddCollateToken(): wrap `e` in a COLLATE node.
pub fn addCollateToken(p: *Parse, e: *Expr, coll_name: Token, dequote: bool) Oom!*Expr {
    if (coll_name.n == 0 or p.n_err != 0) return e;
    const n = try exprAlloc(p.arena, TK.COLLATE, coll_name, dequote);
    n.left = e;
    n.flags |= EP.Collate | EP.Skip;
    n.n_height = e.n_height + 1;
    _ = checkHeight(p, n.n_height);
    return n;
}

/// Port of sqlite3ExprAddCollateString().
pub fn addCollateString(p: *Parse, e: *Expr, z: []const u8) Oom!*Expr {
    return addCollateToken(p, e, Token.init(z), false);
}

/// Port of sqlite3ExprSkipCollate().
pub fn skipCollate(e_arg: ?*Expr) ?*Expr {
    var e = e_arg;
    while (e) |x| {
        if (!x.has(EP.Skip)) break;
        e = x.left;
    }
    return e;
}

/// Port of sqlite3ExprSkipCollateAndLikely().
pub fn skipCollateAndLikely(e_arg: ?*Expr) ?*Expr {
    var e = e_arg;
    while (e) |x| {
        if (!x.has(EP.Skip | EP.Unlikely)) break;
        if (x.has(EP.Unlikely)) {
            e = x.x.list.?.at(0).expr;
        } else if (x.op == TK.COLLATE) {
            e = x.left;
        } else {
            break;
        }
    }
    return e;
}

/// Port of sqlite3ExprAnd(): AND two expressions; null operands are
/// skipped, and a known-false operand outside any ON clause makes the
/// result a constant 0.
pub fn exprAnd(p: *Parse, left: ?*Expr, right: ?*Expr) Oom!?*Expr {
    const l = left orelse return right;
    const r = right orelse return l;
    const f = l.flags | r.flags;
    if (f & (EP.OuterON | EP.InnerON | EP.IsFalse | EP.HasFunc) == EP.IsFalse and !p.inRenameObject()) {
        return try exprInt32(p.arena, 0);
    }
    return try pExpr(p, TK.AND, l, r);
}

/// Port of sqlite3ExprFunction(): a function call node.
pub fn exprFunction(p: *Parse, list: ?*ExprList, name: Token, e_distinct: i32) Oom!*Expr {
    const e = try exprAlloc(p.arena, TK.FUNCTION, name, true);
    e.w = .{ .ofst = tokenOffset(p, name) };
    if (list) |l| {
        if (l.len() > p.db.limit(.function_arg) and p.nested == 0) {
            util.errorMsgAt(p, name.z, "too many arguments on function {s}", .{name.slice()});
        }
    }
    e.x = .{ .list = list };
    e.set(EP.HasFunc);
    setHeightAndFlags(p, e);
    if (e_distinct == SF.Distinct) e.set(EP.Distinct);
    return e;
}

/// Offset of a token from the start of the statement (Expr.w.iOfst).
pub fn tokenOffset(p: *const Parse, t: Token) i32 {
    const z = t.z orelse return 0;
    return @intCast(@as(isize, @bitCast(@intFromPtr(z) -% @intFromPtr(p.tail.ptr))));
}

/// Port of sqlite3ExprOrderByAggregateError().
pub fn orderByAggregateError(p: *Parse, e: *Expr) void {
    util.errorMsg(p, "ORDER BY may not be used with non-aggregate {s}()", .{e.token()});
}

/// Port of sqlite3ExprAddFunctionOrderBy(): attach "f(args ORDER BY ...)"
/// as a TK_ORDER node on the left of the function.
pub fn addFunctionOrderBy(p: *Parse, e: *Expr, order_by: *ExprList) Oom!void {
    std.debug.assert(e.op == TK.FUNCTION and e.left == null and e.useXList());
    // ORDER BY on a function without arguments is ignored.
    if (e.x.list == null or e.x.list.?.len() == 0) return;
    if (e.isWindowFunc()) {
        orderByAggregateError(p, e);
        return;
    }
    if (order_by.len() > p.db.limit(.column)) {
        util.errorMsg(p, "too many terms in ORDER BY clause", .{});
        return;
    }
    const ob = try exprAlloc(p.arena, TK.ORDER, null, false);
    ob.x = .{ .list = order_by };
    e.left = ob;
    ob.set(EP.FullSize);
}

/// Port of sqlite3ExprAssignVarNumber(): number a "?", "?NNN", ":aaa",
/// "@aaa" or "$aaa" parameter. Named parameters reuse the number of an
/// earlier occurrence of the same name.
pub fn assignVarNumber(p: *Parse, e: *Expr, n: u32) Oom!void {
    const db = p.db;
    const z = e.token();
    std.debug.assert(z.len == n and n > 0);
    const max = db.limit(.variable_number);
    var x: i32 = undefined;
    if (z.len == 1) {
        std.debug.assert(z[0] == '?');
        p.n_var += 1;
        x = p.n_var;
    } else {
        var do_add = false;
        if (z[0] == '?') {
            var i: i64 = 0;
            const ok = if (n == 2) blk: {
                i = z[1] - '0';
                break :blk true;
            } else util.atoi64(z[1..], &i) == .ok;
            if (!ok or i < 1 or i > max) {
                util.errorMsg(p, "variable number must be between ?1 and ?{d}", .{max});
                recordErrorOffsetOfExpr(p, e);
                return;
            }
            x = @intCast(i);
            if (x > p.n_var) {
                p.n_var = @intCast(x);
                do_add = true;
            } else if (vlistNumToName(p, x) == null) {
                do_add = true;
            }
        } else {
            x = vlistNameToNum(p, z);
            if (x == 0) {
                p.n_var += 1;
                x = p.n_var;
                do_add = true;
            }
        }
        if (do_add) try p.vlist.append(p.arena, .{ .name = z, .num = @intCast(x) });
    }
    e.i_column = @intCast(x);
    if (x > max) {
        util.errorMsg(p, "too many SQL variables", .{});
        recordErrorOffsetOfExpr(p, e);
    }
}

/// Port of sqlite3VListNumToName().
pub fn vlistNumToName(p: *const Parse, num: i32) ?[]const u8 {
    for (p.vlist.items) |v| if (v.num == num) return v.name;
    return null;
}

/// Port of sqlite3VListNameToNum(): 0 if `name` is not listed.
pub fn vlistNameToNum(p: *const Parse, name: []const u8) i32 {
    for (p.vlist.items) |v| if (std.mem.eql(u8, v.name, name)) return v.num;
    return 0;
}

/// Port of sqlite3RecordErrorOffsetOfExpr().
pub fn recordErrorOffsetOfExpr(p: *Parse, e_arg: ?*const Expr) void {
    var e = e_arg;
    while (e) |x| {
        if (x.useWJoin() or x.w.ofst <= 0) {
            e = x.left;
            continue;
        }
        p.db.err_byte_offset = x.w.ofst;
        return;
    }
}

/// Port of sqlite3ExprUnmapAndDelete(). Parse trees are freed with the
/// statement; only the rename map needs updating.
pub fn unmapAndDelete(p: *Parse, e: ?*Expr) void {
    if (e != null and p.inRenameObject()) @import("alter.zig").renameExprUnmap(p, e);
}

// =========================================================== expr lists

/// Port of sqlite3ExprListAppend().
pub fn listAppend(p: *Parse, list: ?*ExprList, e: ?*Expr) Oom!*ExprList {
    return listAppendIn(p.arena, list, e);
}

/// listAppend() for a list owned by `a` (as a table's DEFAULT values).
pub fn listAppendIn(a: std.mem.Allocator, list: ?*ExprList, e: ?*Expr) Oom!*ExprList {
    const l = list orelse blk: {
        const n = try a.create(ExprList);
        n.* = .{};
        try n.items.ensureTotalCapacity(a, 4);
        break :blk n;
    };
    try l.items.append(a, .{ .expr = e });
    return l;
}

/// Port of sqlite3ExprListAppendVector(): "(a,b,c) = (x,y,z)" in an
/// UPDATE: one entry per column, or TK_SELECT_COLUMN entries for a
/// subquery on the right.
pub fn listAppendVector(p: *Parse, list_arg: ?*ExprList, columns: ?*IdList, e_arg: ?*Expr) Oom!?*ExprList {
    var list = list_arg;
    const cols = columns orelse return list;
    const e = e_arg orelse return list;
    const first: usize = if (list) |l| l.len() else 0;
    if (e.op != TK.SELECT) {
        const n = vectorSize(e);
        if (cols.len() != n) {
            util.errorMsg(p, "{d} columns assigned {d} values", .{ cols.len(), n });
            return list;
        }
    }
    for (cols.names.items, 0..) |name, i| {
        const sub = try forVectorField(p, e, @intCast(i), @intCast(cols.len()));
        list = try listAppend(p, list, sub);
        list.?.last().e_name = name;
    }
    if (e.op == TK.SELECT) {
        const pfirst = list.?.at(first).expr.?;
        std.debug.assert(pfirst.op == TK.SELECT_COLUMN);
        // Owner of the SELECT, and the LHS size for checking at codegen.
        pfirst.right = e;
        pfirst.i_table = @intCast(cols.len());
    }
    return list;
}

/// Port of sqlite3ExprListSetSortOrder(): the sort order and NULLS
/// placement of the last entry.
pub fn listSetSortOrder(list: ?*ExprList, sort_order_arg: i32, e_nulls: i32) void {
    const l = list orelse return;
    const item = l.last();
    std.debug.assert(!item.fg.nulls);
    const sort_order = if (sort_order_arg == int.SortOrder.undef) int.SortOrder.asc else sort_order_arg;
    item.fg.sort_flags = @intCast(sort_order);
    if (e_nulls != int.SortOrder.undef) {
        item.fg.nulls = true;
        if (sort_order != e_nulls) item.fg.sort_flags |= int.KeyInfoOrder.bignull;
    }
}

/// Port of sqlite3ExprListSetName(): name the last entry.
pub fn listSetName(p: *Parse, list: ?*ExprList, name: Token, dequote: bool) Oom!void {
    const l = list orelse return;
    const item = l.last();
    std.debug.assert(item.e_name == null and item.fg.e_ename == .name);
    var z = try p.arena.dupeSentinel(u8, name.slice(), 0);
    if (dequote) {
        // If not dequoted, `name` is not part of a statement the parser
        // handled, so it has no place in the rename map.
        z = util.dequote(z);
        if (p.inRenameObject()) @import("alter.zig").renameTokenMap(p, z, name);
    }
    item.e_name = z;
}

/// Port of sqlite3ExprListSetSpan(): the text of the last entry, unless
/// it already has a name.
pub fn listSetSpan(p: *Parse, list: ?*ExprList, start: ?[*]const u8, end: ?[*]const u8) Oom!void {
    const l = list orelse return;
    const item = l.last();
    if (item.e_name == null) {
        item.e_name = try spanDup(p.arena, start.?, end.?);
        item.fg.e_ename = .span;
    }
}

/// Port of sqlite3DbSpanDup(): copy [start, end) without surrounding
/// whitespace.
pub fn spanDup(a: Allocator, start: [*]const u8, end: [*]const u8) Oom![:0]u8 {
    var s: []const u8 = start[0 .. @intFromPtr(end) - @intFromPtr(start)];
    while (s.len > 0 and ctype.isSpace(s[0])) s = s[1..];
    while (s.len > 0 and ctype.isSpace(s[s.len - 1])) s = s[0 .. s.len - 1];
    return a.dupeSentinel(u8, s, 0);
}

/// Port of sqlite3ExprListCheckLength().
pub fn listCheckLength(p: *Parse, list: ?*ExprList, what: []const u8) void {
    const mx = p.db.limit(.column);
    if (list) |l| if (l.len() > mx) util.errorMsg(p, "too many columns in {s}", .{what});
}

// ============================================================== vectors

/// Port of sqlite3ExprVectorSize(): columns of a vector or subquery; 1
/// for anything else.
pub fn vectorSize(e: *const Expr) usize {
    var op = e.op;
    if (op == TK.REGISTER) op = e.op2;
    if (op == TK.VECTOR) return e.x.list.?.len();
    if (op == TK.SELECT) return e.x.select.?.e_list.?.len();
    return 1;
}

pub fn isVector(e: *const Expr) bool {
    return vectorSize(e) > 1;
}

/// Port of sqlite3VectorFieldSubexpr(): the i-th element, owned by the
/// vector.
pub fn vectorFieldSubexpr(v: *Expr, i: usize) *Expr {
    if (isVector(v)) {
        if (v.op == TK.SELECT or v.op2 == TK.SELECT) return v.x.select.?.e_list.?.at(i).expr.?;
        return v.x.list.?.at(i).expr.?;
    }
    return v;
}

/// Port of sqlite3ExprForVectorField(): a new expression computing field
/// `field` of the vector.
pub fn forVectorField(p: *Parse, v_arg: *Expr, field: i32, n_field: i32) Oom!?*Expr {
    var v = v_arg;
    if (v.op == TK.SELECT) {
        const r = try pExpr(p, TK.SELECT_COLUMN, null, null);
        r.set(EP.FullSize);
        r.i_table = n_field;
        r.i_column = @intCast(field);
        r.left = v;
        return r;
    }
    if (v.op == TK.VECTOR) {
        const item = v.x.list.?.at(@intCast(field));
        v = item.expr.?;
        if (p.inRenameObject()) {
            item.expr = null;
            return v;
        }
    }
    return try exprDup(p.arena, v);
}

/// Port of sqlite3ExprListToValues(): turn "((1,2),(3,4))" on the right of
/// IN into "VALUES(1,2),(3,4)".
pub fn listToValues(p: *Parse, n_elem: usize, list: *ExprList) Oom!?*Select {
    std.debug.assert(n_elem > 1);
    var ret: ?*Select = null;
    for (list.slice()) |item| {
        const e = item.expr.?;
        const n: usize = if (e.op == TK.VECTOR) e.x.list.?.len() else 1;
        if (n != n_elem) {
            util.errorMsg(p, "IN(...) element has {d} term{s} - expected {d}", .{ n, if (n > 1) "s" else "", n_elem });
            break;
        }
        const sel = try select_mod.selectNew(p, e.x.list, null, null, null, null, null, SF.Values, null);
        e.x = .{ .list = null };
        if (ret) |r| {
            sel.op = TK.ALL;
            sel.prior = r;
        }
        ret = sel;
    }
    if (ret) |r| if (r.prior != null) {
        r.sel_flags |= SF.MultiValue;
    };
    return ret;
}

// ========================================================= true / false

/// Port of sqlite3ExprIdToTrueFalse(): turn an unquoted TRUE or FALSE
/// identifier into a TK_TRUEFALSE node.
pub fn idToTrueFalse(e: *Expr) bool {
    std.debug.assert(e.op == TK.ID or e.op == TK.STRING);
    if (!e.has(EP.Quoted | EP.IntValue)) {
        const v = util.isTrueOrFalse(e.token());
        if (v != 0) {
            e.op = TK.TRUEFALSE;
            e.set(v);
            return true;
        }
    }
    return false;
}

/// Port of sqlite3ExprTruthValue(): the value of a TK_TRUEFALSE node.
pub fn truthValue(e_arg: *Expr) bool {
    const e = skipCollateAndLikely(e_arg).?;
    std.debug.assert(e.op == TK.TRUEFALSE);
    return e.token().len == 4;
}

/// Port of sqlite3ExprSimplifiedAndOr(): drop AND/OR terms that are
/// always true or false.
pub fn simplifiedAndOr(e: *Expr) *Expr {
    if (e.op == TK.AND or e.op == TK.OR) {
        const r = simplifiedAndOr(e.right.?);
        const l = simplifiedAndOr(e.left.?);
        if (l.alwaysTrue() or r.alwaysFalse()) return if (e.op == TK.AND) r else l;
        if (r.alwaysTrue() or l.alwaysFalse()) return if (e.op == TK.AND) l else r;
    }
    return e;
}

// ============================================================ constants

/// Port of exprNodeIsConstantFunction().
fn nodeIsConstantFunction(w: *Walker, e: *Expr) u8 {
    std.debug.assert(e.op == TK.FUNCTION);
    var n: usize = 0;
    if (!e.has(EP.TokenOnly)) if (e.x.list) |l| {
        n = l.len();
        _ = walker.walkExprList(w, l);
        if (w.e_code == 0) return WRC.Abort;
    };
    const db = w.parse.?.db;
    const def = callback.findFunction(db, e.token(), @intCast(n), db.enc, false);
    if (def == null or def.?.isAggregate() or
        def.?.func_flags & (callback.FUNC.CONSTANT | callback.FUNC.SLOCHNG) == 0 or
        e.has(EP.WinFunc))
    {
        w.e_code = 0;
        return WRC.Abort;
    }
    return WRC.Prune;
}

/// Port of exprNodeIsConstant(). Walker.e_code selects the kind of
/// constant: 1 constant, 2 constant outside outer-join ON clauses, 3
/// constant for one table (u.i_cur), 4/5 DEFAULT values of new/existing
/// schemas, 6 constant without IS.
fn nodeIsConstant(w: *Walker, e: *Expr) u8 {
    std.debug.assert(w.e_code > 0);
    if (w.e_code == 2 and e.has(EP.OuterON)) {
        w.e_code = 0;
        return WRC.Abort;
    }
    switch (e.op) {
        TK.FUNCTION => {
            if (e.has(EP.WinFunc)) {
                w.e_code = 0;
                return WRC.Abort;
            } else if (w.e_code >= 4 and w.e_code <= 5) {
                if (w.e_code == 5) e.set(EP.FromDDL);
                return WRC.Continue;
            } else if (e.has(EP.ConstFunc)) {
                return WRC.Continue;
            } else if (w.parse != null) {
                return nodeIsConstantFunction(w, e);
            }
            w.e_code = 0;
            return WRC.Abort;
        },
        TK.ID, TK.COLUMN, TK.AGG_FUNCTION, TK.AGG_COLUMN => {
            if (e.op == TK.ID and idToTrueFalse(e)) return WRC.Prune;
            if (e.has(EP.FixedCol) and w.e_code != 2) return WRC.Continue;
            if (w.e_code == 3 and e.i_table == w.u.i_cur) return WRC.Continue;
            w.e_code = 0;
            return WRC.Abort;
        },
        TK.IF_NULL_ROW, TK.REGISTER, TK.DOT, TK.RAISE => {
            w.e_code = 0;
            return WRC.Abort;
        },
        TK.IS, TK.ISNOT => {
            if (w.e_code == 6) {
                w.e_code = 0;
                return WRC.Abort;
            }
            return WRC.Continue;
        },
        TK.VARIABLE => {
            if (w.e_code == 5) {
                // Bound parameters in an existing schema are read as NULL.
                e.op = TK.NULL;
            } else if (w.e_code == 4) {
                w.e_code = 0;
                return WRC.Abort;
            }
            return WRC.Continue;
        },
        else => return WRC.Continue,
    }
}

fn isConst(p: ?*Parse, e: ?*Expr, init_flag: u16) bool {
    var w: Walker = .{
        .parse = p,
        .e_code = init_flag,
        .expr_callback = nodeIsConstant,
        .select_callback = walker.selectWalkFail,
    };
    _ = walker.walkExpr(&w, e);
    return w.e_code != 0;
}

/// Port of sqlite3ExprIsConstant(): true if `e` involves no columns,
/// variables or non-constant functions. Without `p`, every function
/// counts as non-constant.
pub fn isConstant(p: ?*Parse, e: ?*Expr) bool {
    return isConst(p, e, 1);
}

/// Port of sqlite3ExprListIsConstant().
pub fn listIsConstant(p: ?*Parse, list: *ExprList, no_is: bool) bool {
    for (list.slice()) |item| if (!isConst(p, item.expr, if (no_is) 6 else 1)) return false;
    return true;
}

/// Port of sqlite3ExprIsConstantNotJoin().
pub fn isConstantNotJoin(p: ?*Parse, e: ?*Expr) bool {
    return isConst(p, e, 2);
}

/// Port of sqlite3ExprIsConstantOrFunction(): DEFAULT values (4 for a new
/// schema, 5 when reading an existing one).
pub fn isConstantOrFunction(e: ?*Expr, is_init: bool) bool {
    return isConst(null, e, if (is_init) 5 else 4);
}

// ================================================================= dups

/// Port of sqlite3ExprDup(): a deep copy of `e` allocated from `a`.
pub fn exprDup(a: Allocator, e_arg: ?*const Expr) Oom!?*Expr {
    const e = e_arg orelse return null;
    const n = try a.create(Expr);
    n.* = e.*;
    n.flags &= ~(EP.Reduced | EP.TokenOnly | EP.Static);
    if (e.useUToken()) {
        if (e.u.token) |t| n.u = .{ .token = try a.dupeSentinel(u8, t, 0) };
    }
    if ((e.flags | n.flags) & (EP.TokenOnly | EP.Leaf) == 0) {
        if (e.useXSelect()) {
            n.x = .{ .select = try selectDup(a, e.x.select) };
        } else {
            n.x = .{ .list = try listDup(a, e.x.list) };
        }
        if (e.has(EP.WinFunc)) n.y = .{ .win = try window.windowDup(a, n, e.y.win.?) };
        if (e.op == TK.SELECT_COLUMN) {
            n.left = e.left;
        } else {
            n.left = try exprDup(a, e.left);
        }
        n.right = try exprDup(a, e.right);
    }
    return n;
}

/// Port of sqlite3ExprListDup(). TK_SELECT_COLUMN entries sharing a
/// subquery keep sharing the copy.
pub fn listDup(a: Allocator, l_arg: ?*ExprList) Oom!?*ExprList {
    const l = l_arg orelse return null;
    const n = try a.create(ExprList);
    n.* = .{};
    try n.items.ensureTotalCapacity(a, l.len());
    var prior_old: ?*Expr = null;
    var prior_new: ?*Expr = null;
    for (l.slice()) |old| {
        var item = old;
        item.expr = try exprDup(a, old.expr);
        if (old.expr) |oe| if (oe.op == TK.SELECT_COLUMN) if (item.expr) |ne| {
            if (ne.right) |r| {
                prior_old = oe.right;
                prior_new = r;
                ne.left = r;
            } else {
                if (oe.left != prior_old) {
                    prior_old = oe.left;
                    prior_new = try exprDup(a, prior_old);
                    ne.right = prior_new;
                }
                ne.left = prior_new;
            }
        };
        if (old.e_name) |z| item.e_name = try a.dupeSentinel(u8, z, 0);
        n.items.appendAssumeCapacity(item);
    }
    return n;
}

/// Port of sqlite3SrcListDup(). Tables are shared, not copied.
pub fn srcListDup(a: Allocator, l_arg: ?*SrcList) Oom!?*SrcList {
    const l = l_arg orelse return null;
    const n = try a.create(SrcList);
    n.* = .{};
    try n.items.ensureTotalCapacity(a, l.len());
    for (l.slice()) |*old| {
        var it = old.*;
        if (old.fg.is_subquery) {
            const sq = try a.create(int.Subquery);
            sq.* = old.u4.subq.?.*;
            sq.select = (try selectDup(a, sq.select)).?;
            it.u4 = .{ .subq = sq };
        } else if (!old.fg.fixed_schema) {
            it.u4 = .{ .database = try dupZ(a, old.u4.database) };
        }
        it.name = try dupZ(a, old.name);
        it.alias = try dupZ(a, old.alias);
        if (it.fg.is_indexed_by) {
            it.u1 = .{ .indexed_by = try dupZ(a, old.u1.indexed_by) };
        } else if (it.fg.is_tab_func) {
            it.u1 = .{ .func_arg = try listDup(a, old.u1.func_arg) };
        }
        if (it.fg.is_cte) it.u2.cte_use.?.n_use += 1;
        if (old.fg.is_using) {
            it.u3 = .{ .using = try idListDup(a, old.u3.using) };
        } else {
            it.u3 = .{ .on = try exprDup(a, old.u3.on) };
        }
        n.items.appendAssumeCapacity(it);
    }
    return n;
}

pub fn dupZ(a: Allocator, s: ?[:0]const u8) Oom!?[:0]u8 {
    return if (s) |z| try a.dupeSentinel(u8, z, 0) else null;
}

/// Port of sqlite3IdListDup().
pub fn idListDup(a: Allocator, l_arg: ?*IdList) Oom!?*IdList {
    const l = l_arg orelse return null;
    const n = try a.create(IdList);
    n.* = .{};
    try n.names.ensureTotalCapacity(a, l.len());
    for (l.names.items) |name| n.names.appendAssumeCapacity(try a.dupeSentinel(u8, name, 0));
    return n;
}

/// Port of sqlite3WithDup().
pub fn withDup(a: Allocator, w_arg: ?*With) Oom!?*With {
    const w = w_arg orelse return null;
    const n = try a.create(With);
    n.* = .{};
    try n.ctes.ensureTotalCapacity(a, w.ctes.items.len);
    for (w.ctes.items) |cte| {
        n.ctes.appendAssumeCapacity(.{
            .select = try selectDup(a, cte.select),
            .cols = try listDup(a, cte.cols),
            .name = try dupZ(a, cte.name),
            .e_m10d = cte.e_m10d,
        });
    }
    return n;
}

/// Port of sqlite3SelectDup(): a copy of a SELECT and its compound parts.
pub fn selectDup(a: Allocator, s_arg: ?*Select) Oom!?*Select {
    var ret: ?*Select = null;
    var pp: *?*Select = &ret;
    var next: ?*Select = null;
    var it = s_arg;
    while (it) |s| : (it = s.prior) {
        const n = try a.create(Select);
        n.* = .{
            .e_list = try listDup(a, s.e_list),
            .src = try srcListDup(a, s.src),
            .where = try exprDup(a, s.where),
            .group_by = try listDup(a, s.group_by),
            .having = try exprDup(a, s.having),
            .order_by = try listDup(a, s.order_by),
            .op = s.op,
            .next = next,
            .limit = try exprDup(a, s.limit),
            .sel_flags = s.sel_flags,
            .n_select_row = s.n_select_row,
            .with = try withDup(a, s.with),
            .win_defn = try window.windowListDup(a, s.win_defn),
            .sel_id = s.sel_id,
        };
        if (s.win != null) window.gatherSelectWindows(n);
        pp.* = n;
        pp = &n.prior;
        next = n;
    }
    return ret;
}

// ========================================================== comparison

/// Port of exprCompareVariable(). Bound values are only known while
/// re-preparing, which this port does not do yet, so a variable equals
/// only the same variable.
fn compareVariable(v: *const Expr, e: *const Expr) u8 {
    if (e.op == TK.VARIABLE and v.i_column == e.i_column) return 0;
    return 2;
}

/// Port of sqlite3ExprCompare(): 0 if the trees are identical, 1 if they
/// differ only in a top-level COLLATE, 2 if they differ (or might). An
/// element of `b` with i_table -1 may match one of `a` with i_table
/// `i_tab`.
pub fn compare(p: ?*const Parse, a_arg: ?*const Expr, b_arg: ?*const Expr, i_tab: i32) u8 {
    const a = a_arg orelse return if (b_arg == null) 0 else 2;
    const b = b_arg orelse return 2;
    if (p != null and a.op == TK.VARIABLE) return compareVariable(a, b);
    const combined = a.flags | b.flags;
    if (combined & EP.IntValue != 0) {
        if (a.flags & b.flags & EP.IntValue != 0 and a.u.value == b.u.value) return 0;
        return 2;
    }
    if (a.op != b.op or a.op == TK.RAISE) {
        if (a.op == TK.COLLATE and compare(p, a.left, b, i_tab) < 2) return 1;
        if (b.op == TK.COLLATE and compare(p, a, b.left, i_tab) < 2) return 1;
        if (!(a.op == TK.AGG_COLUMN and b.op == TK.COLUMN and b.i_table < 0 and a.i_table == i_tab)) return 2;
    }
    if (a.u.token) |at| {
        if (a.op == TK.FUNCTION or a.op == TK.AGG_FUNCTION) {
            if (!ctype.eqlNoCase(at, b.u.token orelse "")) return 2;
            if (a.has(EP.WinFunc) != b.has(EP.WinFunc)) return 2;
            if (a.has(EP.WinFunc)) {
                if (window.windowCompare(p, a.y.win.?, b.y.win.?, true) != 0) return 2;
            }
        } else if (a.op == TK.NULL) {
            return 0;
        } else if (a.op == TK.COLLATE) {
            if (!ctype.eqlNoCase(at, b.u.token orelse "")) return 2;
        } else if (b.u.token) |bt| {
            if (a.op != TK.COLUMN and a.op != TK.AGG_COLUMN and !std.mem.eql(u8, at, bt)) return 2;
        }
    }
    if (a.flags & (EP.Distinct | EP.Commuted) != b.flags & (EP.Distinct | EP.Commuted)) return 2;
    if (combined & EP.TokenOnly == 0) {
        if (combined & EP.xIsSelect != 0) return 2;
        if (combined & EP.FixedCol == 0 and compare(p, a.left, b.left, i_tab) != 0) return 2;
        if (compare(p, a.right, b.right, i_tab) != 0) return 2;
        if (listCompare(a.x.list, b.x.list, i_tab) != 0) return 2;
        if (a.op != TK.STRING and a.op != TK.TRUEFALSE and combined & EP.Reduced == 0) {
            if (a.i_column != b.i_column) return 2;
            if (a.op2 != b.op2 and a.op == TK.TRUTH) return 2;
            if (a.op != TK.IN and a.i_table != b.i_table and a.i_table != i_tab) return 2;
        }
    }
    return 0;
}

/// Port of sqlite3ExprListCompare(): 0 if identical, 1 if different, 2 if
/// unknown.
pub fn listCompare(a_arg: ?*const ExprList, b_arg: ?*const ExprList, i_tab: i32) u8 {
    const a = a_arg orelse return if (b_arg == null) 0 else 1;
    const b = b_arg orelse return 1;
    if (a.len() != b.len()) return 1;
    for (a.items.items, b.items.items) |ia, ib| {
        if (ia.fg.sort_flags != ib.fg.sort_flags) return 1;
        const res = compare(null, ia.expr, ib.expr, i_tab);
        if (res != 0) return res;
    }
    return 0;
}

/// Port of sqlite3ExprCompareSkip(): compare ignoring top-level COLLATEs.
pub fn compareSkip(a: ?*Expr, b: ?*Expr, i_tab: i32) u8 {
    return compare(null, skipCollate(a), skipCollate(b), i_tab);
}

// ============================================== affinity and collation

const build = @import("build.zig");
const coll_mod = @import("coll.zig");
const Table = int.Table;
const CollSeq = int.CollSeq;
const Aff = int.Aff;
const Index = int.Index;
const NameContext = int.NameContext;
const AggInfo = int.AggInfo;

/// sqlite3IsNumericAffinity().
pub fn isNumericAffinity(aff: u8) bool {
    return aff >= Aff.numeric;
}

/// Port of sqlite3TableColumnAffinity(): the affinity of column `i_col`;
/// INTEGER for the rowid.
pub fn tableColumnAffinity(t: *const Table, i_col: i32) u8 {
    if (i_col < 0 or i_col >= t.cols.len) return Aff.integer;
    return t.cols[@intCast(i_col)].affinity;
}

/// Port of sqlite3ExprAffinity(): the affinity of a column (directly,
/// through an alias or a subquery), a CAST, or the expression's own.
pub fn affinity(e_arg: *const Expr) u8 {
    var e = e_arg;
    var op = e.op;
    while (true) {
        if (op == TK.COLUMN or (op == TK.AGG_COLUMN and e.y.tab != null)) {
            return tableColumnAffinity(e.y.tab.?, e.i_column);
        }
        if (op == TK.SELECT) return affinity(e.x.select.?.e_list.?.at(0).expr.?);
        if (op == TK.CAST) return build.affinityType(e.token(), null);
        if (op == TK.SELECT_COLUMN) {
            return affinity(e.left.?.x.select.?.e_list.?.at(@intCast(e.i_column)).expr.?);
        }
        if (op == TK.VECTOR or (op == TK.FUNCTION and e.aff_expr == Aff.@"defer")) {
            return affinity(e.x.list.?.at(0).expr.?);
        }
        if (e.has(EP.Skip | EP.IfNullRow)) {
            e = e.left.?;
            op = e.op;
            continue;
        }
        if (op != TK.REGISTER) break;
        op = e.op2;
        if (op == TK.REGISTER) break;
    }
    return e.aff_expr;
}

/// Port of sqlite3ExprDataType(): the possible types of the result:
/// 0x01 numeric, 0x02 text, 0x04 blob; 0 if always NULL.
pub fn dataType(e_arg: ?*const Expr) u8 {
    var e = e_arg;
    while (e) |x| {
        switch (x.op) {
            TK.COLLATE, TK.IF_NULL_ROW, TK.UPLUS => e = x.left,
            TK.NULL => e = null,
            TK.STRING => return 0x02,
            TK.BLOB => return 0x04,
            TK.CONCAT => return 0x06,
            TK.VARIABLE, TK.AGG_FUNCTION, TK.FUNCTION => return 0x07,
            TK.COLUMN, TK.AGG_COLUMN, TK.SELECT, TK.CAST, TK.SELECT_COLUMN, TK.VECTOR => {
                const aff = affinity(x);
                if (aff >= Aff.numeric) return 0x05;
                if (aff == Aff.text) return 0x06;
                return 0x07;
            },
            TK.CASE => {
                var res: u8 = 0;
                const l = x.x.list.?;
                var ii: usize = 1;
                while (ii < l.len()) : (ii += 2) res |= dataType(l.at(ii).expr);
                if (l.len() % 2 != 0) res |= dataType(l.at(l.len() - 1).expr);
                return res;
            },
            else => return 0x01,
        }
    }
    return 0x00;
}

/// Port of sqlite3ExprCollSeq(): the collation of `e` from a COLLATE or a
/// column, or null.
pub fn collSeq(p: *Parse, e_arg: ?*const Expr) ?*CollSeq {
    const db = p.db;
    var coll: ?*CollSeq = null;
    var e = e_arg;
    while (e) |x| {
        var op = x.op;
        if (op == TK.REGISTER) op = x.op2;
        if ((op == TK.AGG_COLUMN and x.y.tab != null) or op == TK.COLUMN or op == TK.TRIGGER) {
            if (x.i_column >= 0) {
                // No declared collation is the default one, as C's
                // sqlite3FindCollSeq(db, enc, 0, 0).
                coll = coll_mod.findCollSeq(db, build.columnColl(&x.y.tab.?.cols[@intCast(x.i_column)]), false);
            }
            break;
        }
        if (op == TK.CAST or op == TK.UPLUS) {
            e = x.left;
            continue;
        }
        if (op == TK.VECTOR or (op == TK.FUNCTION and x.aff_expr == Aff.@"defer")) {
            e = x.x.list.?.at(0).expr;
            continue;
        }
        if (op == TK.COLLATE) {
            coll = coll_mod.getCollSeq(p, null, x.token());
            break;
        }
        if (x.flags & EP.Collate != 0) {
            if (x.left != null and x.left.?.flags & EP.Collate != 0) {
                e = x.left;
            } else {
                var next = x.right;
                if (x.useXList()) if (x.x.list) |l| if (!db.malloc_failed) {
                    for (l.slice()) |item| {
                        if (item.expr.?.has(EP.Collate)) {
                            next = item.expr;
                            break;
                        }
                    }
                };
                e = next;
            }
        } else {
            break;
        }
    }
    if (coll_mod.checkCollSeq(p, coll) != int.RC.OK) coll = null;
    return coll;
}

/// Port of sqlite3ExprNNCollSeq(): like collSeq(), but BINARY by default.
pub fn nnCollSeq(p: *Parse, e: ?*const Expr) *CollSeq {
    return collSeq(p, e) orelse coll_mod.defaultColl();
}

/// Port of sqlite3ExprCollSeqMatch().
pub fn collSeqMatch(p: *Parse, e1: *const Expr, e2: *const Expr) bool {
    return nnCollSeq(p, e1) == nnCollSeq(p, e2);
}

/// Port of sqlite3CompareAffinity(): the affinity for comparing `e` with
/// an operand of affinity `aff2`.
pub fn compareAffinity(e: *const Expr, aff2: u8) u8 {
    const aff1 = affinity(e);
    if (aff1 > Aff.none and aff2 > Aff.none) {
        // Both are columns: numeric if either is.
        if (isNumericAffinity(aff1) or isNumericAffinity(aff2)) return Aff.numeric;
        return Aff.blob;
    }
    return (if (aff1 <= Aff.none) aff2 else aff1) | Aff.none;
}

/// Port of comparisonAffinity(): the affinity applied to both operands of
/// a comparison.
fn comparisonAffinity(e: *const Expr) u8 {
    var aff = affinity(e.left.?);
    if (e.right) |r| {
        aff = compareAffinity(r, aff);
    } else if (e.useXSelect()) {
        aff = compareAffinity(e.x.select.?.e_list.?.at(0).expr.?, aff);
    } else if (aff == 0) {
        aff = Aff.blob;
    }
    return aff;
}

/// Port of sqlite3IndexAffinityOk(): an index column of affinity
/// `idx_affinity` can serve comparison `e`.
pub fn indexAffinityOk(e: *const Expr, idx_affinity: u8) bool {
    const aff = comparisonAffinity(e);
    if (aff < Aff.text) return true;
    if (aff == Aff.text) return idx_affinity == Aff.text;
    return isNumericAffinity(idx_affinity);
}

/// Port of binaryCompareP5(): P5 of a comparison opcode.
pub fn binaryCompareP5(e1: *const Expr, e2: *const Expr, jump_if_null: u16) u16 {
    const aff = affinity(e2);
    return @as(u16, compareAffinity(e1, aff)) | jump_if_null;
}

/// Port of sqlite3BinaryCompareCollSeq(): the collation of a comparison:
/// an explicit COLLATE, else the left operand's, else the right's.
pub fn binaryCompareCollSeq(p: *Parse, left: *const Expr, right: ?*const Expr) ?*CollSeq {
    if (left.flags & EP.Collate != 0) return collSeq(p, left);
    if (right) |r| if (r.flags & EP.Collate != 0) return collSeq(p, r);
    return collSeq(p, left) orelse collSeq(p, right);
}

/// Port of sqlite3ExprCompareCollSeq().
pub fn compareCollSeq(p: *Parse, e: *const Expr) ?*CollSeq {
    if (e.has(EP.Commuted)) return binaryCompareCollSeq(p, e.right.?, e.left);
    return binaryCompareCollSeq(p, e.left.?, e.right);
}

// ======================================================== properties

/// Port of sqlite3ExprFunctionUsable(): DIRECTONLY and unsafe functions
/// may not be used from the schema.
pub fn functionUsable(p: *Parse, e: *const Expr, def: *const int.FuncDef) void {
    if (e.has(EP.FromDDL) or p.prep_flags & @import("../vdbe/aux.zig").PREPARE_FROM_DDL != 0) {
        if (def.func_flags & callback.FUNC.DIRECT != 0 or p.db.flags & int.DbFlag.TrustedSchema == 0) {
            util.errorMsg(p, "unsafe use of {s}()", .{e.token()});
        }
    }
}

fn selectWalkTableConstant(w: *Walker, s: *Select) u8 {
    if (s.sel_flags & SF.Correlated != 0) {
        w.e_code = 0;
        return WRC.Abort;
    }
    return WRC.Prune;
}

/// Port of sqlite3ExprIsTableConstant(): `e` is constant for any one row
/// of table `i_cur`.
pub fn isTableConstant(e: ?*Expr, i_cur: i32, allow_subq: bool) bool {
    var w: Walker = .{
        .e_code = 3,
        .expr_callback = nodeIsConstant,
        .select_callback = if (allow_subq) selectWalkTableConstant else walker.selectWalkFail,
        .u = .{ .i_cur = i_cur },
    };
    _ = walker.walkExpr(&w, e);
    return w.e_code != 0;
}

/// Port of sqlite3ExprIsSingleTableConstraint(): `e` constrains FROM term
/// `i_src` alone.
pub fn isSingleTableConstraint(e: *Expr, src_list: *SrcList, i_src: usize, allow_subq: bool) bool {
    const src = src_list.at(i_src);
    if (src.fg.jointype & int.JT.LTORJ != 0) return false;
    if (src.fg.jointype & int.JT.LEFT != 0) {
        if (!e.has(EP.OuterON)) return false;
        if (e.w.join != src.i_cursor) return false;
    } else if (e.has(EP.OuterON)) {
        return false;
    }
    if (e.has(EP.OuterON | EP.InnerON) and src_list.at(0).fg.jointype & int.JT.LTORJ != 0) {
        for (src_list.slice()[0..i_src]) |*s| {
            if (e.w.join == s.i_cursor) {
                if (s.fg.jointype & int.JT.LTORJ != 0) return false;
                break;
            }
        }
    }
    return isTableConstant(e, src.i_cursor, allow_subq);
}

fn nodeIsConstantOrGroupBy(w: *Walker, e: *Expr) u8 {
    const gb = w.u.group_by.?;
    for (gb.slice()) |item| {
        if (compare(null, e, item.expr, -1) < 2) {
            if (@import("../vdbe/serial.zig").isBinary(nnCollSeq(w.parse.?, item.expr))) return WRC.Prune;
        }
    }
    if (e.useXSelect()) {
        w.e_code = 0;
        return WRC.Abort;
    }
    return nodeIsConstant(w, e);
}

/// Port of sqlite3ExprIsConstantOrGroupBy(): `e` is built from constants
/// and BINARY GROUP BY terms only.
pub fn isConstantOrGroupBy(p: *Parse, e: ?*Expr, group_by: *ExprList) bool {
    var w: Walker = .{
        .parse = p,
        .e_code = 1,
        .expr_callback = nodeIsConstantOrGroupBy,
        .u = .{ .group_by = group_by },
    };
    _ = walker.walkExpr(&w, e);
    return w.e_code != 0;
}

/// Port of sqlite3ExprIsInteger(): the value of an integer literal in
/// 0..0x7fffffff (possibly negated), or null. Bound parameters are not
/// looked at (no reprepare on bind).
pub fn isInteger(e_arg: ?*const Expr, p: ?*Parse) ?i32 {
    _ = p;
    var sign: i32 = 1;
    var e = e_arg orelse return null;
    while (true) {
        if (!e.useUToken()) return e.u.value * sign;
        if (e.op == TK.UPLUS) {
            e = e.left orelse return null;
            continue;
        }
        if (e.op == TK.UMINUS) {
            sign = -sign;
            e = e.left orelse return null;
            continue;
        }
        return null;
    }
}

/// Port of sqlite3ExprCanBeNull(): false only if `e` can never be NULL.
pub fn canBeNull(e_arg: *const Expr) bool {
    var e = e_arg;
    while (e.op == TK.UPLUS or e.op == TK.UMINUS) e = e.left.?;
    var op = e.op;
    if (op == TK.REGISTER) op = e.op2;
    return switch (op) {
        TK.INTEGER, TK.STRING, TK.FLOAT, TK.BLOB => false,
        TK.COLUMN => e.has(EP.CanBeNull) or e.y.tab == null or
            (e.i_column >= 0 and e.y.tab.?.cols.len > 0 and e.i_column < e.y.tab.?.cols.len and
            e.y.tab.?.cols[@intCast(e.i_column)].not_null == 0),
        else => true,
    };
}

/// Port of sqlite3ExprNeedsNoAffinityChange(): OP_Affinity with `aff`
/// would not change the constant `e`.
pub fn needsNoAffinityChange(e_arg: *const Expr, aff: u8) bool {
    if (aff == Aff.blob) return true;
    var e = e_arg;
    var unary_minus = false;
    while (e.op == TK.UPLUS or e.op == TK.UMINUS) {
        if (e.op == TK.UMINUS) unary_minus = true;
        e = e.left.?;
    }
    var op = e.op;
    if (op == TK.REGISTER) op = e.op2;
    return switch (op) {
        TK.INTEGER, TK.FLOAT => aff >= Aff.numeric,
        TK.STRING => !unary_minus and aff == Aff.text,
        TK.BLOB => !unary_minus,
        TK.COLUMN => aff >= Aff.numeric and e.i_column < 0,
        else => false,
    };
}

/// Port of sqlite3RowidAlias(): a rowid alias not used as a column name.
pub fn rowidAlias(t: *const Table) ?[:0]const u8 {
    for ([_][:0]const u8{ "_ROWID_", "ROWID", "OID" }) |z| {
        if (build.columnIndex(t, z) < 0) return z;
    }
    return null;
}

/// Port of exprImpliesNotNull().
fn impliesNotNull(p: ?*const Parse, e: *const Expr, nn: *const Expr, i_tab: i32, seen_not_arg: bool) bool {
    var seen_not = seen_not_arg;
    if (compare(p, e, nn, i_tab) == 0) return nn.op != TK.NULL;
    switch (e.op) {
        TK.IN => {
            if (seen_not and e.has(EP.xIsSelect)) return false;
            return impliesNotNull(p, e.left.?, nn, i_tab, true);
        },
        TK.BETWEEN => {
            const l = e.x.list.?;
            if (seen_not) return false;
            if (impliesNotNull(p, l.at(0).expr.?, nn, i_tab, true) or impliesNotNull(p, l.at(1).expr.?, nn, i_tab, true)) return true;
            return impliesNotNull(p, e.left.?, nn, i_tab, true);
        },
        TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE, TK.PLUS, TK.MINUS, TK.BITOR, TK.LSHIFT, TK.RSHIFT, TK.CONCAT, TK.STAR, TK.REM, TK.BITAND, TK.SLASH => {
            switch (e.op) {
                TK.STAR, TK.REM, TK.BITAND, TK.SLASH => {},
                else => seen_not = true,
            }
            if (impliesNotNull(p, e.right.?, nn, i_tab, seen_not)) return true;
            return impliesNotNull(p, e.left.?, nn, i_tab, seen_not);
        },
        TK.SPAN, TK.COLLATE, TK.UPLUS, TK.UMINUS => return impliesNotNull(p, e.left.?, nn, i_tab, seen_not),
        TK.TRUTH => {
            if (seen_not) return false;
            if (e.op2 != TK.IS) return false;
            return impliesNotNull(p, e.left.?, nn, i_tab, true);
        },
        TK.BITNOT, TK.NOT => return impliesNotNull(p, e.left.?, nn, i_tab, true),
        else => return false,
    }
}

/// Port of sqlite3ExprIsNotTrue().
fn isNotTrue(e: *Expr) bool {
    if (e.op == TK.NULL) return true;
    if (e.op == TK.TRUEFALSE and !truthValue(e)) return true;
    if (isInteger(e, null)) |v| if (v == 0) return true;
    return false;
}

/// Port of sqlite3ExprIsIIF().
fn isIIF(db: *int.Sqlite3, e: *const Expr) bool {
    if (e.op == TK.FUNCTION) {
        const z = e.token();
        if (z.len == 0 or (z[0] != 'i' and z[0] != 'I')) return false;
        const l = e.x.list orelse return false;
        const def = callback.findFunction(db, z, @intCast(l.len()), db.enc, false) orelse return false;
        if (def.func_flags & callback.FUNC.INLINE == 0) return false;
        if (@intFromPtr(def.user_data) != INLINEFUNC_iif) return false;
    } else if (e.op == TK.CASE) {
        if (e.left != null) return false;
    } else {
        return false;
    }
    const l = e.x.list.?;
    if (l.len() == 2) return true;
    if (l.len() == 3 and isNotTrue(l.at(2).expr.?)) return true;
    return false;
}

/// The INLINEFUNC_* numbers of functions coded inline (func.zig).
const func_mod = @import("func.zig");
pub const INLINEFUNC_coalesce = func_mod.INLINEFUNC_coalesce;
pub const INLINEFUNC_implies_nonnull_row = func_mod.INLINEFUNC_implies_nonnull_row;
pub const INLINEFUNC_expr_implies_expr = func_mod.INLINEFUNC_expr_implies_expr;
pub const INLINEFUNC_expr_compare = func_mod.INLINEFUNC_expr_compare;
pub const INLINEFUNC_affinity = func_mod.INLINEFUNC_affinity;
pub const INLINEFUNC_iif = func_mod.INLINEFUNC_iif;
pub const INLINEFUNC_sqlite_offset = func_mod.INLINEFUNC_sqlite_offset;
pub const INLINEFUNC_unlikely = func_mod.INLINEFUNC_unlikely;

/// Port of sqlite3ExprImpliesExpr(): `e1` being true proves `e2` true.
pub fn impliesExpr(p: *const Parse, e1: *const Expr, e2: *const Expr, i_tab: i32) bool {
    if (compare(p, e1, e2, i_tab) == 0) return true;
    if (e2.op == TK.OR and (impliesExpr(p, e1, e2.left.?, i_tab) or impliesExpr(p, e1, e2.right.?, i_tab))) return true;
    if (e2.op == TK.NOTNULL and impliesNotNull(p, e1, e2.left.?, i_tab, false)) return true;
    if (isIIF(p.db, e1)) return impliesExpr(p, e1.x.list.?.at(0).expr.?, e2, i_tab);
    return false;
}

fn bothImplyNotNullRow(w: *Walker, e1: ?*Expr, e2: ?*Expr) void {
    if (w.e_code == 0) {
        _ = walker.walkExpr(w, e1);
        if (w.e_code != 0) {
            w.e_code = 0;
            _ = walker.walkExpr(w, e2);
        }
    }
}

fn impliesNotNullRow(w: *Walker, e: *Expr) u8 {
    if (e.has(EP.OuterON)) return WRC.Prune;
    if (e.has(EP.InnerON) and w.m_wflags != 0) return WRC.Prune;
    switch (e.op) {
        TK.ISNOT, TK.ISNULL, TK.NOTNULL, TK.IS, TK.VECTOR, TK.FUNCTION, TK.TRUTH, TK.CASE => return WRC.Prune,
        TK.COLUMN => {
            if (w.u.i_cur == e.i_table) {
                w.e_code = 1;
                return WRC.Abort;
            }
            return WRC.Prune;
        },
        TK.OR, TK.AND => {
            bothImplyNotNullRow(w, e.left, e.right);
            return WRC.Prune;
        },
        TK.IN => {
            if (e.useXList() and e.x.list.?.len() > 0) _ = walker.walkExpr(w, e.left);
            return WRC.Prune;
        },
        TK.BETWEEN => {
            _ = walker.walkExpr(w, e.left);
            bothImplyNotNullRow(w, e.x.list.?.at(0).expr, e.x.list.?.at(1).expr);
            return WRC.Prune;
        },
        TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE => {
            // A virtual table column may not be what it seems.
            const left = e.left.?;
            const right = e.right.?;
            if ((left.op == TK.COLUMN and left.y.tab != null and left.y.tab.?.isVirtual()) or
                (right.op == TK.COLUMN and right.y.tab != null and right.y.tab.?.isVirtual()))
            {
                return WRC.Prune;
            }
            return WRC.Continue;
        },
        else => return WRC.Continue,
    }
}

/// Port of sqlite3ExprImpliesNonNullRow(): `e` can only be true if some
/// column of table `i_tab` is not NULL.
pub fn impliesNonNullRow(e_arg: ?*Expr, i_tab: i32, is_rj: bool) bool {
    var e = skipCollateAndLikely(e_arg) orelse return false;
    if (e.op == TK.NOTNULL) {
        e = e.left.?;
    } else {
        while (e.op == TK.AND) {
            if (impliesNonNullRow(e.left, i_tab, is_rj)) return true;
            e = e.right.?;
        }
    }
    var w: Walker = .{ .expr_callback = impliesNotNullRow, .m_wflags = @intFromBool(is_rj), .u = .{ .i_cur = i_tab } };
    _ = walker.walkExpr(&w, e);
    return w.e_code != 0;
}

const IdxCover = struct { idx: *Index, i_cur: i32 };

fn exprIdxCover(w: *Walker, e: *Expr) u8 {
    const c: *IdxCover = @ptrCast(@alignCast(w.u.ptr.?));
    if (e.op == TK.COLUMN and e.i_table == c.i_cur and build.tableColumnToIndex(c.idx, e.i_column) < 0) {
        w.e_code = 1;
        return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of sqlite3ExprCoveredByIndex(): `e` uses only columns of `idx`.
pub fn coveredByIndex(e: ?*Expr, i_cur: i32, idx: *Index) bool {
    var c: IdxCover = .{ .idx = idx, .i_cur = i_cur };
    var w: Walker = .{ .expr_callback = exprIdxCover, .u = .{ .ptr = &c } };
    _ = walker.walkExpr(&w, e);
    return w.e_code == 0;
}

const RefSrcList = struct {
    gpa: Allocator,
    ref: ?*SrcList,
    exclude: std.ArrayList(i32) = .empty,
};

fn selectRefEnter(w: *Walker, s: *Select) u8 {
    const x: *RefSrcList = @ptrCast(@alignCast(w.u.ptr.?));
    const src = s.src orelse return WRC.Continue;
    if (src.len() == 0) return WRC.Continue;
    for (src.slice()) |item| x.exclude.append(x.gpa, item.i_cursor) catch {
        x.exclude.clearRetainingCapacity();
        return WRC.Abort;
    };
    return WRC.Continue;
}

fn selectRefLeave(w: *Walker, s: *Select) void {
    const x: *RefSrcList = @ptrCast(@alignCast(w.u.ptr.?));
    const n = if (s.src) |src| src.len() else 0;
    if (x.exclude.items.len > 0) x.exclude.shrinkRetainingCapacity(x.exclude.items.len - n);
}

fn exprRefToSrcList(w: *Walker, e: *Expr) u8 {
    if (e.op == TK.COLUMN or e.op == TK.AGG_COLUMN) {
        const x: *RefSrcList = @ptrCast(@alignCast(w.u.ptr.?));
        if (x.ref) |src| for (src.slice()) |item| {
            if (e.i_table == item.i_cursor) {
                w.e_code |= 1;
                return WRC.Continue;
            }
        };
        for (x.exclude.items) |c| if (c == e.i_table) return WRC.Continue;
        w.e_code |= 2;
    }
    return WRC.Continue;
}

/// Port of sqlite3ReferencesSrcList(): whether the aggregate `e` refers
/// to a table of `src_list` (1), to another outer table (0), or to no
/// table outside its own subqueries (-1).
pub fn referencesSrcList(p: *Parse, e: *Expr, src_list: ?*SrcList) i32 {
    var x: RefSrcList = .{ .gpa = p.db.gpa, .ref = src_list };
    defer x.exclude.deinit(x.gpa);
    var w: Walker = .{
        .expr_callback = exprRefToSrcList,
        .select_callback = selectRefEnter,
        .select_callback2 = selectRefLeave,
        .u = .{ .ptr = &x },
    };
    std.debug.assert(e.op == TK.AGG_FUNCTION);
    _ = walker.walkExprList(&w, e.x.list);
    if (e.left) |l| _ = walker.walkExprList(&w, l.x.list);
    if (e.has(EP.WinFunc)) _ = walker.walkExpr(&w, e.y.win.?.filter);
    if (w.e_code & 0x01 != 0) return 1;
    if (w.e_code != 0) return 0;
    return -1;
}

// ========================================================= aggregates

/// Port of findOrCreateAggInfoColumn(): the AggInfo column for `e`,
/// turning a TK_COLUMN into a TK_AGG_COLUMN.
fn findOrCreateAggInfoColumn(p: *Parse, agg: *AggInfo, e: *Expr) Oom!void {
    const mx_term: usize = @intCast(p.db.limit(.column));
    var k: usize = 0;
    const found = for (agg.cols.items, 0..) |*c, i| {
        if (c.c_expr == e) return;
        if (c.i_table == e.i_table and c.i_column == e.i_column and e.op != TK.IF_NULL_ROW) {
            k = i;
            break true;
        }
    } else false;
    if (!found) {
        k = agg.cols.items.len;
        try agg.cols.append(p.arena, .{
            .tab = e.y.tab,
            .c_expr = e,
            .i_table = e.i_table,
            .i_column = e.i_column,
            .i_sorter_column = -1,
        });
        if (k > mx_term) {
            util.errorMsg(p, "more than {d} aggregate terms", .{mx_term});
            k = mx_term;
        }
        const c = &agg.cols.items[k];
        if (agg.group_by) |gb| if (e.op != TK.IF_NULL_ROW) {
            for (gb.slice(), 0..) |item, j| {
                const ge = item.expr.?;
                if (ge.op == TK.COLUMN and ge.i_table == e.i_table and ge.i_column == e.i_column) {
                    c.i_sorter_column = @intCast(j);
                    break;
                }
            }
        };
        if (c.i_sorter_column < 0) {
            c.i_sorter_column = @intCast(agg.n_sorting_column);
            agg.n_sorting_column += 1;
        }
    }
    e.agg_info = agg;
    if (e.op == TK.COLUMN) e.op = TK.AGG_COLUMN;
    e.i_agg = @intCast(k);
}

fn analyzeAggregate(w: *Walker, e: *Expr) u8 {
    return analyzeAggregateImpl(w, e) catch {
        w.u.nc.?.parse.db.malloc_failed = true;
        return WRC.Abort;
    };
}

fn analyzeAggregateImpl(w: *Walker, e: *Expr) Oom!u8 {
    const nc = w.u.nc.?;
    const p = nc.parse;
    const agg = nc.u_nc.agg_info.?;
    switch (e.op) {
        TK.IF_NULL_ROW, TK.AGG_COLUMN, TK.COLUMN => {
            // A column of a table in the FROM clause of the aggregate.
            if (nc.src_list) |src| for (src.slice()) |item| {
                if (e.i_table == item.i_cursor) {
                    try findOrCreateAggInfoColumn(p, agg, e);
                    break;
                }
            };
            return WRC.Continue;
        },
        TK.AGG_FUNCTION => {
            if (nc.nc_flags & NC_InAggFunc == 0 and w.walker_depth == e.op2 and e.agg_info == null) {
                // The same function may already be in the AggInfo.
                const mx_term: usize = @intCast(p.db.limit(.column));
                var i: usize = 0;
                while (i < agg.funcs.items.len) : (i += 1) {
                    if (compare(null, agg.funcs.items[i].f_expr, e, -1) == 0) break;
                }
                if (i > mx_term) {
                    util.errorMsg(p, "more than {d} aggregate terms", .{mx_term});
                    i = mx_term;
                } else if (i >= agg.funcs.items.len) {
                    const n_arg: i32 = if (e.x.list) |l| @intCast(l.len()) else 0;
                    var item: int.AggInfoFunc = .{
                        .f_expr = e,
                        .func = callback.findFunction(p.db, e.token(), n_arg, p.db.enc, false),
                    };
                    if (e.left != null and item.func.?.func_flags & callback.FUNC.NEEDCOLL == 0) {
                        // ORDER BY in an aggregate (ignored for min/max).
                        item.i_ob_tab = p.n_tab;
                        p.n_tab += 1;
                        const ob = e.left.?.x.list.?;
                        if (ob.len() == 1 and n_arg == 1 and compare(null, ob.at(0).expr, e.x.list.?.at(0).expr, -1) == 0) {
                            item.b_ob_payload = false;
                            item.b_ob_unique = e.has(EP.Distinct);
                        } else {
                            item.b_ob_payload = true;
                        }
                        item.b_use_subtype = item.func.?.func_flags & callback.FUNC.SUBTYPE != 0;
                    } else {
                        item.i_ob_tab = -1;
                    }
                    if (e.has(EP.Distinct) and !item.b_ob_unique) {
                        item.i_distinct = p.n_tab;
                        p.n_tab += 1;
                    } else {
                        item.i_distinct = -1;
                    }
                    try agg.funcs.append(p.arena, item);
                }
                e.i_agg = @intCast(i);
                e.agg_info = agg;
                return WRC.Prune;
            }
            return WRC.Continue;
        },
        else => {
            // An argument of an aggregate that an index the query uses
            // holds: read it from the index as an AggInfo column.
            std.debug.assert(p.i_self_tab == 0);
            if (nc.nc_flags & NC_InAggFunc == 0) return WRC.Continue;
            var it = p.idx_epr;
            const ie = while (it) |x| : (it = x.next) {
                if (x.i_data_cur < 0) continue;
                if (compare(null, e, x.expr, x.i_data_cur) == 0) break x;
            } else return WRC.Continue;
            const src = nc.src_list orelse return WRC.Continue;
            for (src.slice()) |item| {
                if (item.i_cursor == ie.i_data_cur) break;
            } else return WRC.Continue;
            if (e.agg_info != null) return WRC.Continue;
            if (p.n_err != 0) return WRC.Abort;
            var tmp: Expr = .{ .op = TK.AGG_COLUMN, .i_table = ie.i_idx_cur, .i_column = @intCast(ie.i_idx_col) };
            try findOrCreateAggInfoColumn(p, agg, &tmp);
            if (p.n_err != 0) return WRC.Abort;
            agg.cols.items[@intCast(tmp.i_agg)].c_expr = e;
            e.agg_info = agg;
            e.i_agg = tmp.i_agg;
            return WRC.Prune;
        },
    }
}

const NC_InAggFunc = int.NC.InAggFunc;

/// Port of sqlite3ExprAnalyzeAggregates(): add the columns and aggregate
/// functions of `e` to the AggInfo of `nc`.
pub fn analyzeAggregates(nc: *NameContext, e: ?*Expr) void {
    var w: Walker = .{
        .expr_callback = analyzeAggregate,
        .select_callback = walker.walkerDepthIncrease,
        .select_callback2 = walker.walkerDepthDecrease,
        .u = .{ .nc = nc },
    };
    _ = walker.walkExpr(&w, e);
}

/// Port of sqlite3ExprAnalyzeAggList().
pub fn analyzeAggList(nc: *NameContext, list: ?*ExprList) void {
    const l = list orelse return;
    for (l.slice()) |item| analyzeAggregates(nc, item.expr);
}

fn agginfoPersistExprCb(w: *Walker, e: *Expr) u8 {
    if (!e.has(EP.TokenOnly | EP.Reduced)) if (e.agg_info) |agg| {
        const i_agg: usize = @intCast(e.i_agg);
        const p = w.parse.?;
        if (e.op != TK.AGG_FUNCTION) {
            if (i_agg < agg.cols.items.len and agg.cols.items[i_agg].c_expr == e) {
                if (exprDup(p.arena, e) catch null) |d| agg.cols.items[i_agg].c_expr = d;
            }
        } else if (i_agg < agg.funcs.items.len and agg.funcs.items[i_agg].f_expr == e) {
            if (exprDup(p.arena, e) catch null) |d| agg.funcs.items[i_agg].f_expr = d;
        }
    };
    return WRC.Continue;
}

/// Port of sqlite3AggInfoPersistWalkerInit(): a walker making the AggInfo
/// entries refer to copies of the expressions walked.
pub fn aggInfoPersistWalker(p: *Parse) Walker {
    return .{ .parse = p, .expr_callback = agginfoPersistExprCb, .select_callback = walker.selectWalkNoop };
}

// ===================================================== temp registers

/// Port of sqlite3GetTempReg().
pub fn getTempReg(p: *Parse) i32 {
    if (p.n_temp_reg == 0) {
        p.n_mem += 1;
        return p.n_mem;
    }
    p.n_temp_reg -= 1;
    return p.temp_regs[p.n_temp_reg];
}

/// Port of sqlite3ReleaseTempReg().
pub fn releaseTempReg(p: *Parse, reg: i32) void {
    if (reg != 0 and p.n_temp_reg < p.temp_regs.len) {
        p.temp_regs[p.n_temp_reg] = reg;
        p.n_temp_reg += 1;
    }
}

/// Port of sqlite3GetTempRange().
pub fn getTempRange(p: *Parse, n_reg: i32) i32 {
    if (n_reg == 1) return getTempReg(p);
    var i = p.i_range_reg;
    if (n_reg <= p.n_range_reg) {
        p.i_range_reg += n_reg;
        p.n_range_reg -= n_reg;
    } else {
        i = p.n_mem + 1;
        p.n_mem += n_reg;
    }
    return i;
}

/// Port of sqlite3ReleaseTempRange().
pub fn releaseTempRange(p: *Parse, reg: i32, n_reg: i32) void {
    if (n_reg == 1) return releaseTempReg(p, reg);
    if (n_reg > p.n_range_reg) {
        p.n_range_reg = n_reg;
        p.i_range_reg = reg;
    }
}

/// Port of sqlite3ClearTempRegCache(): no temporary register may be
/// reused (after coding a subroutine).
pub fn clearTempRegCache(p: *Parse) void {
    p.n_temp_reg = 0;
    p.n_range_reg = 0;
}

/// Port of sqlite3TouchRegister().
pub fn touchRegister(p: *Parse, reg: i32) void {
    if (p.n_mem < reg) p.n_mem = reg;
}

/// Port of sqlite3SubselectError().
pub fn subselectError(p: *Parse, n_actual: usize, n_expect: usize) void {
    if (p.n_err == 0) util.errorMsg(p, "sub-select returns {d} columns - expected {d}", .{ n_actual, n_expect });
}

/// Port of sqlite3VectorErrorMsg().
pub fn vectorErrorMsg(p: *Parse, e: *Expr) void {
    if (e.useXSelect()) {
        subselectError(p, e.x.select.?.e_list.?.len(), 1);
    } else {
        util.errorMsg(p, "row value misused", .{});
    }
}

/// Port of sqlite3ExprCheckIN(): the two sides of IN have matching sizes.
pub fn checkIN(p: *Parse, in: *Expr) bool {
    const n_vector = vectorSize(in.left.?);
    if (in.useXSelect() and !p.db.malloc_failed) {
        if (n_vector != in.x.select.?.e_list.?.len()) {
            subselectError(p, in.x.select.?.e_list.?.len(), n_vector);
            return true;
        }
    } else if (n_vector != 1) {
        vectorErrorMsg(p, in.left.?);
        return true;
    }
    return false;
}

/// Port of sqlite3ExprToRegister(): make `e` a TK_REGISTER reading `reg`,
/// which holds its value.
pub fn toRegister(e_arg: *Expr, reg: i32) void {
    const e = skipCollateAndLikely(e_arg) orelse return;
    if (e.op == TK.REGISTER) {
        std.debug.assert(e.i_table == reg);
    } else {
        e.op2 = e.op;
        e.op = TK.REGISTER;
        e.i_table = reg;
        e.clear(EP.Skip);
    }
}
