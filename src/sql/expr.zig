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
/// statement; only the rename map would need updating.
pub fn unmapAndDelete(p: *Parse, e: ?*Expr) void {
    _ = p;
    _ = e;
}

// =========================================================== expr lists

/// Port of sqlite3ExprListAppend().
pub fn listAppend(p: *Parse, list: ?*ExprList, e: ?*Expr) Oom!*ExprList {
    const l = list orelse blk: {
        const n = try p.arena.create(ExprList);
        n.* = .{};
        try n.items.ensureTotalCapacity(p.arena, 4);
        break :blk n;
    };
    try l.items.append(p.arena, .{ .expr = e });
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
    if (dequote) z = util.dequote(z);
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
        if (it.s_tab) |t| t.n_tab_ref += 1;
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
