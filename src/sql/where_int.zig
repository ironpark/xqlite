//! Structures and constants shared by the query planner (port of
//! whereInt.h). The planner is split over:
//!
//!   where.zig       where.c: sqlite3WhereBegin()/End() and the accessors,
//!                   automatic indexes, Bloom filters, ORDER BY analysis
//!                   and the path solver.
//!   where_loop.zig  where.c: WhereScan, sqlite3WhereFindTerm(), the cost
//!                   estimates and the WhereLoop builders (whereLoopAdd*).
//!   where_code.zig  wherecode.c: code for one loop, EXPLAIN QUERY PLAN
//!                   text, the RIGHT JOIN loop.
//!   where_expr.zig  whereexpr.c: WHERE clause splitting and analysis.
//!
//! All planner memory comes from the Parse arena (`p.arena`), so the C
//! code's free and destructor paths (whereLoopDelete, whereInfoFree,
//! sqlite3WhereClauseClear, ...) have little or nothing to do.
//!
//! C unions whose member depends on flags (WhereTerm.u, WhereLoop.u,
//! WhereLevel.u) are separate fields here, so reading the "wrong" member,
//! as the C code sometimes does harmlessly, is not a safety panic.
//!
//! Not ported: STAT4 (SQLITE_ENABLE_STAT4 is off by default in SQLite as
//! well), scan status. Of WHERETRACE only the WhereLoop listing is ported
//! (traceEnabled, showAllLoops; the xBestIndex inputs and outputs are not
//! printed).

const std = @import("std");
const int = @import("sqlite_int.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Select = int.Select;
const Index = int.Index;
const LogEst = int.LogEst;
const Bitmask = int.Bitmask;
const TK = int.TK;

/// Whether to print the planner's WhereLoops, as SQLite's ".wheretrace"
/// does in debug builds: only in Debug builds of xqlite, when the
/// XQ_WHERETRACE environment variable is set.
pub fn traceEnabled() bool {
    if (@import("builtin").mode != .debug) return false;
    return std.c.getenv("XQ_WHERETRACE") != null;
}

/// Port of sqlite3WhereLoopPrint() (with a WhereClause): one line
/// describing loop `l`, labelled `id`, to stderr.
pub fn loopPrint(l: *const WhereLoop, wc: *const WhereClause, id: u8) void {
    const w = wc.w_info;
    const nb: usize = 1 + (w.tab_list.len() + 3) / 4;
    const item = w.tab_list.at(l.i_tab);
    const m_all: Bitmask = if (nb * 4 >= 64) ALLBITS else (@as(Bitmask, 1) << @intCast(nb * 4)) - 1;
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    out.print("{c}{d:>2}.{x:0>[4]}.{x:0>[4]}", .{ id, l.i_tab, l.mask_self, l.prereq & m_all, nb }) catch {};
    out.print(" {s:>12}", .{item.alias orelse item.s_tab.?.name}) catch {};
    if (l.btree.index) |idx| {
        var name: []const u8 = idx.name;
        if (std.mem.startsWith(u8, name, "sqlite_autoindex_")) {
            name = name[std.mem.lastIndexOfScalar(u8, name, '_').?..];
        }
        out.print(".{s:<16} {d:>2}", .{ name, l.btree.n_eq }) catch {};
    } else {
        out.print("{s:>20}", .{""}) catch {};
    }
    if (l.ws_flags & WHERE_SKIPSCAN != 0) {
        out.print(" f {x:0>6} {d}-{d}", .{ l.ws_flags, l.n_lterm, l.n_skip }) catch {};
    } else {
        out.print(" f {x:0>6} N {d}", .{ l.ws_flags, l.n_lterm }) catch {};
    }
    out.print(" cost {d},{d},{d}\n", .{ l.r_setup, l.r_run, l.n_out }) catch {};
    std.debug.print("{s}", .{out.buffered()});
}

/// Port of showAllWhereLoops().
pub fn showAllLoops(w: *WhereInfo, wc: *const WhereClause) void {
    const labels = "0123456789abcdefghijklmnopqrstuvwyxzABCDEFGHIJKLMNOPQRSTUVWYXZ";
    var it = w.loops;
    var i: usize = 0;
    while (it) |l| : ({
        it = l.next_loop;
        i += 1;
    }) loopPrint(l, wc, labels[i % labels.len]);
}

/// MASKBIT(n).
pub inline fn maskBit(n: anytype) Bitmask {
    return @as(Bitmask, 1) << @intCast(n);
}

/// SMASKBIT32: bit `n` of a u32 mask, 0 for n >= 32.
pub inline fn smaskBit32(n: anytype) u32 {
    return if (n < 32) @as(u32, 1) << @intCast(n) else 0;
}

/// ALLBITS.
pub const ALLBITS: Bitmask = ~@as(Bitmask, 0);

/// Extra information of a WhereLevel that is a RIGHT JOIN (WhereRightJoin).
pub const WhereRightJoin = struct {
    /// Cursor used to determine prior matched rows.
    i_match: i32 = 0,
    /// Bloom filter for iRJMatch.
    reg_bloom: i32 = 0,
    /// Return register for the interior subroutine.
    reg_return: i32 = 0,
    /// Starting address of the interior subroutine.
    addr_subrtn: i32 = 0,
    /// The last opcode in the interior subroutine.
    end_subrtn: i32 = 0,
};

/// One IN operator driving a loop (struct InLoop).
pub const InLoop = struct {
    /// The VDBE cursor used by this IN operator.
    i_cur: i32 = 0,
    /// Top of the IN loop.
    addr_in_top: i32 = 0,
    /// Base register of multi-key index record.
    i_base: i32 = 0,
    /// Number of prior entries in the key.
    n_prefix: i32 = 0,
    /// IN loop terminator: OP_Next or OP_Prev.
    e_end_loop_op: u8 = 0,
};

/// How one nested loop is implemented (WhereLevel). WhereInfo.a[0] is the
/// outer loop.
pub const WhereLevel = struct {
    /// Memory cell used to implement LEFT OUTER JOIN.
    i_left_join: i32 = 0,
    /// The VDBE cursor used to access the table.
    i_tab_cur: i32 = 0,
    /// The VDBE cursor used to access pIdx.
    i_idx_cur: i32 = 0,
    /// Jump here to break out of the loop.
    addr_brk: i32 = 0,
    /// Abort the query due to empty table or similar.
    addr_halt: i32 = 0,
    /// Jump here to start the next IN combination.
    addr_nxt: i32 = 0,
    /// Jump here for next iteration of skip-scan.
    addr_skip: i32 = 0,
    /// Jump here to continue with the next loop cycle.
    addr_cont: i32 = 0,
    /// First instruction of interior of the loop.
    addr_first: i32 = 0,
    /// Beginning of the body of this loop.
    addr_body: i32 = 0,
    /// big-null flag reg. True if a NULL-scan is needed.
    reg_bignull: i32 = 0,
    /// Jump here for next part of big-null scan.
    addr_bignull: i32 = 0,
    /// LIKE range processing counter register (times 2).
    i_like_rep_cntr: u32 = 0,
    /// LIKE range processing address.
    addr_like_rep: i32 = 0,
    /// Bloom filter.
    reg_filter: i32 = 0,
    /// Extra information for RIGHT JOIN.
    rj: ?*WhereRightJoin = null,
    /// Which entry in the FROM clause.
    i_from: u8 = 0,
    /// Opcode, P3 & P5 of the opcode that ends the loop.
    op: u8 = 0,
    p3: u8 = 0,
    p5: u8 = 0,
    /// Operands of the opcode used to end the loop.
    p1: i32 = 0,
    p2: i32 = 0,
    /// u.in: the IN operators (pWLoop->wsFlags & WHERE_IN_ABLE).
    in_loops: []InLoop = &.{},
    /// u.pCoveringIdx: possible covering index for WHERE_MULTI_OR.
    covering_idx: ?*Index = null,
    /// The selected WhereLoop object.
    w_loop: ?*WhereLoop = null,
    /// FROM entries not usable at this level.
    not_ready: Bitmask = 0,

    /// u.in.nIn.
    pub fn nIn(l: *const WhereLevel) usize {
        return l.in_loops.len;
    }
};

/// WhereLoop.u.btree.
pub const WhereLoopBtree = struct {
    /// Number of equality constraints.
    n_eq: u16 = 0,
    /// Size of BTM vector.
    n_btm: u16 = 0,
    /// Size of TOP vector.
    n_top: u16 = 0,
    /// Index columns used to sort for DISTINCT.
    n_distinct_col: u16 = 0,
    /// Index used, or null.
    index: ?*Index = null,
    /// ORDER BY clause if this is really a subquery.
    order_by: ?*ExprList = null,
};

/// WhereLoop.u.vtab. With need_free, idx_str is from db.gpa and the loop
/// owns it (whereLoopClearUnion() frees it, OP_VFilter takes it over);
/// otherwise the module keeps it valid.
pub const WhereLoopVtab = struct {
    idx_num: i32 = 0,
    need_free: bool = false,
    b_omit_offset: bool = false,
    b_idx_num_hex: bool = false,
    is_ordered: i8 = 0,
    omit_mask: u16 = 0,
    idx_str: ?[:0]u8 = null,
    m_handle_in: u32 = 0,
};

/// One algorithm for one FROM-clause term (WhereLoop).
pub const WhereLoop = struct {
    /// Bitmask of other loops that must run first.
    prereq: Bitmask = 0,
    /// Bitmask identifying table iTab.
    mask_self: Bitmask = 0,
    /// Position in FROM clause of table for this loop.
    i_tab: u8 = 0,
    /// Sorting index number. 0==None.
    i_sort_idx: u8 = 0,
    /// One-time setup cost (ex: create transient index).
    r_setup: LogEst = 0,
    /// Cost of running each loop.
    r_run: LogEst = 0,
    /// Estimated number of output rows.
    n_out: LogEst = 0,
    /// u.btree (WHERE_VIRTUALTABLE clear).
    btree: WhereLoopBtree = .{},
    /// u.vtab (WHERE_VIRTUALTABLE set).
    vtab: WhereLoopVtab = .{},
    /// WHERE_* flags describing the plan (WHERE_COLUMN_EQ, ...).
    ws_flags: u32 = 0,
    /// Number of entries in aLTerm[].
    n_lterm: u16 = 0,
    /// Number of NULL aLTerm[] entries.
    n_skip: u16 = 0,
    // ---- whereLoopXfer() copies the fields above ----
    /// WhereTerms used; a_lterm.len is nLSlot.
    a_lterm: []?*WhereTerm = &.{},
    /// Next WhereLoop object in the WhereInfo.
    next_loop: ?*WhereLoop = null,
    /// Cost delta due to the star-schema heuristic (WHERETRACE only in C).
    r_star_delta: LogEst = 0,
    /// aLTermSpace: initial aLTerm[] storage. whereLoopInit() points
    /// a_lterm here, so a WhereLoop must not be copied by value after it.
    a_lterm_space: [3]?*WhereTerm = @splat(null),

    /// nLSlot.
    pub fn nLSlot(l: *const WhereLoop) usize {
        return l.a_lterm.len;
    }
};

/// Prerequisites and cost of one OR-clause subquery (WhereOrCost).
pub const WhereOrCost = struct {
    prereq: Bitmask = 0,
    r_run: LogEst = 0,
    n_out: LogEst = 0,
};

pub const N_OR_COST = 3;

/// The best N_OR_COST WhereOrCosts (WhereOrSet).
pub const WhereOrSet = struct {
    n: u16 = 0,
    a: [N_OR_COST]WhereOrCost = @splat(.{}),
};

/// A sequence of WhereLoops implementing some or all of a plan
/// (WherePath).
pub const WherePath = struct {
    /// Bitmask of all WhereLoop objects in this path.
    mask_loop: Bitmask = 0,
    /// aLoop[]s that should be reversed for ORDER BY.
    rev_loop: Bitmask = 0,
    /// Estimated number of rows generated by this path.
    n_row: LogEst = 0,
    /// Total cost of this path.
    r_cost: LogEst = 0,
    /// Total cost of this path ignoring sorting costs.
    r_unsort: LogEst = 0,
    /// Number of ORDER BY terms satisfied. -1 for unknown.
    is_ordered: i8 = 0,
    /// The WhereLoop objects implementing this path.
    a_loop: []*WhereLoop = &.{},
};

/// WhereTerm.wtFlags (TERM_*).
pub const TERM = struct {
    pub const DYNAMIC: u16 = 0x0001;
    pub const VIRTUAL: u16 = 0x0002;
    pub const CODED: u16 = 0x0004;
    pub const COPIED: u16 = 0x0008;
    pub const ORINFO: u16 = 0x0010;
    pub const ANDINFO: u16 = 0x0020;
    pub const OK: u16 = 0x0040;
    pub const VNULL: u16 = 0x0080;
    pub const LIKEOPT: u16 = 0x0100;
    pub const LIKECOND: u16 = 0x0200;
    pub const LIKE: u16 = 0x0400;
    pub const IS: u16 = 0x0800;
    pub const VARSELECT: u16 = 0x1000;
    pub const HEURTRUTH: u16 = 0x2000;
    /// Only used with STAT4.
    pub const HIGHTRUTH: u16 = 0;
    pub const SLICE: u16 = 0x8000;
};

/// One subexpression of the WHERE clause (WhereTerm).
pub const WhereTerm = struct {
    /// The subexpression that is this term.
    expr: *Expr,
    /// The clause this term is part of.
    wc: *WhereClause,
    /// Probability of truth for this expression.
    truth_prob: LogEst = 0,
    /// TERM_* bit flags.
    wt_flags: u16 = 0,
    /// A WO_* value describing <op>.
    e_operator: u16 = 0,
    /// Number of children that must disable us.
    n_child: u8 = 0,
    /// Op for vtab MATCH/LIKE/GLOB/REGEXP terms.
    e_match_op: u8 = 0,
    /// Disable pWC->a[iParent] when this term disabled.
    i_parent: i32 = -1,
    /// Cursor number of X in "X <op> <expr>".
    left_cursor: i32 = -1,
    /// u.x.leftColumn: column number of X in "X <op> <expr>".
    left_column: i32 = 0,
    /// u.x.iField: field in (?,?,?) IN (SELECT...) vector.
    i_field: i32 = 0,
    /// u.pOrInfo: extra information if (eOperator & WO_OR)!=0.
    or_info: ?*WhereOrInfo = null,
    /// u.pAndInfo: extra information if (eOperator & WO_AND)!=0.
    and_info: ?*WhereAndInfo = null,
    /// Bitmask of tables used by pExpr->pRight.
    prereq_right: Bitmask = 0,
    /// Bitmask of tables referenced by pExpr.
    prereq_all: Bitmask = 0,
};

/// Iterator over the WHERE terms useful to the planner (WhereScan).
pub const WhereScan = struct {
    /// Original, innermost WhereClause.
    orig_wc: *WhereClause = undefined,
    /// WhereClause currently being scanned.
    wc: ?*WhereClause = null,
    /// Required collating sequence, if not null.
    z_coll_name: ?[]const u8 = null,
    /// Search for this index expression.
    idx_expr: ?*Expr = null,
    /// Resume scanning at this->pWC->a[this->k].
    k: i32 = 0,
    /// Acceptable operators.
    op_mask: u32 = 0,
    /// Must match this affinity, if zCollName!=null.
    idxaff: u8 = 0,
    /// Current slot in aiCur[] and aiColumn[].
    i_equiv: u8 = 0,
    /// Number of entries in aiCur[] and aiColumn[].
    n_equiv: u8 = 0,
    /// Cursors in the equivalence class.
    ai_cur: [11]i32 = @splat(0),
    /// Corresponding column number in the eq-class.
    ai_column: [11]i16 = @splat(0),
};

/// The terms of a WHERE clause (WhereClause).
pub const WhereClause = struct {
    /// WHERE clause processing context.
    w_info: *WhereInfo,
    /// Outer conjunction.
    outer: ?*WhereClause = null,
    /// Split operator. TK_AND or TK_OR.
    op: u8 = TK.AND,
    /// True if any a[].eOperator is WO_OR.
    has_or: bool = false,
    /// Number of terms.
    n_term: i32 = 0,
    /// Number of terms through the last non-Virtual.
    n_base: i32 = 0,
    /// The terms; a.len is nSlot. Pointers into it are invalidated by
    /// whereClauseInsert(), as in C.
    a: []WhereTerm = &.{},

    /// nSlot.
    pub fn nSlot(wc: *const WhereClause) i32 {
        return @intCast(wc.a.len);
    }

    /// a[0..nTerm].
    pub fn terms(wc: *WhereClause) []WhereTerm {
        return wc.a[0..@intCast(wc.n_term)];
    }
};

/// WhereTerm.u.pOrInfo (WhereOrInfo).
pub const WhereOrInfo = struct {
    /// Decomposition into subterms.
    wc: WhereClause,
    /// Bitmask of all indexable tables in the clause.
    indexable: Bitmask = 0,
};

/// WhereTerm.u.pAndInfo (WhereAndInfo).
pub const WhereAndInfo = struct {
    /// The subexpression broken out.
    wc: WhereClause,
};

/// Maps VDBE cursor numbers to bitmask bits (WhereMaskSet).
pub const WhereMaskSet = struct {
    /// Used by sqlite3WhereExprUsage().
    b_var_select: bool = false,
    /// Number of assigned cursor values.
    n: i32 = 0,
    /// Cursor assigned to each bit.
    ix: [int.bms]i32 = @splat(0),
};

/// Port of sqlite3WhereGetMask(): the bitmask of cursor `i_cursor`, or 0
/// if it is not in the set.
pub fn getMask(ms: *const WhereMaskSet, i_cursor: i32) Bitmask {
    std.debug.assert(ms.n <= int.bms);
    if (ms.n > 0 and ms.ix[0] == i_cursor) return 1;
    var i: i32 = 1;
    while (i < ms.n) : (i += 1) {
        if (ms.ix[@intCast(i)] == i_cursor) return maskBit(i);
    }
    return 0;
}

/// Port of createMask(): give cursor `i_cursor` the next bit.
pub fn createMask(ms: *WhereMaskSet, i_cursor: i32) void {
    std.debug.assert(ms.n < int.bms);
    ms.ix[@intCast(ms.n)] = i_cursor;
    ms.n += 1;
}

/// State while building WhereLoops for one query (WhereLoopBuilder).
pub const WhereLoopBuilder = struct {
    /// Information about this WHERE.
    w_info: *WhereInfo,
    /// WHERE clause terms.
    wc: *WhereClause,
    /// Template WhereLoop.
    new: *WhereLoop,
    /// Record best loops here, if not null.
    or_set: ?*WhereOrSet = null,
    /// SQLITE_BLDF1_* flags.
    bld_flags1: u8 = 0,
    /// SQLITE_BLDF2_* flags.
    bld_flags2: u8 = 0,
    /// Search limiter.
    i_plan_limit: u32 = 0,
};

/// WhereLoopBuilder.bldFlags* (SQLITE_BLDF*_*).
pub const BLDF1_INDEXED: u8 = 0x0001;
pub const BLDF1_UNIQUE: u8 = 0x0002;
pub const BLDF2_2NDPASS: u8 = 0x0004;

/// SQLITE_QUERY_PLANNER_LIMIT and _INCR.
pub const QUERY_PLANNER_LIMIT: u32 = 20000;
pub const QUERY_PLANNER_LIMIT_INCR: u32 = 1000;

/// The complete state of the planner between sqlite3WhereBegin() and
/// sqlite3WhereEnd() (WhereInfo).
pub const WhereInfo = struct {
    /// Parsing and code generating context.
    parse: *Parse,
    /// List of tables in the join.
    tab_list: *SrcList,
    /// The ORDER BY clause or null.
    order_by: ?*ExprList = null,
    /// Result set of the query.
    result_set: ?*ExprList = null,
    /// The entire SELECT statement containing WHERE.
    select: ?*Select = null,
    /// OP_OpenWrite cursors for the ONEPASS opt.
    ai_cur_one_pass: [2]i32 = .{ -1, -1 },
    /// Jump here to continue with next record.
    i_continue: i32 = 0,
    /// Jump here to break out of the loop.
    i_break: i32 = 0,
    /// pParse->nQueryLoop outside the WHERE loop.
    saved_n_query_loop: LogEst = 0,
    /// Flags originally passed to sqlite3WhereBegin().
    wctrl_flags: u16 = 0,
    /// LIMIT if wctrlFlags has WHERE_USE_LIMIT.
    i_limit: LogEst = 0,
    /// Number of nested loops.
    n_level: u8 = 0,
    /// Number of ORDER BY terms satisfied by indices.
    n_ob_sat: i8 = 0,
    /// ONEPASS_OFF, or _SINGLE, or _MULTI.
    e_one_pass: u8 = 0,
    /// One of the WHERE_DISTINCT_* values.
    e_distinct: u8 = 0,
    /// Uses OP_DeferredSeek.
    b_deferred_seek: bool = false,
    /// Not all WHERE terms resolved by outer loop.
    untested_terms: bool = false,
    /// True if only the inner-most loop is ordered.
    b_ordered_inner_loop: bool = false,
    /// True if really sorted (not just grouped).
    sorted: bool = false,
    /// True if check for star-query is complete.
    b_star_done: bool = false,
    /// True if star-query heuristic is used.
    b_star_used: bool = false,
    /// Estimated number of output rows.
    n_row_out: LogEst = 0,
    /// The very beginning of the WHERE loop.
    i_top: i32 = 0,
    /// End of the WHERE clause itself.
    i_end_where: i32 = 0,
    /// List of all WhereLoop objects.
    loops: ?*WhereLoop = null,
    /// Mask of ORDER BY terms that need reversing.
    rev_mask: Bitmask = 0,
    /// Decomposition of the WHERE clause.
    s_wc: WhereClause,
    /// Map cursor numbers to bitmasks.
    s_mask_set: WhereMaskSet = .{},
    /// Information about each nested loop; a.len is the FROM-clause
    /// length (nLevel can be smaller after whereOmitNoopJoin()).
    a: []WhereLevel = &.{},

    /// a[0..nLevel].
    pub fn levels(w: *WhereInfo) []WhereLevel {
        return w.a[0..w.n_level];
    }
};

/// Port of sqlite3WhereMalloc(): memory freed with the WhereInfo (here,
/// with the Parse arena).
pub fn whereMalloc(w: *WhereInfo, comptime T: type, n: usize) int.Oom![]T {
    return w.parse.arena.alloc(T, n);
}

/// WhereTerm.eOperator bits (WO_*).
pub const WO = struct {
    pub const IN: u16 = 0x0001;
    pub const EQ: u16 = 0x0002;
    pub const LT: u16 = EQ << (TK.LT - TK.EQ);
    pub const LE: u16 = EQ << (TK.LE - TK.EQ);
    pub const GT: u16 = EQ << (TK.GT - TK.EQ);
    pub const GE: u16 = EQ << (TK.GE - TK.EQ);
    /// Op useful to virtual tables only.
    pub const AUX: u16 = 0x0040;
    pub const IS: u16 = 0x0080;
    pub const ISNULL: u16 = 0x0100;
    /// Two or more OR-connected terms.
    pub const OR: u16 = 0x0200;
    /// Two or more AND-connected terms.
    pub const AND: u16 = 0x0400;
    /// Of the form A==B, both columns.
    pub const EQUIV: u16 = 0x0800;
    /// This term does not restrict search space.
    pub const NOOP: u16 = 0x1000;
    /// A row-value term.
    pub const ROWVAL: u16 = 0x2000;
    /// Mask of all possible WO_* values.
    pub const ALL: u16 = 0x3fff;
    /// Mask of all non-compound WO_* values.
    pub const SINGLE: u16 = 0x01ff;
};

/// WhereLoop.wsFlags bits (WHERE_* in whereInt.h; the sqlite3WhereBegin()
/// flags are int.WHERE).
pub const WHERE_COLUMN_EQ: u32 = 0x00000001;
pub const WHERE_COLUMN_RANGE: u32 = 0x00000002;
pub const WHERE_COLUMN_IN: u32 = 0x00000004;
pub const WHERE_COLUMN_NULL: u32 = 0x00000008;
pub const WHERE_CONSTRAINT: u32 = 0x0000000f;
pub const WHERE_TOP_LIMIT: u32 = 0x00000010;
pub const WHERE_BTM_LIMIT: u32 = 0x00000020;
pub const WHERE_BOTH_LIMIT: u32 = 0x00000030;
pub const WHERE_IDX_ONLY: u32 = 0x00000040;
pub const WHERE_IPK: u32 = 0x00000100;
pub const WHERE_INDEXED: u32 = 0x00000200;
pub const WHERE_VIRTUALTABLE: u32 = 0x00000400;
pub const WHERE_IN_ABLE: u32 = 0x00000800;
pub const WHERE_ONEROW: u32 = 0x00001000;
pub const WHERE_MULTI_OR: u32 = 0x00002000;
pub const WHERE_AUTO_INDEX: u32 = 0x00004000;
pub const WHERE_SKIPSCAN: u32 = 0x00008000;
pub const WHERE_UNQ_WANTED: u32 = 0x00010000;
pub const WHERE_PARTIALIDX: u32 = 0x00020000;
pub const WHERE_IN_EARLYOUT: u32 = 0x00040000;
pub const WHERE_BIGNULL_SORT: u32 = 0x00080000;
pub const WHERE_IN_SEEKSCAN: u32 = 0x00100000;
pub const WHERE_TRANSCONS: u32 = 0x00200000;
pub const WHERE_BLOOMFILTER: u32 = 0x00400000;
pub const WHERE_SELFCULL: u32 = 0x00800000;
pub const WHERE_OMIT_OFFSET: u32 = 0x01000000;
pub const WHERE_COROUTINE: u32 = 0x02000000;
pub const WHERE_EXPRIDX: u32 = 0x04000000;

/// ONEPASS_*: how a DELETE or UPDATE visits its rows.
pub const ONEPASS_OFF: u8 = 0;
pub const ONEPASS_SINGLE: u8 = 1;
pub const ONEPASS_MULTI: u8 = 2;
