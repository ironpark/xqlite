//! SELECT statements (port of select.c): building Select objects while
//! parsing, expanding and resolving them, and generating their code.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const ctype = @import("../util/ctype.zig");

const Allocator = std.mem.Allocator;
const Parse = int.Parse;
const ExprListItem = int.ExprListItem;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Select = int.Select;
const With = int.With;
const Token = int.Token;
const Oom = int.Oom;
const JT = int.JT;
const TK = int.TK;

/// Port of sqlite3SelectNew(). A missing result list means "*"; a
/// missing FROM clause is an empty one.
pub fn selectNew(
    p: *Parse,
    e_list_arg: ?*ExprList,
    src_arg: ?*SrcList,
    where: ?*Expr,
    group_by: ?*ExprList,
    having: ?*Expr,
    order_by: ?*ExprList,
    sel_flags: SF,
    limit: ?*Expr,
) Oom!*Select {
    const s = try p.arena.create(Select);
    const e_list = e_list_arg orelse
        try expr_mod.listAppend(p, null, try expr_mod.expr(p.arena, TK.ASTERISK, null));
    const src = src_arg orelse blk: {
        const l = try p.arena.create(SrcList);
        l.* = .{};
        break :blk l;
    };
    p.n_select += 1;
    s.* = .{
        .e_list = e_list,
        .op = TK.SELECT,
        .sel_flags = sel_flags,
        .sel_id = @intCast(p.n_select),
        .src = src,
        .where = where,
        .group_by = group_by,
        .having = having,
        .order_by = order_by,
        .limit = limit,
    };
    return s;
}

/// Port of findRightmost().
pub fn findRightmost(s_arg: *Select) *Select {
    var s = s_arg;
    while (s.next) |n| s = n;
    return s;
}

/// Port of sqlite3JoinType(): the JT_* mask for the one to three words
/// before JOIN ("LEFT OUTER" etc.). Nonsense combinations that SQLite has
/// always accepted are accepted; the rest are errors.
pub fn joinType(p: *Parse, a: Token, b: ?Token, c: ?Token) JT {
    const keywords = [_]struct { []const u8, JT }{
        .{ "natural", .{ .NATURAL = true } },
        .{ "left", .{ .LEFT = true, .OUTER = true } },
        .{ "outer", .{ .OUTER = true } },
        .{ "right", .{ .RIGHT = true, .OUTER = true } },
        .{ "full", .{ .LEFT = true, .RIGHT = true, .OUTER = true } },
        .{ "inner", .{ .INNER = true } },
        .{ "cross", .{ .INNER = true, .CROSS = true } },
    };
    var jointype: JT = .{};
    const all = [3]?Token{ a, b, c };
    for (all) |maybe| {
        const t = maybe orelse break;
        const word = t.slice();
        for (keywords) |k| {
            if (ctype.eqlNoCase(word, k[0])) {
                jointype.set(k[1]);
                break;
            }
        } else {
            jointype.ERROR = true;
            break;
        }
    }
    if (jointype.contains(.{ .INNER = true, .OUTER = true }) or jointype.ERROR or
        jointype.only(.{ .OUTER = true, .LEFT = true, .RIGHT = true }) == JT{ .OUTER = true })
    {
        const sp1 = if (b == null) "" else " ";
        const sp2 = if (c == null) "" else " ";
        util.errorMsgAt(p, a.z, "unknown join type: {s}{s}{s}{s}{s}", .{
            a.slice(),
            sp1,
            if (b) |t| t.slice() else "",
            sp2,
            if (c) |t| t.slice() else "",
        });
        return .{ .INNER = true };
    }
    return jointype;
}

/// Port of sqlite3SelectOpName(): the operator of a compound, for error
/// messages.
pub fn selectOpName(op: u8) []const u8 {
    return switch (op) {
        TK.ALL => "UNION ALL",
        TK.INTERSECT => "INTERSECT",
        TK.EXCEPT => "EXCEPT",
        else => "UNION",
    };
}

/// Port of sqlite3WithPush(): make `w` the innermost WITH clause in scope.
pub fn withPush(p: *Parse, w_arg: ?*With) ?*With {
    const w = w_arg orelse return null;
    if (p.n_err == 0) {
        std.debug.assert(p.with != w);
        w.outer = p.with;
        p.with = w;
    }
    return w;
}

// ============================================================== codegen

/// Where the results of a SELECT go (SRT_*), numbered as in C. The order
/// matters: IgnorableDistinct() and IgnorableOrderby() compare the
/// numbers, as the destinations that ignore DISTINCT and ORDER BY come
/// first.
pub const SRT = enum(u8) {
    Exists = 1,
    Discard = 2,
    DistFifo = 3,
    DistQueue = 4,
    Queue = 5,
    Fifo = 6,
    Output = 7,
    Mem = 8,
    Set = 9,
    EphemTab = 10,
    Coroutine = 11,
    Table = 12,
    Upfrom = 13,

    /// The number of the destination, as C compares it.
    pub inline fn int(d: SRT) u8 {
        return @backingInt(d);
    }
};

/// SelectDest.
pub const SelectDest = struct {
    e_dest: SRT,
    i_sd_parm: i32 = 0,
    i_sd_parm2: i32 = 0,
    i_sdst: i32 = 0,
    n_sdst: i32 = 0,
    aff_sdst: ?[]const u8 = null,
    order_by: ?*ExprList = null,
};

/// Port of sqlite3SelectDestInit().
pub fn selectDestInit(e_dest: SRT, i_parm: i32) SelectDest {
    return .{ .e_dest = e_dest, .i_sd_parm = i_parm };
}

/// Port of sqlite3KeyInfoAlloc(): a KeyInfo for `n` key columns and `x`
/// more, allocated with the program. Null if out of memory.
pub fn keyInfoAlloc(p: *Parse, n: usize, x: usize) ?*vi.KeyInfo {
    const v = build.getVdbe(p) orelse return null;
    const a = v.alloc();
    const k = a.create(vi.KeyInfo) catch return oomNull(p);
    k.* = .{
        .n_key_field = @intCast(n),
        .n_all_field = @intCast(n + x),
        .db = p.db,
        .enc = p.db.enc,
        .sort_flags = a.alloc(u8, n + x) catch return oomNull(p),
        .coll = a.alloc(?*int.CollSeq, n + x) catch return oomNull(p),
    };
    @memset(k.sort_flags, 0);
    @memset(k.coll, null);
    return k;
}

fn oomNull(p: *Parse) ?*vi.KeyInfo {
    build.oomFault(p);
    return null;
}

/// Port of sqlite3SelectWrongNumTermsError().
pub fn selectWrongNumTermsError(p: *Parse, s: *Select) void {
    if (s.sel_flags.Values) {
        util.errorMsg(p, "all VALUES must have the same number of terms", .{});
    } else {
        util.errorMsg(p, "SELECTs to the left and right of {s} do not have the same number of result columns", .{selectOpName(s.op)});
    }
}

const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const build = @import("build.zig");
const ec = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const where_mod = @import("where.zig");
const walker = @import("walker.zig");
const window = @import("window.zig");
const coll_mod = @import("coll.zig");
const prepare = @import("prepare.zig");
const callback = @import("callback.zig");
const serial = @import("../vdbe/serial.zig");

const Sqlite3 = int.Sqlite3;
const Table = int.Table;
const Column = int.Column;
const Index = int.Index;
const SrcItem = int.SrcItem;
const IdList = int.IdList;
const NameContext = int.NameContext;
const AggInfo = int.AggInfo;
const KeyInfo = vi.KeyInfo;
const CollSeq = int.CollSeq;
const Vdbe = vi.Vdbe;
const Walker = walker.Walker;
const WRC = walker.WRC;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;
const EP = int.EP;
const SF = int.SF;
const NC = int.NC;
const TF = int.TF;
const COLFLAG = int.COLFLAG;
const Aff = int.Aff;
const WHERE = int.WHERE;

const oom = build.oomFault;

/// Port of sqlite3SrcItemColumnUsed(): mark result column `i_col` of a
/// parenthesized FROM group as used.
pub fn srcItemColumnUsed(item: *SrcItem, i_col: i32) void {
    if (item.fg.is_nested_from) {
        item.u4.subq.?.select.e_list.?.at(@intCast(i_col)).fg.used = true;
    }
}

/// IsHiddenColumn().
fn isHiddenColumn(c: *const Column) bool {
    return c.col_flags.HIDDEN;
}

/// Port of tableAndColumnIndex(): the first table of src[start..end]
/// with a column named `col` (and the column), or null.
fn tableAndColumnIndex(src: *SrcList, start: usize, end: usize, col: []const u8, ignore_hidden: bool) ?struct { tab: usize, col: i32 } {
    var i = start;
    while (i <= end) : (i += 1) {
        const t = src.at(i).s_tab.?;
        const i_col = build.columnIndex(t, col);
        if (i_col >= 0 and (!ignore_hidden or !isHiddenColumn(&t.cols[@intCast(i_col)]))) {
            srcItemColumnUsed(src.at(i), i_col);
            return .{ .tab = i, .col = i_col };
        }
    }
    return null;
}

/// Port of sqlite3SetJoinExpr(): tag every node of an ON/USING term with
/// `join_flag` and the right table of its join.
pub fn setJoinExpr(e_arg: ?*Expr, i_table: i32, join_flag: EP) void {
    var e = e_arg;
    while (e) |x| {
        x.flags.set(join_flag);
        x.w = .{ .join = i_table };
        if (x.useXList()) if (x.x.list) |l| {
            for (l.slice()) |item| setJoinExpr(item.expr, i_table, join_flag);
        };
        setJoinExpr(x.left, i_table, join_flag);
        e = x.right;
    }
}

/// Port of unsetJoinExpr(): turn the ON terms of table `i_table` (all, if
/// negative) into ordinary terms.
pub fn unsetJoinExpr(e_arg: ?*Expr, i_table: i32, nullable: bool) void {
    var e = e_arg;
    while (e) |x| {
        if (i_table < 0 or (x.flags.OuterON and x.w.join == i_table)) {
            x.flags.clear(.{ .OuterON = true, .InnerON = true });
            if (i_table >= 0) x.flags.InnerON = true;
        }
        if (x.op == TK.COLUMN and x.i_table == i_table and !nullable) x.flags.CanBeNull = false;
        if (x.op == TK.FUNCTION) if (x.x.list) |l| {
            for (l.slice()) |item| unsetJoinExpr(item.expr, i_table, nullable);
        };
        unsetJoinExpr(x.left, i_table, nullable);
        e = x.right;
    }
}

/// Port of sqlite3ProcessJoin(): turn NATURAL joins into USING joins, and
/// move ON and USING constraints into the WHERE clause, tagged with
/// EP_OuterON or EP_InnerON. On error (C: the number of errors) the
/// error is in `p`.
fn processJoin(p: *Parse, s: *Select) (Oom || int.ParseError)!void {
    const src = s.src.?;
    var seen_tfunc = false;
    if (src.len() < 2) return;
    for (0..src.len() - 1) |i| {
        const left = src.at(i);
        const right = src.at(i + 1);
        const right_tab = right.s_tab orelse continue;
        if (left.s_tab == null) continue;
        const join_type: EP = if (right.fg.jointype.OUTER) .{ .OuterON = true } else .{ .InnerON = true };

        // NATURAL becomes USING the columns both sides have.
        if (right.fg.jointype.NATURAL) {
            if (right.fg.is_using or right.u3.on != null) {
                util.errorMsg(p, "a NATURAL join may not have an ON or USING clause", .{});
                return error.ParseFailed;
            }
            var using: ?*IdList = null;
            for (right_tab.cols) |*c| {
                if (isHiddenColumn(c)) continue;
                const name = c.name();
                if (tableAndColumnIndex(src, 0, i, name, true) != null) {
                    const l = using orelse blk: {
                        const n = try p.arena.create(IdList);
                        n.* = .{};
                        break :blk n;
                    };
                    try l.names.append(p.arena, try p.arena.dupeSentinel(u8, name, 0));
                    using = l;
                }
            }
            if (using) |l| {
                right.fg.is_using = true;
                right.fg.is_synth_using = true;
                right.u3 = .{ .using = l };
            }
            if (p.n_err != 0) return error.ParseFailed;
        }

        if (right.fg.is_using) {
            // "A JOIN B USING(x,y)" adds "A.x=B.x AND A.y=B.y".
            const list = right.u3.using.?;
            for (list.names.items) |name| {
                const i_right_col = build.columnIndex(right_tab, name);
                const found = if (i_right_col >= 0) tableAndColumnIndex(src, 0, i, name, right.fg.is_synth_using) else null;
                if (found == null) {
                    util.errorMsg(p, "cannot join using column {s} - column not present in both tables", .{name});
                    return error.ParseFailed;
                }
                var i_left = found.?.tab;
                var e1 = try resolve.createColumnExpr(p, src, i_left, found.?.col);
                srcItemColumnUsed(src.at(i_left), found.?.col);
                if (src.at(0).fg.jointype.LTORJ and p.n_err == 0) {
                    // With RIGHT or FULL JOINs, several tables on the left
                    // may have the column: use coalesce() of them.
                    var func_args: ?*ExprList = null;
                    e1.flags.CanBeNull = true;
                    while (i_left + 1 <= i) {
                        const more = tableAndColumnIndex(src, i_left + 1, i, name, right.fg.is_synth_using) orelse break;
                        i_left = more.tab;
                        const it = src.at(i_left);
                        if (!it.fg.is_using or build.idListIndex(it.u3.using.?, name) == null) {
                            util.errorMsg(p, "ambiguous reference to {s} in USING()", .{name});
                            break;
                        }
                        func_args = try expr_mod.listAppend(p, func_args, e1);
                        e1 = try resolve.createColumnExpr(p, src, i_left, more.col);
                        srcItemColumnUsed(src.at(i_left), more.col);
                    }
                    if (func_args) |fa| {
                        const args = try expr_mod.listAppend(p, fa, e1);
                        e1 = try expr_mod.exprFunction(p, args, Token.init("coalesce"), .{});
                        e1.aff_expr = Aff.@"defer";
                    }
                } else if (src.at(i + 1).fg.jointype.LEFT and p.n_err == 0) {
                    e1.flags.CanBeNull = true;
                }
                const e2 = try resolve.createColumnExpr(p, src, i + 1, i_right_col);
                srcItemColumnUsed(right, i_right_col);
                const eq = try expr_mod.pExpr(p, TK.EQ, e1, e2);
                eq.flags.set(join_type);
                eq.w = .{ .join = e2.i_table };
                s.where = try expr_mod.exprAnd(p, s.where, eq);
            }
        } else if (right.u3.on) |on| {
            // The ON clause joins the WHERE clause.
            setJoinExpr(on, right.i_cursor, join_type);
            s.where = try expr_mod.exprAnd(p, s.where, on);
            right.u3 = .{ .on = null };
            right.fg.is_on = true;
            s.sel_flags.OnToWhere = true;
        }

        if (!seen_tfunc) seen_tfunc = left.fg.is_tab_func and left.u1.func_arg != null;
        // Table-valued function arguments must not refer to tables on
        // their right.
        if ((right.fg.is_tab_func and join_type == EP{ .OuterON = true } and right.u1.func_arg != null) or
            (seen_tfunc and join_type == EP{ .OuterON = true }))
        {
            s.sel_flags.OnToWhere = true;
        }
    }
    return;
}

/// Port of DistinctCtx: how DISTINCT is processed.
const DistinctCtx = struct {
    /// 0 not distinct, 1 DISTINCT, 2 DISTINCT and ORDER BY.
    is_tnct: u8 = 0,
    /// A WHERE_DISTINCT_* value.
    e_tnct_type: int.WHERE_DISTINCT = .NOOP,
    /// The ephemeral table of seen rows.
    tab_tnct: i32 = 0,
    /// The OP_OpenEphemeral of tab_tnct.
    addr_tnct: i32 = 0,
};

/// Port of SortCtx: the ORDER BY (or GROUP BY) being coded.
const SortCtx = struct {
    order_by: ?*ExprList = null,
    /// ORDER BY terms satisfied by an index.
    n_ob_sat: i32 = 0,
    /// The sorter cursor.
    i_e_cursor: i32 = 0,
    /// Return address of the block-output subroutine.
    reg_return: i32 = 0,
    label_bk_out: i32 = 0,
    /// The OP_SorterOpen or OP_OpenEphemeral.
    addr_sort_index: i32 = 0,
    /// Jump here when done (LIMIT reached).
    label_done: i32 = 0,
    /// Jump here when the sorter is full.
    label_ob_lopt: i32 = 0,
    sort_flags: u8 = 0,
    deferred_row_load: ?*RowLoadInfo = null,
};

/// SORTFLAG_UseSorter: OP_SorterOpen instead of OP_OpenEphemeral.
const SORTFLAG_UseSorter: u8 = 0x01;

/// Port of RowLoadInfo: what is needed to load a result row into the
/// sorter later.
const RowLoadInfo = struct {
    reg_result: i32,
    ecel_flags: u8,
};

/// Port of innerLoopLoadRow().
fn innerLoopLoadRow(p: *Parse, s: *Select, info: *RowLoadInfo) void {
    _ = ec.codeExprList(p, s.e_list.?, info.reg_result, 0, info.ecel_flags);
}

/// Port of makeSorterRecord(): the OP_MakeRecord of a sorter entry;
/// returns its register.
fn makeSorterRecord(p: *Parse, sort: *SortCtx, s: *Select, reg_base: i32, n_base: i32) i32 {
    const n_ob_sat = sort.n_ob_sat;
    const v = p.vdbe.?;
    p.n_mem += 1;
    const reg_out = p.n_mem;
    if (sort.deferred_row_load) |d| innerLoopLoadRow(p, s, d);
    _ = aux.addOp3(v, OP.MakeRecord, reg_base + n_ob_sat, n_base - n_ob_sat, reg_out);
    return reg_out;
}

/// Port of pushOntoSorter(): add registers reg_data..+n_data to the
/// sorter, with the sort key in front.
fn pushOntoSorter(p: *Parse, sort: *SortCtx, s: *Select, reg_data: i32, reg_orig_data: i32, n_data: i32, n_prefix_reg: i32) void {
    const v = p.vdbe.?;
    const b_seq: i32 = @intFromBool(sort.sort_flags & SORTFLAG_UseSorter == 0);
    const n_expr: i32 = @intCast(sort.order_by.?.len());
    const n_base = n_expr + b_seq + n_data;
    var reg_record: i32 = 0;
    const n_ob_sat = sort.n_ob_sat;
    var i_skip: i32 = 0;

    var reg_base: i32 = undefined;
    if (n_prefix_reg != 0) {
        reg_base = reg_data - n_prefix_reg;
    } else {
        reg_base = p.n_mem + 1;
        p.n_mem += n_base;
    }
    const i_limit = if (s.i_offset != 0) s.i_offset + 1 else s.i_limit;
    sort.label_done = aux.makeLabel(p);
    _ = ec.codeExprList(p, sort.order_by.?, reg_base, reg_orig_data, ec.ECEL_DUP | (if (reg_orig_data != 0) ec.ECEL_REF else 0));
    if (b_seq != 0) _ = aux.addOp2(v, OP.Sequence, sort.i_e_cursor, reg_base + n_expr);
    if (n_prefix_reg == 0 and n_data > 0) ec.codeMove(p, reg_data, reg_base + n_expr + b_seq, n_data);
    if (n_ob_sat > 0) {
        reg_record = makeSorterRecord(p, sort, s, reg_base, n_base);
        const reg_prev_key = p.n_mem + 1;
        p.n_mem += sort.n_ob_sat;
        const n_key = n_expr - sort.n_ob_sat + b_seq;
        const addr_first = if (b_seq != 0)
            aux.addOp1(v, OP.IfNot, reg_base + n_expr)
        else
            aux.addOp1(v, OP.SequenceTest, sort.i_e_cursor);
        _ = aux.addOp3(v, OP.Compare, reg_prev_key, reg_base, sort.n_ob_sat);
        if (p.db.malloc_failed) return;
        const op = aux.getOp(v, sort.addr_sort_index);
        op.p2 = n_key + n_data;
        const ki = op.p4.keyinfo;
        @memset(ki.sort_flags[0..ki.n_key_field], 0);
        aux.changeP4(v, -1, .{ .keyinfo = ki });
        if (keyInfoFromExprList(p, sort.order_by.?, @intCast(n_ob_sat), ki.n_all_field - ki.n_key_field - 1)) |k| {
            aux.getOp(v, sort.addr_sort_index).setP4(.{ .keyinfo = k });
        }
        const addr_jmp = aux.currentAddr(v);
        _ = aux.addOp3(v, OP.Jump, addr_jmp + 1, 0, addr_jmp + 1);
        sort.label_bk_out = aux.makeLabel(p);
        p.n_mem += 1;
        sort.reg_return = p.n_mem;
        _ = aux.addOp2(v, OP.Gosub, sort.reg_return, sort.label_bk_out);
        _ = aux.addOp1(v, OP.ResetSorter, sort.i_e_cursor);
        if (i_limit != 0) _ = aux.addOp2(v, OP.IfNot, i_limit, sort.label_done);
        aux.jumpHere(v, addr_first);
        ec.codeMove(p, reg_base, reg_prev_key, sort.n_ob_sat);
        aux.jumpHere(v, addr_jmp);
    }
    if (i_limit != 0) {
        // Keep at most LIMIT+OFFSET entries: replace the largest by a
        // smaller one, or skip the row.
        const i_csr = sort.i_e_cursor;
        _ = aux.addOp2(v, OP.IfNotZero, i_limit, aux.currentAddr(v) + 4);
        _ = aux.addOp2(v, OP.Last, i_csr, 0);
        i_skip = aux.addOp4Int(v, OP.IdxLE, i_csr, 0, reg_base + n_ob_sat, n_expr - n_ob_sat);
        _ = aux.addOp1(v, OP.Delete, i_csr);
    }
    if (reg_record == 0) reg_record = makeSorterRecord(p, sort, s, reg_base, n_base);
    const op: OP = if (sort.sort_flags & SORTFLAG_UseSorter != 0) OP.SorterInsert else OP.IdxInsert;
    _ = aux.addOp4Int(v, op, sort.i_e_cursor, reg_record, reg_base + n_ob_sat, n_base - n_ob_sat);
    if (i_skip != 0) {
        aux.changeP2(v, i_skip, if (sort.label_ob_lopt != 0) sort.label_ob_lopt else aux.currentAddr(v));
    }
}

/// Port of codeOffset(): skip the row while the OFFSET counter is
/// positive.
fn codeOffset(v: *Vdbe, i_offset: i32, i_continue: i32) void {
    if (i_offset > 0) _ = aux.addOp3(v, OP.IfPos, i_offset, i_continue, 1);
}

/// Port of codeDistinct(): code the DISTINCT test of the row in
/// registers from `reg_elem`, jumping to `addr_repeat` for a duplicate.
/// Returns the table (or previous-row registers) used.
fn codeDistinct(p: *Parse, e_tnct_type: int.WHERE_DISTINCT, i_tab: i32, addr_repeat: i32, e_list: *ExprList, reg_elem: i32) i32 {
    var ret: i32 = 0;
    const n_result_col: i32 = @intCast(e_list.len());
    const v = p.vdbe.?;
    switch (e_tnct_type) {
        int.WHERE_DISTINCT.ORDERED => {
            // Compare with the previous row.
            const reg_prev = p.n_mem + 1;
            ret = reg_prev;
            p.n_mem += n_result_col;
            const i_jump = aux.currentAddr(v) + n_result_col;
            for (e_list.slice(), 0..) |item, ii| {
                const i: i32 = @intCast(ii);
                const coll = expr_mod.collSeq(p, item.expr);
                if (i < n_result_col - 1) {
                    _ = aux.addOp3(v, OP.Ne, reg_elem + i, i_jump, reg_prev + i);
                } else {
                    _ = aux.addOp3(v, OP.Eq, reg_elem + i, addr_repeat, reg_prev + i);
                }
                if (coll) |c| aux.changeP4(v, -1, .{ .collseq = c });
                aux.changeP5(v, vi.SQLITE_NULLEQ);
            }
            _ = aux.addOp3(v, OP.Copy, reg_elem, reg_prev, n_result_col - 1);
        },
        int.WHERE_DISTINCT.UNIQUE => {},
        else => {
            const r1 = expr_mod.getTempReg(p);
            _ = aux.addOp4Int(v, OP.Found, i_tab, addr_repeat, reg_elem, n_result_col);
            _ = aux.addOp3(v, OP.MakeRecord, reg_elem, n_result_col, r1);
            _ = aux.addOp4Int(v, OP.IdxInsert, i_tab, r1, reg_elem, n_result_col);
            aux.changeP5(v, OPFLAG.USESEEKRESULT);
            expr_mod.releaseTempReg(p, r1);
            ret = i_tab;
        },
    }
    return ret;
}

/// Port of fixDistinctOpenEph(): the ephemeral table of a DISTINCT that
/// turned out not to need one becomes a no-op (or the OP_Null that
/// clears the previous-row registers).
fn fixDistinctOpenEph(p: *Parse, e_tnct_type: int.WHERE_DISTINCT, i_val: i32, i_open_eph_addr: i32) void {
    if (p.n_err == 0 and (e_tnct_type == int.WHERE_DISTINCT.UNIQUE or e_tnct_type == int.WHERE_DISTINCT.ORDERED)) {
        const v = p.vdbe.?;
        _ = aux.changeToNoop(v, i_open_eph_addr);
        if (aux.getOp(v, i_open_eph_addr + 1).opcode == OP.Explain) _ = aux.changeToNoop(v, i_open_eph_addr + 1);
        if (e_tnct_type == int.WHERE_DISTINCT.ORDERED) {
            // OP_Null with MEM_Cleared: the first comparison always fails.
            const op = aux.getOp(v, i_open_eph_addr);
            op.opcode = OP.Null;
            op.p1 = 1;
            op.p2 = i_val;
        }
    }
}

/// Port of selectInnerLoop(): the inside of the loop of a SELECT: compute
/// the row (or read it from `src_tab` if not negative), apply DISTINCT,
/// OFFSET and LIMIT, and send it to `dest` (or the sorter).
fn selectInnerLoop(p: *Parse, s: *Select, src_tab: i32, sort_arg: ?*SortCtx, distinct: ?*DistinctCtx, dest: *SelectDest, i_continue: i32, i_break: i32) void {
    const v = p.vdbe.?;
    const e_dest = dest.e_dest;
    const i_parm = dest.i_sd_parm;
    var n_prefix_reg: i32 = 0;
    var row_load: RowLoadInfo = undefined;
    var sort = sort_arg;
    const has_distinct: int.WHERE_DISTINCT = if (distinct) |d| d.e_tnct_type else int.WHERE_DISTINCT.NOOP;
    if (sort) |so| if (so.order_by == null) {
        sort = null;
    };
    if (sort == null and has_distinct == .NOOP) codeOffset(v, s.i_offset, i_continue);

    var n_result_col: i32 = @intCast(s.e_list.?.len());
    if (dest.i_sdst == 0) {
        if (sort) |so| {
            n_prefix_reg = @intCast(so.order_by.?.len());
            if (so.sort_flags & SORTFLAG_UseSorter == 0) n_prefix_reg += 1;
            p.n_mem += n_prefix_reg;
        }
        dest.i_sdst = p.n_mem + 1;
        p.n_mem += n_result_col;
    } else if (dest.i_sdst + n_result_col > p.n_mem) {
        // Too many result columns for the destination; the error is
        // reported later.
        p.n_mem += n_result_col;
    }
    dest.n_sdst = n_result_col;
    const reg_result = dest.i_sdst;
    var reg_orig = reg_result;
    if (src_tab >= 0) {
        for (0..@intCast(n_result_col)) |i| {
            _ = aux.addOp3(v, OP.Column, src_tab, @intCast(i), reg_result + @as(i32, @intCast(i)));
        }
    } else if (e_dest != SRT.Exists) {
        var ecel_flags: u8 = if (e_dest == SRT.Mem or e_dest == SRT.Output or e_dest == SRT.Coroutine) ec.ECEL_DUP else 0;
        if (sort != null and has_distinct == .NOOP and e_dest != SRT.EphemTab and e_dest != SRT.Table) {
            // Result columns that are also ORDER BY terms are not stored
            // twice in the sorter record.
            const so = sort.?;
            ecel_flags |= ec.ECEL_OMITREF | ec.ECEL_REF;
            var i: usize = @intCast(so.n_ob_sat);
            while (i < so.order_by.?.len()) : (i += 1) {
                const j = so.order_by.?.at(i).u.x.order_by_col;
                if (j > 0) s.e_list.?.at(j - 1).u.x.order_by_col = @intCast(i + 1 - @as(usize, @intCast(so.n_ob_sat)));
            }
            for (s.e_list.?.slice()) |item| {
                if (item.u.x.order_by_col > 0) {
                    n_result_col -= 1;
                    reg_orig = 0;
                }
            }
        }
        row_load = .{ .reg_result = reg_result, .ecel_flags = ecel_flags };
        if (s.i_limit != 0 and ecel_flags & ec.ECEL_OMITREF != 0 and n_prefix_reg > 0) {
            sort.?.deferred_row_load = &row_load;
            reg_orig = 0;
        } else {
            innerLoopLoadRow(p, s, &row_load);
        }
    }

    // Skip a row seen before.
    if (has_distinct != .NOOP) {
        const d = distinct.?;
        const i_tab = codeDistinct(p, d.e_tnct_type, d.tab_tnct, i_continue, s.e_list.?, reg_result);
        fixDistinctOpenEph(p, d.e_tnct_type, i_tab, d.addr_tnct);
        if (sort == null) codeOffset(v, s.i_offset, i_continue);
    }

    switch (e_dest) {
        SRT.Fifo, SRT.DistFifo, SRT.Table, SRT.EphemTab => {
            // Store the row as data with a new rowid.
            const r1 = expr_mod.getTempRange(p, n_prefix_reg + 1);
            _ = aux.addOp3(v, OP.MakeRecord, reg_result, n_result_col, r1 + n_prefix_reg);
            if (e_dest == SRT.DistFifo) {
                // Cursor i_parm+1 holds the rows already written.
                const addr = aux.currentAddr(v) + 4;
                _ = aux.addOp4Int(v, OP.Found, i_parm + 1, addr, r1, 0);
                _ = aux.addOp4Int(v, OP.IdxInsert, i_parm + 1, r1, reg_result, n_result_col);
            }
            if (sort) |so| {
                pushOntoSorter(p, so, s, r1 + n_prefix_reg, reg_orig, 1, n_prefix_reg);
            } else {
                const r2 = expr_mod.getTempReg(p);
                _ = aux.addOp2(v, OP.NewRowid, i_parm, r2);
                _ = aux.addOp3(v, OP.Insert, i_parm, r1, r2);
                aux.changeP5(v, OPFLAG.APPEND);
                expr_mod.releaseTempReg(p, r2);
            }
            expr_mod.releaseTempRange(p, r1, n_prefix_reg + 1);
        },
        SRT.Upfrom => {
            if (sort) |so| {
                pushOntoSorter(p, so, s, reg_result, reg_orig, n_result_col, n_prefix_reg);
            } else {
                const i_2 = dest.i_sd_parm2;
                const r1 = expr_mod.getTempReg(p);
                // An aggregate matching no rows still makes one; skip it.
                _ = aux.addOp2(v, OP.IsNull, reg_result, i_break);
                _ = aux.addOp3(v, OP.MakeRecord, reg_result + @intFromBool(i_2 < 0), n_result_col - @intFromBool(i_2 < 0), r1);
                if (i_2 < 0) {
                    _ = aux.addOp3(v, OP.Insert, i_parm, r1, reg_result);
                } else {
                    _ = aux.addOp4Int(v, OP.IdxInsert, i_parm, r1, reg_result, i_2);
                }
            }
        },
        SRT.Set => {
            // The keys of the set of "expr IN (SELECT ...)".
            if (sort) |so| {
                // The ORDER BY matters if there is a LIMIT.
                pushOntoSorter(p, so, s, reg_result, reg_orig, n_result_col, n_prefix_reg);
                dest.i_sd_parm2 = 0;
            } else {
                const r1 = expr_mod.getTempReg(p);
                _ = aux.addOp4Str(v, OP.MakeRecord, reg_result, n_result_col, r1, dest.aff_sdst.?);
                _ = aux.addOp4Int(v, OP.IdxInsert, i_parm, r1, reg_result, n_result_col);
                if (dest.i_sd_parm2 != 0) {
                    _ = aux.addOp4Int(v, OP.FilterAdd, dest.i_sd_parm2, 0, reg_result, n_result_col);
                    _ = aux.explain(p, false, "CREATE BLOOM FILTER", .{});
                }
                expr_mod.releaseTempReg(p, r1);
            }
        },
        SRT.Exists => {
            // The LIMIT ends the loop.
            _ = aux.addOp2(v, OP.Integer, 1, i_parm);
        },
        SRT.Mem => {
            // A scalar subquery.
            if (sort) |so| {
                pushOntoSorter(p, so, s, reg_result, reg_orig, n_result_col, n_prefix_reg);
                dest.i_sd_parm = reg_result;
            } else if (reg_result != i_parm) {
                // With DISTINCT and OFFSET.
                _ = aux.addOp3(v, OP.Copy, reg_result, i_parm, n_result_col - 1);
            }
        },
        SRT.Coroutine, SRT.Output => {
            if (sort) |so| {
                pushOntoSorter(p, so, s, reg_result, reg_orig, n_result_col, n_prefix_reg);
            } else if (e_dest == SRT.Coroutine) {
                _ = aux.addOp1(v, OP.Yield, dest.i_sd_parm);
            } else {
                _ = aux.addOp2(v, OP.ResultRow, reg_result, n_result_col);
            }
        },
        SRT.DistQueue, SRT.Queue => {
            // A priority queue ordered by dest.order_by, made unique by an
            // OP_Sequence column; the record is the last column.
            const so = dest.order_by.?;
            const n_key: i32 = @intCast(so.len());
            const r1 = expr_mod.getTempReg(p);
            const r2 = expr_mod.getTempRange(p, n_key + 2);
            const r3 = r2 + n_key + 1;
            var addr_test: i32 = 0;
            if (e_dest == SRT.DistQueue) {
                // Cursor i_parm+1 holds every row ever queued.
                addr_test = aux.addOp4Int(v, OP.Found, i_parm + 1, 0, reg_result, n_result_col);
            }
            _ = aux.addOp3(v, OP.MakeRecord, reg_result, n_result_col, r3);
            if (e_dest == SRT.DistQueue) {
                _ = aux.addOp2(v, OP.IdxInsert, i_parm + 1, r3);
                aux.changeP5(v, OPFLAG.USESEEKRESULT);
            }
            for (so.slice(), 0..) |item, i| {
                _ = aux.addOp2(v, OP.SCopy, reg_result + @as(i32, item.u.x.order_by_col) - 1, r2 + @as(i32, @intCast(i)));
            }
            _ = aux.addOp2(v, OP.Sequence, i_parm, r2 + n_key);
            _ = aux.addOp3(v, OP.MakeRecord, r2, n_key + 2, r1);
            _ = aux.addOp4Int(v, OP.IdxInsert, i_parm, r1, r2, n_key + 2);
            if (addr_test != 0) aux.jumpHere(v, addr_test);
            expr_mod.releaseTempReg(p, r1);
            expr_mod.releaseTempRange(p, r2, n_key + 2);
        },
        else => {
            // SRT_Discard: a SELECT in a trigger, run for its side effects.
            std.debug.assert(e_dest == SRT.Discard);
        },
    }

    // Stop at the LIMIT, unless the sorter already applies it.
    if (sort == null and s.i_limit != 0) _ = aux.addOp2(v, OP.DecrJumpZero, s.i_limit, i_break);
}

/// Port of sqlite3KeyInfoFromExprList(): a KeyInfo with the collation and
/// order of each term of `list` from `start`, plus `n_extra` columns.
pub fn keyInfoFromExprList(p: *Parse, list: *ExprList, start: usize, n_extra: usize) ?*KeyInfo {
    const n_expr = list.len();
    const info = keyInfoAlloc(p, n_expr - start, n_extra + 1) orelse return null;
    for (list.slice()[start..], 0..) |item, i| {
        info.coll[i] = expr_mod.nnCollSeq(p, item.expr);
        info.sort_flags[i] = item.fg.sort_flags;
    }
    return info;
}

/// Port of generateSortTail(): after the loop, read the sorted rows back
/// and send them to `dest`.
fn generateSortTail(p: *Parse, s: *Select, sort: *SortCtx, n_column_arg: i32, dest: *SelectDest) void {
    const v = p.vdbe.?;
    var n_column = n_column_arg;
    const addr_break = sort.label_done;
    const addr_continue = aux.makeLabel(p);
    var addr_once: i32 = 0;
    const order_by = sort.order_by.?;
    const e_dest = dest.e_dest;
    const i_parm = dest.i_sd_parm;
    const out_ex = s.e_list.?.slice();
    const n_key: i32 = @as(i32, @intCast(order_by.len())) - sort.n_ob_sat;

    if (sort.n_ob_sat == 0 or n_key == 1) {
        _ = aux.explain(p, false, "USE TEMP B-TREE FOR {s}ORDER BY", .{if (sort.n_ob_sat != 0) "LAST TERM OF " else ""});
    } else {
        _ = aux.explain(p, false, "USE TEMP B-TREE FOR LAST {d} TERMS OF ORDER BY", .{n_key});
    }
    if (sort.label_bk_out != 0) {
        _ = aux.addOp2(v, OP.Gosub, sort.reg_return, sort.label_bk_out);
        _ = aux.goto_(v, addr_break);
        aux.resolveLabel(v, sort.label_bk_out);
    }

    const i_tab = sort.i_e_cursor;
    var reg_rowid: i32 = 0;
    var reg_row: i32 = undefined;
    if (e_dest == SRT.Output or e_dest == SRT.Coroutine or e_dest == SRT.Mem) {
        if (e_dest == SRT.Mem and s.i_offset != 0) _ = aux.addOp2(v, OP.Null, 0, dest.i_sdst);
        reg_row = dest.i_sdst;
    } else {
        reg_rowid = expr_mod.getTempReg(p);
        if (e_dest == SRT.EphemTab or e_dest == SRT.Table) {
            reg_row = expr_mod.getTempReg(p);
            n_column = 0;
        } else {
            reg_row = expr_mod.getTempRange(p, n_column);
        }
    }
    var i_sort_tab: i32 = undefined;
    var addr: i32 = undefined;
    var b_seq: i32 = undefined;
    if (sort.sort_flags & SORTFLAG_UseSorter != 0) {
        p.n_mem += 1;
        const reg_sort_out = p.n_mem;
        i_sort_tab = p.n_tab;
        p.n_tab += 1;
        if (sort.label_bk_out != 0) addr_once = aux.addOp0(v, OP.Once);
        _ = aux.addOp3(v, OP.OpenPseudo, i_sort_tab, reg_sort_out, n_key + 1 + n_column);
        if (addr_once != 0) aux.jumpHere(v, addr_once);
        addr = 1 + aux.addOp2(v, OP.SorterSort, i_tab, addr_break);
        _ = aux.addOp3(v, OP.SorterData, i_tab, reg_sort_out, i_sort_tab);
        b_seq = 0;
    } else {
        addr = 1 + aux.addOp2(v, OP.Sort, i_tab, addr_break);
        codeOffset(v, s.i_offset, addr_continue);
        i_sort_tab = i_tab;
        b_seq = 1;
        if (s.i_offset > 0) _ = aux.addOp2(v, OP.AddImm, s.i_limit, -1);
    }
    var i_col: i32 = n_key + b_seq - 1;
    for (out_ex[0..@intCast(n_column)]) |item| {
        if (item.u.x.order_by_col == 0) i_col += 1;
    }
    var i: i32 = n_column - 1;
    while (i >= 0) : (i -= 1) {
        const item = out_ex[@intCast(i)];
        var i_read: i32 = undefined;
        if (item.u.x.order_by_col != 0) {
            i_read = @as(i32, item.u.x.order_by_col) - 1;
        } else {
            i_read = i_col;
            i_col -= 1;
        }
        _ = aux.addOp3(v, OP.Column, i_sort_tab, i_read, reg_row + i);
    }
    switch (e_dest) {
        SRT.Table, SRT.EphemTab => {
            _ = aux.addOp3(v, OP.Column, i_sort_tab, n_key + b_seq, reg_row);
            _ = aux.addOp2(v, OP.NewRowid, i_parm, reg_rowid);
            _ = aux.addOp3(v, OP.Insert, i_parm, reg_row, reg_rowid);
            aux.changeP5(v, OPFLAG.APPEND);
        },
        SRT.Set => {
            _ = aux.addOp4Str(v, OP.MakeRecord, reg_row, n_column, reg_rowid, dest.aff_sdst.?);
            _ = aux.addOp4Int(v, OP.IdxInsert, i_parm, reg_rowid, reg_row, n_column);
        },
        SRT.Mem => {
            // The LIMIT ends the loop.
        },
        SRT.Upfrom => {
            const i_2 = dest.i_sd_parm2;
            const r1 = expr_mod.getTempReg(p);
            _ = aux.addOp3(v, OP.MakeRecord, reg_row + @intFromBool(i_2 < 0), n_column - @intFromBool(i_2 < 0), r1);
            if (i_2 < 0) {
                _ = aux.addOp3(v, OP.Insert, i_parm, r1, reg_row);
            } else {
                _ = aux.addOp4Int(v, OP.IdxInsert, i_parm, r1, reg_row, i_2);
            }
        },
        else => {
            if (e_dest == SRT.Output) {
                _ = aux.addOp2(v, OP.ResultRow, dest.i_sdst, n_column);
            } else {
                _ = aux.addOp1(v, OP.Yield, dest.i_sd_parm);
            }
        },
    }
    if (reg_rowid != 0) {
        if (e_dest == SRT.Set) {
            expr_mod.releaseTempRange(p, reg_row, n_column);
        } else {
            expr_mod.releaseTempReg(p, reg_row);
        }
        expr_mod.releaseTempReg(p, reg_rowid);
    }
    // The bottom of the loop.
    aux.resolveLabel(v, addr_continue);
    if (sort.sort_flags & SORTFLAG_UseSorter != 0) {
        _ = aux.addOp2(v, OP.SorterNext, i_tab, addr);
    } else {
        _ = aux.addOp2(v, OP.Next, i_tab, addr);
    }
    if (sort.reg_return != 0) _ = aux.addOp1(v, OP.Return, sort.reg_return);
    aux.resolveLabel(v, addr_break);
}

/// Port of columnTypeImpl(): the declared type of a result expression
/// that is (through subqueries) a table column; INTEGER for a rowid.
fn columnType(nc_arg: *NameContext, e: *Expr) ?[:0]const u8 {
    switch (e.op) {
        TK.COLUMN => {
            // Find the table (or subquery) of the column.
            var t: ?*Table = null;
            var sub: ?*Select = null;
            var nc: ?*NameContext = nc_arg;
            const i_col = e.i_column;
            search: while (nc) |n| {
                for (n.src_list.?.slice()) |*item| {
                    if (item.i_cursor == e.i_table) {
                        t = item.s_tab;
                        sub = if (item.fg.is_subquery) item.u4.subq.?.select else null;
                        break :search;
                    }
                }
                nc = n.next;
            }
            const tab = t orelse return null;
            if (sub) |ss| {
                // The type of the subquery's result column (a rowid of a
                // view is always NULL).
                if (i_col >= 0 and i_col < ss.e_list.?.len()) {
                    var snc: NameContext = .{ .parse = nc_arg.parse, .src_list = ss.src, .next = nc };
                    return columnType(&snc, ss.e_list.?.at(@intCast(i_col)).expr.?);
                }
                return null;
            }
            if (i_col < 0) return "INTEGER";
            const z = build.columnType(&tab.cols[@intCast(i_col)], "");
            return if (z.len == 0) null else z;
        },
        TK.SELECT => {
            // The type of the single result column of the subquery.
            const ss = e.x.select.?;
            var snc: NameContext = .{ .parse = nc_arg.parse, .src_list = ss.src, .next = nc_arg };
            return columnType(&snc, ss.e_list.?.at(0).expr.?);
        },
        else => return null,
    }
}

/// Port of generateColumnTypes(): the declared types of the result
/// columns (sqlite3_column_decltype()).
fn generateColumnTypes(p: *Parse, tab_list: *SrcList, e_list: *ExprList) void {
    const v = p.vdbe.?;
    var nc: NameContext = .{ .parse = p, .src_list = tab_list };
    for (e_list.slice(), 0..) |item, i| {
        const z = columnType(&nc, item.expr.?) orelse continue;
        if (z.len == 0) continue;
        aux.setColName(v, i, vi.COLNAME_DECLTYPE, z);
    }
}

/// Port of sqlite3GenerateColumnNames(): the names of the result columns:
/// the AS name, else the column name for a direct column reference (or
/// TABLE.COLUMN with full_column_names), else the expression's text.
pub fn generateColumnNames(p: *Parse, s_arg: *Select) void {
    const v = p.vdbe.?;
    const db = p.db;
    if (p.col_names_set) return;
    // Names come from the leftmost term of a compound.
    var s = s_arg;
    while (s.prior) |pr| s = pr;
    const tab_list = s.src.?;
    const e_list = s.e_list.?;
    p.col_names_set = true;
    const full_name = db.flags.FullColNames;
    const src_name = db.flags.ShortColNames or full_name;
    aux.setNumCols(v, @intCast(e_list.len()));
    for (e_list.slice(), 0..) |item, i| {
        const e = item.expr.?;
        if (item.e_name != null and item.fg.e_ename == .name) {
            aux.setColName(v, i, vi.COLNAME_NAME, item.e_name.?);
        } else if (src_name and e.op == TK.COLUMN) {
            const t = e.y.tab.?;
            var i_col = e.i_column;
            if (i_col < 0) i_col = t.i_pkey;
            const col: [:0]const u8 = if (i_col < 0) "rowid" else t.cols[@intCast(i_col)].name();
            if (full_name) {
                const z = std.fmt.allocPrintSentinel(p.arena, "{s}.{s}", .{ t.name, col }, 0) catch return oom(p);
                aux.setColName(v, i, vi.COLNAME_NAME, z);
            } else {
                aux.setColName(v, i, vi.COLNAME_NAME, col);
            }
        } else if (item.e_name) |z| {
            aux.setColName(v, i, vi.COLNAME_NAME, z);
        } else {
            const z = std.fmt.allocPrintSentinel(p.arena, "column{d}", .{i + 1}, 0) catch return oom(p);
            aux.setColName(v, i, vi.COLNAME_NAME, z);
        }
    }
    generateColumnTypes(p, tab_list, e_list);
}

/// Port of sqlite3ColumnsFromExprList(): unique column names for a table
/// holding the result set `e_list`, allocated from `a`.
pub fn columnsFromExprList(p: *Parse, a: Allocator, e_list: ?*ExprList) Oom![]Column {
    const list = e_list orelse return &.{};
    const n_col = @min(list.len(), 32767);
    const cols = try a.alloc(Column, n_col);
    var ht: int.NameMap(*ExprListItem) = .empty;
    defer ht.deinit(p.db.gpa);
    for (cols, 0..) |*col, i| {
        if (p.n_err != 0) break;
        const x = list.at(i);
        col.* = .{ .cn_name = undefined };
        var name: ?[]const u8 = null;
        if (x.e_name != null and x.fg.e_ename == .name) {
            name = x.e_name.?;
        } else {
            var ce = expr_mod.skipCollateAndLikely(x.expr).?;
            while (ce.op == TK.DOT) ce = ce.right.?;
            if (ce.op == TK.COLUMN and ce.y.tab != null) {
                const t = ce.y.tab.?;
                var i_col = ce.i_column;
                if (i_col < 0) i_col = t.i_pkey;
                name = if (i_col >= 0) t.cols[@intCast(i_col)].name() else "rowid";
            } else if (ce.op == TK.ID) {
                name = ce.token();
            } else {
                name = x.e_name;
            }
        }
        var z: [:0]u8 = if (name != null and util.isTrueOrFalse(name.?).isEmpty())
            try a.dupeSentinel(u8, name.?, 0)
        else
            try std.fmt.allocPrintSentinel(a, "column{d}", .{i + 1}, 0);

        // Make the name unique by appending ":N".
        var cnt: u32 = 0;
        while (ht.get(z)) |collide| {
            if (collide.fg.using_term) col.col_flags.NOEXPAND = true;
            var n_name = z.len;
            if (n_name > 0) {
                var j = n_name - 1;
                while (j > 0 and ctype.isDigit(z[j])) j -= 1;
                if (z[j] == ':') n_name = j;
            }
            cnt += 1;
            z = try std.fmt.allocPrintSentinel(a, "{s}:{d}", .{ z[0..n_name], cnt }, 0);
            if (cnt > 3) @import("func.zig").randomness(p.db, std.mem.asBytes(&cnt));
        }
        col.cn_name = z;
        if (x.fg.no_expand) col.col_flags.NOEXPAND = true;
        try ht.put(p.db.gpa, z, x);
    }
    return cols;
}

/// Port of sqlite3SubqueryColumnTypes(): the declared types, collations
/// and affinities of the columns of `t`, the table of subquery `s`.
pub fn subqueryColumnTypes(p: *Parse, a: std.mem.Allocator, t: *Table, s_arg: *Select, default_aff: u8) Oom!void {
    if (p.db.malloc_failed or p.inRenameObject()) return;
    var s = s_arg;
    while (s.prior) |pr| s = pr;
    const items = s.e_list.?.slice();
    var nc: NameContext = .{ .parse = p, .src_list = s.src };
    for (t.cols, 0..) |*col, i| {
        var m: u8 = 0;
        var s2 = s;
        t.tab_flags.set(.ofColumn(col.col_flags));
        const e = items[i].expr.?;
        col.affinity = expr_mod.affinity(e);
        while (col.affinity <= Aff.none and s2.next != null) {
            m |= expr_mod.dataType(s2.e_list.?.at(i).expr);
            s2 = s2.next.?;
            col.affinity = expr_mod.affinity(s2.e_list.?.at(i).expr.?);
        }
        if (col.affinity <= Aff.none) col.affinity = default_aff;
        if (col.affinity >= Aff.text and (s2.next != null or s2 != s)) {
            var it = s2.next;
            while (it) |s3| : (it = s3.next) m |= expr_mod.dataType(s3.e_list.?.at(i).expr);
            if (col.affinity == Aff.text and m & 0x01 != 0) {
                col.affinity = Aff.blob;
            } else if (col.affinity >= Aff.numeric and m & 0x02 != 0) {
                col.affinity = Aff.blob;
            }
            if (col.affinity >= Aff.numeric and e.op == TK.CAST) col.affinity = Aff.flexnum;
        }
        var typ = columnType(&nc, e);
        if (typ == null or col.affinity != build.affinityType(typ.?, null)) {
            if (col.affinity == Aff.numeric or col.affinity == Aff.flexnum) {
                typ = "NUM";
            } else {
                typ = null;
                for (build.std_type_affinity[1..], 1..) |aff, j| {
                    if (aff == col.affinity) {
                        typ = build.std_type[j];
                        break;
                    }
                }
            }
        }
        if (typ) |zt| {
            const n = col.cn_name.len;
            const new = try a.allocSentinel(u8, n + zt.len + 1, 0);
            @memcpy(new[0..n], col.cn_name);
            new[n] = 0;
            @memcpy(new[n + 1 ..], zt);
            col.cn_name = new[0..n :0];
            col.col_flags.clear(.{ .HASTYPE = true, .HASCOLL = true });
            col.col_flags.HASTYPE = true;
        }
        if (expr_mod.collSeq(p, e)) |c| try build.columnSetColl(a, col, c.name);
    }
    t.sz_tab_row = 1;
}

/// Port of checkSubqueryNestingDepth().
fn checkSubqueryNestingDepth(p: *Parse) bool {
    if (p.n_nest_sel >= p.db.limit(.expr_depth)) {
        util.errorMsg(p, "VIEWs and/or subqueries nested too deep", .{});
        return true;
    }
    return false;
}

/// Port of sqlite3ResultSetOfSelect(): a table (in the statement's
/// memory) describing the result set of `s`.
pub fn resultSetOfSelect(p: *Parse, s_arg: *Select, aff: u8) Oom!?*Table {
    const db = p.db;
    p.n_nest_sel += 1;
    if (checkSubqueryNestingDepth(p)) return null;
    const saved_flags = db.flags;
    db.flags.FullColNames = false;
    db.flags.ShortColNames = true;
    selectPrep(p, s_arg, null);
    db.flags = saved_flags;
    if (p.n_err != 0) return null;
    var s = s_arg;
    while (s.prior) |pr| s = pr;
    const t = try p.arena.create(Table);
    t.* = .{ .name = try p.arena.dupeSentinel(u8, "", 0), .n_row_log_est = 200 };
    t.cols = try columnsFromExprList(p, p.arena, s.e_list);
    t.n_nv_col = @intCast(t.cols.len);
    try subqueryColumnTypes(p, build.tableAlloc(p, t), t, s, aff);
    t.i_pkey = -1;
    if (db.malloc_failed) return null;
    p.n_nest_sel -= 1;
    return t;
}

/// Port of computeLimitRegisters(): code the LIMIT and OFFSET counters
/// (i_limit, i_offset, and i_offset+1 for LIMIT+OFFSET).
fn computeLimitRegisters(p: *Parse, s: *Select, i_break: i32) void {
    if (s.i_limit != 0) return;
    const limit = s.limit orelse return;
    std.debug.assert(limit.op == TK.LIMIT);
    p.n_mem += 1;
    const i_limit = p.n_mem;
    s.i_limit = i_limit;
    const v = build.getVdbe(p).?;
    if (expr_mod.isInteger(limit.left, p)) |n| {
        _ = aux.addOp2(v, OP.Integer, n, i_limit);
        if (n == 0) {
            _ = aux.goto_(v, i_break);
        } else if (n >= 0 and s.n_select_row > util.logEst(@intCast(n))) {
            s.n_select_row = util.logEst(@intCast(n));
            s.sel_flags.FixedLimit = true;
        }
    } else {
        ec.exprCode(p, limit.left, i_limit);
        _ = aux.addOp1(v, OP.MustBeInt, i_limit);
        @import("main.zig").mayAbort(p);
        _ = aux.addOp2(v, OP.IfNot, i_limit, i_break);
    }
    if (limit.right) |off| {
        p.n_mem += 1;
        const i_offset = p.n_mem;
        s.i_offset = i_offset;
        p.n_mem += 1;
        ec.exprCode(p, off, i_offset);
        _ = aux.addOp1(v, OP.MustBeInt, i_offset);
        @import("main.zig").mayAbort(p);
        _ = aux.addOp3(v, OP.OffsetLimit, i_limit, i_offset + 1, i_offset);
    }
}

/// Port of multiSelectCollSeq(): the collation of column `i_col` of a
/// compound: that of the leftmost term that has one.
fn multiSelectCollSeq(p: *Parse, s: *Select, i_col: usize) ?*CollSeq {
    var ret: ?*CollSeq = if (s.prior) |pr| multiSelectCollSeq(p, pr, i_col) else null;
    if (ret == null and i_col < s.e_list.?.len()) ret = expr_mod.collSeq(p, s.e_list.?.at(i_col).expr);
    return ret;
}

/// Port of multiSelectByMergeKeyInfo(): the KeyInfo of the ORDER BY of a
/// compound.
fn multiSelectByMergeKeyInfo(p: *Parse, s: *Select, n_extra: usize) ?*KeyInfo {
    const order_by = s.order_by;
    const n_order_by: usize = if (order_by) |ob| ob.len() else 0;
    const ret = keyInfoAlloc(p, n_order_by + n_extra, 1) orelse return null;
    for (0..n_order_by) |i| {
        const item = order_by.?.at(i);
        const term = item.expr.?;
        var c: *CollSeq = undefined;
        if (term.flags.Collate) {
            c = expr_mod.collSeq(p, term) orelse coll_mod.defaultColl();
        } else {
            c = multiSelectCollSeq(p, s, @as(usize, item.u.x.order_by_col) - 1) orelse coll_mod.defaultColl();
            item.expr = expr_mod.addCollateString(p, term, c.name) catch {
                oom(p);
                return null;
            };
        }
        ret.coll[i] = c;
        ret.sort_flags[i] = item.fg.sort_flags;
    }
    return ret;
}

/// Port of generateWithRecursiveQuery(): code a recursive CTE
/// "<setup> UNION [ALL] <recursive>": rows go through a Queue table, one
/// at a time becoming the content of the recursive table (Current) for a
/// run of the recursive part.
fn generateWithRecursiveQuery(p: *Parse, s: *Select, dest: *SelectDest) void {
    const src = s.src.?;
    var n_col: i32 = @intCast(s.e_list.?.len());
    const v = p.vdbe.?;
    var i_current: i32 = 0;
    var i_distinct: i32 = 0;

    if (s.win != null) {
        util.errorMsg(p, "cannot use window functions in recursive queries", .{});
        return;
    }

    // LIMIT and OFFSET.
    const addr_break = aux.makeLabel(p);
    s.n_select_row = 320;
    computeLimitRegisters(p, s, addr_break);
    const limit = s.limit;
    const reg_limit = s.i_limit;
    const reg_offset = s.i_offset;
    s.limit = null;
    s.i_limit = 0;
    s.i_offset = 0;
    const order_by = s.order_by;
    defer {
        s.order_by = order_by;
        s.limit = limit;
    }

    // The cursor of the Current table.
    for (src.slice()) |item| {
        if (item.fg.is_recursive) {
            i_current = item.i_cursor;
            break;
        }
    }

    // Cursors for Queue and Distinct; Distinct must be Queue+1 for
    // SRT_DistFifo and SRT_DistQueue.
    const i_queue = p.n_tab;
    p.n_tab += 1;
    var e_dest: SRT = undefined;
    if (s.op == TK.UNION) {
        e_dest = if (order_by != null) SRT.DistQueue else SRT.DistFifo;
        i_distinct = p.n_tab;
        p.n_tab += 1;
    } else {
        e_dest = if (order_by != null) SRT.Queue else SRT.Fifo;
    }
    var dest_queue = selectDestInit(e_dest, i_queue);

    p.n_mem += 1;
    const reg_current = p.n_mem;
    _ = aux.addOp3(v, OP.OpenPseudo, i_current, reg_current, n_col);
    if (order_by) |ob| {
        const ki = multiSelectByMergeKeyInfo(p, s, 1);
        _ = aux.addOp4(v, OP.OpenEphemeral, i_queue, @as(i32, @intCast(ob.len())) + 2, 0, if (ki) |k| .{ .keyinfo = k } else .notused);
        dest_queue.order_by = ob;
    } else {
        _ = aux.addOp2(v, OP.OpenEphemeral, i_queue, n_col);
    }
    if (i_distinct != 0) {
        // Keeps the recursive part's output distinct.
        n_col = @intCast(s.e_list.?.len());
        if (keyInfoAlloc(p, @intCast(n_col), 1)) |ki| {
            for (ki.coll[0..@intCast(n_col)], 0..) |*c, i| c.* = multiSelectCollSeq(p, s, i) orelse coll_mod.defaultColl();
            _ = aux.addOp4(v, OP.OpenEphemeral, i_distinct, n_col, 0, .{ .keyinfo = ki });
        }
    }

    s.order_by = null;

    // The recursive terms (marked UNION ALL: the Distinct table removes
    // duplicates), which may not be aggregates.
    var first_rec = s;
    while (true) {
        if (first_rec.sel_flags.Aggregate) {
            util.errorMsg(p, "recursive aggregate queries not supported", .{});
            return;
        }
        first_rec.op = TK.ALL;
        if (!first_rec.prior.?.sel_flags.Recursive) break;
        first_rec = first_rec.prior.?;
    }

    // The setup query fills the Queue.
    const setup = first_rec.prior.?;
    setup.next = null;
    _ = aux.explain(p, true, "SETUP", .{});
    const rc = select(p, setup, &dest_queue);
    setup.next = s;
    rc catch return;

    // Move the next row of the Queue to Current and output it.
    const addr_top = aux.addOp2(v, OP.Rewind, i_queue, addr_break);
    _ = aux.addOp1(v, OP.NullRow, i_current);
    if (order_by) |ob| {
        _ = aux.addOp3(v, OP.Column, i_queue, @as(i32, @intCast(ob.len())) + 1, reg_current);
    } else {
        _ = aux.addOp2(v, OP.RowData, i_queue, reg_current);
    }
    _ = aux.addOp1(v, OP.Delete, i_queue);

    const addr_cont = aux.makeLabel(p);
    codeOffset(v, reg_offset, addr_cont);
    selectInnerLoop(p, s, i_current, null, null, dest, addr_cont, addr_break);
    if (reg_limit != 0) _ = aux.addOp2(v, OP.DecrJumpZero, reg_limit, addr_break);
    aux.resolveLabel(v, addr_cont);

    // The recursive part, with Current as the recursive table, adds to the
    // Queue.
    first_rec.prior = null;
    _ = aux.explain(p, true, "RECURSIVE STEP", .{});
    select(p, s, &dest_queue) catch {};
    first_rec.prior = setup;

    // Until the Queue is empty.
    _ = aux.goto_(v, addr_top);
    aux.resolveLabel(v, addr_break);
}

/// Port of multiSelectValues(): a multi-row VALUES clause; each row is
/// coded in turn (only the first with LIMIT 1). Returns -1 if it has
/// window functions.
fn multiSelectValues(p: *Parse, s_arg: *Select, dest: *SelectDest) i32 {
    var s = s_arg;
    var n_row: i16 = 1;
    const show_all = s.limit == null;
    while (true) {
        if (s.win != null) return -1;
        const pr = s.prior orelse break;
        s = pr;
        if (show_all) n_row += 1;
    }
    _ = aux.explain(p, false, "SCAN {d} CONSTANT ROW{s}", .{ n_row, if (n_row == 1) "" else "S" });
    var it: ?*Select = s;
    while (it) |x| {
        selectInnerLoop(p, x, -1, null, null, dest, 1, 1);
        if (!show_all) break;
        x.n_select_row = n_row;
        it = x.next;
    }
    return 0;
}

/// Port of hasAnchor(): the recursive SELECT still has its anchor terms.
fn hasAnchor(s_arg: ?*Select) bool {
    var s = s_arg;
    while (s) |x| {
        if (!x.sel_flags.Recursive) break;
        s = x.prior;
    }
    return s != null;
}

/// Port of unionWithLimitOne(): a UNION with LIMIT 1 and no OFFSET.
fn unionWithLimitOne(db: *Sqlite3, s: *Select) bool {
    if (s.op != TK.UNION) return false;
    const limit = s.limit orelse return false;
    if (limit.right != null) return false;
    const v = expr_mod.isInteger(limit.left, null) orelse return false;
    if (v != 1) return false;
    if (db.optDisabled(int.OPT.UnionLimit)) return false;
    return true;
}

/// Port of multiSelect(): code a compound "A op B" (s is B, s.prior A).
/// UNION ALL runs one query after the other; the others merge sorted
/// results.
fn multiSelect(p: *Parse, s: *Select, dest_arg: *SelectDest) (Oom || int.ParseError)!void {
    const db = p.db;
    const prior = s.prior.?;
    var dest = dest_arg.*;
    const v = build.getVdbe(p).?;
    defer {
        dest_arg.i_sdst = dest.i_sdst;
        dest_arg.n_sdst = dest.n_sdst;
        dest_arg.i_sd_parm2 = dest.i_sd_parm2;
    }

    // Create the destination temporary table if necessary.
    if (dest.e_dest == SRT.EphemTab) {
        _ = aux.addOp2(v, OP.OpenEphemeral, dest.i_sd_parm, @intCast(s.e_list.?.len()));
        dest.e_dest = SRT.Table;
    }

    if (s.sel_flags.MultiValue) {
        if (multiSelectValues(p, s, &dest) >= 0) return;
    }

    if (s.sel_flags.Recursive and hasAnchor(s)) {
        generateWithRecursiveQuery(p, s, &dest);
    } else if (s.order_by != null) {
        {
            const r = multiSelectByMerge(p, s, dest_arg);
            dest = dest_arg.*;
            return r;
        }
    } else if (s.op != TK.ALL and !unionWithLimitOne(db, s)) {
        // The merge needs an ORDER BY: invent one.
        const one = try expr_mod.exprInt32(p.arena, 1);
        s.order_by = try expr_mod.listAppend(p, null, one);
        if (p.n_err != 0) return;
        s.order_by.?.at(0).u.x.order_by_col = 1;
        {
            const r = multiSelectByMerge(p, s, dest_arg);
            dest = dest_arg.*;
            return r;
        }
    } else {
        // UNION ALL (or UNION LIMIT 1): run the left query, then the
        // right one.
        var addr: i32 = 0;
        if (prior.prior == null) {
            _ = aux.explain(p, true, "COMPOUND QUERY", .{});
            _ = aux.explain(p, true, "LEFT-MOST SUBQUERY", .{});
        }
        prior.i_limit = s.i_limit;
        prior.i_offset = s.i_offset;
        prior.limit = try expr_mod.exprDup(p.arena, s.limit);
        const rc_prior = select(p, prior, &dest);
        prior.limit = null;
        try rc_prior;
        s.prior = null;
        s.i_limit = prior.i_limit;
        s.i_offset = prior.i_offset;
        if (s.i_limit != 0) {
            addr = aux.addOp1(v, OP.IfNot, s.i_limit);
            if (s.i_offset != 0) _ = aux.addOp3(v, OP.OffsetLimit, s.i_limit, s.i_offset + 1, s.i_offset);
        }
        _ = aux.explain(p, true, "UNION ALL", .{});
        const rc = select(p, s, &dest);
        s.prior = prior;
        s.n_select_row = util.logEstAdd(s.n_select_row, prior.n_select_row);
        if (s.limit) |lim| if (expr_mod.isInteger(lim.left, p)) |n_limit| {
            if (n_limit > 0 and s.n_select_row > util.logEst(@intCast(n_limit))) s.n_select_row = util.logEst(@intCast(n_limit));
        };
        if (addr != 0) aux.jumpHere(v, addr);
        if (s.next == null) aux.explainPop(p);
        return rc;
    }
}

/// Port of generateOutputSubroutine(): the subroutine sending a row of a
/// merge co-routine (`in`) to `dest`, skipping duplicates of the previous
/// output if `reg_prev` is set. Returns its address.
fn generateOutputSubroutine(p: *Parse, s: *Select, in: *SelectDest, dest: *SelectDest, reg_return: i32, reg_prev: i32, key_info: ?*KeyInfo, i_break: i32) i32 {
    const v = p.vdbe.?;
    std.debug.assert(in.e_dest == SRT.Coroutine);
    const addr = aux.currentAddr(v);
    const i_continue = aux.makeLabel(p);

    // UNION, EXCEPT and INTERSECT: skip a row equal to the previous one.
    if (reg_prev != 0) {
        const addr1 = aux.addOp1(v, OP.IfNot, reg_prev);
        const addr2 = aux.addOp4(v, OP.Compare, in.i_sdst, reg_prev + 1, in.n_sdst, if (key_info) |k| .{ .keyinfo = k } else .notused);
        _ = aux.addOp3(v, OP.Jump, addr2 + 2, i_continue, addr2 + 2);
        aux.jumpHere(v, addr1);
        _ = aux.addOp3(v, OP.Copy, in.i_sdst, reg_prev + 1, in.n_sdst - 1);
        _ = aux.addOp2(v, OP.Integer, 1, reg_prev);
    }
    if (p.db.malloc_failed) return 0;

    codeOffset(v, s.i_offset, i_continue);

    switch (dest.e_dest) {
        SRT.Fifo, SRT.DistFifo, SRT.Table, SRT.EphemTab => {
            const r1 = expr_mod.getTempReg(p);
            const r2 = expr_mod.getTempReg(p);
            const i_parm = dest.i_sd_parm;
            _ = aux.addOp3(v, OP.MakeRecord, in.i_sdst, in.n_sdst, r1);
            if (dest.e_dest == SRT.DistFifo) {
                // Populate the uniqueness index of the recursive phase.
                _ = aux.addOp4Int(v, OP.IdxInsert, i_parm + 1, r1, in.i_sdst, in.n_sdst);
            }
            _ = aux.addOp2(v, OP.NewRowid, i_parm, r2);
            _ = aux.addOp3(v, OP.Insert, i_parm, r1, r2);
            aux.changeP5(v, OPFLAG.APPEND);
            expr_mod.releaseTempReg(p, r2);
            expr_mod.releaseTempReg(p, r1);
        },
        SRT.Exists => _ = aux.addOp2(v, OP.Integer, 1, dest.i_sd_parm),
        SRT.Set => {
            const r1 = expr_mod.getTempReg(p);
            _ = aux.addOp4Str(v, OP.MakeRecord, in.i_sdst, in.n_sdst, r1, dest.aff_sdst.?);
            _ = aux.addOp4Int(v, OP.IdxInsert, dest.i_sd_parm, r1, in.i_sdst, in.n_sdst);
            if (dest.i_sd_parm2 > 0) {
                _ = aux.addOp4Int(v, OP.FilterAdd, dest.i_sd_parm2, 0, in.i_sdst, in.n_sdst);
                _ = aux.explain(p, false, "CREATE BLOOM FILTER", .{});
            }
            expr_mod.releaseTempReg(p, r1);
        },
        SRT.Mem => ec.codeMove(p, in.i_sdst, dest.i_sd_parm, in.n_sdst),
        SRT.Coroutine => {
            if (dest.i_sdst == 0) {
                dest.i_sdst = expr_mod.getTempRange(p, in.n_sdst);
                dest.n_sdst = in.n_sdst;
            }
            ec.codeMove(p, in.i_sdst, dest.i_sdst, in.n_sdst);
            _ = aux.addOp1(v, OP.Yield, dest.i_sd_parm);
        },
        SRT.DistQueue, SRT.Queue => {
            const so = dest.order_by.?;
            const i_parm = dest.i_sd_parm;
            const n_key: i32 = @intCast(so.len());
            const r1 = expr_mod.getTempReg(p);
            const r2 = expr_mod.getTempRange(p, n_key + 2);
            const r3 = r2 + n_key + 1;
            _ = aux.addOp3(v, OP.MakeRecord, in.i_sdst, in.n_sdst, r3);
            if (dest.e_dest == SRT.DistQueue) _ = aux.addOp2(v, OP.IdxInsert, i_parm + 1, r3);
            for (so.slice(), 0..) |item, ii| {
                _ = aux.addOp2(v, OP.SCopy, in.i_sdst + @as(i32, item.u.x.order_by_col) - 1, r2 + @as(i32, @intCast(ii)));
            }
            _ = aux.addOp2(v, OP.Sequence, i_parm, r2 + n_key);
            _ = aux.addOp3(v, OP.MakeRecord, r2, n_key + 2, r1);
            _ = aux.addOp4Int(v, OP.IdxInsert, i_parm, r1, r2, n_key + 2);
            expr_mod.releaseTempReg(p, r1);
            expr_mod.releaseTempRange(p, r2, n_key + 2);
        },
        SRT.Discard => {},
        else => {
            std.debug.assert(dest.e_dest == SRT.Output);
            _ = aux.addOp2(v, OP.ResultRow, in.i_sdst, in.n_sdst);
        },
    }

    // Stop at the LIMIT.
    if (s.i_limit != 0) _ = aux.addOp2(v, OP.DecrJumpZero, s.i_limit, i_break);

    // The subroutine return.
    aux.resolveLabel(v, i_continue);
    _ = aux.addOp1(v, OP.Return, reg_return);
    return addr;
}

/// Port of multiSelectByMerge(): code "<A> op <B> ORDER BY ..." by
/// running A and B as co-routines in ORDER BY order and merging their
/// rows.
fn multiSelectByMerge(p: *Parse, s: *Select, dest: *SelectDest) (Oom || int.ParseError)!void {
    const db = p.db;
    const v = p.vdbe.?;
    const label_end = aux.makeLabel(p);
    const label_cmpr = aux.makeLabel(p);
    const op = s.op;
    var order_by = s.order_by.?;
    var n_order_by = order_by.len();

    // Except for UNION ALL, the ORDER BY must cover every result column.
    if (op != TK.ALL) {
        var i: usize = 1;
        while (!db.malloc_failed and i <= s.e_list.?.len()) : (i += 1) {
            for (order_by.slice()) |item| {
                if (item.u.x.order_by_col == i) break;
            } else {
                const new = try expr_mod.exprInt32(p.arena, @intCast(i));
                order_by = try expr_mod.listAppend(p, order_by, new);
                s.order_by = order_by;
                order_by.at(n_order_by).u.x.order_by_col = @intCast(i);
                n_order_by += 1;
            }
        }
    }

    // The permutation from ORDER BY terms to result columns, and the
    // KeyInfo of the merge; COLLATEs are added to the ORDER BY terms.
    var permute: ?[]u32 = try v.alloc().alloc(u32, n_order_by + 1);
    {
        var keep = false;
        permute.?[0] = @intCast(n_order_by);
        for (order_by.slice(), 1..) |item, i| {
            permute.?[i] = @as(u32, item.u.x.order_by_col) - 1;
            if (permute.?[i] != i - 1) keep = true;
        }
        if (!keep) permute = null;
    }
    const key_merge = multiSelectByMergeKeyInfo(p, s, 1);

    // Registers and KeyInfo for removing duplicates.
    var reg_prev: i32 = 0;
    var key_dup: ?*KeyInfo = null;
    if (op != TK.ALL) {
        const n_expr = s.e_list.?.len();
        reg_prev = p.n_mem + 1;
        p.n_mem += @as(i32, @intCast(n_expr)) + 1;
        _ = aux.addOp2(v, OP.Integer, 0, reg_prev);
        key_dup = keyInfoAlloc(p, n_expr, 1);
        if (key_dup) |k| {
            for (0..n_expr) |i| {
                k.coll[i] = multiSelectCollSeq(p, s, i);
                k.sort_flags[i] = 0;
            }
        }
    }

    // Separate the left and right queries; a long UNION [ALL] chain is
    // split in the middle.
    var n_select: usize = 1;
    if ((op == TK.ALL or op == TK.UNION) and !db.optDisabled(int.OPT.BalancedMerge)) {
        var it = s;
        while (it.prior != null and it.op == op) : (it = it.prior.?) n_select += 1;
    }
    var split = s;
    if (n_select > 3) {
        var i: usize = 2;
        while (i < n_select) : (i += 2) split = split.prior.?;
    }
    const prior = split.prior.?;
    split.prior = null;
    prior.next = null;
    prior.order_by = try expr_mod.listDup(p.arena, order_by);
    resolve.resolveOrderGroupBy(p, s, s.order_by, "ORDER") catch {};
    resolve.resolveOrderGroupBy(p, prior, prior.order_by, "ORDER") catch {};

    // The limit registers.
    computeLimitRegisters(p, s, label_end);
    var reg_limit_a: i32 = 0;
    var reg_limit_b: i32 = 0;
    if (s.i_limit != 0 and (op == TK.ALL or unionWithLimitOne(db, s))) {
        p.n_mem += 1;
        reg_limit_a = p.n_mem;
        p.n_mem += 1;
        reg_limit_b = p.n_mem;
        _ = aux.addOp2(v, OP.Copy, if (s.i_offset != 0) s.i_offset + 1 else s.i_limit, reg_limit_a);
        _ = aux.addOp2(v, OP.Copy, reg_limit_a, reg_limit_b);
    }
    s.limit = null;

    p.n_mem += 1;
    const reg_addr_a = p.n_mem;
    p.n_mem += 1;
    const reg_addr_b = p.n_mem;
    p.n_mem += 1;
    const reg_out_a = p.n_mem;
    p.n_mem += 1;
    const reg_out_b = p.n_mem;
    var dest_a = selectDestInit(SRT.Coroutine, reg_addr_a);
    var dest_b = selectDestInit(SRT.Coroutine, reg_addr_b);

    _ = aux.explain(p, true, "MERGE ({s})", .{selectOpName(s.op)});

    // Co-routine A: the query on the left.
    const addr_select_a = aux.currentAddr(v) + 1;
    var addr1 = aux.addOp3(v, OP.InitCoroutine, reg_addr_a, 0, addr_select_a);
    prior.i_limit = reg_limit_a;
    _ = aux.explain(p, true, "LEFT", .{});
    select(p, prior, &dest_a) catch {};
    aux.endCoroutine(v, reg_addr_a);
    aux.jumpHere(v, addr1);

    // Co-routine B: the query on the right.
    const addr_select_b = aux.currentAddr(v) + 1;
    addr1 = aux.addOp3(v, OP.InitCoroutine, reg_addr_b, 0, addr_select_b);
    const saved_limit = s.i_limit;
    const saved_offset = s.i_offset;
    s.i_limit = reg_limit_b;
    s.i_offset = 0;
    _ = aux.explain(p, true, "RIGHT", .{});
    select(p, s, &dest_b) catch {};
    s.i_limit = saved_limit;
    s.i_offset = saved_offset;
    aux.endCoroutine(v, reg_addr_b);

    // Output a row of A, or of B.
    const addr_out_a = generateOutputSubroutine(p, s, &dest_a, dest, reg_out_a, reg_prev, key_dup, label_end);
    var addr_out_b: i32 = 0;
    if (op == TK.ALL or op == TK.UNION) {
        addr_out_b = generateOutputSubroutine(p, s, &dest_b, dest, reg_out_b, reg_prev, key_dup, label_end);
    }

    // A is exhausted.
    var addr_eof_a: i32 = undefined;
    var addr_eof_a_no_b: i32 = undefined;
    if (op == TK.EXCEPT or op == TK.INTERSECT) {
        addr_eof_a = label_end;
        addr_eof_a_no_b = label_end;
    } else {
        addr_eof_a = aux.addOp2(v, OP.Gosub, reg_out_b, addr_out_b);
        addr_eof_a_no_b = aux.addOp2(v, OP.Yield, reg_addr_b, label_end);
        _ = aux.goto_(v, addr_eof_a);
        s.n_select_row = util.logEstAdd(s.n_select_row, prior.n_select_row);
    }

    // B is exhausted.
    var addr_eof_b: i32 = undefined;
    if (op == TK.INTERSECT) {
        addr_eof_b = addr_eof_a;
        if (s.n_select_row > prior.n_select_row) s.n_select_row = prior.n_select_row;
    } else {
        addr_eof_b = aux.addOp2(v, OP.Gosub, reg_out_a, addr_out_a);
        _ = aux.addOp2(v, OP.Yield, reg_addr_a, label_end);
        _ = aux.goto_(v, addr_eof_b);
    }

    // A<B.
    var addr_alt_b = aux.addOp2(v, OP.Gosub, reg_out_a, addr_out_a);
    _ = aux.addOp2(v, OP.Yield, reg_addr_a, addr_eof_a);
    _ = aux.goto_(v, label_cmpr);

    // A==B.
    var addr_aeq_b: i32 = undefined;
    if (op == TK.ALL) {
        addr_aeq_b = addr_alt_b;
    } else if (op == TK.INTERSECT) {
        addr_aeq_b = addr_alt_b;
        addr_alt_b += 1;
    } else {
        addr_aeq_b = addr_alt_b + 1;
    }

    // A>B.
    var addr_agt_b = aux.currentAddr(v);
    if (op == TK.ALL or op == TK.UNION) {
        _ = aux.addOp2(v, OP.Gosub, reg_out_b, addr_out_b);
        _ = aux.addOp2(v, OP.Yield, reg_addr_b, addr_eof_b);
        _ = aux.goto_(v, label_cmpr);
    } else {
        // Just next-B: the code below has it.
        addr_agt_b += 1;
    }

    // Initialization.
    aux.jumpHere(v, addr1);
    _ = aux.addOp2(v, OP.Yield, reg_addr_a, addr_eof_a_no_b);
    // Also the A>B case of EXCEPT and INTERSECT.
    _ = aux.addOp2(v, OP.Yield, reg_addr_b, addr_eof_b);

    // The merge loop.
    if (permute) |pm| _ = aux.addOp4(v, OP.Permutation, 0, 0, 0, .{ .intarray = pm });
    aux.resolveLabel(v, label_cmpr);
    _ = aux.addOp4(v, OP.Compare, dest_a.i_sdst, dest_b.i_sdst, @intCast(n_order_by), if (key_merge) |k| .{ .keyinfo = k } else .notused);
    if (permute != null) aux.changeP5(v, OPFLAG.PERMUTE);
    _ = aux.addOp3(v, OP.Jump, addr_alt_b, addr_aeq_b, addr_agt_b);

    aux.resolveLabel(v, label_end);

    split.prior = prior;
    prior.next = split;
    prior.order_by = null;
    aux.explainPop(p);
    if (p.n_err != 0) return error.ParseFailed;
}

/// SubstContext: the substitution made by substExpr().
const SubstContext = struct {
    parse: *Parse,
    /// Replace references to this table...
    i_table: i32,
    /// ...by references to this one.
    i_new_table: i32,
    /// Add TK_IF_NULL_ROW nodes on each replacement.
    is_outer_join: bool,
    /// Depth of subquery recursion. Top is 1.
    n_sel_depth: i32,
    /// Replacement expressions.
    e_list: *ExprList,
    /// Collation sequences of the replacement expressions.
    c_list: *ExprList,
};

/// Port of substExpr(): replace every reference to column N of table
/// `x.i_table` in `e` with a copy of the N-th expression of `x.e_list`,
/// so that the outer query of a flattened subquery refers to the source
/// tables of the subquery directly.
fn substExpr(x: *SubstContext, e_arg: ?*Expr) Oom!?*Expr {
    var e = e_arg orelse return null;
    if (e.flags.intersects(.{ .OuterON = true, .InnerON = true }) and e.w.join == x.i_table) e.w = .{ .join = x.i_new_table };
    if (e.op == TK.COLUMN and e.i_table == x.i_table and !e.flags.FixedCol) {
        const i_column: usize = @intCast(e.i_column);
        std.debug.assert(e.right == null);
        var copy = x.e_list.at(i_column).expr.?;
        if (expr_mod.isVector(copy)) {
            expr_mod.vectorErrorMsg(x.parse, copy);
        } else {
            var if_null_row: Expr = undefined;
            if (x.is_outer_join and (copy.op != TK.COLUMN or copy.i_table != x.i_new_table)) {
                if_null_row = .{ .op = TK.IF_NULL_ROW, .left = copy, .i_table = x.i_new_table, .i_column = -99, .flags = .{ .IfNullRow = true } };
                copy = &if_null_row;
            }
            var new = (try expr_mod.exprDup(x.parse.arena, copy)).?;
            if (x.is_outer_join) new.flags.CanBeNull = true;
            if (new.op == TK.TRUEFALSE) {
                const value: i32 = @intFromBool(expr_mod.truthValue(new));
                new.u = .{ .value = value };
                new.op = TK.INTEGER;
                new.flags.IntValue = true;
            }
            // Keep the implicit collation the column of the view or
            // subquery had.
            const nat = expr_mod.collSeq(x.parse, new);
            const coll = expr_mod.collSeq(x.parse, x.c_list.at(i_column).expr);
            if (nat != coll or (new.op != TK.COLUMN and new.op != TK.COLLATE)) {
                new = try expr_mod.addCollateString(x.parse, new, if (coll) |c| c.name else "BINARY");
            }
            new.flags.Collate = false;
            if (e.flags.intersects(.{ .OuterON = true, .InnerON = true })) setJoinExpr(new, e.w.join, e.flags.only(.{ .OuterON = true, .InnerON = true }));
            e = new;
        }
    } else {
        if (e.op == TK.IF_NULL_ROW and e.i_table == x.i_table) e.i_table = x.i_new_table;
        if (e.op == TK.AGG_FUNCTION and e.op2 >= x.n_sel_depth) e.op2 -= 1;
        e.left = try substExpr(x, e.left);
        e.right = try substExpr(x, e.right);
        if (e.useXSelect()) {
            try substSelect(x, e.x.select, true);
        } else {
            try substExprList(x, e.x.list);
        }
        if (e.flags.WinFunc) {
            const win = e.y.win.?;
            win.filter = try substExpr(x, win.filter);
            try substExprList(x, win.partition);
            try substExprList(x, win.order_by);
        }
    }
    return e;
}

/// Port of substExprList().
fn substExprList(x: *SubstContext, list: ?*ExprList) Oom!void {
    const l = list orelse return;
    for (l.slice()) |*item| item.expr = try substExpr(x, item.expr);
}

/// Port of substSelect(): substExpr() over the expressions of `s_arg`, its
/// FROM-clause subqueries, and with `do_prior` its compound parts.
fn substSelect(x: *SubstContext, s_arg: ?*Select, do_prior: bool) Oom!void {
    var s = s_arg orelse return;
    x.n_sel_depth += 1;
    while (true) {
        try substExprList(x, s.e_list);
        try substExprList(x, s.group_by);
        try substExprList(x, s.order_by);
        s.having = try substExpr(x, s.having);
        s.where = try substExpr(x, s.where);
        for (s.src.?.slice()) |*item| {
            if (item.fg.is_subquery) try substSelect(x, item.u4.subq.?.select, true);
            if (item.fg.is_tab_func) try substExprList(x, item.u1.func_arg);
        }
        if (!do_prior) break;
        s = s.prior orelse break;
    }
    x.n_sel_depth -= 1;
}

fn recomputeColumnsUsedExpr(w: *Walker, e: *Expr) WRC {
    if (e.op != TK.COLUMN) return WRC.Continue;
    const item = w.u.src_item;
    if (item.i_cursor != e.i_table) return WRC.Continue;
    if (e.i_column < 0) return WRC.Continue;
    item.col_used |= resolve.exprColUsed(e);
    return WRC.Continue;
}

/// Port of recomputeColumnsUsed(): recompute `item.col_used` from the
/// whole of `s`.
fn recomputeColumnsUsed(s: *Select, item: *SrcItem) void {
    if (item.s_tab == null) return;
    var w: Walker = .{
        .expr_callback = recomputeColumnsUsedExpr,
        .select_callback = walker.selectWalkNoop,
        .u = .{ .src_item = item },
    };
    item.col_used = 0;
    _ = walker.walkSelect(&w, s);
}

/// Port of srclistRenumberCursors(): give each term of `src` but
/// `i_except` (and of its subqueries, recursively) a new cursor, noting
/// csr_map[old+1] = new. csr_map[0] is the size of the map.
fn srclistRenumberCursors(p: *Parse, csr_map: []i32, src: *SrcList, i_except: i32) void {
    for (src.slice(), 0..) |*item, i| {
        if (@as(i32, @intCast(i)) == i_except) continue;
        std.debug.assert(item.i_cursor < csr_map[0]);
        const k: usize = @intCast(item.i_cursor + 1);
        if (!item.fg.is_recursive or csr_map[k] == 0) {
            csr_map[k] = p.n_tab;
            p.n_tab += 1;
        }
        item.i_cursor = csr_map[k];
        if (item.fg.is_subquery) {
            var it: ?*Select = item.u4.subq.?.select;
            while (it) |sub| : (it = sub.prior) srclistRenumberCursors(p, csr_map, sub.src.?, -1);
        }
    }
}

/// Port of renumberCursorDoMapping().
fn renumberCursorDoMapping(w: *Walker, cursor: *i32) void {
    const csr_map = w.u.ai_col;
    const i_csr = cursor.*;
    if (i_csr < -1) return;
    if (i_csr < csr_map[0] and csr_map[@intCast(i_csr + 1)] > 0) cursor.* = csr_map[@intCast(i_csr + 1)];
}

/// Port of renumberCursorsCb().
fn renumberCursorsCb(w: *Walker, e: *Expr) WRC {
    if (e.op == TK.COLUMN or e.op == TK.IF_NULL_ROW) renumberCursorDoMapping(w, &e.i_table);
    if (e.flags.intersects(.{ .OuterON = true, .InnerON = true })) renumberCursorDoMapping(w, &e.w.join);
    return WRC.Continue;
}

/// Port of renumberCursors(): new cursors for the FROM clause of `s` but
/// term `i_except` (and its subqueries), with every reference updated.
/// `csr_map` is larger than any cursor of `s` and zero for every cursor
/// not in those FROM clauses.
fn renumberCursors(p: *Parse, s: *Select, i_except: i32, csr_map: []i32) void {
    srclistRenumberCursors(p, csr_map, s.src.?, i_except);
    var w: Walker = .{
        .expr_callback = renumberCursorsCb,
        .select_callback = walker.selectWalkNoop,
        .u = .{ .ai_col = csr_map.ptr },
    };
    _ = walker.walkSelect(&w, s);
}

/// Port of findLeftmostExprlist(): the result set of the leftmost SELECT
/// of a compound.
fn findLeftmostExprlist(sel_arg: *Select) *ExprList {
    var sel = sel_arg;
    while (sel.prior) |pr| sel = pr;
    return sel.e_list.?;
}

/// Port of compoundHasDifferentAffinities(): some result column has
/// different affinities in different arms of the compound.
fn compoundHasDifferentAffinities(s: *Select) bool {
    for (s.e_list.?.slice(), 0..) |item, ii| {
        const aff = expr_mod.affinity(item.expr.?);
        var it = s.prior;
        while (it) |sub1| : (it = sub1.prior) {
            if (expr_mod.affinity(sub1.e_list.?.at(ii).expr.?) != aff) return true;
        }
    }
    return false;
}

/// Port of flattenSubquery(): merge the FROM-clause subquery `i_from` of
/// `s` into `s`, as in
///
///     SELECT a FROM (SELECT x+y AS a FROM t1 WHERE z<100) WHERE a>5
///  -> SELECT x+y AS a FROM t1 WHERE z<100 AND a>5
///
/// when the restrictions numbered as in select.c allow it. A UNION ALL
/// subquery makes `s` a compound with one copy of `s` per arm. Returns
/// true if flattened. `is_agg` tells whether `s` is an aggregate.
fn flattenSubquery(p: *Parse, s: *Select, i_from: usize, is_agg: bool) Oom!bool {
    const db = p.db;
    std.debug.assert(s.prior == null);
    if (db.optDisabled(int.OPT.QueryFlattener)) return false;
    var src = s.src.?;
    const subitem = src.at(i_from);
    const i_parent = subitem.i_cursor;
    const sub = subitem.u4.subq.?.select;

    if (s.win != null or sub.win != null) return false; // (25)

    var sub_src = sub.src.?;
    if (sub.limit != null and s.limit != null) return false; // (13)
    if (sub.limit != null and sub.limit.?.right != null) return false; // (14)
    if (s.sel_flags.Compound and sub.limit != null) return false; // (15)
    if (sub_src.len() == 0) return false; // (7)
    if (sub.sel_flags.Distinct) return false; // (4)
    if (sub.limit != null and (src.len() > 1 or is_agg)) return false; // (8) (9)
    if (s.order_by != null and sub.order_by != null) return false; // (11)
    if (is_agg and sub.order_by != null) return false; // (16)
    if (sub.limit != null and s.where != null) return false; // (19)
    if (sub.limit != null and s.sel_flags.Distinct) return false; // (21)
    if (sub.sel_flags.Recursive) return false; // (22)

    // The right operand of a LEFT JOIN may not be a join itself: "t1 LEFT
    // JOIN (t2 JOIN t3)" is not "(t1 LEFT JOIN t2) JOIN t3".
    var is_outer_join = false;
    if (subitem.fg.jointype.intersects(.{ .OUTER = true, .LTORJ = true })) {
        if (sub_src.len() > 1 or // (3a)
            s.sel_flags.Distinct or // (3d)
            subitem.fg.jointype.RIGHT) // (26)
        {
            return false;
        }
        is_outer_join = true;
    }

    if (i_from > 0 and sub_src.at(0).fg.jointype.LTORJ) return false; // (27a)

    // (17): a compound subquery is a UNION ALL of simple non-aggregate,
    // non-DISTINCT queries.
    var csr_map: ?[]i32 = null;
    if (sub.prior != null) {
        if (sub.order_by != null) return false; // (20)
        if (is_agg or s.sel_flags.Distinct or is_outer_join) return false; // (17d1) (17d2) (17f)
        var it: ?*Select = sub;
        while (it) |sub1| : (it = sub1.prior) {
            if (sub1.sel_flags.intersects(.{ .Distinct = true, .Aggregate = true }) or // (17b)
                (sub1.prior != null and sub1.op != TK.ALL) or // (17a)
                sub1.src.?.len() < 1 or // (17c)
                sub1.win != null) // (17e)
            {
                return false;
            }
            // Else JT_LTORJ would be lost on the left tables of the RIGHT
            // JOIN being flattened.
            if (i_from > 0 and sub1.src.?.at(0).fg.jointype.LTORJ) return false; // (17g) (27b)
        }

        // (18)
        if (s.order_by) |ob| for (ob.slice()) |item| {
            if (item.u.x.order_by_col == 0) return false;
        };

        if (s.sel_flags.Recursive) return false; // (23)
        if (compoundHasDifferentAffinities(sub)) return false; // (17h)

        if (src.len() > 1) {
            if (p.n_select > 500) return false;
            if (db.optDisabled(int.OPT.FlttnUnionAll)) return false;
            const map = try p.arena.alloc(i32, @intCast(p.n_tab + 1));
            @memset(map, 0);
            map[0] = p.n_tab;
            csr_map = map;
        }
    }

    // Flattening is permitted.
    const sub1 = build.subqueryDetach(subitem);
    subitem.name = null;
    subitem.alias = null;

    // Compound-subquery flattening: N-1 copies of the outer query, without
    // ORDER BY, LIMIT or OFFSET, are joined to its left by UNION ALL, one
    // for each arm of the subquery:
    //
    //     SELECT a+1 FROM (SELECT x FROM tab UNION ALL SELECT y FROM tab)
    //     WHERE a!=5 ORDER BY 1
    //  -> SELECT x+1 FROM tab WHERE x+1!=5
    //     UNION ALL SELECT y+1 FROM tab WHERE y+1!=5 ORDER BY 1
    var arm = sub.prior;
    while (arm) |a| : (arm = a.prior) {
        const order_by = s.order_by;
        const limit = s.limit;
        const prior = s.prior;
        const item_tab = subitem.s_tab;
        subitem.s_tab = null;
        s.order_by = null;
        s.prior = null;
        s.limit = null;
        const new = try expr_mod.selectDup(p.arena, s);
        s.limit = limit;
        s.order_by = order_by;
        s.op = TK.ALL;
        subitem.s_tab = item_tab;
        if (new) |n| {
            p.n_select += 1;
            n.sel_id = @intCast(p.n_select);
            if (csr_map) |m| renumberCursors(p, n, @intCast(i_from), m);
            n.prior = prior;
            if (prior) |pr| pr.next = n;
            n.next = s;
            s.prior = n;
        } else {
            s.prior = prior;
        }
    }

    // Drop the Table of the subquery. There may still be Expr.y.tab
    // references to it (ticket #3346), but its reference is held by
    // p.tab_refs (or it lives in the arena) until the statement is done.
    subitem.s_tab = null;

    // Once per arm of a compound flattening (else once): move the FROM
    // terms of the subquery into the outer query, and substitute the
    // subquery's result expressions for the references to cursor
    // i_parent, which is never used again.
    var sub_it: ?*Select = sub1;
    var parent_it: ?*Select = s;
    while (parent_it) |parent| : ({
        parent_it = parent.prior;
        sub_it = sub_it.?.prior;
    }) {
        const sx = sub_it.?;
        const jointype = parent.src.?.at(i_from).fg.jointype;
        sub_src = sx.src.?;
        const n_sub_src = sub_src.len();
        src = parent.src.?;

        // The subquery takes one slot of the outer FROM clause; make room
        // for all of its terms.
        if (n_sub_src > 1) {
            src = (try build.srcListEnlarge(p, src, n_sub_src - 1, i_from + 1)) orelse break;
            parent.src = src;
        }

        const i_new_parent = sub_src.at(0).i_cursor;
        for (0..n_sub_src) |i| {
            const item = src.at(i + i_from);
            item.* = sub_src.at(i).*;
            if (jointype.LTORJ) item.fg.jointype.LTORJ = true;
            sub_src.at(i).* = .{};
        }
        src.at(i_from).fg.jointype = src.at(i_from).fg.jointype.with(jointype);

        if (sx.order_by) |ob| {
            // Its iOrderByCol values refer to the subquery's result set,
            // not the parent's (ticket [d11a6e908f]).
            for (ob.slice()) |*item| item.u.x.order_by_col = 0;
            std.debug.assert(parent.order_by == null);
            parent.order_by = ob;
            sx.order_by = null;
        }
        const where = sx.where;
        sx.where = null;
        if (is_outer_join) setJoinExpr(where, i_new_parent, .{ .OuterON = true });
        if (where) |w| {
            parent.where = if (parent.where) |pw| try expr_mod.pExpr(p, TK.AND, w, pw) else w;
        }
        if (!db.malloc_failed) {
            var x: SubstContext = .{
                .parse = p,
                .i_table = i_parent,
                .i_new_table = i_new_parent,
                .is_outer_join = is_outer_join,
                .n_sel_depth = 0,
                .e_list = sx.e_list.?,
                .c_list = findLeftmostExprlist(sx),
            };
            try substSelect(&x, parent, false);
        }

        // The result is a compound if either query was.
        if (sx.sel_flags.Compound) parent.sel_flags.Compound = true;

        // The limits of "SELECT ... FROM (SELECT ... LIMIT a OFFSET b)
        // LIMIT x OFFSET y" cannot be combined, if either is negative.
        if (sx.limit) |l| {
            parent.limit = l;
            sx.limit = null;
        }

        for (0..n_sub_src) |i| recomputeColumnsUsed(parent, src.at(i + i_from));
    }

    // The AggInfo entries must not refer to the abandoned subquery.
    var w = expr_mod.aggInfoPersistWalker(p);
    _ = walker.walkSelect(&w, sub1);
    return true;
}

/// WhereConst: the columns fixed to a constant by WHERE terms of the form
/// COLUMN=VALUE, for propagateConstants().
pub const WhereConst = struct {
    parse: *Parse,
    /// Number of COLUMN=CONSTANT terms.
    n_const: usize = 0,
    /// Number of times a constant was propagated.
    n_chng: i32 = 0,
    /// A column of `exprs` has affinity BLOB.
    has_aff_blob: bool = false,
    /// The ON terms not considered: EP_OuterON, or EP_InnerON|EP_OuterON.
    exclude_on: EP = .{},
    /// [i*2] is the COLUMN and [i*2+1] the VALUE.
    exprs: std.ArrayList(*Expr) = .empty,
};

/// Port of constInsert(): note that `column` is `value` by `e`, unless
/// `value` has an affinity, the comparison is not BINARY, `value` might
/// return a subtype, or `column` is already noted. `value` is constant.
fn constInsert(c: *WhereConst, column: *Expr, value: *Expr, e: *Expr) Oom!void {
    std.debug.assert(column.op == TK.COLUMN);
    if (column.flags.FixedCol) return;
    if (expr_mod.affinity(value) != 0) return;
    if (!serial.isBinary(expr_mod.compareCollSeq(c.parse, e))) return;
    if (ec.canReturnSubtype(c.parse, value)) return;

    // Each column only once (ticket [cf5ed20f]).
    for (0..c.n_const) |i| {
        const e2 = c.exprs.items[i * 2];
        if (e2.i_table == column.i_table and e2.i_column == column.i_column) return;
    }
    if (expr_mod.affinity(column) <= Aff.blob) c.has_aff_blob = true;

    try c.exprs.appendSlice(c.parse.arena, &.{ column, value });
    c.n_const += 1;
}

/// Port of findConstInWhere(): constInsert() each COLUMN=VALUE or
/// VALUE=COLUMN term, with a constant VALUE, of the AND-connected terms
/// of `e_arg`.
fn findConstInWhere(c: *WhereConst, e_arg: ?*Expr) Oom!void {
    const e = e_arg orelse return;
    if (e.flags.intersects(c.exclude_on)) return;
    if (e.op == TK.AND) {
        try findConstInWhere(c, e.right);
        try findConstInWhere(c, e.left);
        return;
    }
    if (e.op != TK.EQ) return;
    const right = e.right.?;
    const left = e.left.?;
    if (right.op == TK.COLUMN and expr_mod.isConstant(c.parse, left)) try constInsert(c, right, left, e);
    if (left.op == TK.COLUMN and expr_mod.isConstant(c.parse, right)) try constInsert(c, left, right, e);
}

/// Port of propagateConstantExprRewriteOne(): if `e` is one of the
/// columns of `c`, tag it EP_FixedCol and hang a copy of its value off
/// its left. Not for a BLOB column if `ignore_aff_blob`.
fn propagateConstantExprRewriteOne(c: *WhereConst, e: *Expr, ignore_aff_blob: bool) WRC {
    if (c.parse.db.malloc_failed) return WRC.Prune;
    if (e.op != TK.COLUMN) return WRC.Continue;
    if (e.flags.intersects(c.exclude_on.with(.{ .FixedCol = true }))) return WRC.Continue;
    for (0..c.n_const) |i| {
        const column = c.exprs.items[i * 2];
        if (column == e) continue;
        if (column.i_table != e.i_table) continue;
        if (column.i_column != e.i_column) continue;
        if (ignore_aff_blob and expr_mod.affinity(column) <= Aff.blob) break;
        c.n_chng += 1;
        e.flags.Leaf = false;
        e.flags.FixedCol = true;
        std.debug.assert(e.left == null);
        e.left = expr_mod.exprDup(c.parse.arena, c.exprs.items[i * 2 + 1]) catch {
            oom(c.parse);
            return WRC.Prune;
        };
        break;
    }
    return WRC.Prune;
}

/// Port of propagateConstantExprRewrite(): substitute the constants of
/// `w.u` for `e`, a column, or for the column operands of `e`, a
/// comparison (=, <, <=, >, >=, IS) whose left operand is not TEXT.
fn propagateConstantExprRewrite(w: *Walker, e: *Expr) WRC {
    const c = w.u.where_const;
    if (c.has_aff_blob) {
        if ((e.op >= TK.EQ and e.op <= TK.GE) or e.op == TK.IS) {
            _ = propagateConstantExprRewriteOne(c, e.left.?, false);
            if (c.parse.db.malloc_failed) return WRC.Prune;
            if (expr_mod.affinity(e.left.?) != Aff.text) _ = propagateConstantExprRewriteOne(c, e.right.?, false);
        }
    }
    return propagateConstantExprRewriteOne(c, e, c.has_aff_blob);
}

/// Port of propagateConstants(): the WHERE-clause constant propagation
/// optimization. Each top-level AND-connected COLUMN=CONSTANT term (not
/// of an OUTER JOIN's ON clause) fixes every other use of COLUMN in the
/// WHERE clause to CONSTANT:
///
///     SELECT * FROM t1, t2, t3 WHERE t1.a=39 AND t2.b=t1.a AND t3.c=t2.b
///  -> SELECT * FROM t1, t2, t3 WHERE t1.a=39 AND t2.b=39 AND t3.c=39
///
/// Because of affinities, the column is not replaced but tagged
/// EP_FixedCol with the constant on its left, which the code generator
/// uses instead of the column; and only with BINARY comparisons. For a
/// BLOB column the constant is only used by comparison operators, which
/// apply the right conversions ("x=10 AND x LIKE 10" must not become
/// "10 LIKE 10" for x='10.0'). Returns the number of changes.
fn propagateConstants(p: *Parse, s: *Select) Oom!i32 {
    var x: WhereConst = .{ .parse = p };
    var n_chng: i32 = 0;
    while (true) {
        x.n_const = 0;
        x.n_chng = 0;
        x.exprs.clearRetainingCapacity();
        x.has_aff_blob = false;
        const src = s.src.?;
        // No propagation into any ON clause if there is a RIGHT JOIN,
        // else none into the ON clause of a LEFT JOIN.
        x.exclude_on = if (src.len() > 0 and src.at(0).fg.jointype.LTORJ) .{ .InnerON = true, .OuterON = true } else .{ .OuterON = true };
        try findConstInWhere(&x, s.where);
        if (x.n_const != 0) {
            var w: Walker = .{
                .parse = p,
                .expr_callback = propagateConstantExprRewrite,
                .select_callback = walker.selectWalkNoop,
                .u = .{ .where_const = &x },
            };
            _ = walker.walkExpr(&w, s.where);
            n_chng += x.n_chng;
        }
        if (x.n_chng == 0) break;
    }
    return n_chng;
}

/// Port of pushDownWindowCheck(): `e` may be pushed down into `subq`,
/// which has window functions, as it only uses constants and the
/// PARTITION BY terms (filtering out whole partitions is safe).
fn pushDownWindowCheck(p: *Parse, subq: *Select, e: *Expr) bool {
    std.debug.assert(!subq.sel_flags.MultiPart and subq.prior == null);
    return expr_mod.isConstantOrGroupBy(p, e, subq.win.?.partition.?);
}

/// Port of pushDownWhereTerms(): the WHERE-clause push-down optimization.
/// Copy the terms of `where_arg` that only constrain the FROM-clause
/// subquery `i_src` of `src_list` into `subq`'s WHERE (or HAVING) clause:
///
///     SELECT * FROM (SELECT a AS x, c-d AS y FROM t1) WHERE x=5 AND y=10
///  -> SELECT * FROM (SELECT a AS x, c-d AS y FROM t1 WHERE a=5 AND c-d=10)
///     WHERE x=5 AND y=10
///
/// subject to the restrictions numbered as in select.c. Returns the
/// number of terms copied.
fn pushDownWhereTerms(p: *Parse, subq_arg: *Select, where_arg: ?*Expr, src_list: *SrcList, i_src: usize) Oom!i32 {
    var subq = subq_arg;
    var where = where_arg orelse return 0;
    const src = src_list.at(i_src);
    var n_chng: i32 = 0;
    if (subq.sel_flags.intersects(.{ .Recursive = true, .MultiPart = true })) return 0; // (2) (11)
    if (src.fg.jointype.intersects(.{ .LTORJ = true, .RIGHT = true })) return 0; // (10)

    if (subq.prior != null) {
        var not_union_all = false;
        var it: ?*Select = subq;
        while (it) |sel| : (it = sel.prior) {
            if (sel.op != TK.ALL and sel.op != TK.SELECT) not_union_all = true;
            if (sel.win != null) return 0; // (6b)
        }
        if (not_union_all) {
            // With UNION, INTERSECT or EXCEPT, every result column must be
            // BINARY.
            it = subq;
            while (it) |sel| : (it = sel.prior) {
                for (sel.e_list.?.slice()) |item| {
                    if (!serial.isBinary(expr_mod.collSeq(p, item.expr))) return 0; // (8)
                }
            }
        }
    } else if (subq.win) |win| {
        if (win.partition == null) return 0;
    }

    if (subq.limit != null) return 0; // (3)
    while (where.op == TK.AND) {
        n_chng += try pushDownWhereTerms(p, subq, where.right, src_list, i_src);
        where = where.left.?;
    }

    // Restrictions (4), (5) and (9) are checked by isSingleTableConstraint().
    if (expr_mod.isSingleTableConstraint(where, src_list, i_src, true)) {
        n_chng += 1;
        subq.sel_flags.PushDown = true;
        while (true) {
            var new = (try expr_mod.exprDup(p.arena, where)).?;
            unsetJoinExpr(new, -1, true);
            var x: SubstContext = .{
                .parse = p,
                .i_table = src.i_cursor,
                .i_new_table = src.i_cursor,
                .is_outer_join = false,
                .n_sel_depth = 0,
                .e_list = subq.e_list.?,
                .c_list = findLeftmostExprlist(subq),
            };
            new = (try substExpr(&x, new)).?;
            if (p.n_err == 0 and new.op == TK.IN and new.useXSelect()) {
                new.x.select.?.sel_flags.ClonedRhsIn = true;
                where.x.select.?.sel_flags.ClonedRhsIn = true;
            }
            if (subq.win != null and !pushDownWindowCheck(p, subq, new)) {
                // Restriction (6c).
                n_chng -= 1;
                break;
            }
            if (subq.sel_flags.Aggregate) {
                subq.having = try expr_mod.exprAnd(p, subq.having, new);
            } else {
                subq.where = try expr_mod.exprAnd(p, subq.where, new);
            }
            subq = subq.prior orelse break;
        }
    }
    return n_chng;
}

/// Port of disableUnusedSubqueryResultColumns(): turn the result columns
/// of the FROM-clause subquery `item` that are never used into NULLs.
/// Returns the number of columns changed.
fn disableUnusedSubqueryResultColumns(item: *SrcItem) i32 {
    if (item.fg.is_correlated or item.fg.is_cte) return 0;
    const t = item.s_tab.?;
    const sub = item.u4.subq.?.select;
    std.debug.assert(sub.e_list.?.len() == t.cols.len);
    var it: ?*Select = sub;
    while (it) |x| : (it = x.prior) {
        if (x.sel_flags.intersects(.{ .Distinct = true, .Aggregate = true })) return 0;
        // Only UNION ALL compounds.
        if (x.prior != null and x.op != TK.ALL) return 0;
        if (x.win != null) return 0;
    }
    var col_used = item.col_used;
    if (sub.order_by) |ob| for (ob.slice()) |o| {
        var i_col = o.u.x.order_by_col;
        if (i_col > 0) {
            i_col -= 1;
            col_used |= @as(int.Bitmask, 1) << @intCast(if (i_col >= int.bms) int.bms - 1 else i_col);
        }
    };
    var n_chng: i32 = 0;
    for (0..t.cols.len) |j| {
        const m: int.Bitmask = if (j < int.bms - 1) @as(int.Bitmask, 1) << @intCast(j) else @as(int.Bitmask, 1) << (int.bms - 1);
        if (m & col_used != 0) continue;
        it = sub;
        while (it) |x| : (it = x.prior) {
            const y = x.e_list.?.at(j).expr.?;
            if (y.op == TK.NULL) continue;
            y.op = TK.NULL;
            y.flags.clear(.{ .Skip = true, .Unlikely = true });
            x.sel_flags.PushDown = true;
            n_chng += 1;
        }
    }
    return n_chng;
}

/// Port of isSimpleCount(): the table of "SELECT count(*) FROM <tbl>", or
/// null.
fn isSimpleCount(s: *Select, agg: *AggInfo) ?*Table {
    std.debug.assert(s.group_by == null);
    if (s.where != null or s.e_list.?.len() != 1 or s.src.?.len() != 1 or
        s.src.?.at(0).fg.is_subquery or agg.funcs.items.len != 1 or s.having != null)
    {
        return null;
    }
    const t = s.src.?.at(0).s_tab.?;
    if (!t.isOrdinary()) return null;
    const e = s.e_list.?.at(0).expr.?;
    if (e.op != TK.AGG_FUNCTION) return null;
    if (e.agg_info != agg) return null;
    if (!agg.funcs.items[0].func.?.func_flags.COUNT) return null;
    if (e.flags.intersects(.{ .Distinct = true, .WinFunc = true })) return null;
    return t;
}

/// Port of sqlite3IndexedByLookup(): find the index of INDEXED BY.
pub fn indexedByLookup(p: *Parse, from: *SrcItem) bool {
    const t = from.s_tab.?;
    const name = from.u1.indexed_by.?;
    var idx = t.index;
    while (idx) |ix| : (idx = ix.next) {
        if (ctype.eqlNoCase(ix.name, name)) break;
    }
    const found = idx orelse {
        util.errorMsg(p, "no such index: {s}", .{name});
        p.check_schema = true;
        return true;
    };
    from.u2 = .{ .ib_index = found };
    return false;
}

/// Port of convertCompoundSelectToSubquery(): a compound (other than
/// UNION ALL) with a COLLATE in its ORDER BY becomes "SELECT * FROM
/// (compound) ORDER BY ...", as the merge needs the result columns'
/// collations.
fn convertCompoundSelectToSubquery(w: *Walker, s: *Select) WRC {
    return convertCompoundSelectToSubqueryImpl(w, s) catch {
        oom(w.parse.?);
        return WRC.Abort;
    };
}

fn convertCompoundSelectToSubqueryImpl(w: *Walker, s: *Select) Oom!WRC {
    if (s.prior == null) return WRC.Continue;
    const order_by = s.order_by orelse return WRC.Continue;
    var x: ?*Select = s;
    while (x) |xs| {
        if (xs.op != TK.ALL and xs.op != TK.SELECT) break;
        x = xs.prior;
    }
    if (x == null) return WRC.Continue;
    // Already matched to result columns (a window rewrite).
    if (order_by.at(0).u.x.order_by_col != 0) return WRC.Continue;
    var i = order_by.len();
    while (i > 0) {
        i -= 1;
        if (order_by.at(i).expr.?.flags.Collate) break;
    } else return WRC.Continue;

    const p = w.parse.?;
    const new = try p.arena.create(Select);
    const new_src = (try build.srcListAppendFromTerm(p, null, null, null, .{}, new, null)) orelse return WRC.Abort;
    if (p.n_err != 0) return WRC.Abort;
    new.* = s.*;
    s.src = new_src;
    s.e_list = try expr_mod.listAppend(p, null, try expr_mod.expr(p.arena, TK.ASTERISK, null));
    s.op = TK.SELECT;
    s.where = null;
    new.group_by = null;
    new.having = null;
    new.order_by = null;
    s.prior = null;
    s.next = null;
    s.with = null;
    s.win_defn = null;
    s.sel_flags.Compound = false;
    s.sel_flags.Converted = true;
    new.prior.?.next = new;
    new.limit = null;
    return WRC.Continue;
}

/// Port of cannotBeFunction(): a table-valued function where a plain
/// table is needed is an error.
fn cannotBeFunction(p: *Parse, from: *SrcItem) bool {
    if (from.fg.is_tab_func) {
        util.errorMsg(p, "'{s}' is not a function", .{from.name.?});
        return true;
    }
    return false;
}

/// Port of searchWith(): the CTE the FROM term `item` names, in the WITH
/// clauses in scope, with its WITH clause in `context`.
fn searchWith(with_arg: ?*With, item: *SrcItem, context: *?*With) ?*int.Cte {
    const name = item.name.?;
    var w = with_arg;
    while (w) |x| : (w = x.outer) {
        for (x.ctes.items) |*c| {
            if (ctype.eqlNoCase(name, c.name orelse "")) {
                context.* = x;
                return c;
            }
        }
        if (x.view) break;
    }
    return null;
}

/// Port of resolveFromTermToCte(): if `from` names a CTE in scope, give
/// it the CTE's subquery and a table for its result. Returns 0 if not a
/// CTE, 1 if it is, 2 on error.
fn resolveFromTermToCte(p: *Parse, w: *Walker, from: *SrcItem) Oom!u8 {
    const db = p.db;
    if (p.with == null) return 0;
    if (p.n_err != 0) return 0;
    // A schema qualifier rules out a CTE, as does fg.not_cte.
    if (!from.fg.fixed_schema and from.u4.database != null) return 0;
    if (from.fg.not_cte) return 0;
    var with: ?*With = null;
    const cte = searchWith(p.with, from, &with) orelse return 0;

    // An illegal recursive reference.
    if (cte.cte_err) |err| {
        if (std.mem.eql(u8, err, "circular reference: %s")) {
            util.errorMsg(p, "circular reference: {s}", .{cte.name.?});
        } else if (std.mem.eql(u8, err, "multiple recursive references: %s")) {
            util.errorMsg(p, "multiple recursive references: {s}", .{cte.name.?});
        } else {
            util.errorMsg(p, "recursive reference in a subquery: {s}", .{cte.name.?});
        }
        return 2;
    }
    if (cannotBeFunction(p, from)) return 2;

    const t = try p.arena.create(Table);
    var cte_use = cte.use;
    if (cte_use == null) {
        const u = try p.arena.create(int.CteUse);
        u.* = .{ .e_m10d = cte.e_m10d };
        cte.use = u;
        cte_use = u;
    }
    from.s_tab = t;
    t.* = .{
        .name = try p.arena.dupeSentinel(u8, cte.name.?, 0),
        .n_row_log_est = 200,
        .tab_flags = .{ .Ephemeral = true, .NoVisibleRowid = true },
    };
    try build.srcItemAttachSubquery(p, from, (try expr_mod.selectDup(p.arena, cte.select)).?);
    if (db.malloc_failed) return 2;
    const sel = from.u4.subq.?.select;
    sel.sel_flags.CopyCte = true;
    if (from.fg.is_indexed_by) {
        util.errorMsg(p, "no such index: \"{s}\"", .{from.u1.indexed_by.?});
        return 2;
    }
    from.fg.is_cte = true;
    from.u2 = .{ .cte_use = cte_use };
    cte_use.?.n_use += 1;

    // Is it recursive?
    var rec_term = sel;
    const may_recursive = sel.op == TK.ALL or sel.op == TK.UNION;
    var i_rec_tab: i32 = -1;
    while (may_recursive and rec_term.op == sel.op) {
        for (rec_term.src.?.slice()) |*item| {
            if (item.name != null and !item.fg.had_schema and !item.fg.is_subquery and
                (item.fg.fixed_schema or item.u4.database == null) and
                ctype.eqlNoCase(item.name.?, cte.name.?))
            {
                item.s_tab = t;
                build.tableRef(p, t);
                item.fg.is_recursive = true;
                if (rec_term.sel_flags.Recursive) {
                    util.errorMsg(p, "multiple references to recursive table: {s}", .{cte.name.?});
                    return 2;
                }
                rec_term.sel_flags.Recursive = true;
                if (i_rec_tab < 0) {
                    i_rec_tab = p.n_tab;
                    p.n_tab += 1;
                }
                item.i_cursor = i_rec_tab;
            }
        }
        if (!rec_term.sel_flags.Recursive) break;
        rec_term = rec_term.prior.?;
    }

    if (p.n_tab >= db.limit(.expr_depth)) {
        // Nested CTEs must not make an exponential number of cursors.
        p.n_nest_sel = p.n_tab;
    }
    p.n_nest_sel += 1;
    if (checkSubqueryNestingDepth(p)) return 2;
    cte.cte_err = "circular reference: %s";
    const saved_with = p.with;
    p.with = with;
    if (sel.sel_flags.Recursive) {
        rec_term.with = sel.with;
        const rc = walker.walkSelect(w, rec_term);
        rec_term.with = null;
        if (rc != .Continue) {
            p.with = saved_with;
            return 2;
        }
    } else if (walker.walkSelect(w, sel) != .Continue) {
        p.with = saved_with;
        return 2;
    }
    p.with = with;
    p.n_nest_sel -= 1;

    var left = sel;
    while (left.prior) |pr| left = pr;
    var e_list = left.e_list;
    if (cte.cols) |cols| {
        if (e_list != null and e_list.?.len() != cols.len()) {
            util.errorMsg(p, "table {s} has {d} values for {d} columns", .{ cte.name.?, e_list.?.len(), cols.len() });
            p.with = saved_with;
            return 2;
        }
        e_list = cols;
    }

    t.cols = try columnsFromExprList(p, p.arena, e_list);
    t.n_nv_col = @intCast(t.cols.len);
    if (may_recursive) {
        cte.cte_err = if (sel.sel_flags.Recursive)
            "multiple recursive references: %s"
        else
            "recursive reference in a subquery: %s";
        _ = walker.walkSelect(w, sel);
    }
    cte.cte_err = null;
    p.with = saved_with;
    return 1;
}

/// Port of sqlite3SelectPopWith(): pop the WITH clause of `s` (the
/// leftmost term of a compound) off the stack.
pub fn selectPopWith(w: *Walker, s: *Select) void {
    const p = w.parse.?;
    if (p.with != null and s.prior == null) {
        if (findRightmost(s).with) |with| p.with = with.outer;
    }
}

/// Port of sqlite3ExpandSubquery(): the table describing the result of
/// the FROM-clause subquery `from`.
pub fn expandSubquery(p: *Parse, from: *SrcItem) Oom!bool {
    var sel = from.u4.subq.?.select;
    const t = try p.arena.create(Table);
    from.s_tab = t;
    const name = if (from.alias) |a| try p.arena.dupeSentinel(u8, a, 0) else try build.mprintf(p, "%!S", &.{.{ .src_item = from }});
    while (sel.prior) |pr| sel = pr;
    t.* = .{
        .name = name,
        .n_row_log_est = 200,
        .e_tab_type = .view,
        .tab_flags = .{ .Ephemeral = true, .NoVisibleRowid = true },
    };
    t.cols = try columnsFromExprList(p, p.arena, sel.e_list);
    t.n_nv_col = @intCast(t.cols.len);
    return p.n_err != 0;
}

/// Port of inAnyUsingClause(): `name` is in a USING clause of one of the
/// `n` terms after `base` of `src`.
fn inAnyUsingClause(name: []const u8, src: *SrcList, base: usize, n: usize) bool {
    for (src.slice()[base + 1 .. base + 1 + n]) |*item| {
        if (!item.fg.is_using) continue;
        const using = item.u3.using orelse continue;
        if (build.idListIndex(using, name) != null) return true;
    }
    return false;
}

/// Port of sqlite3SrcListAssignCursors() (build.c): give every FROM term
/// (and those of subqueries) a cursor.
pub fn srcListAssignCursors(p: *Parse, list: ?*SrcList) void {
    const l = list orelse return;
    for (l.slice()) |*item| {
        if (item.i_cursor >= 0) continue;
        item.i_cursor = p.n_tab;
        p.n_tab += 1;
        if (item.fg.is_subquery) srcListAssignCursors(p, item.u4.subq.?.select.src);
    }
}

/// Port of selectExpander(): assign cursors to the FROM terms and find
/// their tables (views and subqueries become subquery tables), apply the
/// joins, and expand "*" and "TABLE.*" in the result set.
fn selectExpander(w: *Walker, s: *Select) WRC {
    return selectExpanderImpl(w, s) catch {
        oom(w.parse.?);
        return WRC.Abort;
    };
}

fn selectExpanderImpl(w: *Walker, s: *Select) Oom!WRC {
    const p = w.parse.?;
    const db = p.db;
    const sel_flags = s.sel_flags;
    var elist_flags: EP = .{};

    s.sel_flags.Expanded = true;
    if (db.malloc_failed) return WRC.Abort;
    if (sel_flags.Expanded) return WRC.Prune;
    if (w.e_code != 0) {
        // Copied from a view: renumber.
        p.n_select += 1;
        s.sel_id = @intCast(p.n_select);
    }
    const tab_list = s.src.?;
    const e_list = s.e_list.?;
    if (p.with != null and s.sel_flags.View) {
        if (s.with == null) {
            const nw = try p.arena.create(With);
            nw.* = .{};
            s.with = nw;
        }
        s.with.?.view = true;
    }
    _ = withPush(p, s.with);

    srcListAssignCursors(p, tab_list);

    // Find the table of each FROM term.
    for (tab_list.slice()) |*from| {
        if (from.s_tab != null) continue;
        if (from.name == null) {
            // A subquery.
            const sel = from.u4.subq.?.select;
            if (walker.walkSelect(w, sel) != .Continue) return WRC.Abort;
            if (try expandSubquery(p, from)) return WRC.Abort;
        } else {
            const rc = try resolveFromTermToCte(p, w, from);
            if (rc > 1) return WRC.Abort;
            if (rc == 0) {
                // A table or view.
                const t = build.locateTableItem(p, 0, from) orelse return WRC.Abort;
                from.s_tab = t;
                if (t.n_tab_ref >= 0xffff) {
                    util.errorMsg(p, "too many references to \"{s}\": max 65535", .{t.name});
                    from.s_tab = null;
                    return WRC.Abort;
                }
                build.tableRef(p, t);
                if (t.e_tab_type != .vtab and cannotBeFunction(p, from)) return WRC.Abort;
                if (!t.isOrdinary()) {
                    const e_code_orig = w.e_code;
                    build.viewGetColumnNames(p, t) catch return WRC.Abort;
                    if (t.isView()) {
                        if (!db.flags.EnableView and t.schema != db.dbs.items[1].schema) {
                            util.errorMsg(p, "access to view \"{s}\" prohibited", .{t.name});
                        }
                        try build.srcItemAttachSubquery(p, from, (try expr_mod.selectDup(p.arena, t.u.view.select)).?);
                    } else if (t.isVirtual() and
                        (from.fg.from_ddl or p.prep_flags & aux.PREPARE_FROM_DDL != 0) and
                        t.u.vtab.p != null and
                        t.u.vtab.p.?.e_vtab_risk.unsafeInSchema(db.flags.TrustedSchema))
                    {
                        util.errorMsg(p, "unsafe use of virtual table \"{s}\"", .{t.name});
                    }
                    // Renumber the Select ids of the view's copy.
                    w.e_code = 1;
                    if (from.fg.is_subquery) _ = walker.walkSelect(w, from.u4.subq.?.select);
                    w.e_code = e_code_orig;
                }
            }
        }
        if (from.fg.is_indexed_by and indexedByLookup(p, from)) return WRC.Abort;
    }

    // NATURAL, ON and USING.
    if (p.n_err != 0) return WRC.Abort;
    processJoin(p, s) catch |err| switch (err) {
        error.ParseFailed => return WRC.Abort,
        error.OutOfMemory => |e| return e,
    };

    // Expand "*" and "TABLE.*".
    var k: usize = 0;
    while (k < e_list.len()) : (k += 1) {
        const e = e_list.at(k).expr.?;
        if (e.op == TK.ASTERISK) break;
        if (e.op == TK.DOT and e.right.?.op == TK.ASTERISK) break;
        elist_flags.set(e.flags);
    }
    if (k < e_list.len()) {
        var new: ?*ExprList = null;
        const flags = db.flags;
        const long_names = flags.FullColNames and !flags.ShortColNames;
        for (e_list.slice()) |*a| {
            const e = a.expr.?;
            elist_flags.set(e.flags);
            const right_ast = e.right;
            if (e.op != TK.ASTERISK and (e.op != TK.DOT or right_ast.?.op != TK.ASTERISK)) {
                // No expansion needed.
                new = try expr_mod.listAppend(p, new, e);
                new.?.last().e_name = a.e_name;
                new.?.last().fg.e_ename = a.fg.e_ename;
                continue;
            }
            // "*" or "TABLE.*".
            var table_seen = false;
            var tname: ?[]const u8 = null;
            var i_err_ofst: i32 = undefined;
            if (e.op == TK.DOT) {
                tname = e.left.?.token();
                i_err_ofst = e.right.?.w.ofst;
            } else {
                i_err_ofst = e.w.ofst;
            }
            for (tab_list.slice(), 0..) |*from, i| {
                const t = from.s_tab.?;
                const tab_name: []const u8 = from.alias orelse t.name;
                var nested_from: ?*ExprList = null;
                var schema_name: ?[]const u8 = null;
                if (db.malloc_failed) break;
                if (from.fg.is_nested_from) {
                    nested_from = from.u4.subq.?.select.e_list;
                } else {
                    if (tname) |tn| if (!ctype.eqlNoCase(tn, tab_name)) continue;
                    const i_db = prepare.schemaToIndex(db, t.schema);
                    schema_name = if (i_db >= 0) db.dbs.items[@intCast(i_db)].name else "*";
                }
                var using: ?*IdList = null;
                if (i + 1 < tab_list.len() and tab_list.at(i + 1).fg.is_using and sel_flags.NestedFrom) {
                    using = tab_list.at(i + 1).u3.using;
                    for (using.?.names.items) |uname| {
                        const r = try expr_mod.expr(p.arena, TK.ID, uname);
                        expr_mod.setErrorOffset(r, i_err_ofst);
                        new = try expr_mod.listAppend(p, new, r);
                        const x = new.?.last();
                        x.e_name = try std.fmt.allocPrintSentinel(p.arena, "..{s}", .{uname}, 0);
                        x.fg.e_ename = .tab;
                        x.fg.using_term = true;
                    }
                }

                var n_add = t.cols.len;
                if (!t.tab_flags.NoVisibleRowid and sel_flags.NestedFrom) n_add += 1;
                for (0..n_add) |j| {
                    var name: []const u8 = undefined;
                    if (j == t.cols.len) {
                        name = expr_mod.rowidAlias(t) orelse continue;
                    } else {
                        name = t.cols[j].name();
                        // Not the ENAME_ROWID columns of a nested FROM.
                        if (nested_from) |nf| if (nf.at(j).fg.e_ename == .rowid) continue;
                        if (tname != null and nested_from != null and !resolve.matchEName(nested_from.?.at(j), null, tname, null, null)) continue;
                        // Hidden columns unless SF_IncludeHidden.
                        if (!s.sel_flags.IncludeHidden and isHiddenColumn(&t.cols[j])) continue;
                        if (t.cols[j].col_flags.NOEXPAND and tname == null and !sel_flags.NestedFrom) continue;
                    }
                    table_seen = true;

                    if (i > 0 and tname == null and !sel_flags.NestedFrom) {
                        // A USING column comes from the left table only.
                        if (from.fg.is_using and build.idListIndex(from.u3.using.?, name) != null) continue;
                    }
                    const right = try expr_mod.expr(p.arena, TK.ID, name);
                    var ex: *Expr = undefined;
                    if ((tab_list.len() > 1 and (!from.fg.jointype.LTORJ or tname != null or
                        sel_flags.NestedFrom or !inAnyUsingClause(name, tab_list, i, tab_list.len() - i - 1))) or
                        p.inRenameObject())
                    {
                        var left = try expr_mod.expr(p.arena, TK.ID, tab_name);
                        ex = try expr_mod.pExpr(p, TK.DOT, left, right);
                        if (p.inRenameObject()) if (e.left) |el| @import("alter.zig").renameTokenRemap(p, left, el);
                        if (schema_name) |sn| {
                            left = try expr_mod.expr(p.arena, TK.ID, sn);
                            ex = try expr_mod.pExpr(p, TK.DOT, left, ex);
                        }
                    } else {
                        ex = right;
                    }
                    expr_mod.setErrorOffset(ex, i_err_ofst);
                    new = try expr_mod.listAppend(p, new, ex);
                    const x = new.?.last();
                    if (sel_flags.NestedFrom and !p.inRenameObject()) {
                        if (nested_from != null and j < nested_from.?.len()) {
                            x.e_name = if (nested_from.?.at(j).e_name) |en| try p.arena.dupeSentinel(u8, en, 0) else null;
                        } else {
                            x.e_name = try std.fmt.allocPrintSentinel(p.arena, "{s}.{s}.{s}", .{ schema_name orelse "", tab_name, name }, 0);
                        }
                        x.fg.e_ename = if (j == t.cols.len) .rowid else .tab;
                        if ((from.fg.is_using and build.idListIndex(from.u3.using.?, name) != null) or
                            (using != null and build.idListIndex(using.?, name) != null) or
                            (j < t.cols.len and t.cols[j].col_flags.NOEXPAND))
                        {
                            x.fg.no_expand = true;
                        }
                    } else if (long_names) {
                        x.e_name = try std.fmt.allocPrintSentinel(p.arena, "{s}.{s}", .{ tab_name, name }, 0);
                        x.fg.e_ename = .name;
                    } else {
                        x.e_name = try p.arena.dupeSentinel(u8, name, 0);
                        x.fg.e_ename = .name;
                    }
                }
            }
            if (!table_seen) {
                if (tname) |tn| {
                    util.errorMsg(p, "no such table: {s}", .{tn});
                } else {
                    util.errorMsg(p, "no tables specified", .{});
                }
            }
        }
        s.e_list = new;
    }
    if (s.e_list) |el| {
        if (el.len() > @as(usize, @intCast(db.limit(.column)))) {
            util.errorMsg(p, "too many columns in result set", .{});
            return WRC.Abort;
        }
        if (elist_flags.intersects(.{ .HasFunc = true, .Subquery = true })) s.sel_flags.ComplexResult = true;
    }
    return WRC.Continue;
}

/// Port of sqlite3SelectExpand(): expand a SELECT and its subqueries.
fn selectExpand(p: *Parse, s: *Select) void {
    var w: Walker = .{ .parse = p, .expr_callback = walker.exprWalkNoop };
    if (p.has_compound) {
        w.select_callback = convertCompoundSelectToSubquery;
        _ = walker.walkSelect(&w, s);
    }
    w.select_callback = selectExpander;
    w.select_callback2 = selectPopWith;
    w.e_code = 0;
    _ = walker.walkSelect(&w, s);
}

/// Port of selectAddSubqueryTypeInfo(): the types of the tables of the
/// FROM-clause subqueries, now that names are resolved.
fn selectAddSubqueryTypeInfo(w: *Walker, s: *Select) void {
    if (s.sel_flags.HasTypeInfo) return;
    s.sel_flags.HasTypeInfo = true;
    const p = w.parse.?;
    for (s.src.?.slice()) |*from| {
        const t = from.s_tab.?;
        if (t.tab_flags.Ephemeral and from.fg.is_subquery) {
            subqueryColumnTypes(p, build.tableAlloc(p, t), t, from.u4.subq.?.select, Aff.none) catch oom(p);
        }
    }
}

/// Port of sqlite3SelectAddTypeInfo().
fn selectAddTypeInfo(p: *Parse, s: *Select) void {
    var w: Walker = .{
        .parse = p,
        .expr_callback = walker.exprWalkNoop,
        .select_callback = walker.selectWalkNoop,
        .select_callback2 = selectAddSubqueryTypeInfo,
    };
    _ = walker.walkSelect(&w, s);
}

/// Port of sqlite3SelectPrep(): expand a SELECT (cursors, FROM tables,
/// joins, "*"), resolve its names, and type its FROM subqueries.
pub fn selectPrep(p: *Parse, s: *Select, outer_nc: ?*NameContext) void {
    if (p.db.malloc_failed) return;
    if (s.sel_flags.HasTypeInfo) return;
    selectExpand(p, s);
    if (p.n_err != 0) return;
    resolve.resolveSelectNames(p, s, outer_nc);
    if (p.n_err != 0) return;
    selectAddTypeInfo(p, s);
}

/// Port of analyzeAggFuncArgs(): the AggInfo columns used only as
/// arguments of aggregate functions.
fn analyzeAggFuncArgs(agg: *AggInfo, nc: *NameContext) void {
    nc.nc_flags.InAggFunc = true;
    for (agg.funcs.items) |f| {
        const e = f.f_expr;
        expr_mod.analyzeAggList(nc, e.x.list);
        if (e.left) |l| expr_mod.analyzeAggList(nc, l.x.list);
        if (e.flags.WinFunc) expr_mod.analyzeAggregates(nc, e.y.win.?.filter);
    }
    nc.nc_flags.InAggFunc = false;
}

/// Port of optimizeAggregateUseOfIndexedExpr(): after whereBegin() has
/// chosen indexes, analyze the aggregate function arguments again so that
/// the indexed expressions among them become columns of those indexes.
fn optimizeAggregateUseOfIndexedExpr(s: *Select, agg: *AggInfo, nc: *NameContext) void {
    std.debug.assert(agg.i_first_reg == 0);
    agg.cols.shrinkRetainingCapacity(@intCast(agg.n_accumulator));
    if (agg.n_sorting_column > 0) {
        var mx: i32 = @as(i32, @intCast(s.group_by.?.len())) - 1;
        for (agg.cols.items) |c| mx = @max(mx, c.i_sorter_column);
        agg.n_sorting_column = @intCast(mx + 1);
    }
    analyzeAggFuncArgs(agg, nc);
}

/// Walker callback of aggregateConvertIndexedExprRefToColumn().
fn aggregateIdxEprRefToColCallback(_: *walker.Walker, e: *Expr) WRC {
    const agg = e.agg_info orelse return WRC.Continue;
    if (e.op == TK.AGG_COLUMN or e.op == TK.AGG_FUNCTION or e.op == TK.IF_NULL_ROW) return WRC.Continue;
    if (e.i_agg >= agg.cols.items.len) return WRC.Continue;
    const col = &agg.cols.items[@intCast(e.i_agg)];
    e.op = TK.AGG_COLUMN;
    e.i_table = col.i_table;
    e.i_column = @intCast(col.i_column);
    e.flags.clear(.{ .Skip = true, .Collate = true, .Unlikely = true });
    return WRC.Prune;
}

/// Port of aggregateConvertIndexedExprRefToColumn(): the nodes of the
/// aggregate function arguments that optimizeAggregateUseOfIndexedExpr()
/// tied to index columns become TK_AGG_COLUMN.
fn aggregateConvertIndexedExprRefToColumn(agg: *AggInfo) void {
    var w: walker.Walker = .{ .expr_callback = aggregateIdxEprRefToColCallback };
    for (agg.funcs.items) |f| _ = walker.walkExpr(&w, f.f_expr);
}

/// Port of assignAggregateRegisters(): one register per AggInfo column
/// and function.
fn assignAggregateRegisters(p: *Parse, agg: *AggInfo) void {
    agg.i_first_reg = p.n_mem + 1;
    p.n_mem += @intCast(agg.cols.items.len + agg.funcs.items.len);
}

/// Port of resetAccumulator(): code NULLs into the accumulators, and open
/// the tables of DISTINCT and ORDER BY aggregates.
fn resetAccumulator(p: *Parse, agg: *AggInfo) void {
    const v = p.vdbe.?;
    const n_reg: i32 = @intCast(agg.funcs.items.len + agg.cols.items.len);
    if (n_reg == 0) return;
    if (p.n_err != 0) return;
    _ = aux.addOp3(v, OP.Null, 0, agg.i_first_reg, agg.i_first_reg + n_reg - 1);
    for (agg.funcs.items) |*f| {
        if (f.i_distinct >= 0) {
            const e = f.f_expr;
            if (e.x.list == null or e.x.list.?.len() != 1) {
                util.errorMsg(p, "DISTINCT aggregates must have exactly one argument", .{});
                f.i_distinct = -1;
            } else {
                const ki = keyInfoFromExprList(p, e.x.list.?, 0, 0);
                f.i_dist_addr = aux.addOp4(v, OP.OpenEphemeral, f.i_distinct, 0, 0, if (ki) |k| .{ .keyinfo = k } else .notused);
                _ = aux.explain(p, false, "USE TEMP B-TREE FOR {s}(DISTINCT)", .{f.func.?.name});
            }
        }
        if (f.i_ob_tab >= 0) {
            const ob_list = f.f_expr.left.?.x.list.?;
            var n_extra: usize = 0;
            if (!f.b_ob_unique) n_extra += 1;
            if (f.b_ob_payload) n_extra += f.f_expr.x.list.?.len();
            if (f.b_use_subtype) n_extra += f.f_expr.x.list.?.len();
            const ki = keyInfoFromExprList(p, ob_list, 0, n_extra);
            if (!f.b_ob_unique and p.n_err == 0) ki.?.n_key_field += 1;
            _ = aux.addOp4(v, OP.OpenEphemeral, f.i_ob_tab, @intCast(ob_list.len() + n_extra), 0, if (ki) |k| .{ .keyinfo = k } else .notused);
            _ = aux.explain(p, false, "USE TEMP B-TREE FOR {s}(ORDER BY)", .{f.func.?.name});
        }
    }
}

/// Port of finalizeAggFunctions(): OP_AggFinal for every aggregate (after
/// running the deferred steps of ORDER BY aggregates).
fn finalizeAggFunctions(p: *Parse, agg: *AggInfo) void {
    const v = p.vdbe.?;
    for (agg.funcs.items, 0..) |*f, i| {
        if (p.n_err != 0) return;
        const list = f.f_expr.x.list;
        if (f.i_ob_tab >= 0) {
            // Feed the rows of the ORDER BY table to OP_AggStep in order.
            const n_arg: i32 = @intCast(list.?.len());
            const reg_agg = expr_mod.getTempRange(p, n_arg);
            var n_key: i32 = 0;
            if (f.b_ob_payload) {
                n_key = @intCast(f.f_expr.left.?.x.list.?.len());
                if (!f.b_ob_unique) n_key += 1;
            }
            const i_top = aux.addOp1(v, OP.Rewind, f.i_ob_tab);
            var j = n_arg - 1;
            while (j >= 0) : (j -= 1) _ = aux.addOp3(v, OP.Column, f.i_ob_tab, n_key + j, reg_agg + j);
            if (f.b_use_subtype) {
                const reg_subtype = expr_mod.getTempReg(p);
                const i_base_col = n_key + n_arg + @intFromBool(!f.b_ob_payload and !f.b_ob_unique);
                j = n_arg - 1;
                while (j >= 0) : (j -= 1) {
                    _ = aux.addOp3(v, OP.Column, f.i_ob_tab, i_base_col + j, reg_subtype);
                    _ = aux.addOp2(v, OP.SetSubtype, reg_subtype, reg_agg + j);
                }
                expr_mod.releaseTempReg(p, reg_subtype);
            }
            _ = aux.addOp3(v, OP.AggStep, 0, reg_agg, agg.funcReg(i));
            aux.appendP4(v, .{ .funcdef = f.func.? });
            aux.changeP5(v, @intCast(n_arg));
            _ = aux.addOp2(v, OP.Next, f.i_ob_tab, i_top + 1);
            aux.jumpHere(v, i_top);
            expr_mod.releaseTempRange(p, reg_agg, n_arg);
        }
        _ = aux.addOp2(v, OP.AggFinal, agg.funcReg(i), if (list) |l| @intCast(l.len()) else 0);
        aux.appendP4(v, .{ .funcdef = f.func.? });
    }
}

/// Port of updateAccumulator(): code the step of every aggregate for the
/// current row, and the accumulator columns (only for the first row if
/// `reg_acc` is set and there is no min() or max()).
fn updateAccumulator(p: *Parse, reg_acc: i32, agg: *AggInfo, e_distinct_type: int.WHERE_DISTINCT) void {
    const v = p.vdbe.?;
    var reg_hit: i32 = 0;
    var addr_hit_test: i32 = 0;
    if (p.n_err != 0) return;
    agg.direct_mode = true;
    for (agg.funcs.items, 0..) |*f, i| {
        var addr_next: i32 = 0;
        var reg_agg: i32 = 0;
        var reg_agg_sz: i32 = 0;
        var reg_distinct: i32 = 0;
        var n_arg: i32 = 0;
        const list = f.f_expr.x.list;
        if (f.f_expr.flags.WinFunc) {
            const filter = f.f_expr.y.win.?.filter;
            if (agg.n_accumulator != 0 and f.func.?.func_flags.NEEDCOLL and reg_acc != 0) {
                // The "magnet" register: populate the accumulators on the
                // first row even if the FILTER skips min() or max().
                if (reg_hit == 0) {
                    p.n_mem += 1;
                    reg_hit = p.n_mem;
                }
                _ = aux.addOp2(v, OP.Copy, reg_acc, reg_hit);
            }
            addr_next = aux.makeLabel(p);
            ec.exprIfFalse(p, filter, addr_next, vi.SQLITE_JUMPIFNULL);
        }
        if (f.i_ob_tab >= 0) {
            // The arguments go to the ORDER BY table; OP_AggStep runs at
            // the end.
            n_arg = @intCast(list.?.len());
            const ob_list = f.f_expr.left.?.x.list.?;
            reg_agg_sz = @intCast(ob_list.len());
            if (!f.b_ob_unique) reg_agg_sz += 1;
            if (f.b_ob_payload) reg_agg_sz += n_arg;
            if (f.b_use_subtype) reg_agg_sz += n_arg;
            reg_agg_sz += 1;
            reg_agg = expr_mod.getTempRange(p, reg_agg_sz);
            reg_distinct = reg_agg;
            _ = ec.codeExprList(p, ob_list, reg_agg, 0, ec.ECEL_DUP);
            var jj: i32 = @intCast(ob_list.len());
            if (!f.b_ob_unique) {
                _ = aux.addOp2(v, OP.Sequence, f.i_ob_tab, reg_agg + jj);
                jj += 1;
            }
            if (f.b_ob_payload) {
                reg_distinct = reg_agg + jj;
                _ = ec.codeExprList(p, list.?, reg_distinct, 0, ec.ECEL_DUP);
                jj += n_arg;
            }
            if (f.b_use_subtype) {
                const reg_base = if (f.b_ob_payload) reg_distinct else reg_agg;
                var kk: i32 = 0;
                while (kk < n_arg) : (kk += 1) {
                    _ = aux.addOp2(v, OP.GetSubtype, reg_base + kk, reg_agg + jj);
                    jj += 1;
                }
            }
        } else if (list) |l| {
            n_arg = @intCast(l.len());
            reg_agg = expr_mod.getTempRange(p, n_arg);
            reg_distinct = reg_agg;
            _ = ec.codeExprList(p, l, reg_agg, 0, ec.ECEL_DUP);
        }
        if (f.i_distinct >= 0 and list != null) {
            if (addr_next == 0) addr_next = aux.makeLabel(p);
            f.i_distinct = codeDistinct(p, e_distinct_type, f.i_distinct, addr_next, list.?, reg_distinct);
        }
        if (f.i_ob_tab >= 0) {
            // A row of the ORDER BY table.
            _ = aux.addOp3(v, OP.MakeRecord, reg_agg, reg_agg_sz - 1, reg_agg + reg_agg_sz - 1);
            _ = aux.addOp4Int(v, OP.IdxInsert, f.i_ob_tab, reg_agg + reg_agg_sz - 1, reg_agg, reg_agg_sz - 1);
            expr_mod.releaseTempRange(p, reg_agg, reg_agg_sz);
        } else {
            if (f.func.?.func_flags.NEEDCOLL) {
                var c: ?*CollSeq = null;
                for (list.?.slice()) |item| {
                    if (c != null) break;
                    c = expr_mod.collSeq(p, item.expr);
                }
                if (reg_hit == 0 and agg.n_accumulator != 0) {
                    p.n_mem += 1;
                    reg_hit = p.n_mem;
                }
                _ = aux.addOp4(v, OP.CollSeq, reg_hit, 0, 0, .{ .collseq = c orelse coll_mod.defaultColl() });
            }
            _ = aux.addOp3(v, OP.AggStep, 0, reg_agg, agg.funcReg(i));
            aux.appendP4(v, .{ .funcdef = f.func.? });
            aux.changeP5(v, @intCast(n_arg));
            expr_mod.releaseTempRange(p, reg_agg, n_arg);
        }
        if (addr_next != 0) aux.resolveLabel(v, addr_next);
        if (p.n_err != 0) return;
    }
    if (reg_hit == 0 and agg.n_accumulator != 0) reg_hit = reg_acc;
    if (reg_hit != 0) addr_hit_test = aux.addOp1(v, OP.If, reg_hit);
    for (agg.cols.items[0..@intCast(agg.n_accumulator)], 0..) |c, i| {
        ec.exprCode(p, c.c_expr, agg.columnReg(i));
        if (p.n_err != 0) return;
    }
    agg.direct_mode = false;
    if (addr_hit_test != 0) aux.jumpHereOrPopInst(v, addr_hit_test);
}

/// Walker callback of havingToWhere(): descend through AND nodes; move any
/// other term that is constant or GROUP BY terms to the WHERE clause,
/// leaving a "1" in its place.
fn havingToWhereExprCb(w: *Walker, e: *Expr) WRC {
    if (e.op == TK.AND) return WRC.Continue;
    const s = w.u.select.?;
    const p = w.parse.?;
    // An agg_info here (before the HAVING clause is analyzed) means a
    // correlated reference to an outer aggregate, whose AggInfo moving it
    // could corrupt.
    if (expr_mod.isConstantOrGroupBy(p, e, s.group_by.?) and !e.alwaysFalse() and e.agg_info == null) {
        const new = expr_mod.exprInt32(p.arena, 1) catch {
            oom(p);
            return WRC.Abort;
        };
        const where = s.where;
        std.mem.swap(Expr, new, e);
        s.where = expr_mod.exprAnd(p, where, new) catch {
            oom(p);
            return WRC.Abort;
        };
        w.e_code = 1;
    }
    return WRC.Prune;
}

/// Port of havingToWhere(): move the HAVING terms made of constants and
/// BINARY GROUP BY terms to the WHERE clause, where they filter rows
/// before grouping:
///
///     SELECT * FROM <tables> WHERE a=? GROUP BY b HAVING b=? AND c=?
///  -> SELECT * FROM <tables> WHERE a=? AND b=? GROUP BY b HAVING c=?
fn havingToWhere(p: *Parse, s: *Select) void {
    var w: Walker = .{
        .parse = p,
        .expr_callback = havingToWhereExprCb,
        .u = .{ .select = s },
    };
    _ = walker.walkExpr(&w, s.having);
}

/// Port of isSelfJoinView(): an earlier materialization of the same view
/// in tab_list[first..end], or null.
fn isSelfJoinView(tab_list: *SrcList, this: *SrcItem, first: usize, end: usize) ?*SrcItem {
    const sel = this.u4.subq.?.select;
    if (sel.sel_flags.PushDown) return null;
    for (tab_list.slice()[first..end]) |*item| {
        if (!item.fg.is_subquery) continue;
        if (item.fg.via_coroutine) continue;
        const name = item.name orelse continue;
        if (item.s_tab.?.schema != this.s_tab.?.schema) continue;
        if (!ctype.eqlNoCase(name, this.name orelse "")) continue;
        const s1 = item.u4.subq.?.select;
        if (item.s_tab.?.schema == null and sel.sel_id != s1.sel_id) continue;
        if (s1.sel_flags.PushDown) continue;
        return item;
    }
    return null;
}

/// Port of countOfViewOptimization(): rewrite
///
///     SELECT count(*) FROM (SELECT x FROM t1 UNION ALL SELECT y FROM t2)
///  -> SELECT (SELECT count(*) FROM t1)+(SELECT count(*) FROM t2)
///
/// when the subquery is a UNION ALL without LIMIT, WHERE, GROUP BY,
/// HAVING, DISTINCT or aggregates, and the outer query is a plain
/// count(*). Returns true if done.
fn countOfViewOptimization(p: *Parse, s: *Select) Oom!bool {
    if (!s.sel_flags.Aggregate) return false;
    if (s.e_list.?.len() != 1) return false;
    if (s.where != null) return false;
    if (s.having != null) return false;
    if (s.group_by != null) return false;
    if (s.order_by != null) return false;
    const count = s.e_list.?.at(0).expr.?;
    if (count.op != TK.AGG_FUNCTION) return false;
    if (!ctype.eqlNoCase(count.token(), "count")) return false;
    if (count.x.list != null) return false; // count(*)
    if (s.src.?.len() != 1) return false;
    if (count.flags.WinFunc) return false;
    const from = s.src.?.at(0);
    if (!from.fg.is_subquery) return false;
    if (s.sel_flags.Correlated) return false;
    var sub: ?*Select = from.u4.subq.?.select;
    if (sub.?.prior == null) return false; // a compound
    if (sub.?.sel_flags.CopyCte) return false; // not a CTE
    while (sub) |sx| : (sub = sx.prior) {
        if (sx.op != TK.ALL and sx.prior != null) return false;
        if (sx.where != null) return false;
        if (sx.limit != null) return false;
        if (sx.sel_flags.intersects(.{ .Aggregate = true, .Distinct = true })) return false;
        std.debug.assert(sx.having == null);
    }

    var e: ?*Expr = null;
    sub = build.subqueryDetach(from);
    const new_src = try p.arena.create(SrcList);
    new_src.* = .{};
    s.src = new_src;
    while (sub) |sx| {
        const prior = sx.prior;
        sx.prior = null;
        sx.next = null;
        sx.sel_flags.Aggregate = true;
        sx.sel_flags.Compound = false;
        sx.n_select_row = 0;
        var term = if (prior != null) (try expr_mod.exprDup(p.arena, count)).? else count;
        sx.e_list = try expr_mod.listAppend(p, null, term);
        term = try expr_mod.pExpr(p, TK.SELECT, null, null);
        expr_mod.pExprAddSelect(p, term, sx);
        e = if (e) |x| try expr_mod.pExpr(p, TK.PLUS, term, x) else term;
        if (p.n_err != 0) e = null;
        sub = prior;
    }
    s.e_list.?.at(0).expr = e;
    s.sel_flags.Aggregate = false;
    return true;
}

/// Port of fromClauseTermCanBeCoroutine(): FROM-clause subquery `i` can
/// be a co-routine rather than materialized.
fn fromClauseTermCanBeCoroutine(p: *Parse, tab_list: *SrcList, i_arg: usize, sel_flags: SF) bool {
    var i = i_arg;
    const item = tab_list.at(i);
    if (item.fg.is_cte) {
        const use = item.u2.cte_use.?;
        if (use.e_m10d == .yes) return false;
        if (use.n_use >= 2 and use.e_m10d != .no) return false;
    }
    if (tab_list.at(0).fg.jointype.LTORJ) return false;
    if (p.db.optDisabled(int.OPT.Coroutines)) return false;
    if (isSelfJoinView(tab_list, item, i + 1, tab_list.len()) != null) return false;
    if (i == 0) {
        if (tab_list.len() == 1) return true;
        if (tab_list.at(1).fg.jointype.CROSS) return true;
        if (sel_flags.UpdateFrom) return false;
        return true;
    }
    if (sel_flags.UpdateFrom) return false;
    while (true) {
        if (tab_list.at(i).fg.jointype.intersects(.{ .OUTER = true, .CROSS = true })) return false;
        if (i == 0) break;
        i -= 1;
        if (tab_list.at(i).fg.is_subquery) return false;
    }
    return true;
}

/// Port of existsToJoin(): turn the "EXISTS (SELECT ...)" terms of the
/// WHERE clause `where_arg` of `s` into joins:
///
///     SELECT name FROM sailors AS S WHERE EXISTS (
///       SELECT * FROM reserves AS R WHERE S.sid=R.sid AND R.day='2022-10-25')
///  -> SELECT name FROM sailors AS S, reserves AS R
///       WHERE S.sid=R.sid AND R.day='2022-10-25'
///
/// The new term is tagged fg.from_exists so that the planner leaves its
/// loop after the first match.
fn existsToJoin(p: *Parse, s: *Select, where_arg: ?*Expr) Oom!void {
    const where = where_arg orelse return;
    if (p.n_err == 0 and !where.flags.intersects(.{ .OuterON = true, .InnerON = true }) and s.src.?.len() < int.bms and
        (s.limit == null or s.limit.?.right == null))
    {
        if (where.op == TK.AND) {
            const right = where.right;
            try existsToJoin(p, s, where.left);
            try existsToJoin(p, s, right);
        } else if (where.op == TK.EXISTS) {
            const sub = where.x.select.?;
            const sub_where = sub.where;
            if (sub.src.?.len() == 1 and !sub.sel_flags.Aggregate and !sub.src.?.at(0).fg.is_subquery and
                sub.limit == null and sub.prior == null)
            {
                // The EXISTS might be a copy of another one in the tree, so
                // its cursor must be made unique.
                const csr_map = try p.arena.alloc(i32, @intCast(p.n_tab + 2));
                @memset(csr_map, 0);
                csr_map[0] = p.n_tab + 1;
                renumberCursors(p, sub, -1, csr_map);

                where.* = .{ .op = TK.INTEGER, .flags = .{ .IntValue = true }, .u = .{ .value = 1 } };
                sub.src.?.at(0).fg.from_exists = true;
                s.src = try build.srcListAppendList(p, s.src.?, sub.src);
                if (sub_where) |sw| {
                    s.where = try expr_mod.pExpr(p, TK.AND, s.where, sw);
                    sub.where = null;
                }
                sub.src = null;
                const src = s.src.?;
                recomputeColumnsUsed(s, src.at(src.len() - 1));
            }
        }
    }
}

/// CheckOnCtx: the state of selectCheckOnClauses().
pub const CheckOnCtx = struct {
    src: *SrcList,
    /// Cursors must be left of this one, if not negative.
    i_join: i32 = -1,
    func_arg: bool = false,
    parent: ?*CheckOnCtx = null,
};

fn hasRightJoin(src: *SrcList) bool {
    return src.at(0).fg.jointype.LTORJ;
}

fn selectCheckOnClausesExpr(w: *Walker, e: *Expr) WRC {
    const c0 = w.u.check_on_ctx;
    var ctx: ?*CheckOnCtx = c0;
    // The root of an ON term of an OUTER join, or of an INNER join in a
    // FROM clause with a RIGHT or FULL join.
    if (e.flags.OuterON or (e.flags.InnerON and hasRightJoin(c0.src))) {
        if (c0.i_join < 0) {
            c0.i_join = e.w.join;
            _ = walker.walkExprNN(w, e);
            c0.i_join = -1;
            return WRC.Prune;
        }
    }
    if (e.op == TK.COLUMN) {
        // The column must not be of a table right of the ON term's join.
        const i_tab = e.i_table;
        while (ctx) |c| {
            const items = c.src.slice();
            var ii: usize = 0;
            while (ii < items.len and items[ii].i_cursor != i_tab) ii += 1;
            if (ii < items.len) {
                if (c.i_join >= 0) {
                    var k = ii;
                    while (k > 0) {
                        k -= 1;
                        if (items[k].i_cursor == c.i_join) {
                            util.errorMsg(w.parse.?, "{s} references tables to its right", .{if (c.func_arg) "table-function argument" else "ON clause"});
                            return WRC.Abort;
                        }
                    }
                }
                break;
            }
            ctx = c.parent;
        }
    }
    return WRC.Continue;
}

fn selectCheckOnClausesSelect(w: *Walker, s: *Select) WRC {
    const ctx = w.u.check_on_ctx;
    if (s.src == ctx.src or s.src.?.len() == 0) return WRC.Continue;
    var sub: CheckOnCtx = .{ .src = s.src.?, .parent = ctx };
    w.u = .{ .check_on_ctx = &sub };
    _ = walker.walkSelect(w, s);
    w.u = .{ .check_on_ctx = ctx };
    s.sel_flags.OnToWhere = false;
    return WRC.Prune;
}

/// Port of sqlite3SelectCheckOnClauses(): ON clauses (and table-valued
/// function arguments) must not refer to tables on their right.
pub fn selectCheckOnClauses(p: *Parse, s: *Select) void {
    var ctx: CheckOnCtx = .{ .src = s.src.? };
    var w: Walker = .{
        .parse = p,
        .expr_callback = selectCheckOnClausesExpr,
        .select_callback = selectCheckOnClausesSelect,
        .u = .{ .check_on_ctx = &ctx },
    };
    _ = walker.walkExpr(&w, s.where);
    s.sel_flags.OnToWhere = false;

    ctx.func_arg = true;
    const items = s.src.?.slice();
    for (items, 0..) |*item, ii| {
        if (!item.fg.is_tab_func) continue;
        ctx.i_join = -1;
        if (item.fg.jointype.intersects(.{ .LTORJ = true, .RIGHT = true })) {
            ctx.i_join = item.i_cursor;
        } else {
            for (items[ii + 1 ..], ii + 1..) |*item2, jj| {
                if (item2.fg.jointype.OUTER) {
                    ctx.i_join = items[jj - 1].i_cursor;
                    break;
                }
            }
        }
        if (ctx.i_join >= 0) _ = walker.walkExprList(&w, item.u1.func_arg);
    }
}

/// Port of sqlite3CopySortOrder(): give `p1` the sort orders of `p2` if
/// they have the same length.
fn copySortOrder(p1: *ExprList, p2: ?*ExprList) bool {
    const l2 = p2 orelse return false;
    if (p1.len() != l2.len()) return false;
    for (p1.slice(), l2.slice()) |*a, b| a.fg.sort_flags = b.fg.sort_flags & int.KeyInfoOrder.desc;
    return true;
}

/// IgnorableDistinct() and IgnorableOrderby().
fn ignorableDistinct(dest: *const SelectDest) bool {
    return dest.e_dest.int() <= SRT.DistQueue.int();
}

fn ignorableOrderby(dest: *const SelectDest) bool {
    return dest.e_dest.int() <= SRT.Fifo.int();
}

/// Port of sqlite3Select(): generate code for a SELECT, sending the rows
/// to `dest`. On error (C: nonzero) the error is in `p`.
pub fn select(p: *Parse, s: *Select, dest: *SelectDest) int.ParseError!void {
    if (p.syntax_only) return;
    return selectImpl(p, s, dest) catch |err| switch (err) {
        error.OutOfMemory => {
            oom(p);
            return error.ParseFailed;
        },
        error.ParseFailed => |e| return e,
    };
}

fn selectImpl(p: *Parse, s: *Select, dest: *SelectDest) (Oom || int.ParseError)!void {
    const db = p.db;
    const v = build.getVdbe(p) orelse return error.ParseFailed;
    if (p.n_err != 0) return error.ParseFailed;

    if (ignorableDistinct(dest)) {
        // These destinations ignore ORDER BY and DISTINCT.
        s.order_by = null;
        s.sel_flags.Distinct = false;
    }
    selectPrep(p, s, null);
    if (p.n_err != 0) return error.ParseFailed;

    // UPDATE ... FROM: the target may not appear in the FROM clause.
    if (s.sel_flags.UFSrcCheck) {
        const p0 = s.src.?.at(0);
        if (sameSrcAlias(p0, s.src.?)) {
            util.errorMsg(p, "target object/alias may not appear in FROM clause: {s}", .{p0.alias orelse p0.s_tab.?.name});
            return error.ParseFailed;
        }
        s.sel_flags.UFSrcCheck = false;
    }

    if (dest.e_dest == SRT.Output) generateColumnNames(p, s);

    try window.windowRewrite(p, s);
    var tab_list = s.src.?;
    var is_agg = s.sel_flags.Aggregate;
    var sort: SortCtx = .{ .order_by = s.order_by };

    // Optimize the FROM clause: OUTER JOIN strength reduction, removal of
    // pointless subquery ORDER BYs, and query flattening.
    var i_from: usize = 0;
    while (s.prior == null and i_from < tab_list.len()) {
        const i = i_from;
        i_from += 1;
        const item = tab_list.at(i);
        const sub: ?*Select = if (item.fg.is_subquery) item.u4.subq.?.select else null;
        const t = item.s_tab.?;

        // LEFT JOIN becomes JOIN, RIGHT JOIN becomes JOIN and FULL JOIN
        // becomes RIGHT JOIN when the WHERE clause rules out the NULL row
        // of the i-th table.
        if (item.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true }) and
            expr_mod.impliesNonNullRow(s.where, item.i_cursor, item.fg.jointype.LTORJ) and
            !db.optDisabled(int.OPT.SimplifyJoin))
        {
            if (item.fg.jointype.LEFT) {
                if (item.fg.jointype.RIGHT) {
                    item.fg.jointype.LEFT = false;
                } else {
                    item.fg.jointype = item.fg.jointype.without(.{ .LEFT = true, .OUTER = true });
                    unsetJoinExpr(s.where, item.i_cursor, false);
                }
            }
            if (item.fg.jointype.LTORJ) {
                for (tab_list.slice()[i + 1 ..]) |*item2| {
                    if (item2.fg.jointype.RIGHT) {
                        if (item2.fg.jointype.LEFT) {
                            item2.fg.jointype.RIGHT = false;
                        } else {
                            item2.fg.jointype = item2.fg.jointype.without(.{ .RIGHT = true, .OUTER = true });
                            unsetJoinExpr(s.where, item2.i_cursor, true);
                        }
                    }
                }
                var j = tab_list.len();
                while (j > 0) {
                    j -= 1;
                    tab_list.at(j).fg.jointype.LTORJ = false;
                    if (tab_list.at(j).fg.jointype.RIGHT) break;
                }
            }
        }

        const sq = sub orelse continue;
        // The declared columns of a view must match its SELECT.
        if (t.cols.len != sq.e_list.?.len()) {
            util.errorMsg(p, "expected {d} columns for '{s}' but got {d}", .{ t.cols.len, t.name, sq.e_list.?.len() });
            return error.ParseFailed;
        }
        // A MATERIALIZED CTE is an optimization fence.
        if (item.fg.is_cte and item.u2.cte_use.?.e_m10d == .yes) continue;

        // An aggregate subquery is not flattened: that is only possible if
        // the outer query is not a join, and then the subquery is a
        // co-routine anyway.
        if (sq.sel_flags.Aggregate) continue;

        // Omit an ORDER BY of a subquery that does nothing, so that it
        // does not block flattening. It is kept with a LIMIT, for a window
        // function or recursive CTE subquery, in UPDATE FROM, if the outer
        // query uses an aggregate other than count(), min() or max(), and
        // unless the outer query has its own ORDER BY or is a join.
        if (sq.order_by != null and (s.order_by != null or tab_list.len() > 1) and sq.limit == null and
            !sq.sel_flags.intersects(.{ .OrderByReqd = true, .Recursive = true }) and !s.sel_flags.OrderByReqd and
            !db.optDisabled(int.OPT.OmitOrderBy))
        {
            sq.order_by = null;
        }

        // A subquery with ORDER BY that would be a co-routine is not
        // flattened into a query with a complex result set, so that in
        // "SELECT expensive_function(x) FROM (SELECT x FROM tab ORDER BY y
        // LIMIT 10)" the function only runs for the 10 output rows.
        if (sq.order_by != null and i == 0 and s.sel_flags.ComplexResult and
            (tab_list.len() == 1 or tab_list.at(1).fg.jointype.intersects(.{ .OUTER = true, .CROSS = true })))
        {
            continue;
        }

        if (try flattenSubquery(p, s, i, is_agg)) {
            if (p.n_err != 0) return error.ParseFailed;
            // Start over with the new FROM clause.
            i_from = 0;
        }
        tab_list = s.src.?;
        if (db.malloc_failed) return error.ParseFailed;
        if (!ignorableOrderby(dest)) sort.order_by = s.order_by;
    }

    // Compound SELECTs.
    if (s.prior != null) {
        const r = multiSelect(p, s, dest);
        if (s.next == null) aux.explainPop(p);
        return r;
    }
    defer aux.explainPop(p);

    // EXISTS (SELECT ...) terms of the WHERE clause may become joins.
    if (p.bhas_exists and !db.optDisabled(int.OPT.ExistsToJoin)) {
        try existsToJoin(p, s, s.where);
        tab_list = s.src.?;
    }

    // WHERE-clause constant propagation, for joins only: for a single
    // table the planner does the equivalent.
    if (s.where != null and s.where.?.op == TK.AND and !db.optDisabled(int.OPT.PropagateConst)) {
        _ = try propagateConstants(p, s);
    }

    if (!db.optDisabled(int.OPT.QueryFlattener | int.OPT.CountOfView) and try countOfViewOptimization(p, s)) {
        if (db.malloc_failed) return error.ParseFailed;
        tab_list = s.src.?;
    }

    // Code the FROM-clause subqueries.
    for (tab_list.slice(), 0..) |*item, i| {
        if (!item.fg.is_subquery) continue;
        const subq = item.u4.subq.?;
        const sub = subq.select;
        // Only once.
        if (subq.addr_fill_sub != 0) continue;
        p.n_height += expr_mod.selectExprHeight(s);

        // Copy WHERE-clause terms of the outer query into the subquery
        // (predicate push-down).
        if (!db.optDisabled(int.OPT.PushDown) and
            (!item.fg.is_cte or (item.u2.cte_use.?.e_m10d != .yes and item.u2.cte_use.?.n_use < 2)))
        {
            _ = try pushDownWhereTerms(p, sub, s.where, tab_list, i);
        }

        // Unused result columns of the subquery become NULLs.
        if (!db.optDisabled(int.OPT.NullUnusedCols)) _ = disableUnusedSubqueryResultColumns(item);

        if (fromClauseTermCanBeCoroutine(p, tab_list, i, s.sel_flags)) {
            // A co-routine returning one row per call.
            const addr_top = aux.currentAddr(v) + 1;
            p.n_mem += 1;
            subq.reg_return = p.n_mem;
            _ = aux.addOp3(v, OP.InitCoroutine, subq.reg_return, 0, addr_top);
            subq.addr_fill_sub = addr_top;
            var d = selectDestInit(SRT.Coroutine, subq.reg_return);
            _ = aux.explain(p, true, "CO-ROUTINE {f}", .{util.srcItemNameNoAlias(item)});
            select(p, sub, &d) catch {};
            item.s_tab.?.n_row_log_est = sub.n_select_row;
            item.fg.via_coroutine = true;
            subq.reg_result = d.i_sdst;
            aux.endCoroutine(v, subq.reg_return);
            aux.jumpHere(v, addr_top - 1);
            expr_mod.clearTempRegCache(p);
        } else if (item.fg.is_cte and item.u2.cte_use.?.addr_m9e > 0) {
            // A CTE already materialized: run its subroutine and use a
            // copy of its table.
            const use = item.u2.cte_use.?;
            _ = aux.addOp2(v, OP.Gosub, use.reg_rtn, use.addr_m9e);
            if (item.i_cursor != use.i_cur) _ = aux.addOp2(v, OP.OpenDup, item.i_cursor, use.i_cur);
            sub.n_select_row = use.n_row_est;
        } else if (isSelfJoinView(tab_list, item, 0, i)) |prior| {
            // Materialized by an earlier term of this FROM clause.
            const prior_subq = prior.u4.subq.?;
            if (prior_subq.addr_fill_sub != 0) _ = aux.addOp2(v, OP.Gosub, prior_subq.reg_return, prior_subq.addr_fill_sub);
            _ = aux.addOp2(v, OP.OpenDup, item.i_cursor, prior.i_cursor);
            sub.n_select_row = prior_subq.select.n_select_row;
        } else {
            // Materialize, in a subroutine that later uses can call.
            p.n_mem += 1;
            subq.reg_return = p.n_mem;
            const top_addr = aux.addOp0(v, OP.Goto);
            subq.addr_fill_sub = top_addr + 1;
            item.fg.is_materialized = true;
            var once_addr: i32 = 0;
            // An uncorrelated subquery is computed once.
            if (!item.fg.is_correlated) once_addr = aux.addOp0(v, OP.Once);
            var d = selectDestInit(SRT.EphemTab, item.i_cursor);
            _ = aux.explain(p, true, "MATERIALIZE {f}", .{util.srcItemNameNoAlias(item)});
            select(p, sub, &d) catch {};
            item.s_tab.?.n_row_log_est = sub.n_select_row;
            if (once_addr != 0) aux.jumpHere(v, once_addr);
            _ = aux.addOp2(v, OP.Return, subq.reg_return, top_addr + 1);
            aux.jumpHere(v, top_addr);
            expr_mod.clearTempRegCache(p);
            if (item.fg.is_cte and !item.fg.is_correlated) {
                const use = item.u2.cte_use.?;
                use.addr_m9e = subq.addr_fill_sub;
                use.reg_rtn = subq.reg_return;
                use.i_cur = item.i_cursor;
                use.n_row_est = sub.n_select_row;
            }
        }
        if (db.malloc_failed) return error.ParseFailed;
        p.n_height -= expr_mod.selectExprHeight(s);
    }

    var e_list = s.e_list.?;
    var where = s.where;
    var group_by = s.group_by;
    const having = s.having;
    var distinct: DistinctCtx = .{ .is_tnct = @intFromBool(s.sel_flags.Distinct) };

    // "SELECT DISTINCT xyz ... ORDER BY xyz" is coded as "... GROUP BY xyz
    // ORDER BY xyz".
    if (s.sel_flags.only(.{ .Distinct = true, .Aggregate = true }) == SF{ .Distinct = true } and copySortOrder(e_list, sort.order_by) and
        expr_mod.listCompare(e_list, sort.order_by, -1) == 0 and !db.optDisabled(int.OPT.GroupByOrder) and s.win == null)
    {
        s.sel_flags.Distinct = false;
        group_by = try expr_mod.listDup(p.arena, e_list);
        s.group_by = group_by;
        if (group_by) |gb| for (gb.slice(), 0..) |*item, i| {
            item.u = .{ .x = .{ .order_by_col = @intCast(i + 1) } };
        };
        s.sel_flags.Aggregate = true;
        is_agg = true;
        distinct.is_tnct = 2;
    }

    // The sorter of the ORDER BY (made a no-op if rows come out sorted).
    if (sort.order_by) |ob| {
        const ki = keyInfoFromExprList(p, ob, 0, e_list.len());
        sort.i_e_cursor = p.n_tab;
        p.n_tab += 1;
        sort.addr_sort_index = aux.addOp4(v, OP.OpenEphemeral, sort.i_e_cursor, @intCast(ob.len() + 1 + e_list.len()), 0, if (ki) |k| .{ .keyinfo = k } else .notused);
    } else {
        sort.addr_sort_index = -1;
    }

    // The output table.
    if (dest.e_dest == SRT.EphemTab) {
        _ = aux.addOp2(v, OP.OpenEphemeral, dest.i_sd_parm, @intCast(e_list.len()));
        if (s.sel_flags.NestedFrom) {
            // Unused result columns are dropped or NULL.
            var ii = e_list.len() - 1;
            while (ii > 0 and !e_list.at(ii).fg.used) : (ii -= 1) {
                e_list.items.items.len -= 1;
            }
            for (e_list.slice()) |item| {
                if (!item.fg.used) item.expr.?.op = TK.NULL;
            }
        }
    }

    // LIMIT.
    const i_end = aux.makeLabel(p);
    if (!s.sel_flags.FixedLimit) s.n_select_row = 320;
    if (s.limit != null) computeLimitRegisters(p, s, i_end);
    if (s.i_limit == 0 and sort.addr_sort_index >= 0) {
        aux.changeOpcode(v, sort.addr_sort_index, OP.SorterOpen);
        sort.sort_flags |= SORTFLAG_UseSorter;
    }

    // The table of DISTINCT.
    if (s.sel_flags.Distinct) {
        distinct.tab_tnct = p.n_tab;
        p.n_tab += 1;
        const ki = keyInfoFromExprList(p, s.e_list.?, 0, 0);
        distinct.addr_tnct = aux.addOp4(v, OP.OpenEphemeral, distinct.tab_tnct, 0, 0, if (ki) |k| .{ .keyinfo = k } else .notused);
        aux.changeP5(v, BTREE_UNORDERED);
        distinct.e_tnct_type = int.WHERE_DISTINCT.UNORDERED;
    } else {
        distinct.e_tnct_type = int.WHERE_DISTINCT.NOOP;
    }

    if (!is_agg and group_by == null) {
        // No aggregates and no GROUP BY.
        // C: selFlags & SF_FixedLimit, the bit of WHERE_USE_LIMIT.
        const wctrl_flags: WHERE = .{ .WANT_DISTINCT = distinct.is_tnct != 0, .USE_LIMIT = s.sel_flags.FixedLimit };
        const win = s.win; // The main window object, or null.
        if (win != null) window.windowCodeInit(p, s);
        const w = where_mod.whereBegin(p, tab_list, where, sort.order_by, s.e_list, s, wctrl_flags, s.n_select_row) orelse return error.ParseFailed;
        if (where_mod.outputRowCount(w) < s.n_select_row) {
            s.n_select_row = where_mod.outputRowCount(w);
            // A UNION CTE implies DISTINCT.
            if (dest.e_dest.int() <= SRT.DistQueue.int() and dest.e_dest.int() >= SRT.DistFifo.int()) s.n_select_row -= 30;
        }
        if (distinct.is_tnct != 0 and where_mod.isDistinct(w) != .NOOP) distinct.e_tnct_type = where_mod.isDistinct(w);
        if (sort.order_by) |ob| {
            sort.n_ob_sat = where_mod.isOrdered(w);
            sort.label_ob_lopt = where_mod.orderByLimitOptLabel(w);
            if (sort.n_ob_sat == ob.len()) sort.order_by = null;
        }
        // An unneeded sorter.
        if (sort.addr_sort_index >= 0 and sort.order_by == null) _ = aux.changeToNoop(v, sort.addr_sort_index);

        if (win != null) {
            const addr_gosub = aux.makeLabel(p);
            const i_cont = aux.makeLabel(p);
            const i_break = aux.makeLabel(p);
            p.n_mem += 1;
            const reg_gosub = p.n_mem;

            window.windowCodeStep(p, s, w, reg_gosub, addr_gosub);

            _ = aux.addOp2(v, OP.Goto, 0, i_break);
            aux.resolveLabel(v, addr_gosub);
            // The inner-loop subroutine.
            sort.label_ob_lopt = 0;
            selectInnerLoop(p, s, -1, &sort, &distinct, dest, i_cont, i_break);
            aux.resolveLabel(v, i_cont);
            _ = aux.addOp1(v, OP.Return, reg_gosub);
            aux.resolveLabel(v, i_break);
        } else {
            // The standard inner loop.
            selectInnerLoop(p, s, -1, &sort, &distinct, dest, where_mod.continueLabel(w), where_mod.breakLabel(w));
            where_mod.whereEnd(w);
        }
    } else {
        // Aggregates and/or GROUP BY.
        var order_by_grp = false;
        if (group_by) |gb| {
            // No aliases between the result set and GROUP BY.
            for (s.e_list.?.slice()) |*item| item.u.x.alias = 0;
            for (gb.slice()) |*item| item.u.x.alias = 0;
            if (s.n_select_row > 66) s.n_select_row = 66;
            // Identical GROUP BY and ORDER BY.
            if (copySortOrder(gb, sort.order_by) and expr_mod.listCompare(gb, sort.order_by, -1) == 0) order_by_grp = true;
        } else {
            s.n_select_row = 0;
        }

        const addr_end = aux.makeLabel(p);

        // TK_COLUMN become TK_AGG_COLUMN; the aggregate functions go into
        // the AggInfo.
        const agg = try p.arena.create(AggInfo);
        agg.* = .{ .sel_id = s.sel_id };
        var nc: NameContext = .{ .parse = p, .src_list = tab_list, .u_nc = .{ .agg_info = agg }, .nc_flags = .{ .UAggInfo = true } };
        agg.n_sorting_column = if (group_by) |gb| @intCast(gb.len()) else 0;
        agg.group_by = group_by;
        expr_mod.analyzeAggList(&nc, e_list);
        expr_mod.analyzeAggList(&nc, sort.order_by);
        if (having) |h| {
            if (group_by != null) {
                havingToWhere(p, s);
                where = s.where;
            }
            expr_mod.analyzeAggregates(&nc, h);
        }
        agg.n_accumulator = @intCast(agg.cols.items.len);
        var min_max_order_by: ?*ExprList = null;
        const min_max_flag: WHERE = if (s.group_by == null and s.having == null and agg.funcs.items.len == 1)
            try minMaxQuery(p, agg.funcs.items[0].f_expr, &min_max_order_by)
        else
            WHERE.ORDERBY_NORMAL;
        analyzeAggFuncArgs(agg, &nc);
        if (db.malloc_failed) return error.ParseFailed;

        if (group_by) |gb| {
            var distinct_list: ?*ExprList = null;
            var dist_flag: WHERE = .{};
            if (agg.funcs.items.len == 1 and agg.funcs.items[0].i_distinct >= 0 and agg.funcs.items[0].f_expr.x.list != null) {
                const e = try expr_mod.exprDup(p.arena, agg.funcs.items[0].f_expr.x.list.?.at(0).expr);
                distinct_list = try expr_mod.listDup(p.arena, gb);
                distinct_list = try expr_mod.listAppend(p, distinct_list, e);
                dist_flag = .{ .WANT_DISTINCT = true, .AGG_DISTINCT = true };
            }

            // The sorter of the GROUP BY (made a no-op if not needed).
            agg.sorting_idx = p.n_tab;
            p.n_tab += 1;
            const key_info = keyInfoFromExprList(p, gb, 0, agg.cols.items.len);
            const addr_sorting_idx = aux.addOp4(v, OP.SorterOpen, agg.sorting_idx, @intCast(agg.n_sorting_column), 0, if (key_info) |k| .{ .keyinfo = k } else .notused);

            p.n_mem += 1;
            const i_use_flag = p.n_mem;
            p.n_mem += 1;
            const i_abort_flag = p.n_mem;
            p.n_mem += 1;
            const reg_output_row = p.n_mem;
            var addr_output_row = aux.makeLabel(p);
            p.n_mem += 1;
            const reg_reset = p.n_mem;
            const addr_reset = aux.makeLabel(p);
            const n_gb: i32 = @intCast(gb.len());
            const i_a_mem = p.n_mem + 1;
            p.n_mem += n_gb;
            const i_b_mem = p.n_mem + 1;
            p.n_mem += n_gb;
            _ = aux.addOp2(v, OP.Integer, 0, i_abort_flag);
            _ = aux.addOp3(v, OP.Null, 0, i_a_mem, i_a_mem + n_gb - 1);
            ec.nullRegisterRange(p, i_a_mem, n_gb);

            // The rows in GROUP BY order: sorted by the sorter unless the
            // loop delivers them so.
            _ = aux.addOp2(v, OP.Gosub, reg_reset, addr_reset);
            const w = where_mod.whereBegin(p, tab_list, where, gb, distinct_list, s, dist_flag.with(.{
                .DISTINCTBY = distinct.is_tnct == 2,
                .GROUPBY = distinct.is_tnct != 2,
                .SORTBYGROUP = order_by_grp,
            }), 0) orelse return error.ParseFailed;
            if (p.idx_epr != null) optimizeAggregateUseOfIndexedExpr(s, agg, &nc);
            assignAggregateRegisters(p, agg);
            const e_dist = where_mod.isDistinct(w);
            var group_by_sort = false;
            var sort_p_tab: i32 = 0;
            var sort_out: i32 = 0;
            if (where_mod.isOrdered(w) == n_gb) {
                group_by_sort = false;
            } else {
                _ = aux.explain(p, false, "USE TEMP B-TREE FOR {s}", .{if (distinct.is_tnct != 0 and !s.sel_flags.Distinct) "DISTINCT" else "GROUP BY"});
                group_by_sort = true;
                var n_col: i32 = n_gb;
                var j: i32 = n_gb;
                for (agg.cols.items) |c| {
                    if (c.i_sorter_column >= j) {
                        n_col += 1;
                        j += 1;
                    }
                }
                const reg_base = expr_mod.getTempRange(p, n_col);
                _ = ec.codeExprList(p, gb, reg_base, 0, 0);
                j = n_gb;
                agg.direct_mode = true;
                for (agg.cols.items) |c| {
                    if (c.i_sorter_column >= j) {
                        ec.exprCode(p, c.c_expr, j + reg_base);
                        j += 1;
                    }
                }
                agg.direct_mode = false;
                const reg_record = expr_mod.getTempReg(p);
                _ = aux.addOp3(v, OP.MakeRecord, reg_base, n_col, reg_record);
                _ = aux.addOp2(v, OP.SorterInsert, agg.sorting_idx, reg_record);
                expr_mod.releaseTempReg(p, reg_record);
                expr_mod.releaseTempRange(p, reg_base, n_col);
                where_mod.whereEnd(w);
                sort_p_tab = p.n_tab;
                agg.sorting_idx_ptab = sort_p_tab;
                p.n_tab += 1;
                sort_out = expr_mod.getTempReg(p);
                _ = aux.addOp3(v, OP.OpenPseudo, sort_p_tab, sort_out, n_col);
                _ = aux.addOp2(v, OP.SorterSort, agg.sorting_idx, addr_end);
                agg.use_sorting_idx = true;
            }

            // The indexed subexpressions tagged by
            // optimizeAggregateUseOfIndexedExpr() are read from the index.
            if (p.idx_epr != null) aggregateConvertIndexedExprRefToColumn(agg);

            // Rows already in ORDER BY order need no sorter.
            if (order_by_grp and !db.optDisabled(int.OPT.GroupByOrder) and (group_by_sort or where_mod.isSorted(w))) {
                sort.order_by = null;
                _ = aux.changeToNoop(v, sort.addr_sort_index);
            }

            // The current GROUP BY terms go to b0, b1, ...; compare with the
            // previous row's in a0, a1, ...
            const addr_top_of_loop = aux.currentAddr(v);
            if (group_by_sort) _ = aux.addOp3(v, OP.SorterData, agg.sorting_idx, sort_out, sort_p_tab);
            for (gb.slice(), 0..) |item, jj| {
                const j: i32 = @intCast(jj);
                const order_by_col = item.u.x.order_by_col;
                if (group_by_sort) {
                    _ = aux.addOp3(v, OP.Column, sort_p_tab, j, i_b_mem + j);
                } else {
                    agg.direct_mode = true;
                    ec.exprCode(p, item.expr, i_b_mem + j);
                }
                if (order_by_col != 0) {
                    var x = s.e_list.?.at(order_by_col - 1).expr.?;
                    var base = expr_mod.skipCollateAndLikely(x);
                    while (base != null and base.?.op == TK.IF_NULL_ROW) {
                        x = base.?.left.?;
                        base = expr_mod.skipCollateAndLikely(x);
                    }
                    if (base) |b| if (b.op != TK.AGG_COLUMN and b.op != TK.REGISTER) {
                        expr_mod.toRegister(x, i_a_mem + j);
                    };
                }
            }
            _ = aux.addOp4(v, OP.Compare, i_a_mem, i_b_mem, n_gb, if (key_info) |k| .{ .keyinfo = k } else .notused);
            const addr1 = aux.currentAddr(v);
            _ = aux.addOp3(v, OP.Jump, addr1 + 1, 0, addr1 + 1);

            // A new group: output the previous one and reset.
            _ = aux.addOp2(v, OP.Gosub, reg_output_row, addr_output_row);
            ec.codeMove(p, i_b_mem, i_a_mem, n_gb);
            _ = aux.addOp2(v, OP.IfPos, i_abort_flag, addr_end);
            _ = aux.addOp2(v, OP.Gosub, reg_reset, addr_reset);

            // Update the accumulators with the current row.
            aux.jumpHere(v, addr1);
            updateAccumulator(p, i_use_flag, agg, e_dist);
            _ = aux.addOp2(v, OP.Integer, 1, i_use_flag);

            // The end of the loop.
            if (group_by_sort) {
                _ = aux.addOp2(v, OP.SorterNext, agg.sorting_idx, addr_top_of_loop);
            } else {
                where_mod.whereEnd(w);
                _ = aux.changeToNoop(v, addr_sorting_idx);
            }

            // Output the last group.
            _ = aux.addOp2(v, OP.Gosub, reg_output_row, addr_output_row);
            _ = aux.goto_(v, addr_end);

            // The subroutine outputting a group (a no-op if empty; it sets
            // the abort flag at the LIMIT).
            const addr_set_abort = aux.currentAddr(v);
            _ = aux.addOp2(v, OP.Integer, 1, i_abort_flag);
            _ = aux.addOp1(v, OP.Return, reg_output_row);
            aux.resolveLabel(v, addr_output_row);
            addr_output_row = aux.currentAddr(v);
            _ = aux.addOp2(v, OP.IfPos, i_use_flag, addr_output_row + 2);
            _ = aux.addOp1(v, OP.Return, reg_output_row);
            finalizeAggFunctions(p, agg);
            ec.exprIfFalse(p, having, addr_output_row + 1, vi.SQLITE_JUMPIFNULL);
            selectInnerLoop(p, s, -1, &sort, &distinct, dest, addr_output_row + 1, addr_set_abort);
            _ = aux.addOp1(v, OP.Return, reg_output_row);

            // The subroutine resetting the accumulators.
            aux.resolveLabel(v, addr_reset);
            resetAccumulator(p, agg);
            _ = aux.addOp2(v, OP.Integer, 0, i_use_flag);
            _ = aux.addOp1(v, OP.Return, reg_reset);

            if (!dist_flag.isEmpty() and e_dist != int.WHERE_DISTINCT.NOOP) {
                const f = &agg.funcs.items[0];
                fixDistinctOpenEph(p, e_dist, f.i_distinct, f.i_dist_addr);
            }
        } else {
            // Aggregates without GROUP BY.
            if (isSimpleCount(s, agg)) |t| {
                // "SELECT count(*) FROM <tbl>": OP_Count on the table or
                // its smallest index.
                const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
                const i_csr = p.n_tab;
                p.n_tab += 1;
                var key_info: ?*KeyInfo = null;
                var best: ?*Index = null;
                var i_root = t.tnum;
                build.codeVerifySchema(p, i_db);
                if (!t.hasRowid()) best = build.primaryKeyIndex(t);
                if (!s.src.?.at(0).fg.not_indexed) {
                    var idx = t.index;
                    while (idx) |ix| : (idx = ix.next) {
                        if (!ix.unordered and ix.sz_idx_row < t.sz_tab_row and ix.part_idx_where == null and
                            (best == null or ix.sz_idx_row < best.?.sz_idx_row))
                        {
                            best = ix;
                        }
                    }
                }
                if (best) |b| {
                    i_root = b.tnum;
                    key_info = build.keyInfoOfIndex(p, b);
                }
                _ = aux.addOp4Int(v, OP.OpenRead, i_csr, @intCast(i_root), @intCast(i_db), 1);
                if (key_info) |k| aux.changeP4(v, -1, .{ .keyinfo = k });
                assignAggregateRegisters(p, agg);
                _ = aux.addOp2(v, OP.Count, i_csr, agg.funcReg(0));
                _ = aux.addOp1(v, OP.Close, i_csr);
                explainSimpleCount(p, t, best);
            } else {
                // The general case.
                var reg_acc: i32 = 0;
                var distinct_list: ?*ExprList = null;
                var dist_flag: WHERE = .{};
                // regAcc is 0 for the first row and 1 after, so that the
                // accumulators are set once (unless min() or max() set them).
                if (agg.n_accumulator != 0) {
                    const has_minmax = for (agg.funcs.items) |f| {
                        if (f.f_expr.flags.WinFunc) continue;
                        if (f.func.?.func_flags.NEEDCOLL) break true;
                    } else false;
                    if (!has_minmax) {
                        p.n_mem += 1;
                        reg_acc = p.n_mem;
                        _ = aux.addOp2(v, OP.Integer, 0, reg_acc);
                    }
                } else if (agg.funcs.items.len == 1 and agg.funcs.items[0].i_distinct >= 0) {
                    distinct_list = agg.funcs.items[0].f_expr.x.list;
                    if (distinct_list != null) dist_flag = .{ .WANT_DISTINCT = true, .AGG_DISTINCT = true };
                }
                assignAggregateRegisters(p, agg);
                resetAccumulator(p, agg);

                const w = where_mod.whereBegin(p, tab_list, where, min_max_order_by, distinct_list, s, min_max_flag.with(dist_flag), 0) orelse return error.ParseFailed;
                const e_dist = where_mod.isDistinct(w);
                updateAccumulator(p, reg_acc, agg, e_dist);
                if (e_dist != int.WHERE_DISTINCT.NOOP and agg.funcs.items.len > 0) {
                    const f = &agg.funcs.items[0];
                    fixDistinctOpenEph(p, e_dist, f.i_distinct, f.i_dist_addr);
                }
                if (reg_acc != 0) _ = aux.addOp2(v, OP.Integer, 1, reg_acc);
                if (!min_max_flag.isEmpty()) where_mod.minMaxOptEarlyOut(v, w);
                where_mod.whereEnd(w);
                finalizeAggFunctions(p, agg);
            }

            sort.order_by = null;
            ec.exprIfFalse(p, having, addr_end, vi.SQLITE_JUMPIFNULL);
            selectInnerLoop(p, s, -1, null, null, dest, addr_end, addr_end);
        }
        aux.resolveLabel(v, addr_end);
    }

    if (distinct.e_tnct_type == int.WHERE_DISTINCT.UNORDERED) explainTempTable(p, "DISTINCT");

    // Sort the results.
    if (sort.order_by != null) generateSortTail(p, s, &sort, @intCast(e_list.len()), dest);

    aux.resolveLabel(v, i_end);
    if (p.n_err > 0) return error.ParseFailed;
}

/// Port of minMaxQuery(): WHERE_ORDERBY_MIN or _MAX if `func` is min()
/// or max() of one argument, with the ORDER BY that lets the loop find
/// the value in `min_max` ; else WHERE_ORDERBY_NORMAL.
fn minMaxQuery(p: *Parse, func: *Expr, min_max: *?*ExprList) Oom!WHERE {
    std.debug.assert(func.op == TK.AGG_FUNCTION);
    const list = func.x.list orelse return WHERE.ORDERBY_NORMAL;
    if (list.len() != 1 or func.flags.WinFunc or p.db.optDisabled(int.OPT.MinMaxOpt)) return WHERE.ORDERBY_NORMAL;
    const name = func.token();
    var ret: WHERE = undefined;
    var sort_flags: u8 = 0;
    if (ctype.eqlNoCase(name, "min")) {
        ret = .{ .ORDERBY_MIN = true };
        if (expr_mod.canBeNull(list.at(0).expr.?)) sort_flags = int.KeyInfoOrder.bignull;
    } else if (ctype.eqlNoCase(name, "max")) {
        ret = .{ .ORDERBY_MAX = true };
        sort_flags = int.KeyInfoOrder.desc;
    } else {
        return WHERE.ORDERBY_NORMAL;
    }
    const ob = (try expr_mod.listDup(p.arena, list)).?;
    ob.at(0).fg.sort_flags = sort_flags;
    min_max.* = ob;
    return ret;
}

/// Port of explainTempTable().
fn explainTempTable(p: *Parse, usage: []const u8) void {
    _ = aux.explain(p, false, "USE TEMP B-TREE FOR {s}", .{usage});
}

/// Port of explainSimpleCount(): the EXPLAIN QUERY PLAN line of
/// "SELECT count(*) FROM <tbl>".
fn explainSimpleCount(p: *Parse, t: *Table, idx: ?*Index) void {
    if (p.explain != 2) return;
    const cover = if (idx) |ix| t.hasRowid() or !ix.isPrimaryKey() else false;
    _ = aux.explain(p, false, "SCAN {s}{s}{s}", .{ t.name, if (cover) " USING COVERING INDEX " else "", if (cover) idx.?.name else "" });
}

/// BTREE_UNORDERED: P5 of OP_OpenEphemeral for a table only used for
/// lookups.
const BTREE_UNORDERED: u16 = 8;

/// Port of sameSrcAlias(): the target of UPDATE ... FROM appears again in
/// the FROM clause (or its subqueries).
fn sameSrcAlias(p0: *SrcItem, src: *SrcList) bool {
    for (src.slice()) |*p1| {
        if (p0 != p1) {
            if (p0.s_tab == p1.s_tab and ctype.eqlNoCase(p0.alias orelse "", p1.alias orelse "")) return true;
            if (p1.fg.is_subquery and p1.u4.subq.?.select.sel_flags.NestedFrom and
                sameSrcAlias(p0, p1.u4.subq.?.select.src.?))
            {
                return true;
            }
        }
    }
    return false;
}
