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
const flags = @import("../util/flags.zig");
const thunk = @import("../util/thunk.zig");

pub const TK = grammar.TK;
pub const Allocator = std.mem.Allocator;
pub const Pgno = u32;

/// Out of memory: the only failure of parse-tree constructors.
pub const Oom = error{OutOfMemory};

/// The failure of a step of compiling a statement, where C returns a
/// nonzero error count or SQLITE_ERROR: the error is already in the Parse
/// (Parse.n_err, Parse.err_msg and Parse.rc, as sqlite3ErrorMsg() and
/// sqlite3OomFault() leave them; nothing if db.suppress_err is set), and
/// the caller stops. Running out of memory is reported this way too, once
/// the Parse knows (build.oomFault()).
pub const ParseError = error{ParseFailed};

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
pub const EP = packed struct(u32) {
    OuterON: bool = false,
    InnerON: bool = false,
    Distinct: bool = false,
    HasFunc: bool = false,
    Agg: bool = false,
    FixedCol: bool = false,
    VarSelect: bool = false,
    DblQuoted: bool = false,
    InfixFunc: bool = false,
    Collate: bool = false,
    Commuted: bool = false,
    IntValue: bool = false,
    xIsSelect: bool = false,
    Skip: bool = false,
    Reduced: bool = false,
    Win: bool = false,
    TokenOnly: bool = false,
    FullSize: bool = false,
    IfNullRow: bool = false,
    Unlikely: bool = false,
    ConstFunc: bool = false,
    CanBeNull: bool = false,
    Subquery: bool = false,
    Leaf: bool = false,
    WinFunc: bool = false,
    Subrtn: bool = false,
    Quoted: bool = false,
    Static: bool = false,
    IsTrue: bool = false,
    IsFalse: bool = false,
    FromDDL: bool = false,
    SubtArg: bool = false,

    /// Properties that propagate up to parent nodes.
    pub const Propagate: EP = .{ .HasFunc = true, .Collate = true, .Subquery = true };

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(EP, .{
            .OuterON = 0x00000001,
            .InnerON = 0x00000002,
            .Distinct = 0x00000004,
            .HasFunc = 0x00000008,
            .Agg = 0x00000010,
            .FixedCol = 0x00000020,
            .VarSelect = 0x00000040,
            .DblQuoted = 0x00000080,
            .InfixFunc = 0x00000100,
            .Collate = 0x00000200,
            .Commuted = 0x00000400,
            .IntValue = 0x00000800,
            .xIsSelect = 0x00001000,
            .Skip = 0x00002000,
            .Reduced = 0x00004000,
            .Win = 0x00008000,
            .TokenOnly = 0x00010000,
            .FullSize = 0x00020000,
            .IfNullRow = 0x00040000,
            .Unlikely = 0x00080000,
            .ConstFunc = 0x00100000,
            .CanBeNull = 0x00200000,
            .Subquery = 0x00400000,
            .Leaf = 0x00800000,
            .WinFunc = 0x01000000,
            .Subrtn = 0x02000000,
            .Quoted = 0x04000000,
            .Static = 0x08000000,
            .IsTrue = 0x10000000,
            .IsFalse = 0x20000000,
            .FromDDL = 0x40000000,
            .SubtArg = 0x80000000,
        });
    }
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
    flags: EP = .{},
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
    agg_info: ?*AggInfo = null,
    y: union {
        tab: ?*Table,
        win: ?*Window,
        n_reg: i32,
        sub: struct { addr: i32, reg_return: i32 },
    } = .{ .tab = null },

    pub fn useUToken(e: *const Expr) bool {
        return !e.flags.IntValue;
    }

    pub fn useXList(e: *const Expr) bool {
        return !e.flags.xIsSelect;
    }

    pub fn useXSelect(e: *const Expr) bool {
        return e.flags.xIsSelect;
    }

    pub fn useYWin(e: *const Expr) bool {
        return e.flags.WinFunc;
    }

    pub fn useYTab(e: *const Expr) bool {
        return !e.flags.intersects(.{ .WinFunc = true, .Subrtn = true });
    }

    pub fn useWJoin(e: *const Expr) bool {
        return e.flags.intersects(.{ .InnerON = true, .OuterON = true });
    }

    /// The token text, or "" (u.zToken).
    pub fn token(e: *const Expr) [:0]const u8 {
        std.debug.assert(e.useUToken());
        return e.u.token orelse "";
    }

    pub fn alwaysTrue(e: *const Expr) bool {
        return e.flags.IsTrue and !e.flags.OuterON;
    }

    pub fn alwaysFalse(e: *const Expr) bool {
        return e.flags.IsFalse and !e.flags.OuterON;
    }

    /// IsWindowFunc(): a function with an OVER clause.
    pub fn isWindowFunc(e: *const Expr) bool {
        return e.flags.WinFunc and e.y.win.?.e_frm_type != TK.FILTER;
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
pub const JT = packed struct(u8) {
    INNER: bool = false,
    CROSS: bool = false,
    NATURAL: bool = false,
    LEFT: bool = false,
    RIGHT: bool = false,
    OUTER: bool = false,
    LTORJ: bool = false,
    ERROR: bool = false,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(JT, .{
            .INNER = 0x01,
            .CROSS = 0x02,
            .NATURAL = 0x04,
            .LEFT = 0x08,
            .RIGHT = 0x10,
            .OUTER = 0x20,
            .LTORJ = 0x40,
            .ERROR = 0x80,
        });
    }
};

/// One term of a FROM clause (SrcItem).
pub const SrcItem = struct {
    name: ?[:0]u8 = null,
    alias: ?[:0]u8 = null,
    /// The table zName resolved to.
    s_tab: ?*Table = null,
    fg: packed struct {
        jointype: JT = .{},
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
pub const SF = packed struct(u32) {
    Distinct: bool = false,
    All: bool = false,
    Resolved: bool = false,
    Aggregate: bool = false,
    HasAgg: bool = false,
    ClonedRhsIn: bool = false,
    Expanded: bool = false,
    HasTypeInfo: bool = false,
    Compound: bool = false,
    Values: bool = false,
    MultiValue: bool = false,
    NestedFrom: bool = false,
    MinMaxAgg: bool = false,
    Recursive: bool = false,
    FixedLimit: bool = false,
    _15: u1 = 0,
    Converted: bool = false,
    IncludeHidden: bool = false,
    ComplexResult: bool = false,
    WhereBegin: bool = false,
    WinRewrite: bool = false,
    View: bool = false,
    _22: u1 = 0,
    UFSrcCheck: bool = false,
    PushDown: bool = false,
    MultiPart: bool = false,
    CopyCte: bool = false,
    OrderByReqd: bool = false,
    UpdateFrom: bool = false,
    Correlated: bool = false,
    OnToWhere: bool = false,
    _31: u1 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(SF, .{
            .Distinct = 0x00000001,
            .All = 0x00000002,
            .Resolved = 0x00000004,
            .Aggregate = 0x00000008,
            .HasAgg = 0x00000010,
            .ClonedRhsIn = 0x00000020,
            .Expanded = 0x00000040,
            .HasTypeInfo = 0x00000080,
            .Compound = 0x00000100,
            .Values = 0x00000200,
            .MultiValue = 0x00000400,
            .NestedFrom = 0x00000800,
            .MinMaxAgg = 0x00001000,
            .Recursive = 0x00002000,
            .FixedLimit = 0x00004000,
            .Converted = 0x00010000,
            .IncludeHidden = 0x00020000,
            .ComplexResult = 0x00040000,
            .WhereBegin = 0x00080000,
            .WinRewrite = 0x00100000,
            .View = 0x00200000,
            .UFSrcCheck = 0x00800000,
            .PushDown = 0x01000000,
            .MultiPart = 0x02000000,
            .CopyCte = 0x04000000,
            .OrderByReqd = 0x08000000,
            .UpdateFrom = 0x10000000,
            .Correlated = 0x20000000,
            .OnToWhere = 0x40000000,
        });
    }
};

/// One SELECT (Select). Compound selects link through `prior`.
pub const Select = struct {
    /// TK_SELECT, or TK_UNION, TK_ALL, TK_INTERSECT, TK_EXCEPT.
    op: u8 = TK.SELECT,
    n_select_row: LogEst = 0,
    sel_flags: SF = .{},
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
    w_func: ?*const FuncDef = null,
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

/// Conflict resolution (OE_*), numbered as in C. The codes travel as
/// integers through the parser's values (with two foreign key actions
/// packed in one), the P2 of OP_Halt, the P5 of OP_VUpdate and OP_Insert
/// and Expr.aff_expr of RAISE(); int() and fromInt() convert there.
pub const OE = enum(u8) {
    None = 0,
    Rollback = 1,
    Abort = 2,
    Fail = 3,
    Ignore = 4,
    Replace = 5,
    Update = 6,
    Restrict = 7,
    SetNull = 8,
    SetDflt = 9,
    Cascade = 10,
    Default = 11,

    /// The number of the code, as C stores it.
    pub inline fn int(oe: OE) u8 {
        return @backingInt(oe);
    }

    /// The code numbered `n`, which must be one.
    pub inline fn fromInt(n: anytype) OE {
        return @fromBackingInt(@intCast(n));
    }
};

/// One statement of a trigger body (TriggerStep).
pub const TriggerStep = struct {
    /// TK_DELETE, TK_UPDATE, TK_INSERT, TK_SELECT or TK_RETURNING.
    op: u8,
    orconf: OE = .None,
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
    /// The trigger implements a foreign key action (fkey.zig).
    is_fk_action: bool = false,
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
    /// The memory of a schema trigger, which holds the trigger and its
    /// steps; null while it is being built.
    mem: ?*std.heap.ArenaAllocator = null,
};

/// A RETURNING clause (Returning): a transient TEMP trigger whose one step
/// stores each changed row's results in an ephemeral table, which the
/// statement returns at its end.
pub const Returning = struct {
    parse: *Parse,
    return_el: ?*ExprList,
    ret_trig: Trigger,
    ret_tstep: TriggerStep,
    /// The ephemeral table of results.
    i_ret_cur: i32 = 0,
    /// Results per row once "*" is expanded.
    n_ret_col: i32 = 0,
    /// Registers holding a row of results.
    i_ret_reg: i32 = 0,
    /// The trigger's name: "sqlite_returning_%p".
    name_buf: [40]u8 = undefined,
};

// ================================================================= schema

/// Column.col_flags (COLFLAG_*).
pub const COLFLAG = packed struct(u16) {
    PRIMKEY: bool = false,
    HIDDEN: bool = false,
    HASTYPE: bool = false,
    UNIQUE: bool = false,
    SORTERREF: bool = false,
    VIRTUAL: bool = false,
    STORED: bool = false,
    NOTAVAIL: bool = false,
    BUSY: bool = false,
    HASCOLL: bool = false,
    NOEXPAND: bool = false,
    _11: u5 = 0,

    /// Either kind of generated column.
    pub const GENERATED: COLFLAG = .{ .VIRTUAL = true, .STORED = true };

    /// Not set by an INSERT: hidden or generated.
    pub const NOINSERT: COLFLAG = .{ .HIDDEN = true, .VIRTUAL = true, .STORED = true };

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(COLFLAG, .{
            .PRIMKEY = 0x0001,
            .HIDDEN = 0x0002,
            .HASTYPE = 0x0004,
            .UNIQUE = 0x0008,
            .SORTERREF = 0x0010,
            .VIRTUAL = 0x0020,
            .STORED = 0x0040,
            .NOTAVAIL = 0x0080,
            .BUSY = 0x0100,
            .HASCOLL = 0x0200,
            .NOEXPAND = 0x0400,
        });
    }
};

/// Column.e_ctype: the standard types of STRICT tables (COLTYPE_*),
/// numbered as in C. CUSTOM (0) is any other declared type; the standard
/// ones follow from ANY in the order of sqlite3StdType[], so that C
/// indexes that array and its companions by eCType-1 (stdTypeIndex()) and
/// tests for a type stricter than ANY with eCType>COLTYPE_ANY.
pub const COLTYPE = enum(u4) {
    CUSTOM = 0,
    ANY = 1,
    BLOB = 2,
    INT = 3,
    INTEGER = 4,
    REAL = 5,
    TEXT = 6,

    /// The number of the type, as C stores it.
    pub inline fn int(t: COLTYPE) u4 {
        return @backingInt(t);
    }

    /// The position of a standard type in sqlite3StdType[] (C:
    /// `eCType-1`). Not for CUSTOM.
    pub inline fn stdTypeIndex(t: COLTYPE) usize {
        std.debug.assert(t != .CUSTOM);
        return t.int() - 1;
    }

    /// The standard type at sqlite3StdType[i] (C: `i+1`).
    pub inline fn fromStdTypeIndex(i: usize) COLTYPE {
        return @fromBackingInt(@intCast(i + 1));
    }
};

/// A table column (Column). As in C, the declared type and collation
/// follow the name in `cn_name`, each NUL-terminated, when COLFLAG_HASTYPE
/// and COLFLAG_HASCOLL are set.
pub const Column = struct {
    cn_name: [:0]u8,
    /// An OE_ code for NOT NULL.
    not_null: OE = .None,
    e_ctype: COLTYPE = .CUSTOM,
    affinity: u8 = Aff.blob,
    /// Estimated size; sizeof(INT) is 1.
    sz_est: u8 = 1,
    h_name: u8 = 0,
    /// 1-based index of the DEFAULT expression in Table.dflt_list; 0 none.
    i_dflt: u16 = 0,
    col_flags: COLFLAG = .{},

    pub fn name(c: *const Column) [:0]const u8 {
        return std.mem.sliceTo(c.cn_name, 0);
    }
};

/// Table.tab_flags (TF_*).
pub const TF = packed struct(u32) {
    Readonly: bool = false,
    HasHidden: bool = false,
    HasPrimaryKey: bool = false,
    Autoincrement: bool = false,
    HasStat1: bool = false,
    HasVirtual: bool = false,
    HasStored: bool = false,
    WithoutRowid: bool = false,
    MaybeReanalyze: bool = false,
    NoVisibleRowid: bool = false,
    OOOHidden: bool = false,
    HasNotNull: bool = false,
    Shadow: bool = false,
    HasStat4: bool = false,
    Ephemeral: bool = false,
    Eponymous: bool = false,
    Strict: bool = false,
    Imposter: bool = false,
    _18: u14 = 0,

    /// Has a generated column, VIRTUAL or STORED.
    pub const HasGenerated: TF = .{ .HasVirtual = true, .HasStored = true };

    /// The flags a table takes from one of its columns: TF_HasHidden,
    /// TF_HasVirtual and TF_HasStored (C ors `colFlags & COLFLAG_NOINSERT`
    /// into tabFlags, the bits being the same).
    pub fn ofColumn(c: COLFLAG) TF {
        return .{ .HasHidden = c.HIDDEN, .HasVirtual = c.VIRTUAL, .HasStored = c.STORED };
    }

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(TF, .{
            .Readonly = 0x00000001,
            .HasHidden = 0x00000002,
            .HasPrimaryKey = 0x00000004,
            .Autoincrement = 0x00000008,
            .HasStat1 = 0x00000010,
            .HasVirtual = 0x00000020,
            .HasStored = 0x00000040,
            .WithoutRowid = 0x00000080,
            .MaybeReanalyze = 0x00000100,
            .NoVisibleRowid = 0x00000200,
            .OOOHidden = 0x00000400,
            .HasNotNull = 0x00000800,
            .Shadow = 0x00001000,
            .HasStat4 = 0x00002000,
            .Ephemeral = 0x00004000,
            .Eponymous = 0x00008000,
            .Strict = 0x00010000,
            .Imposter = 0x00020000,
        });
    }
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
    tab_flags: TF = .{},
    /// The INTEGER PRIMARY KEY column, or -1.
    i_pkey: i16 = -1,
    /// Columns that are not VIRTUAL.
    n_nv_col: i16 = 0,
    n_row_log_est: LogEst = 200,
    sz_tab_row: LogEst = 0,
    key_conf: OE = .None,
    e_tab_type: TabType = .norm,
    /// The columns of this view are being computed (SQLite marks this
    /// with a negative nCol), to catch circular definitions.
    view_resolving: bool = false,
    u: union {
        tab: struct {
            add_col_offset: i32 = 0,
            fkey: ?*FKey = null,
            /// DEFAULT clauses, or the AS of generated columns.
            dflt_list: ?*ExprList = null,
        },
        view: struct {
            select: ?*Select = null,
            /// The memory of the computed columns of a schema view, freed
            /// when they are reset (viewResetAll()).
            cols_mem: ?*std.heap.ArenaAllocator = null,
        },
        vtab: struct {
            /// The module arguments (azArg): the module name, the
            /// database name (set when a constructor runs), the table
            /// name, then the arguments of CREATE VIRTUAL TABLE. They
            /// live in the table's memory.
            args: [][:0]const u8 = &.{},
            /// The VTable of each connection using the table.
            p: ?*VTable = null,
            /// The memory of the columns sqlite3_declare_vtab() made (the
            /// declared table's), freed with the table.
            decl_mem: ?*std.heap.ArenaAllocator = null,
        },
    } = .{ .tab = .{} },
    trigger: ?*Trigger = null,
    schema: ?*Schema = null,
    /// The memory of a schema table, which holds the table itself, its
    /// columns, indexes and expressions; null for the tables of a single
    /// statement, which live in the Parse arena.
    mem: ?*std.heap.ArenaAllocator = null,

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
        return !t.tab_flags.WithoutRowid;
    }

    /// IsVirtual().
    pub fn isVirtual(t: *const Table) bool {
        return t.e_tab_type == .vtab;
    }
};

/// A virtual table module registered on a connection (Module).
pub const Module = struct {
    /// The callback methods.
    module: *const @import("vtab.zig").Module,
    name: [:0]u8,
    /// pAux, passed to xCreate and xConnect.
    aux: ?*anyopaque = null,
    /// Destructor of `aux`.
    x_destroy: ?DestructorFn = null,
    /// References: the registration and each VTable.
    n_ref_module: i32 = 1,
    /// The eponymous virtual table, if made.
    epo_tab: ?*Table = null,
};

/// SQLITE_VTABRISK_*, numbered as in C.
pub const VTABRISK = enum(u8) {
    Low = 0,
    Normal = 1,
    High = 2,

    /// Whether a virtual table of this risk may not be used from the schema
    /// (C: `eVtabRisk > ((db->flags & SQLITE_TrustedSchema)!=0)`): High
    /// never, Normal only with a trusted schema, Low always.
    pub inline fn unsafeInSchema(risk: VTABRISK, trusted_schema: bool) bool {
        return @backingInt(risk) > @intFromBool(trusted_schema);
    }
};

/// The instance of a virtual table on one connection (VTable).
pub const VTable = struct {
    db: *Sqlite3,
    mod: *Module,
    /// The object the module's constructor made.
    vtab: ?*@import("vtab.zig").Vtab = null,
    n_ref: i32 = 0,
    /// SQLITE_VTAB_CONSTRAINT_SUPPORT was enabled.
    b_constraint: bool = false,
    /// SQLITE_VTAB_USES_ALL_SCHEMAS was set.
    b_all_schemas: bool = false,
    /// SQLITE_VTABRISK_*.
    e_vtab_risk: VTABRISK = .Normal,
    /// Depth of the SAVEPOINT stack.
    i_savepoint: i32 = 0,
    next: ?*VTable = null,
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
    a_action: [2]OE = .{ .None, .None },
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
    on_error: OE = .None,
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
pub const DB = packed struct(u16) {
    /// The schema has been read.
    SchemaLoaded: bool = false,
    /// Some views have defined column names.
    UnresetViews: bool = false,
    _2: u1 = 0,
    /// Reset the schema when nRefTables==0.
    ResetWanted: bool = false,
    _4: u12 = 0,

    comptime {
        flags.checkBits(DB, .{
            .SchemaLoaded = 0x0001,
            .UnresetViews = 0x0002,
            .ResetWanted = 0x0008,
        });
    }
};

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

/// A SAVEPOINT (Savepoint).
pub const Savepoint = struct {
    name: [:0]u8,
    /// Deferred constraint violations when it opened.
    n_deferred_cons: i64,
    n_deferred_imm_cons: i64,
    next: ?*Savepoint,
};

/// The schema of one database file (Schema).
pub const Schema = struct {
    schema_cookie: i32 = 0,
    i_generation: i32 = 0,
    tbl_hash: NameMap(*Table) = .empty,
    /// The tables in the order of C's tblHash (hash.zig).
    tbl_order: @import("hash.zig").HashOrder(*Table) = .{},
    idx_hash: NameMap(*Index) = .empty,
    trig_hash: NameMap(*Trigger) = .empty,
    fkey_hash: NameMap(*FKey) = .empty,
    seq_tab: ?*Table = null,
    file_format: u8 = 0,
    enc: u8 = 0,
    schema_flags: DB = .{},
    cache_size: i32 = 0,
};

// ============================================================== functions

/// A collating sequence (CollSeq).
pub const CollSeq = struct {
    name: [:0]const u8,
    enc: u8 = 1,
    user: ?*anyopaque = null,
    /// Null for a collation named in the schema but not defined.
    cmp: ?CmpFn = null,

    pub const CmpFn = *const fn (user: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order;
};

/// An SQL function (FuncDef). The implementations are typed by the VDBE
/// (func.zig); here they are opaque.
pub const FuncDef = struct {
    /// Number of arguments; -1 means any.
    n_arg: i16,
    /// SQLITE_FUNC_* flags (callback.FUNC).
    func_flags: @import("callback.zig").FUNC = .{},
    user_data: ?*anyopaque = null,
    /// Next application-defined function with the same name (a built-in
    /// has its overloads next to it in callback.builtins).
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
    /// Destructor of an application-defined function (u.pDestructor).
    destructor: ?*FuncDestructor = null,

    pub const StepFn = *const fn (ctx: *Context, argv: []*Mem) void;
    pub const FinalFn = *const fn (ctx: *Context) void;
    const Context = @import("../vdbe/vdbe_int.zig").Context;

    /// The type of the user data of `f`, a function that takes it as a
    /// third parameter.
    pub fn UserData(comptime f: anytype) type {
        return @typeInfo(@TypeOf(f)).@"fn".param_types[2].?;
    }

    /// The StepFn of `f` (`fn (*Context, []*Mem, data: P) void`), which
    /// takes the user data of its function (sqlite3_user_data()) typed,
    /// cast from `user_data` here only. Register it with
    /// userDataFor(f, data) as the user data.
    pub fn withUserData(comptime f: anytype) StepFn {
        return struct {
            fn call(ctx: *Context, argv: []*Mem) void {
                @call(.always_inline, f, .{ ctx, argv, thunk.downcast(UserData(f), ctx.func.user_data) });
            }
        }.call;
    }

    /// `data`, of the type withUserData(f) takes, as user data.
    pub fn userDataFor(comptime f: anytype, data: UserData(f)) ?*anyopaque {
        return @ptrCast(@constCast(data));
    }

    /// The user data of `def`, a function made with withUserData(f), as
    /// `f` takes it.
    pub fn userDataOf(def: *const FuncDef, comptime f: anytype) UserData(f) {
        std.debug.assert(def.x_sfunc == withUserData(f));
        return thunk.downcast(UserData(f), def.user_data);
    }

    pub fn isAggregate(f: *const FuncDef) bool {
        return f.x_finalize != null;
    }
};

// ============================================================== planning

/// sqlite3WhereBegin() flags (WHERE_*).
pub const WHERE = packed struct(u16) {
    ORDERBY_MIN: bool = false,
    ORDERBY_MAX: bool = false,
    ONEPASS_DESIRED: bool = false,
    ONEPASS_MULTIROW: bool = false,
    DUPLICATES_OK: bool = false,
    OR_SUBCLAUSE: bool = false,
    GROUPBY: bool = false,
    DISTINCTBY: bool = false,
    WANT_DISTINCT: bool = false,
    SORTBYGROUP: bool = false,
    AGG_DISTINCT: bool = false,
    ORDERBY_LIMIT: bool = false,
    RIGHT_JOIN: bool = false,
    KEEP_ALL_JOINS: bool = false,
    USE_LIMIT: bool = false,
    _15: u1 = 0,

    /// No ORDER BY optimization (neither ORDERBY_MIN nor ORDERBY_MAX).
    pub const ORDERBY_NORMAL: WHERE = .{};

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(WHERE, .{
            .ORDERBY_MIN = 0x0001,
            .ORDERBY_MAX = 0x0002,
            .ONEPASS_DESIRED = 0x0004,
            .ONEPASS_MULTIROW = 0x0008,
            .DUPLICATES_OK = 0x0010,
            .OR_SUBCLAUSE = 0x0020,
            .GROUPBY = 0x0040,
            .DISTINCTBY = 0x0080,
            .WANT_DISTINCT = 0x0100,
            .SORTBYGROUP = 0x0200,
            .AGG_DISTINCT = 0x0400,
            .ORDERBY_LIMIT = 0x0800,
            .RIGHT_JOIN = 0x1000,
            .KEEP_ALL_JOINS = 0x2000,
            .USE_LIMIT = 0x4000,
        });
    }
};

/// sqlite3WhereIsDistinct() results (WHERE_DISTINCT_*).
pub const WHERE_DISTINCT = enum(u8) {
    /// DISTINCT keyword not used.
    NOOP = 0,
    /// No duplicates.
    UNIQUE = 1,
    /// All duplicates are adjacent.
    ORDERED = 2,
    /// Duplicates are scattered.
    UNORDERED = 3,
};

// ============================================================ resolution

/// NameContext.nc_flags (NC_*).
pub const NC = packed struct(u32) {
    AllowAgg: bool = false,
    PartIdx: bool = false,
    IsCheck: bool = false,
    GenCol: bool = false,
    HasAgg: bool = false,
    IdxExpr: bool = false,
    Subquery: bool = false,
    UEList: bool = false,
    UAggInfo: bool = false,
    UUpsert: bool = false,
    UBaseReg: bool = false,
    _11: u1 = 0,
    MinMaxAgg: bool = false,
    _13: u1 = 0,
    AllowWin: bool = false,
    HasWin: bool = false,
    IsDDL: bool = false,
    InAggFunc: bool = false,
    FromDDL: bool = false,
    NoSelect: bool = false,
    Where: bool = false,
    _21: u6 = 0,
    OrderAgg: bool = false,
    _28: u4 = 0,

    /// Resolving an expression that may only refer to its own table.
    pub const SelfRef: NC = .{ .PartIdx = true, .IsCheck = true, .GenCol = true, .IdxExpr = true };

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(NC, .{
            .AllowAgg = 0x00000001,
            .PartIdx = 0x00000002,
            .IsCheck = 0x00000004,
            .GenCol = 0x00000008,
            .HasAgg = 0x00000010,
            .IdxExpr = 0x00000020,
            .Subquery = 0x00000040,
            .UEList = 0x00000080,
            .UAggInfo = 0x00000100,
            .UUpsert = 0x00000200,
            .UBaseReg = 0x00000400,
            .MinMaxAgg = 0x00001000,
            .AllowWin = 0x00004000,
            .HasWin = 0x00008000,
            .IsDDL = 0x00010000,
            .InAggFunc = 0x00020000,
            .FromDDL = 0x00040000,
            .NoSelect = 0x00080000,
            .Where = 0x00100000,
            .OrderAgg = 0x08000000,
        });
    }
};

/// The tables and result columns names are resolved against
/// (NameContext). Contexts chain outward through `next`.
pub const NameContext = struct {
    parse: *Parse,
    src_list: ?*SrcList = null,
    /// Which member is valid is given by NC_UEList, NC_UAggInfo,
    /// NC_UUpsert and NC_UBaseReg.
    u_nc: union { e_list: ?*ExprList, agg_info: ?*AggInfo, upsert: ?*Upsert, i_base_reg: i32 } = .{ .e_list = null },
    next: ?*NameContext = null,
    /// Names resolved by this context.
    n_ref: i32 = 0,
    n_nc_err: i32 = 0,
    nc_flags: NC = .{},
    n_nested_select: u32 = 0,
    /// The SELECT of any window functions.
    win_select: ?*Select = null,
};

/// A column used by an aggregate query (AggInfo_col).
pub const AggInfoCol = struct {
    tab: ?*Table,
    c_expr: *Expr,
    i_table: i32,
    i_column: i32,
    i_sorter_column: i32,
};

/// An aggregate function of a query (AggInfo_func).
pub const AggInfoFunc = struct {
    f_expr: *Expr,
    func: ?*const FuncDef,
    i_distinct: i32 = -1,
    i_dist_addr: i32 = 0,
    i_ob_tab: i32 = -1,
    b_ob_payload: bool = false,
    b_ob_unique: bool = false,
    b_use_subtype: bool = false,
};

/// An expression stored in an index the query uses: code reads its value
/// from the index instead of computing it (IndexedExpr).
pub const IndexedExpr = struct {
    /// The expression contained in the index.
    expr: *Expr,
    /// The data cursor associated with the index.
    i_data_cur: i32,
    /// The index cursor.
    i_idx_cur: i32,
    /// The index column that holds the value of expr.
    i_idx_col: i32,
    /// An OP_IfNullRow check is needed (the table is on the right of an
    /// outer join).
    b_maybe_null_row: bool = false,
    /// Affinity of the expression.
    aff: u8 = 0,
    next: ?*IndexedExpr = null,
};

/// How an aggregate query computes its result (AggInfo).
pub const AggInfo = struct {
    /// Read data directly from the source tables, not the accumulators.
    direct_mode: bool = false,
    /// In direct mode, read from the sorting index.
    use_sorting_idx: bool = false,
    n_sorting_column: u32 = 0,
    sorting_idx: i32 = 0,
    sorting_idx_ptab: i32 = 0,
    /// First register of the columns, then the functions.
    i_first_reg: i32 = 0,
    group_by: ?*ExprList = null,
    cols: std.ArrayList(AggInfoCol) = .empty,
    /// Columns that show through to the output.
    n_accumulator: i32 = 0,
    funcs: std.ArrayList(AggInfoFunc) = .empty,
    sel_id: u32 = 0,

    pub fn columnReg(a: *const AggInfo, i: usize) i32 {
        std.debug.assert(a.i_first_reg != 0);
        return a.i_first_reg + @as(i32, @intCast(i));
    }

    pub fn funcReg(a: *const AggInfo, i: usize) i32 {
        std.debug.assert(a.i_first_reg != 0);
        return a.i_first_reg + @as(i32, @intCast(a.cols.items.len + i));
    }
};

/// The user-data destructor shared by the copies of an application-defined
/// function (FuncDestructor).
pub const FuncDestructor = struct {
    n_ref: i32 = 0,
    x_destroy: DestructorFn,
    user_data: ?*anyopaque,
};

/// A destructor of the C API (`void(*)(void*)`): the xDel of a Mem and of
/// sqlite3_result_text() and the like, of sqlite3_set_auxdata() and
/// sqlite3_result_pointer(), and the xDestroy of
/// sqlite3_create_function_v2() and sqlite3_create_module_v2().
pub const DestructorFn = *const fn (?*anyopaque) void;

/// The DestructorFn of `f`, a typed destructor (`fn (*T) void`): it calls
/// `f` with the pointer cast to the type of its parameter (thunk.thunk()).
/// It is one function per `f`, so it can be compared as C compares xDel
/// (`pMem->xDel==sqlite3RowSetDelete`).
pub fn destructor(comptime f: anytype) DestructorFn {
    return thunk.thunk(DestructorFn, f);
}

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
    pub const CORRUPT_SEQUENCE: i32 = CORRUPT | (2 << 8);
    pub const CORRUPT_INDEX: i32 = CORRUPT | (3 << 8);
    pub const ERROR_MISSING_COLLSEQ: i32 = ERROR | (1 << 8);
    pub const ERROR_RETRY: i32 = ERROR | (2 << 8);
    pub const ERROR_SNAPSHOT: i32 = ERROR | (3 << 8);
    pub const LOCKED_SHAREDCACHE: i32 = LOCKED | (1 << 8);
    pub const ABORT_ROLLBACK: i32 = ABORT | (2 << 8);
    pub const IOERR_SHORT_READ: i32 = IOERR | (2 << 8);
    pub const IOERR_LOCK: i32 = IOERR | (15 << 8);
    pub const IOERR_SHMOPEN: i32 = IOERR | (18 << 8);
    pub const IOERR_SHMSIZE: i32 = IOERR | (19 << 8);
    pub const IOERR_SHMLOCK: i32 = IOERR | (20 << 8);
    pub const IOERR_SHMMAP: i32 = IOERR | (21 << 8);
    pub const BUSY_RECOVERY: i32 = BUSY | (1 << 8);
    pub const BUSY_SNAPSHOT: i32 = BUSY | (2 << 8);
    pub const READONLY_RECOVERY: i32 = READONLY | (1 << 8);
    pub const READONLY_CANTLOCK: i32 = READONLY | (2 << 8);
    pub const READONLY_ROLLBACK: i32 = READONLY | (3 << 8);
    pub const READONLY_CANTINIT: i32 = READONLY | (5 << 8);
    // Other extended codes of sqlite3.h, which the VFS, extensions or
    // the application may report (named by the Zig API's ResultCode).
    pub const BUSY_TIMEOUT: i32 = BUSY | (3 << 8);
    pub const READONLY_DBMOVED: i32 = READONLY | (4 << 8);
    pub const READONLY_DIRECTORY: i32 = READONLY | (6 << 8);
    pub const IOERR_READ: i32 = IOERR | (1 << 8);
    pub const IOERR_WRITE: i32 = IOERR | (3 << 8);
    pub const IOERR_FSYNC: i32 = IOERR | (4 << 8);
    pub const CORRUPT_VTAB: i32 = CORRUPT | (1 << 8);
    pub const CANTOPEN_NOTEMPDIR: i32 = CANTOPEN | (1 << 8);
    pub const CANTOPEN_ISDIR: i32 = CANTOPEN | (2 << 8);
    pub const CANTOPEN_FULLPATH: i32 = CANTOPEN | (3 << 8);
    pub const CONSTRAINT_COMMITHOOK: i32 = CONSTRAINT | (2 << 8);
    pub const CONSTRAINT_FUNCTION: i32 = CONSTRAINT | (4 << 8);
    pub const CONSTRAINT_VTAB: i32 = CONSTRAINT | (9 << 8);
    pub const CONSTRAINT_PINNED: i32 = CONSTRAINT | (11 << 8);
};

/// The errors of the SQL and VDBE layers. Those of the storage layers
/// (btree.Error) each stand for one result code, primary or extended;
/// the others stand for the primary codes only the upper layers report.
/// An extended code with no error of its own (CONSTRAINT_UNIQUE,
/// CORRUPT_INDEX, ERROR_MISSING_COLLSEQ, ...) travels as the error of its
/// primary code, while the code itself is kept where C keeps it (Vdbe.rc,
/// Parse.rc, db.err_code): see resultCode(). The integer codes are only
/// seen at the C-shaped API and in the callbacks of extensions, which
/// errorCode() and codeError() convert from and to.
pub const Error = @import("../btree/btree.zig").Error || error{
    /// SQLITE_ERROR: an SQL error or missing database, and the error of
    /// any code that has no error of its own.
    Error,
    /// SQLITE_INTERNAL.
    Internal,
    /// SQLITE_PERM.
    Perm,
    /// SQLITE_LOCKED: a table of the connection is in use.
    Locked,
    /// SQLITE_NOTFOUND.
    NotFound,
    /// SQLITE_SCHEMA: the schema changed since the statement was compiled.
    Schema,
    /// SQLITE_TOOBIG: a string or blob over the length limit.
    TooBig,
    /// SQLITE_CONSTRAINT.
    Constraint,
    /// SQLITE_MISMATCH.
    Mismatch,
    /// SQLITE_MISUSE.
    Misuse,
    /// SQLITE_NOLFS.
    NoLfs,
    /// SQLITE_AUTH.
    Auth,
    /// SQLITE_FORMAT.
    Format,
    /// SQLITE_RANGE.
    Range,
    /// SQLITE_EMPTY.
    Empty,
};

/// The result code of each error, primary or extended: the one table
/// errorCode() and codeError() derive from. Every error of Error is in
/// it once, with a code of its own (checked below).
const error_codes = [_]struct { Error, i32 }{
    .{ error.Error, RC.ERROR },
    .{ error.Internal, RC.INTERNAL },
    .{ error.Perm, RC.PERM },
    .{ error.Abort, RC.ABORT },
    .{ error.Busy, RC.BUSY },
    .{ error.BusyRecovery, RC.BUSY_RECOVERY },
    .{ error.BusySnapshot, RC.BUSY_SNAPSHOT },
    .{ error.Locked, RC.LOCKED },
    .{ error.OutOfMemory, RC.NOMEM },
    .{ error.ReadOnly, RC.READONLY },
    .{ error.ReadOnlyRecovery, RC.READONLY_RECOVERY },
    .{ error.ReadOnlyRollback, RC.READONLY_ROLLBACK },
    .{ error.ReadOnlyCantInit, RC.READONLY_CANTINIT },
    .{ error.Interrupt, RC.INTERRUPT },
    .{ error.IoErr, RC.IOERR },
    .{ error.ShortRead, RC.IOERR_SHORT_READ },
    .{ error.LockErr, RC.IOERR_LOCK },
    .{ error.ShmOpen, RC.IOERR_SHMOPEN },
    .{ error.ShmSize, RC.IOERR_SHMSIZE },
    .{ error.ShmLock, RC.IOERR_SHMLOCK },
    .{ error.ShmMap, RC.IOERR_SHMMAP },
    .{ error.Corrupt, RC.CORRUPT },
    .{ error.NotFound, RC.NOTFOUND },
    .{ error.DiskFull, RC.FULL },
    .{ error.CantOpen, RC.CANTOPEN },
    .{ error.Protocol, RC.PROTOCOL },
    .{ error.Empty, RC.EMPTY },
    .{ error.Schema, RC.SCHEMA },
    .{ error.TooBig, RC.TOOBIG },
    .{ error.Constraint, RC.CONSTRAINT },
    .{ error.Mismatch, RC.MISMATCH },
    .{ error.Misuse, RC.MISUSE },
    .{ error.NoLfs, RC.NOLFS },
    .{ error.Auth, RC.AUTH },
    .{ error.Format, RC.FORMAT },
    .{ error.Range, RC.RANGE },
    .{ error.NotADatabase, RC.NOTADB },
};

comptime {
    @setEvalBranchQuota(10_000);
    const names = @typeInfo(Error).error_set.error_names.?;
    if (names.len != error_codes.len) @compileError("error_codes must list every error of Error once");
    for (names) |name| {
        var n = 0;
        for (error_codes) |m| {
            if (std.mem.eql(u8, @errorName(m[0]), name)) n += 1;
        }
        if (n != 1) @compileError("error." ++ name ++ " must be in error_codes once");
    }
    for (error_codes, 0..) |m, i| {
        if (m[1] == RC.OK or m[1] & 0xff == RC.OK) @compileError("error_codes maps an error to SQLITE_OK");
        for (error_codes[0..i]) |o| {
            if (o[1] == m[1]) @compileError("two errors of error_codes share a code");
        }
    }
}

/// The error of each primary code: that of the code itself, or
/// error.Error for codes with none (ERROR, and ROW, DONE, NOTICE,
/// WARNING and unknown codes, which are not errors).
const primary_errors: [256]Error = blk: {
    var t: [256]Error = @splat(error.Error);
    for (error_codes) |m| {
        if (m[1] <= 0xff) t[m[1]] = m[0];
    }
    break :blk t;
};

/// The result code `err` stands for.
pub fn errorCode(err: Error) i32 {
    return switch (err) {
        inline else => |e| comptime for (error_codes) |m| {
            if (m[0] == e) break m[1];
        } else unreachable,
    };
}

/// The error of result code `rc`, which is not OK: that of the code
/// itself if it has one, else that of its primary code. Codes that are
/// not errors (ROW, DONE, NOTICE, WARNING) or unknown give error.Error,
/// as do the SQLITE_ERROR codes.
pub fn codeError(rc: i32) Error {
    std.debug.assert(rc != RC.OK);
    inline for (error_codes) |m| {
        if (comptime m[1] > 0xff) {
            if (rc == m[1]) return m[0];
        }
    }
    return primary_errors[@as(u8, @truncate(@as(u32, @bitCast(rc))))];
}

/// The result code to report for `err`, given the code `recorded` where
/// the failing code keeps it (Vdbe.rc, Parse.rc, ...): `recorded` if it
/// is a code of `err` (the error's own code or one of its extended
/// codes), else errorCode(err). So an extended code survives the trip
/// through the error, and a stale or unrelated one is ignored.
pub fn resultCode(err: Error, recorded: i32) i32 {
    if (recorded != RC.OK and codeError(recorded) == err) return recorded;
    return errorCode(err);
}

/// Inward conversion: the error of `rc` (from a callback of an
/// extension, or a function that returns a result code) unless it is
/// OK. The caller keeps `rc` where resultCode() finds it.
pub fn check(rc: i32) Error!void {
    if (rc != RC.OK) return codeError(rc);
}

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
    schema,
    trigger_steps,

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
        .schema = 10000000,
        .trigger_steps = 65000,
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
    /// Schema tables the parse trees point at, each holding one
    /// reference (Table.n_tab_ref) until the statement is prepared.
    tab_refs: std.ArrayList(*Table) = .empty,
    err_msg: ?[:0]u8 = null,
    rc: i32 = RC.OK,
    nested: u8 = 0,
    disable_lookaside: u8 = 0,
    prep_flags: u8 = 0,
    is_create: bool = false,
    /// Only check syntax: no schema is read and no code is generated
    /// (statement builders that are not ported yet do nothing instead of
    /// failing, see pending.zig).
    syntax_only: bool = false,
    disable_triggers: bool = false,
    may_abort: bool = false,
    has_compound: bool = false,
    returning: bool = false,
    has_with: bool = false,
    check_schema: bool = false,
    /// xqlite: SQLite's grammar does not finish the statement it parses
    /// (ir.stmt.lowerSqliteText(): a frontend adds to it and finishes).
    xq_hold_finish: bool = false,
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
    e_orconf: OE = .None,
    bhas_exists: bool = false,
    col_names_set: bool = false,
    ok_const_factor: bool = false,
    uses_ainc: bool = false,
    /// The AUTOINCREMENT tables written by the statement.
    ainc: ?*AutoincInfo = null,
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
    /// pIdxEpr: expressions of indexes the query uses.
    idx_epr: ?*IndexedExpr = null,
    /// pIdxPartExpr: columns that the WHERE terms of a partial index the
    /// query uses fix to constant values.
    idx_part_expr: ?*IndexedExpr = null,
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
    /// The trigger programs coded for the statement (top-level Parse
    /// only), a list of trigger.TriggerPrg.
    trigger_prg: ?*TriggerPrg = null,
    temp_regs: [8]i32 = @splat(0),
    outer_parse: ?*Parse = null,
    name_token: Token = .{},
    oldmask: u32 = 0,
    newmask: u32 = 0,
    /// The innermost EXPLAIN QUERY PLAN node.
    addr_explain: i32 = 0,
    u1: union { cr: CreateState, d: struct { returning: ?*Returning = null } } = .{ .cr = .{} },

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
    /// ASC or DESC of the INTEGER PRIMARY KEY.
    i_pk_sort_order: u8 = 0,
    /// The statement has IF NOT EXISTS.
    if_not_exists: bool = false,
    new_trigger: ?*Trigger = null,
    with: ?*With = null,
    /// The rename-token map built in rename mode (pRename; see alter.zig).
    rename: ?*RenameToken = null,
    /// The argument of CREATE VIRTUAL TABLE being parsed (sArg).
    s_arg: Token = .{},
    /// Virtual tables that need an OP_VBegin (apVtabLock); top-level
    /// Parse only.
    vtab_lock: std.ArrayList(*Table) = .empty,

    pub fn inRenameObject(p: *const Parse) bool {
        return @backingInt(p.e_parse_mode) >= @backingInt(ParseMode.rename);
    }

    pub fn inSpecialParse(p: *const Parse) bool {
        return p.e_parse_mode != .normal;
    }

    pub fn inDeclareVtab(p: *const Parse) bool {
        return p.e_parse_mode == .declare_vtab;
    }
};

/// One entry of the rename-token map (RenameToken): parse-tree element
/// `p` (its address, see alter.key()) was made from token `t`.
pub const RenameToken = struct {
    p: ?*const anyopaque,
    t: Token,
    next: ?*RenameToken,
};

/// An AUTOINCREMENT table written by a statement (AutoincInfo).
pub const AutoincInfo = struct {
    next: ?*AutoincInfo = null,
    tab: *Table,
    i_db: usize,
    /// Register holding the largest rowid.
    reg_ctr: i32,
};

/// A named variable and its number (VList entry).
pub const VListEntry = struct { name: []const u8, num: YnVar };

/// Sqlite3.flags (SQLITE_* connection flags).
pub const DbFlag = packed struct(u64) {
    WriteSchema: bool = false,
    LegacyFileFmt: bool = false,
    FullColNames: bool = false,
    FullFSync: bool = false,
    CkptFullFSync: bool = false,
    CacheSpill: bool = false,
    ShortColNames: bool = false,
    TrustedSchema: bool = false,
    NullCallback: bool = false,
    IgnoreChecks: bool = false,
    StmtScanStatus: bool = false,
    NoCkptOnClose: bool = false,
    ReverseOrder: bool = false,
    RecTriggers: bool = false,
    ForeignKeys: bool = false,
    AutoIndex: bool = false,
    LoadExtension: bool = false,
    LoadExtFunc: bool = false,
    EnableTrigger: bool = false,
    DeferFKs: bool = false,
    QueryOnly: bool = false,
    CellSizeCk: bool = false,
    Fts3Tokenizer: bool = false,
    EnableQPSG: bool = false,
    TriggerEQP: bool = false,
    ResetDatabase: bool = false,
    LegacyAlter: bool = false,
    NoSchemaError: bool = false,
    Defensive: bool = false,
    DqsDDL: bool = false,
    DqsDML: bool = false,
    EnableView: bool = false,
    CountRows: bool = false,
    CorruptRdOnly: bool = false,
    ReadUncommit: bool = false,
    FkNoAction: bool = false,
    AttachCreate: bool = false,
    AttachWrite: bool = false,
    Comments: bool = false,
    _39: u25 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(DbFlag, .{
            .WriteSchema = 0x0000000000000001,
            .LegacyFileFmt = 0x0000000000000002,
            .FullColNames = 0x0000000000000004,
            .FullFSync = 0x0000000000000008,
            .CkptFullFSync = 0x0000000000000010,
            .CacheSpill = 0x0000000000000020,
            .ShortColNames = 0x0000000000000040,
            .TrustedSchema = 0x0000000000000080,
            .NullCallback = 0x0000000000000100,
            .IgnoreChecks = 0x0000000000000200,
            .StmtScanStatus = 0x0000000000000400,
            .NoCkptOnClose = 0x0000000000000800,
            .ReverseOrder = 0x0000000000001000,
            .RecTriggers = 0x0000000000002000,
            .ForeignKeys = 0x0000000000004000,
            .AutoIndex = 0x0000000000008000,
            .LoadExtension = 0x0000000000010000,
            .LoadExtFunc = 0x0000000000020000,
            .EnableTrigger = 0x0000000000040000,
            .DeferFKs = 0x0000000000080000,
            .QueryOnly = 0x0000000000100000,
            .CellSizeCk = 0x0000000000200000,
            .Fts3Tokenizer = 0x0000000000400000,
            .EnableQPSG = 0x0000000000800000,
            .TriggerEQP = 0x0000000001000000,
            .ResetDatabase = 0x0000000002000000,
            .LegacyAlter = 0x0000000004000000,
            .NoSchemaError = 0x0000000008000000,
            .Defensive = 0x0000000010000000,
            .DqsDDL = 0x0000000020000000,
            .DqsDML = 0x0000000040000000,
            .EnableView = 0x0000000080000000,
            .CountRows = 0x0000000100000000,
            .CorruptRdOnly = 0x0000000200000000,
            .ReadUncommit = 0x0000000400000000,
            .FkNoAction = 0x0000000800000000,
            .AttachCreate = 0x0000001000000000,
            .AttachWrite = 0x0000002000000000,
            .Comments = 0x0000004000000000,
        });
    }
};

/// Query optimizations that Sqlite3.db_opt_flags can disable (SQLITE_*).
pub const OPT = struct {
    pub const QueryFlattener: u32 = 0x00000001;
    pub const WindowFunc: u32 = 0x00000002;
    pub const GroupByOrder: u32 = 0x00000004;
    pub const FactorOutConst: u32 = 0x00000008;
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
pub const DBFLAG = packed struct(u32) {
    SchemaChange: bool = false,
    PreferBuiltin: bool = false,
    Vacuum: bool = false,
    VacuumInto: bool = false,
    SchemaKnownOk: bool = false,
    InternalFunc: bool = false,
    EncodingFixed: bool = false,
    _7: u25 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;
    pub const intersects = ops.intersects;
    pub const contains = ops.contains;
    pub const isEmpty = ops.isEmpty;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const only = ops.only;
    pub const set = ops.set;
    pub const clear = ops.clear;

    comptime {
        flags.checkBits(DBFLAG, .{
            .SchemaChange = 0x00000001,
            .PreferBuiltin = 0x00000002,
            .Vacuum = 0x00000004,
            .VacuumInto = 0x00000008,
            .SchemaKnownOk = 0x00000010,
            .InternalFunc = 0x00000020,
            .EncodingFixed = 0x00000040,
        });
    }
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
const TriggerPrg = @import("trigger.zig").TriggerPrg;
const Mem = @import("../vdbe/vdbe_int.zig").Mem;

/// Root page of sqlite_schema.
pub const SCHEMA_ROOT: Pgno = 1;
pub const LEGACY_SCHEMA_TABLE = "sqlite_master";
pub const LEGACY_TEMP_SCHEMA_TABLE = "sqlite_temp_master";
pub const PREFERRED_SCHEMA_TABLE = "sqlite_schema";
pub const PREFERRED_TEMP_SCHEMA_TABLE = "sqlite_temp_schema";

/// SCHEMA_TABLE(): the name of the schema table of database `i_db`.
pub fn schemaTable(i_db: usize) [:0]const u8 {
    return if (i_db == 1) LEGACY_TEMP_SCHEMA_TABLE else LEGACY_SCHEMA_TABLE;
}

/// SQLITE_MAX_FILE_FORMAT.
pub const MAX_FILE_FORMAT = 4;
/// SQLITE_DEFAULT_CACHE_SIZE.
pub const DEFAULT_CACHE_SIZE = -2000;

/// SQLITE_MAX_DB: as a database index, every database.
pub const MAX_DB: i32 = 10 + 2;

/// A busy handler (struct BusyHandler).
pub const BusyHandler = struct {
    /// Called with the number of prior calls; nonzero means retry
    /// (xBusyHandler).
    func: ?Fn = null,
    arg: ?*anyopaque = null,
    /// Calls so far, or -1 once the handler gave up (nBusy).
    n_busy: i32 = 0,

    /// The busy callback of sqlite3_busy_handler().
    pub const Fn = *const fn (arg: ?*anyopaque, count: i32) i32;
};

/// A WAL hook (sqlite3_wal_hook()): called after a commit with the
/// database name and the frames in its WAL.
pub const WalCallback = *const fn (arg: ?*anyopaque, db: *Sqlite3, name: [:0]const u8, n_frame: i32) i32;

/// One attached database (Db): aDb[0] is "main", aDb[1] "temp".
pub const Db = struct {
    name: [:0]const u8,
    bt: ?*Btree = null,
    safety_level: u8 = 3,
    sync_set: bool = false,
    schema: *Schema,
};

/// A free lookaside slot (LookasideSlot).
pub const LookasideSlot = struct {
    next: ?*LookasideSlot,
};

/// The lookaside memory of a connection (Lookaside): one block cut into
/// slots of `sz_true` bytes, then smaller ones of LOOKASIDE_SMALL bytes
/// from `middle` on. See malloc.zig.
pub const Lookaside = struct {
    /// Slots are handed out only while this is zero (bDisable).
    b_disable: u32 = 1,
    /// Size of each slot, or 0 while disabled (sz).
    sz: u16 = 0,
    /// Size of each slot, even while disabled (szTrue).
    sz_true: u16 = 0,
    /// The block came from malloc() (bMalloced).
    b_malloced: bool = false,
    /// Slots in all (nSlot).
    n_slot: u32 = 0,
    /// Hits, misses for size and misses with every slot taken (anStat).
    an_stat: [3]u32 = .{ 0, 0, 0 },
    /// Slots never used (pInit), and freed ones (pFree).
    init: ?*LookasideSlot = null,
    free: ?*LookasideSlot = null,
    /// The same for the small slots (pSmallInit, pSmallFree).
    small_init: ?*LookasideSlot = null,
    small_free: ?*LookasideSlot = null,
    /// Addresses of the block, its small slots and its end (pStart,
    /// pMiddle, pEnd; pTrueEnd is pEnd).
    start: usize = 0,
    middle: usize = 0,
    end: usize = 0,
};

/// A database connection (sqlite3).
pub const Sqlite3 = struct {
    /// The memory of the connection: sqlite3DbMalloc*() and
    /// sqlite3DbFree(), through `lookaside` (malloc.dbAllocator()).
    gpa: Allocator,
    lookaside: Lookaside = .{},
    /// The VFS of the connection's files, also used for ephemeral tables.
    vfs: ?@import("../vfs/vfs.zig").Vfs = null,
    /// The flags the connection was opened with (openFlags), which ATTACH
    /// starts from.
    open_flags: @import("main.zig").OpenFlags = .{},
    /// The databases: main, temp, then the attached ones (aDb, nDb). The
    /// names of attached databases are owned (from gpa).
    dbs: std.ArrayList(Db) = .empty,
    flags: DbFlag = .{
        .ShortColNames = true,
        .EnableTrigger = true,
        .EnableView = true,
        .CacheSpill = true,
        .TrustedSchema = true,
        .DqsDML = true,
        .DqsDDL = true,
        .AutoIndex = true,
        .Comments = true,
        .AttachCreate = true,
        .AttachWrite = true,
    },
    m_db_flags: DBFLAG = .{},
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
    /// The open SAVEPOINTs, innermost first (pSavepoint).
    savepoint: ?*Savepoint = null,
    /// The outermost savepoint started the transaction (a SAVEPOINT
    /// outside BEGIN): releasing it commits.
    is_transaction_savepoint: bool = false,
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
    /// Application-defined functions (aFunc), keyed by name; each entry
    /// heads a FuncDef.next list. Freed by callback.freeFunctions().
    funcs: NameMap(*FuncDef) = .empty,
    /// Collations defined on the connection (see coll.zig).
    colls: NameMap(*CollSeq) = .empty,
    /// PMAs the sorters of the connection wrote, for tests that check
    /// that a sort spilled (C has no such counter; tests only).
    n_pma_written: if (@import("builtin").is_test) u64 else void = if (@import("builtin").is_test) 0 else {},
    /// Page size for new databases, as set by PRAGMA page_size.
    next_pagesize: u32 = 0,
    /// Schema resets are deferred while this is nonzero.
    n_schema_lock: u32 = 0,
    /// PRAGMA temp_store: 0 default, 1 file, 2 memory.
    temp_store: u8 = 0,
    /// PRAGMA auto_vacuum for databases yet to be created, or -1.
    next_autovac: i8 = -1,
    /// PRAGMA busy_timeout, in milliseconds (busyTimeout).
    busy_timeout: i32 = 0,
    /// The busy handler (busyHandler).
    busy_handler: BusyHandler = .{},
    /// The WAL hook (xWalCallback and pWalArg).
    wal_callback: ?WalCallback = null,
    wal_arg: ?*anyopaque = null,
    /// PRAGMA analysis_limit.
    n_analysis_limit: i32 = 0,
    /// OP_SqlExec statements running (nSqlExec).
    n_sql_exec: i32 = 0,
    /// Registered virtual table modules (aModule).
    modules: NameMap(*Module) = .empty,
    /// Context of the virtual table constructor running (pVtabCtx).
    vtab_ctx: ?*@import("vtab.zig").VtabCtx = null,
    /// Virtual tables with an open transaction (aVTrans, nVTrans):
    /// `a_vtrans` holds room for a multiple of 5. It is null while xSync
    /// methods run (sqlite3VtabInSync()).
    a_vtrans: ?[]*VTable = null,
    n_vtrans: usize = 0,
    /// VTables to disconnect at the next opportunity (pDisconnect).
    disconnect: ?*VTable = null,
    /// The ON CONFLICT mode of the running xUpdate (vtabOnConflict).
    vtab_on_conflict: OE = .None,
    /// OP_VDestroy calls running (nVDestroy).
    n_vdestroy: i32 = 0,
    /// xqlite: the SQL dialect of the connection and the state of its
    /// semantic hooks (src/dialect/dialect.zig). No C counterpart.
    xq: @import("../dialect/dialect.zig").ConnState = .{},
    /// The commit, rollback and update hooks and the progress handler
    /// (xCommitCallback, xRollbackCallback, xUpdateCallback, xProgress,
    /// nProgressOps), set by the C ABI (sqlite3_commit_hook() ...).
    commit_hook: ?*const fn (arg: ?*anyopaque) i32 = null,
    commit_arg: ?*anyopaque = null,
    rollback_hook: ?*const fn (arg: ?*anyopaque) void = null,
    rollback_arg: ?*anyopaque = null,
    /// `op` is SQLITE_INSERT, SQLITE_UPDATE or SQLITE_DELETE.
    update_hook: ?*const fn (arg: ?*anyopaque, op: i32, db_name: [:0]const u8, table: [:0]const u8, rowid: i64) void = null,
    update_arg: ?*anyopaque = null,
    /// Nonzero from the handler interrupts the statement.
    progress: ?*const fn (arg: ?*anyopaque) i32 = null,
    progress_arg: ?*anyopaque = null,
    n_progress_ops: u32 = 0,
    /// xqlite: the state the C ABI (src/capi) keeps for a connection it
    /// opened (hooks, C callbacks, filenames); the engine never reads it.
    capi: ?*anyopaque = null,
    /// xqlite: carray() is found as an eponymous virtual table (what
    /// SQLITE_ENABLE_CARRAY compiles in; src/ext/carray.zig). The C ABI
    /// turns it on, as it has sqlite3_carray_bind().
    enable_carray: bool = false,

    pub fn limit(db: *const Sqlite3, l: Limit) i32 {
        return db.limits.get(l);
    }

    /// sqlite3OomFault(): record an allocation failure.
    pub fn oomFault(db: *Sqlite3) void {
        @import("malloc.zig").oomFault(db);
    }

    /// OptimizationDisabled().
    pub fn optDisabled(db: *const Sqlite3, mask: u32) bool {
        return db.db_opt_flags & mask != 0;
    }
};

const Btree = @import("../btree/btree.zig").Btree;

test "errorCode() and codeError() are inverse for every error" {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        const err = @field(anyerror, name);
        const rc = errorCode(err);
        try std.testing.expect(rc != RC.OK);
        try std.testing.expectEqual(@as(Error, err), codeError(rc));
        try std.testing.expectEqual(rc, resultCode(err, RC.OK));
    }
}

test "resultCode() keeps every extended code through its error" {
    // Every primary code, the non-error codes, and extended codes with
    // and without errors of their own.
    var codes: std.ArrayList(i32) = .empty;
    defer codes.deinit(std.testing.allocator);
    for (1..29) |p| try codes.append(std.testing.allocator, @intCast(p));
    inline for (comptime std.meta.declarations(RC)) |name| {
        try codes.append(std.testing.allocator, @field(RC, name));
    }
    for ([_]i32{
        RC.IOERR | (3 << 8), // IOERR_WRITE
        RC.IOERR | (12 << 8), // IOERR_NOMEM
        RC.CORRUPT | (1 << 8), // CORRUPT_VTAB
        RC.CANTOPEN | (1 << 8), // CANTOPEN_NOTEMPDIR
        RC.CONSTRAINT | (2 << 8), // CONSTRAINT_COMMITHOOK
        RC.CONSTRAINT | (4 << 8), // CONSTRAINT_FUNCTION
        RC.CONSTRAINT | (9 << 8), // CONSTRAINT_VTAB
        RC.NOTICE | (1 << 8), // NOTICE_RECOVER_WAL
        RC.WARNING | (1 << 8), // WARNING_AUTOINDEX
        RC.AUTH | (1 << 8), // AUTH_USER
        RC.OK | (1 << 8), // OK_LOAD_PERMANENTLY
        0x7f, // unknown
    }) |c| try codes.append(std.testing.allocator, c);
    for (codes.items) |rc| {
        if (rc == RC.OK) continue;
        const err = codeError(rc);
        // The code survives when it is recorded next to its error ...
        try std.testing.expectEqual(rc, resultCode(err, rc));
        // ... and the error alone gives the primary code (or the code
        // itself, if it has an error of its own), else SQLITE_ERROR.
        const alone = errorCode(err);
        try std.testing.expect(alone == rc or alone == rc & 0xff or alone == RC.ERROR);
    }
    try std.testing.expectEqual(error.Constraint, codeError(RC.CONSTRAINT_UNIQUE));
    try std.testing.expectEqual(error.BusySnapshot, codeError(RC.BUSY_SNAPSHOT));
    try std.testing.expectEqual(error.Busy, codeError(RC.BUSY | (3 << 8)));
    try std.testing.expectEqual(error.Error, codeError(RC.ROW));
    try std.testing.expectEqual(error.Error, codeError(RC.ERROR_MISSING_COLLSEQ));
    try std.testing.expectEqual(RC.ERROR_MISSING_COLLSEQ, resultCode(error.Error, RC.ERROR_MISSING_COLLSEQ));
    try std.testing.expectEqual(RC.ROW, resultCode(error.Error, RC.ROW));
    try std.testing.expectEqual(RC.CORRUPT_INDEX, resultCode(error.Corrupt, RC.CORRUPT_INDEX));
    try std.testing.expectEqual(RC.IOERR | (3 << 8), resultCode(error.IoErr, RC.IOERR | (3 << 8)));
    // A recorded code of another error is not taken.
    try std.testing.expectEqual(RC.BUSY, resultCode(error.Busy, RC.CONSTRAINT_UNIQUE));
    try std.testing.expectEqual(RC.BUSY, resultCode(error.Busy, RC.BUSY_SNAPSHOT));
    try std.testing.expectEqual(RC.IOERR_SHORT_READ, resultCode(error.ShortRead, RC.IOERR));
    try std.testing.expectEqual(RC.NOMEM, resultCode(error.OutOfMemory, RC.ERROR));
    try check(RC.OK);
    try std.testing.expectError(error.Constraint, check(RC.CONSTRAINT_FOREIGNKEY));
}
