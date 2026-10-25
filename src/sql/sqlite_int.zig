//! Core types of the SQL layer (the parts of sqliteInt.h the parser and
//! code generator share): parse trees, schema objects and the Parse
//! context.
//!
//! Memory: parse-tree nodes (Expr, ExprList, Select, ...) live in the
//! statement's arena (`Parse.arena`) and are freed with it, so the many
//! sqlite3XxxDelete() calls of the C code have no counterpart. Schema
//! objects (Table, Index, ...) outlive the statement and use the
//! connection's allocator; parse trees they keep are copied into it.

const std = @import("std");
const grammar = @import("../parse/grammar.zig");

pub const TK = grammar.TK;
pub const Allocator = std.mem.Allocator;
pub const Pgno = u32;

/// Out of memory: the only failure of parse-tree constructors.
pub const Oom = error{OutOfMemory};

/// LogEst: 10*log2(X), so 10 means 2 and 33 means 10.
pub const LogEst = i16;

/// Bitmask of columns or tables (bit 63 also means "column 63 or later").
pub const Bitmask = u64;
pub const bms = 64;

/// ynVar: variable numbers (?NNN).
pub const YnVar = i16;

// ================================================================= tokens

/// A slice of the SQL text (Token). `z` is null for an empty, absent
/// token, as some grammar rules produce.
pub const Token = extern struct {
    z: ?[*]const u8 = null,
    n: u32 = 0,

    pub fn init(s: []const u8) Token {
        return .{ .z = s.ptr, .n = @intCast(s.len) };
    }

    pub fn slice(t: Token) []const u8 {
        return if (t.z) |z| z[0..t.n] else "";
    }
};

// ============================================================ expressions

/// Column affinities (SQLITE_AFF_*).
pub const Aff = struct {
    pub const none: u8 = 0x40;
    pub const blob: u8 = 0x41;
    pub const text: u8 = 0x42;
    pub const numeric: u8 = 0x43;
    pub const integer: u8 = 0x44;
    pub const real: u8 = 0x45;
    /// Affinity of a flexible-typed column of a STRICT table.
    pub const flexnum: u8 = 0x46;
    pub const @"defer": u8 = 0x58;
    pub const mask: u8 = 0x47;
};

/// Expr.flags (EP_*).
pub const EP = struct {
    pub const OuterON: u32 = 0x000001;
    pub const InnerON: u32 = 0x000002;
    pub const Distinct: u32 = 0x000004;
    pub const HasFunc: u32 = 0x000008;
    pub const Agg: u32 = 0x000010;
    pub const FixedCol: u32 = 0x000020;
    pub const VarSelect: u32 = 0x000040;
    pub const DblQuoted: u32 = 0x000080;
    pub const InfixFunc: u32 = 0x000100;
    pub const Collate: u32 = 0x000200;
    pub const Commuted: u32 = 0x000400;
    pub const IntValue: u32 = 0x000800;
    pub const xIsSelect: u32 = 0x001000;
    pub const Skip: u32 = 0x002000;
    pub const Reduced: u32 = 0x004000;
    pub const Win: u32 = 0x008000;
    pub const TokenOnly: u32 = 0x010000;
    pub const FullSize: u32 = 0x020000;
    pub const IfNullRow: u32 = 0x040000;
    pub const Unlikely: u32 = 0x080000;
    pub const ConstFunc: u32 = 0x100000;
    pub const CanBeNull: u32 = 0x200000;
    pub const Subquery: u32 = 0x400000;
    pub const Leaf: u32 = 0x800000;
    pub const WinFunc: u32 = 0x1000000;
    pub const Subrtn: u32 = 0x2000000;
    pub const Quoted: u32 = 0x4000000;
    pub const Static: u32 = 0x8000000;
    pub const IsTrue: u32 = 0x10000000;
    pub const IsFalse: u32 = 0x20000000;
    pub const FromDDL: u32 = 0x40000000;
    pub const SubtArg: u32 = 0x80000000;
    /// Properties that propagate up to parent nodes.
    pub const Propagate: u32 = EP.Collate | EP.Subquery | EP.HasFunc;
};

/// A node of an expression tree (Expr). Which union members are valid
/// depends on `op` and `flags`, as documented on the C struct.
pub const Expr = struct {
    op: u8,
    /// Affinity, or the RAISE type.
    aff_expr: u8 = 0,
    /// TK_REGISTER/TK_TRUTH: original op. TK_COLUMN: P5 of OP_Column.
    /// TK_AGG_FUNCTION: nesting depth. TK_FUNCTION: NC_SelfRef flag.
    op2: u8 = 0,
    flags: u32 = 0,
    /// Token value (dequoted, NUL-terminated), or with EP_IntValue a
    /// non-negative integer.
    u: union { token: ?[:0]u8, value: i32 } = .{ .token = null },
    left: ?*Expr = null,
    right: ?*Expr = null,
    /// Function arguments, CASE/IN/BETWEEN lists, or with EP_xIsSelect a
    /// subquery.
    x: union { list: ?*ExprList, select: ?*Select } = .{ .list = null },
    n_height: i32 = 0,
    /// TK_COLUMN: cursor. TK_REGISTER: register. TK_TRIGGER: 1 new, 0 old.
    /// EP_Unlikely: 134217728 times the likelihood. TK_IN: ephemeral table.
    /// TK_SELECT_COLUMN: columns on the LHS. TK_SELECT: first result reg.
    i_table: i32 = 0,
    /// TK_COLUMN: column (-1 rowid). TK_VARIABLE: variable number.
    i_column: YnVar = 0,
    i_agg: i16 = 0,
    /// The right table of an ON/USING term (EP_OuterON/EP_InnerON), else
    /// the token's offset in the statement.
    w: union { join: i32, ofst: i32 } = .{ .ofst = 0 },
    agg_info: ?*anyopaque = null,
    y: union {
        tab: ?*Table,
        win: ?*Window,
        n_reg: i32,
        sub: struct { addr: i32, reg_return: i32 },
    } = .{ .tab = null },

    pub fn has(e: *const Expr, p: u32) bool {
        return e.flags & p != 0;
    }

    pub fn hasAll(e: *const Expr, p: u32) bool {
        return e.flags & p == p;
    }

    pub fn set(e: *Expr, p: u32) void {
        e.flags |= p;
    }

    pub fn clear(e: *Expr, p: u32) void {
        e.flags &= ~p;
    }

    pub fn useUToken(e: *const Expr) bool {
        return e.flags & EP.IntValue == 0;
    }

    pub fn useXList(e: *const Expr) bool {
        return e.flags & EP.xIsSelect == 0;
    }

    pub fn useXSelect(e: *const Expr) bool {
        return e.flags & EP.xIsSelect != 0;
    }

    pub fn useYWin(e: *const Expr) bool {
        return e.flags & EP.WinFunc != 0;
    }

    pub fn useYTab(e: *const Expr) bool {
        return e.flags & (EP.WinFunc | EP.Subrtn) == 0;
    }

    pub fn useWJoin(e: *const Expr) bool {
        return e.flags & (EP.InnerON | EP.OuterON) != 0;
    }

    /// The token text, or "" (u.zToken).
    pub fn token(e: *const Expr) [:0]const u8 {
        std.debug.assert(e.useUToken());
        return e.u.token orelse "";
    }

    pub fn alwaysTrue(e: *const Expr) bool {
        return e.flags & (EP.OuterON | EP.IsTrue) == EP.IsTrue;
    }

    pub fn alwaysFalse(e: *const Expr) bool {
        return e.flags & (EP.OuterON | EP.IsFalse) == EP.IsFalse;
    }

    /// IsWindowFunc(): a function with an OVER clause.
    pub fn isWindowFunc(e: *const Expr) bool {
        return e.has(EP.WinFunc) and e.y.win.?.e_frm_type != TK.FILTER;
    }
};

/// ExprList.a[].fg.eEName values.
pub const EName = enum(u2) {
    /// The AS name of a result column, or COLUMN= of an UPDATE.
    name = 0,
    /// The original text of a result expression.
    span = 1,
    /// "DB.TABLE.NAME", to resolve names of subquery results.
    tab = 2,
    /// "DB.TABLE._rowid_", for "*" expansion of the rowid.
    rowid = 3,
};

/// Sort flags of ORDER BY terms (KEYINFO_ORDER_*).
pub const KeyInfoOrder = struct {
    pub const desc: u8 = 0x01;
    pub const bignull: u8 = 0x02;
};

/// SQLITE_SO_*: sort order as written; undefined means not given.
pub const SortOrder = struct {
    pub const asc: i32 = 0;
    pub const desc: i32 = 1;
    pub const undef: i32 = -1;
};

pub const ExprListItem = struct {
    expr: ?*Expr,
    /// Name; meaning depends on `fg.e_ename`.
    e_name: ?[:0]u8 = null,
    fg: packed struct {
        sort_flags: u8 = 0,
        e_ename: EName = .name,
        done: bool = false,
        reusable: bool = false,
        sorter_ref: bool = false,
        nulls: bool = false,
        used: bool = false,
        using_term: bool = false,
        no_expand: bool = false,
    } = .{},
    u: union {
        x: struct { order_by_col: u16 = 0, alias: u16 = 0 },
        const_expr_reg: i32,
    } = .{ .x = .{} },
};

/// A list of expressions, optionally named (ExprList).
pub const ExprList = struct {
    items: std.ArrayList(ExprListItem) = .empty,

    pub fn len(l: *const ExprList) usize {
        return l.items.items.len;
    }

    pub fn at(l: *ExprList, i: usize) *ExprListItem {
        return &l.items.items[i];
    }

    pub fn slice(l: *ExprList) []ExprListItem {
        return l.items.items;
    }

    pub fn last(l: *ExprList) *ExprListItem {
        return &l.items.items[l.items.items.len - 1];
    }
};

/// A list of identifiers, as in "INSERT INTO t(a,b,c)" (IdList).
pub const IdList = struct {
    names: std.ArrayList([:0]u8) = .empty,

    pub fn len(l: *const IdList) usize {
        return l.names.items.len;
    }
};

/// The subquery of a FROM-clause term (Subquery).
pub const Subquery = struct {
    select: *Select,
    addr_fill_sub: i32 = 0,
    reg_return: i32 = 0,
    reg_result: i32 = 0,
};

/// Join types (JT_*).
pub const JT = struct {
    pub const INNER: u8 = 0x01;
    pub const CROSS: u8 = 0x02;
    pub const NATURAL: u8 = 0x04;
    pub const LEFT: u8 = 0x08;
    pub const RIGHT: u8 = 0x10;
    pub const OUTER: u8 = 0x20;
    pub const LTORJ: u8 = 0x40;
    pub const ERROR: u8 = 0x80;
};

/// One term of a FROM clause (SrcItem).
pub const SrcItem = struct {
    name: ?[:0]u8 = null,
    alias: ?[:0]u8 = null,
    /// The table zName resolved to.
    s_tab: ?*Table = null,
    fg: packed struct {
        jointype: u8 = 0,
        not_indexed: bool = false,
        is_indexed_by: bool = false,
        is_subquery: bool = false,
        is_tab_func: bool = false,
        is_correlated: bool = false,
        is_materialized: bool = false,
        via_coroutine: bool = false,
        is_recursive: bool = false,
        from_ddl: bool = false,
        is_cte: bool = false,
        not_cte: bool = false,
        is_using: bool = false,
        is_on: bool = false,
        is_synth_using: bool = false,
        is_nested_from: bool = false,
        rowid_used: bool = false,
        fixed_schema: bool = false,
        had_schema: bool = false,
        from_exists: bool = false,
    } = .{},
    i_cursor: i32 = -1,
    col_used: Bitmask = 0,
    /// INDEXED BY name (fg.is_indexed_by), table-valued function arguments
    /// (fg.is_tab_func), or the row count of a VALUES clause.
    u1: union { indexed_by: ?[:0]u8, func_arg: ?*ExprList, n_row: u32 } = .{ .n_row = 0 },
    u2: union { ib_index: ?*Index, cte_use: ?*CteUse } = .{ .ib_index = null },
    /// The ON clause, or with fg.is_using the USING list.
    u3: union { on: ?*Expr, using: ?*IdList } = .{ .on = null },
    /// The database name, the schema (fg.fixed_schema), or the subquery
    /// (fg.is_subquery).
    u4: union { schema: ?*Schema, database: ?[:0]u8, subq: ?*Subquery } = .{ .database = null },

    pub fn subquery(it: *SrcItem) ?*Select {
        return if (it.fg.is_subquery) it.u4.subq.?.select else null;
    }
};

/// An ON or USING clause (OnOrUsing).
pub const OnOrUsing = extern struct {
    on: ?*Expr = null,
    using: ?*IdList = null,
};

/// The tables of a FROM clause, or the target of INSERT/UPDATE/DELETE
/// (SrcList).
pub const SrcList = struct {
    items: std.ArrayList(SrcItem) = .empty,

    pub fn len(l: *const SrcList) usize {
        return l.items.items.len;
    }

    pub fn at(l: *SrcList, i: usize) *SrcItem {
        return &l.items.items[i];
    }

    pub fn slice(l: *SrcList) []SrcItem {
        return l.items.items;
    }
};

/// Select.sel_flags (SF_*).
pub const SF = struct {
    pub const Distinct: u32 = 0x0000001;
    pub const All: u32 = 0x0000002;
    pub const Resolved: u32 = 0x0000004;
    pub const Aggregate: u32 = 0x0000008;
    pub const HasAgg: u32 = 0x0000010;
    pub const ClonedRhsIn: u32 = 0x0000020;
    pub const Expanded: u32 = 0x0000040;
    pub const HasTypeInfo: u32 = 0x0000080;
    pub const Compound: u32 = 0x0000100;
    pub const Values: u32 = 0x0000200;
    pub const MultiValue: u32 = 0x0000400;
    pub const NestedFrom: u32 = 0x0000800;
    pub const MinMaxAgg: u32 = 0x0001000;
    pub const Recursive: u32 = 0x0002000;
    pub const FixedLimit: u32 = 0x0004000;
    pub const Converted: u32 = 0x0010000;
    pub const IncludeHidden: u32 = 0x0020000;
    pub const ComplexResult: u32 = 0x0040000;
    pub const WhereBegin: u32 = 0x0080000;
    pub const WinRewrite: u32 = 0x0100000;
    pub const View: u32 = 0x0200000;
    pub const UFSrcCheck: u32 = 0x0800000;
    pub const PushDown: u32 = 0x1000000;
    pub const MultiPart: u32 = 0x2000000;
    pub const CopyCte: u32 = 0x4000000;
    pub const OrderByReqd: u32 = 0x8000000;
    pub const UpdateFrom: u32 = 0x10000000;
    pub const Correlated: u32 = 0x20000000;
    pub const OnToWhere: u32 = 0x40000000;
};

/// One SELECT (Select). Compound selects link through `prior`.
pub const Select = struct {
    /// TK_SELECT, or TK_UNION, TK_ALL, TK_INTERSECT, TK_EXCEPT.
    op: u8 = TK.SELECT,
    n_select_row: LogEst = 0,
    sel_flags: u32 = 0,
    i_limit: i32 = 0,
    i_offset: i32 = 0,
    sel_id: u32 = 0,
    e_list: ?*ExprList = null,
    src: ?*SrcList = null,
    where: ?*Expr = null,
    group_by: ?*ExprList = null,
    having: ?*Expr = null,
    order_by: ?*ExprList = null,
    prior: ?*Select = null,
    next: ?*Select = null,
    limit: ?*Expr = null,
    with: ?*With = null,
    win: ?*Window = null,
    win_defn: ?*Window = null,
};

/// ON CONFLICT clause of an INSERT (Upsert).
pub const Upsert = struct {
    target: ?*ExprList = null,
    target_where: ?*Expr = null,
    set: ?*ExprList = null,
    where: ?*Expr = null,
    next: ?*Upsert = null,
    is_do_update: bool = false,
    is_dup: bool = false,
    // Set while generating code.
    idx: ?*Index = null,
    src: ?*SrcList = null,
    reg_data: i32 = 0,
    i_data_cur: i32 = 0,
    i_idx_cur: i32 = 0,
};

/// Materialization hint of a CTE (M10d_*).
pub const M10d = enum(u8) { yes = 0, any = 1, no = 2 };

/// A common table expression (Cte).
pub const Cte = struct {
    name: ?[:0]u8 = null,
    cols: ?*ExprList = null,
    select: ?*Select = null,
    cte_err: ?[:0]const u8 = null,
    use: ?*CteUse = null,
    e_m10d: M10d = .any,
};

/// A WITH clause (With).
pub const With = struct {
    view: bool = false,
    outer: ?*With = null,
    ctes: std.ArrayList(Cte) = .empty,
};

/// Per-statement usage of a CTE (CteUse).
pub const CteUse = struct {
    n_use: i32 = 0,
    addr_m9e: i32 = 0,
    reg_rtn: i32 = 0,
    i_cur: i32 = 0,
    n_row_est: LogEst = 0,
    e_m10d: M10d = .any,
};

/// A window definition, or the FILTER of an aggregate (Window).
pub const Window = struct {
    name: ?[:0]u8 = null,
    base: ?[:0]u8 = null,
    partition: ?*ExprList = null,
    order_by: ?*ExprList = null,
    /// TK_RANGE, TK_GROUPS, TK_ROWS, TK_FILTER or 0.
    e_frm_type: u8 = 0,
    e_start: u8 = 0,
    e_end: u8 = 0,
    implicit_frame: bool = false,
    /// TK_NO, TK_CURRENT, TK_TIES, TK_GROUP or 0.
    e_exclude: u8 = 0,
    start: ?*Expr = null,
    end: ?*Expr = null,
    this: ?*?*Window = null,
    next_win: ?*Window = null,
    filter: ?*Expr = null,
    w_func: ?*FuncDef = null,
    i_eph_csr: i32 = 0,
    reg_accum: i32 = 0,
    reg_result: i32 = 0,
    csr_app: i32 = 0,
    reg_app: i32 = 0,
    reg_part: i32 = 0,
    owner: ?*Expr = null,
    n_buffer_col: i32 = 0,
    i_arg_col: i32 = 0,
    reg_one: i32 = 0,
    reg_start_rowid: i32 = 0,
    reg_end_rowid: i32 = 0,
    expr_args: bool = false,
};

/// Conflict resolution (OE_*).
pub const OE = struct {
    pub const None: u8 = 0;
    pub const Rollback: u8 = 1;
    pub const Abort: u8 = 2;
    pub const Fail: u8 = 3;
    pub const Ignore: u8 = 4;
    pub const Replace: u8 = 5;
    pub const Update: u8 = 6;
    pub const Restrict: u8 = 7;
    pub const SetNull: u8 = 8;
    pub const SetDflt: u8 = 9;
    pub const Cascade: u8 = 10;
    pub const Default: u8 = 11;
};

/// One statement of a trigger body (TriggerStep).
pub const TriggerStep = struct {
    /// TK_DELETE, TK_UPDATE, TK_INSERT, TK_SELECT or TK_RETURNING.
    op: u8,
    orconf: u8 = 0,
    trig: ?*Trigger = null,
    select: ?*Select = null,
    src: ?*SrcList = null,
    where: ?*Expr = null,
    expr_list: ?*ExprList = null,
    id_list: ?*IdList = null,
    upsert: ?*Upsert = null,
    span: ?[:0]u8 = null,
    next: ?*TriggerStep = null,
    /// Last element of the list; valid on the first element only.
    last: ?*TriggerStep = null,
};

/// When a trigger fires (TRIGGER_*).
pub const TRIGGER_BEFORE: u8 = 1;
pub const TRIGGER_AFTER: u8 = 2;

/// A trigger (Trigger).
pub const Trigger = struct {
    name: [:0]u8,
    table: [:0]u8,
    op: u8,
    tr_tm: u8,
    returning: bool = false,
    when: ?*Expr = null,
    columns: ?*IdList = null,
    schema: ?*Schema = null,
    tab_schema: ?*Schema = null,
    step_list: ?*TriggerStep = null,
    next: ?*Trigger = null,
};

// ================================================================= schema

/// Column.col_flags (COLFLAG_*).
pub const COLFLAG = struct {
    pub const PRIMKEY: u16 = 0x0001;
    pub const HIDDEN: u16 = 0x0002;
    pub const HASTYPE: u16 = 0x0004;
    pub const UNIQUE: u16 = 0x0008;
    pub const SORTERREF: u16 = 0x0010;
    pub const VIRTUAL: u16 = 0x0020;
    pub const STORED: u16 = 0x0040;
    pub const NOTAVAIL: u16 = 0x0080;
    pub const BUSY: u16 = 0x0100;
    pub const HASCOLL: u16 = 0x0200;
    pub const NOEXPAND: u16 = 0x0400;
    pub const GENERATED: u16 = 0x0060;
    pub const NOINSERT: u16 = 0x0062;
};

/// Column.e_ctype: the standard types of STRICT tables (COLTYPE_*).
pub const COLTYPE = struct {
    pub const CUSTOM: u4 = 0;
    pub const ANY: u4 = 1;
    pub const BLOB: u4 = 2;
    pub const INT: u4 = 3;
    pub const INTEGER: u4 = 4;
    pub const REAL: u4 = 5;
    pub const TEXT: u4 = 6;
};

/// A table column (Column). As in C, the declared type and collation
/// follow the name in `cn_name`, each NUL-terminated, when COLFLAG_HASTYPE
/// and COLFLAG_HASCOLL are set.
pub const Column = struct {
    cn_name: [:0]u8,
    /// An OE_ code for NOT NULL.
    not_null: u4 = 0,
    e_ctype: u4 = 0,
    affinity: u8 = Aff.blob,
    /// Estimated size; sizeof(INT) is 1.
    sz_est: u8 = 1,
    h_name: u8 = 0,
    /// 1-based index of the DEFAULT expression in Table.dflt_list; 0 none.
    i_dflt: u16 = 0,
    col_flags: u16 = 0,

    pub fn name(c: *const Column) [:0]const u8 {
        return std.mem.sliceTo(c.cn_name, 0);
    }
};

/// Table.tab_flags (TF_*).
pub const TF = struct {
    pub const Readonly: u32 = 0x00000001;
    pub const HasHidden: u32 = 0x00000002;
    pub const HasPrimaryKey: u32 = 0x00000004;
    pub const Autoincrement: u32 = 0x00000008;
    pub const HasStat1: u32 = 0x00000010;
    pub const HasVirtual: u32 = 0x00000020;
    pub const HasStored: u32 = 0x00000040;
    pub const HasGenerated: u32 = 0x00000060;
    pub const WithoutRowid: u32 = 0x00000080;
    pub const MaybeReanalyze: u32 = 0x00000100;
    pub const NoVisibleRowid: u32 = 0x00000200;
    pub const OOOHidden: u32 = 0x00000400;
    pub const HasNotNull: u32 = 0x00000800;
    pub const Shadow: u32 = 0x00001000;
    pub const HasStat4: u32 = 0x00002000;
    pub const Ephemeral: u32 = 0x00004000;
    pub const Eponymous: u32 = 0x00008000;
    pub const Strict: u32 = 0x00010000;
    pub const Imposter: u32 = 0x00020000;
};

pub const TabType = enum(u8) { norm = 0, vtab = 1, view = 2 };

/// A table or view (Table).
pub const Table = struct {
    name: [:0]u8,
    cols: []Column = &.{},
    index: ?*Index = null,
    col_aff: ?[:0]u8 = null,
    /// CHECK constraints; the column names of a view.
    check: ?*ExprList = null,
    tnum: Pgno = 0,
    n_tab_ref: u32 = 1,
    tab_flags: u32 = 0,
    /// The INTEGER PRIMARY KEY column, or -1.
    i_pkey: i16 = -1,
    /// Columns that are not VIRTUAL.
    n_nv_col: i16 = 0,
    n_row_log_est: LogEst = 200,
    sz_tab_row: LogEst = 0,
    key_conf: u8 = 0,
    e_tab_type: TabType = .norm,
    u: union {
        tab: struct {
            add_col_offset: i32 = 0,
            fkey: ?*FKey = null,
            /// DEFAULT clauses, or the AS of generated columns.
            dflt_list: ?*ExprList = null,
        },
        view: struct { select: ?*Select = null },
    } = .{ .tab = .{} },
    trigger: ?*Trigger = null,
    schema: ?*Schema = null,

    pub fn nCol(t: *const Table) i16 {
        return @intCast(t.cols.len);
    }

    pub fn isView(t: *const Table) bool {
        return t.e_tab_type == .view;
    }

    pub fn isOrdinary(t: *const Table) bool {
        return t.e_tab_type == .norm;
    }

    pub fn hasRowid(t: *const Table) bool {
        return t.tab_flags & TF.WithoutRowid == 0;
    }
};

/// A foreign key (FKey).
pub const FKey = struct {
    from: *Table,
    next_from: ?*FKey = null,
    to: [:0]u8,
    next_to: ?*FKey = null,
    prev_to: ?*FKey = null,
    is_deferred: bool = false,
    /// OE_ actions for ON DELETE and ON UPDATE.
    a_action: [2]u8 = .{ 0, 0 },
    trigger: [2]?*Trigger = .{ null, null },
    cols: []FKeyCol = &.{},
};

pub const FKeyCol = struct {
    /// Column of `from`.
    i_from: i32,
    /// Name of the column in `to`, or null for its primary key.
    col: ?[:0]u8,
};

/// Index.idx_type (SQLITE_IDXTYPE_*).
pub const IdxType = enum(u2) { appdef = 0, unique = 1, primarykey = 2, ipk = 3 };

/// Index.ai_column values below zero.
pub const XN_ROWID: i16 = -1;
pub const XN_EXPR: i16 = -2;

/// An index (Index).
pub const Index = struct {
    name: [:0]u8,
    ai_column: []i16 = &.{},
    ai_row_log_est: []LogEst = &.{},
    table: *Table,
    col_aff: ?[:0]u8 = null,
    next: ?*Index = null,
    schema: ?*Schema = null,
    sort_order: []u8 = &.{},
    coll: [][:0]const u8 = &.{},
    part_idx_where: ?*Expr = null,
    col_expr: ?*ExprList = null,
    tnum: Pgno = 0,
    sz_idx_row: LogEst = 0,
    n_key_col: u16 = 0,
    /// Columns in the b-tree; can be 2*Table.nCol.
    n_column: u16 = 0,
    on_error: u8 = OE.None,
    idx_type: IdxType = .appdef,
    unordered: bool = false,
    uniq_not_null: bool = false,
    is_resized: bool = false,
    is_covering: bool = false,
    no_skip_scan: bool = false,
    has_stat1: bool = false,
    no_query: bool = false,
    asc_key_bug: bool = false,
    has_vcol: bool = false,
    has_expr: bool = false,
    col_not_idxed: Bitmask = 0,

    pub fn isPrimaryKey(i: *const Index) bool {
        return i.idx_type == .primarykey;
    }

    pub fn isUnique(i: *const Index) bool {
        return i.on_error != OE.None;
    }
};

/// Schema.schema_flags (DB_*).
pub const DB_SchemaLoaded: u16 = 0x0001;
pub const DB_UnresetViews: u16 = 0x0002;
pub const DB_ResetWanted: u16 = 0x0008;

/// Case-insensitive name map, as SQLite's Hash with sqlite3StrICmp.
pub fn NameMap(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, NoCaseContext, std.hash_map.default_max_load_percentage);
}

pub const NoCaseContext = struct {
    pub fn hash(_: NoCaseContext, s: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        for (s) |c| h.update(&.{std.ascii.toLower(c)});
        return h.final();
    }

    pub fn eql(_: NoCaseContext, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// The schema of one database file (Schema).
pub const Schema = struct {
    schema_cookie: i32 = 0,
    i_generation: i32 = 0,
    tbl_hash: NameMap(*Table) = .empty,
    idx_hash: NameMap(*Index) = .empty,
    trig_hash: NameMap(*Trigger) = .empty,
    fkey_hash: NameMap(*FKey) = .empty,
    seq_tab: ?*Table = null,
    file_format: u8 = 0,
    enc: u8 = 0,
    schema_flags: u16 = 0,
    cache_size: i32 = 0,
};

// ============================================================== functions

/// A collating sequence (CollSeq).
pub const CollSeq = struct {
    name: [:0]const u8,
    enc: u8 = 1,
    user: ?*anyopaque = null,
    cmp: ?*const fn (user: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order = null,
};

/// An SQL function (FuncDef). The implementations are typed by the VDBE
/// (func.zig); here they are opaque.
pub const FuncDef = struct {
    /// Number of arguments; -1 means any.
    n_arg: i16,
    /// SQLITE_FUNC_* flags (callback.FUNC).
    func_flags: u32 = 0,
    user_data: ?*anyopaque = null,
    /// Next function with the same name.
    next: ?*FuncDef = null,
    /// Scalar function, or aggregate step.
    x_sfunc: ?StepFn = null,
    /// Aggregate finalizer; set for aggregates only.
    x_finalize: ?FinalFn = null,
    /// Current value of a window aggregate.
    x_value: ?FinalFn = null,
    /// Inverse step of a window aggregate.
    x_inverse: ?StepFn = null,
    name: [:0]const u8,

    pub const StepFn = *const fn (ctx: *Context, argv: []*Mem) void;
    pub const FinalFn = *const fn (ctx: *Context) void;
    const Context = @import("../vdbe/vdbe_int.zig").Context;

    pub fn isAggregate(f: *const FuncDef) bool {
        return f.x_finalize != null;
    }
};

// ================================================================ parsing

/// Parse.e_parse_mode (PARSE_MODE_*).
pub const ParseMode = enum(u8) { normal = 0, declare_vtab = 1, rename = 2, unmap = 3 };

/// SQLite result codes used by the SQL layer.
pub const RC = struct {
    pub const OK: i32 = 0;
    pub const ERROR: i32 = 1;
    pub const INTERNAL: i32 = 2;
    pub const PERM: i32 = 3;
    pub const ABORT: i32 = 4;
    pub const BUSY: i32 = 5;
    pub const LOCKED: i32 = 6;
    pub const NOMEM: i32 = 7;
    pub const READONLY: i32 = 8;
    pub const INTERRUPT: i32 = 9;
    pub const IOERR: i32 = 10;
    pub const CORRUPT: i32 = 11;
    pub const NOTFOUND: i32 = 12;
    pub const FULL: i32 = 13;
    pub const CANTOPEN: i32 = 14;
    pub const PROTOCOL: i32 = 15;
    pub const EMPTY: i32 = 16;
    pub const SCHEMA: i32 = 17;
    pub const TOOBIG: i32 = 18;
    pub const CONSTRAINT: i32 = 19;
    pub const MISMATCH: i32 = 20;
    pub const MISUSE: i32 = 21;
    pub const NOLFS: i32 = 22;
    pub const AUTH: i32 = 23;
    pub const FORMAT: i32 = 24;
    pub const RANGE: i32 = 25;
    pub const NOTADB: i32 = 26;
    pub const NOTICE: i32 = 27;
    pub const WARNING: i32 = 28;
    pub const ROW: i32 = 100;
    pub const DONE: i32 = 101;
    // Extended codes used by the VM.
    pub const CONSTRAINT_CHECK: i32 = CONSTRAINT | (1 << 8);
    pub const CONSTRAINT_FOREIGNKEY: i32 = CONSTRAINT | (3 << 8);
    pub const CONSTRAINT_NOTNULL: i32 = CONSTRAINT | (5 << 8);
    pub const CONSTRAINT_PRIMARYKEY: i32 = CONSTRAINT | (6 << 8);
    pub const CONSTRAINT_TRIGGER: i32 = CONSTRAINT | (7 << 8);
    pub const CONSTRAINT_UNIQUE: i32 = CONSTRAINT | (8 << 8);
    pub const CONSTRAINT_ROWID: i32 = CONSTRAINT | (10 << 8);
    pub const CONSTRAINT_DATATYPE: i32 = CONSTRAINT | (12 << 8);
    pub const CORRUPT_INDEX: i32 = CORRUPT | (3 << 8);
    pub const ERROR_RETRY: i32 = ERROR | (2 << 8);
    pub const ERROR_SNAPSHOT: i32 = ERROR | (3 << 8);
    pub const LOCKED_SHAREDCACHE: i32 = LOCKED | (1 << 8);
    pub const ABORT_ROLLBACK: i32 = ABORT | (2 << 8);
    pub const IOERR_SHORT_READ: i32 = IOERR | (2 << 8);
    pub const IOERR_LOCK: i32 = IOERR | (15 << 8);
    pub const READONLY_ROLLBACK: i32 = READONLY | (3 << 8);
};

/// sqlite3_limit() categories (SQLITE_LIMIT_*) with their defaults.
pub const Limit = enum(u4) {
    length,
    sql_length,
    column,
    expr_depth,
    compound_select,
    vdbe_op,
    function_arg,
    attached,
    like_pattern_length,
    variable_number,
    trigger_depth,
    worker_threads,
    parser_depth,

    pub const defaults = std.enums.EnumArray(Limit, i32).init(.{
        .length = 1000000000,
        .sql_length = 1000000000,
        .column = 2000,
        .expr_depth = 1000,
        .compound_select = 500,
        .vdbe_op = 250000000,
        .function_arg = 1000,
        .attached = 10,
        .like_pattern_length = 50000,
        .variable_number = 32766,
        .trigger_depth = 1000,
        .worker_threads = 0,
        .parser_depth = 2500,
    });
};

/// Fields of Parse used by CREATE TABLE/INDEX/VIEW (u1.cr).
pub const CreateState = struct {
    /// Address of OP_CreateBtree for CREATE TABLE.
    addr_cr_tab: i32 = 0,
    /// Register with the rowid of the new sqlite_schema entry.
    reg_rowid: i32 = 0,
    /// Register with the root page of the new object.
    reg_root: i32 = 0,
    /// Name of the constraint being parsed.
    constraint_name: Token = .{},
};

/// The state of parsing and compiling one statement (Parse).
pub const Parse = struct {
    db: *Sqlite3,
    /// Holds the parse trees and other per-statement memory.
    arena: Allocator,
    err_msg: ?[:0]u8 = null,
    rc: i32 = RC.OK,
    nested: u8 = 0,
    disable_lookaside: u8 = 0,
    prep_flags: u8 = 0,
    is_create: bool = false,
    /// Only check syntax: statement builders that are not ported yet do
    /// nothing instead of failing (see pending.zig).
    syntax_only: bool = false,
    disable_triggers: bool = false,
    may_abort: bool = false,
    has_compound: bool = false,
    returning: bool = false,
    has_with: bool = false,
    check_schema: bool = false,
    n_err: i32 = 0,
    /// Counter for Select.sel_id.
    n_select: i32 = 0,

    // Code generation.
    vdbe: ?*Vdbe = null,
    /// Estimated iterations of a query (10*log2(N)).
    n_query_loop: LogEst = 0,
    n_temp_reg: u8 = 0,
    is_multi_write: bool = false,
    within_rj_subrtn: u8 = 0,
    e_trigger_op: u8 = 0,
    e_orconf: u8 = 0,
    bhas_exists: bool = false,
    col_names_set: bool = false,
    ok_const_factor: bool = false,
    uses_ainc: bool = false,
    /// Size and first register of the temporary register block.
    n_range_reg: i32 = 0,
    i_range_reg: i32 = 0,
    /// VDBE cursors allocated so far.
    n_tab: i32 = 0,
    /// Registers allocated so far.
    n_mem: i32 = 0,
    /// Table of an index on an expression, or minus the base register
    /// of a CHECK constraint.
    i_self_tab: i32 = 0,
    /// Nested SELECTs and views.
    n_nest_sel: i32 = 0,
    /// Minus the number of labels made.
    n_label: i32 = 0,
    /// Addresses of the labels, by -label-1.
    labels: std.ArrayList(i32) = .empty,
    const_expr: ?*ExprList = null,
    /// Databases needing a write transaction or a schema check.
    write_mask: u32 = 0,
    cookie_mask: u32 = 0,
    /// Most arguments of xUpdate/xFilter.
    n_max_arg: i32 = 0,
    /// Main Parse of a trigger program, or null.
    toplevel: ?*Parse = null,
    trigger_tab: ?*Table = null,
    temp_regs: [8]i32 = @splat(0),
    outer_parse: ?*Parse = null,
    name_token: Token = .{},
    oldmask: u32 = 0,
    newmask: u32 = 0,
    /// The innermost EXPLAIN QUERY PLAN node.
    addr_explain: i32 = 0,
    u1: union { cr: CreateState, d: struct { returning: ?*anyopaque = null } } = .{ .cr = .{} },

    // Reset for each recursion.
    last_token: Token = .{},
    /// Number of '?' variables so far.
    n_var: YnVar = 0,
    /// Names of named variables and their numbers.
    vlist: std.ArrayList(VListEntry) = .empty,
    /// 1 for EXPLAIN, 2 for EXPLAIN QUERY PLAN.
    explain: u8 = 0,
    e_parse_mode: ParseMode = .normal,
    /// Expression tree height of the current sub-select.
    n_height: i32 = 0,
    /// SQL text after the last statement parsed.
    tail: []const u8 = "",
    new_table: ?*Table = null,
    new_index: ?*Index = null,
    new_trigger: ?*Trigger = null,
    with: ?*With = null,

    pub fn inRenameObject(p: *const Parse) bool {
        return @intFromEnum(p.e_parse_mode) >= @intFromEnum(ParseMode.rename);
    }

    pub fn inSpecialParse(p: *const Parse) bool {
        return p.e_parse_mode != .normal;
    }

    pub fn inDeclareVtab(p: *const Parse) bool {
        return p.e_parse_mode == .declare_vtab;
    }
};

/// A named variable and its number (VList entry).
pub const VListEntry = struct { name: []const u8, num: YnVar };

/// Sqlite3.flags (SQLITE_* connection flags).
pub const DbFlag = struct {
    pub const WriteSchema: u64 = 0x00000001;
    pub const LegacyFileFmt: u64 = 0x00000002;
    pub const FullColNames: u64 = 0x00000004;
    pub const FullFSync: u64 = 0x00000008;
    pub const CkptFullFSync: u64 = 0x00000010;
    pub const CacheSpill: u64 = 0x00000020;
    pub const ShortColNames: u64 = 0x00000040;
    pub const TrustedSchema: u64 = 0x00000080;
    pub const NullCallback: u64 = 0x00000100;
    pub const IgnoreChecks: u64 = 0x00000200;
    pub const StmtScanStatus: u64 = 0x00000400;
    pub const NoCkptOnClose: u64 = 0x00000800;
    pub const ReverseOrder: u64 = 0x00001000;
    pub const RecTriggers: u64 = 0x00002000;
    pub const ForeignKeys: u64 = 0x00004000;
    pub const AutoIndex: u64 = 0x00008000;
    pub const LoadExtension: u64 = 0x00010000;
    pub const LoadExtFunc: u64 = 0x00020000;
    pub const EnableTrigger: u64 = 0x00040000;
    pub const DeferFKs: u64 = 0x00080000;
    pub const QueryOnly: u64 = 0x00100000;
    pub const CellSizeCk: u64 = 0x00200000;
    pub const Fts3Tokenizer: u64 = 0x00400000;
    pub const EnableQPSG: u64 = 0x00800000;
    pub const TriggerEQP: u64 = 0x01000000;
    pub const ResetDatabase: u64 = 0x02000000;
    pub const LegacyAlter: u64 = 0x04000000;
    pub const NoSchemaError: u64 = 0x08000000;
    pub const Defensive: u64 = 0x10000000;
    pub const DqsDDL: u64 = 0x20000000;
    pub const DqsDML: u64 = 0x40000000;
    pub const EnableView: u64 = 0x80000000;
    pub const CountRows: u64 = 0x1_00000000;
    pub const CorruptRdOnly: u64 = 0x2_00000000;
    pub const ReadUncommit: u64 = 0x4_00000000;
    pub const FkNoAction: u64 = 0x8_00000000;
    pub const AttachCreate: u64 = 0x10_00000000;
    pub const AttachWrite: u64 = 0x20_00000000;
    pub const Comments: u64 = 0x40_00000000;
};

/// Query optimizations that Sqlite3.db_opt_flags can disable (SQLITE_*).
pub const OPT = struct {
    pub const QueryFlattener: u32 = 0x00000001;
    pub const WindowFunc: u32 = 0x00000002;
    pub const GroupByOrder: u32 = 0x00000004;
    pub const DistinctOpt: u32 = 0x00000010;
    pub const CoverIdxScan: u32 = 0x00000020;
    pub const OrderByIdxJoin: u32 = 0x00000040;
    pub const Transitive: u32 = 0x00000080;
    pub const OmitNoopJoin: u32 = 0x00000100;
    pub const CountOfView: u32 = 0x00000200;
    pub const CursorHints: u32 = 0x00000400;
    pub const PushDown: u32 = 0x00001000;
    pub const SimplifyJoin: u32 = 0x00002000;
    pub const SkipScan: u32 = 0x00004000;
    pub const PropagateConst: u32 = 0x00008000;
    pub const MinMaxOpt: u32 = 0x00010000;
    pub const SeekScan: u32 = 0x00020000;
    pub const OmitOrderBy: u32 = 0x00040000;
    pub const BloomFilter: u32 = 0x00080000;
    pub const BalancedMerge: u32 = 0x00200000;
    pub const ReleaseReg: u32 = 0x00400000;
    pub const FlttnUnionAll: u32 = 0x00800000;
    pub const IndexedExpr: u32 = 0x01000000;
    pub const Coroutines: u32 = 0x02000000;
    pub const NullUnusedCols: u32 = 0x04000000;
    pub const OnePass: u32 = 0x08000000;
    pub const OrderBySubq: u32 = 0x10000000;
    pub const StarQuery: u32 = 0x20000000;
    pub const ExistsToJoin: u32 = 0x40000000;
    pub const UnionLimit: u32 = 0x80000000;
};

/// Sqlite3.m_db_flags (DBFLAG_*).
pub const DBFLAG = struct {
    pub const SchemaChange: u32 = 0x0001;
    pub const PreferBuiltin: u32 = 0x0002;
    pub const Vacuum: u32 = 0x0004;
    pub const VacuumInto: u32 = 0x0008;
    pub const SchemaKnownOk: u32 = 0x0010;
    pub const InternalFunc: u32 = 0x0020;
    pub const EncodingFixed: u32 = 0x0040;
};

/// sqlite3.init: state while reading the schema.
pub const InitState = struct {
    /// Root page of the object being read.
    new_tnum: Pgno = 0,
    /// Database whose schema is being read.
    i_db: u8 = 0,
    /// Reading the schema (sqlite_schema rows are parsed).
    busy: bool = false,
    orphan_trigger: bool = false,
    imposter_table: u2 = 0,
    reopen_memdb: bool = false,
    /// azInit: object type, name and table, for error messages.
    az_init: [3][]const u8 = .{ "", "", "" },
};

const Vdbe = @import("../vdbe/vdbe_int.zig").Vdbe;
const Mem = @import("../vdbe/vdbe_int.zig").Mem;

/// One attached database (Db): aDb[0] is "main", aDb[1] "temp".
pub const Db = struct {
    name: [:0]const u8,
    bt: ?*Btree = null,
    safety_level: u8 = 3,
    sync_set: bool = false,
    schema: *Schema,
};

/// A database connection (sqlite3).
pub const Sqlite3 = struct {
    gpa: Allocator,
    /// The VFS of the connection's files, also used for ephemeral tables.
    vfs: ?@import("../vfs/vfs.zig").Vfs = null,
    dbs: std.ArrayList(Db) = .empty,
    flags: u64 = DbFlag.ShortColNames | DbFlag.EnableTrigger | DbFlag.EnableView |
        DbFlag.CacheSpill | DbFlag.TrustedSchema | DbFlag.DqsDML | DbFlag.DqsDDL |
        DbFlag.AutoIndex | DbFlag.Comments | DbFlag.FkNoAction,
    m_db_flags: u32 = 0,
    /// Text encoding (SQLITE_UTF8 = 1).
    enc: u8 = 1,
    limits: std.enums.EnumArray(Limit, i32) = Limit.defaults,
    init: InitState = .{},
    /// Statements currently running, and those that write.
    n_vdbe_active: i32 = 0,
    n_vdbe_write: i32 = 0,
    /// Autocommit mode: no BEGIN is in effect.
    auto_commit: bool = true,
    /// Rows changed by the last statement, and in total.
    n_change: i64 = 0,
    n_total_change: i64 = 0,
    last_rowid: i64 = 0,
    err_code: i32 = RC.OK,
    /// Offset in the statement of the token an error is about, or -1
    /// (sqlite3_error_offset). -2 while an error message is formatted.
    err_byte_offset: i32 = -1,
    /// Errors are not recorded while this is nonzero.
    suppress_err: u8 = 0,
    is_interrupted: std.atomic.Value(bool) = .init(false),
    /// Optimizations turned off (SQLITE_TESTCTRL_OPTIMIZATIONS); see OPT.
    db_opt_flags: u32 = 0,
    /// The innermost Parse running on this connection.
    parse: ?*Parse = null,
    /// Prepared statements of the connection.
    vdbe: ?*Vdbe = null,
    n_vdbe_read: i32 = 0,
    n_vdbe_exec: i32 = 0,
    /// Open statement transactions and savepoints.
    n_statement: i32 = 0,
    n_savepoint: i32 = 0,
    /// Outstanding deferred foreign key violations.
    n_deferred_cons: i64 = 0,
    n_deferred_imm_cons: i64 = 0,
    /// The last error message.
    err: ?*Mem = null,
    /// Applied to result codes (0xff without extended codes).
    err_mask: i32 = 0xff,
    /// Significant digits when REAL values become text.
    n_fp_digit: u8 = 17,
    malloc_failed: bool = false,

    pub fn limit(db: *const Sqlite3, l: Limit) i32 {
        return db.limits.get(l);
    }

    /// OptimizationDisabled().
    pub fn optDisabled(db: *const Sqlite3, mask: u32) bool {
        return db.db_opt_flags & mask != 0;
    }
};

const Btree = @import("../btree/btree.zig").Btree;
