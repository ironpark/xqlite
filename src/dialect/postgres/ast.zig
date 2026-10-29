//! The syntax tree of the PostgreSQL dialect: what parser.zig reads, and
//! what lower.zig lowers into the common IR (queries and DML) and
//! render.zig prints as SQLite text (DDL, whose text the schema keeps).
//! Everything lives in the arena of the statement (Parse.arena).
//!
//! Names are already folded (unquoted identifiers to lower case) and
//! strings decoded; `pos`/`end` are byte offsets in the statement text.

const std = @import("std");

pub const Name = struct {
    text: []const u8,
    pos: u32,
};

/// `[schema.]name`.
pub const QName = struct {
    schema: ?Name = null,
    name: Name,
};

// =========================================================== expressions

pub const Expr = struct {
    pos: u32,
    end: u32,
    kind: Kind,
};

pub const Kind = union(enum) {
    /// a, t.a, s.t.a (1 to 3 names).
    column: []const Name,
    integer: []const u8,
    float: []const u8,
    string: []const u8,
    /// A bytea constant ('\x0102'::bytea), as hex digits.
    blob: []const u8,
    null,
    boolean: bool,
    /// $n
    param: u32,
    /// DEFAULT in a VALUES row or an UPDATE SET.
    default,
    unary: Unary,
    binary: Binary,
    cast: Cast,
    func: *Func,
    case: Case,
    in_list: InList,
    in_select: InSelect,
    exists: *Select,
    subquery: *Select,
    between: Between,
    like: Like,
    is_null: IsNull,
    is_distinct: IsDistinct,
    is_bool: IsBool,
    row: []*Expr,
    collate: Collate,
};

pub const UnOp = enum { neg, plus, not, bit_not };

pub const Unary = struct { op: UnOp, e: *Expr };

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    concat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
    bit_and,
    bit_or,
    shl,
    shr,
    json_get,
    json_get_text,
};

pub const Binary = struct { op: BinOp, l: *Expr, r: *Expr };

pub const Cast = struct { e: *Expr, ty: TypeName };

pub const Case = struct {
    operand: ?*Expr,
    /// WHEN and THEN expressions in turn.
    whens: []*Expr,
    @"else": ?*Expr,
};

pub const InList = struct { e: *Expr, not: bool, items: []*Expr };
pub const InSelect = struct { e: *Expr, not: bool, sel: *Select };
pub const Between = struct { e: *Expr, not: bool, lo: *Expr, hi: *Expr };
pub const Like = struct { e: *Expr, not: bool, pat: *Expr, escape: ?*Expr, ilike: bool };
pub const IsNull = struct { e: *Expr, not: bool };
pub const IsDistinct = struct { l: *Expr, r: *Expr, not: bool };
/// IS [NOT] TRUE/FALSE/UNKNOWN (`value` null).
pub const IsBool = struct { e: *Expr, value: ?bool, not: bool };
pub const Collate = struct { e: *Expr, name: Name };

/// A function call; `name` is folded and without a pg_catalog prefix.
pub const Func = struct {
    name: Name,
    args: []*Expr = &.{},
    /// f(*)
    star: bool = false,
    distinct: bool = false,
    order_by: []SortItem = &.{},
    filter: ?*Expr = null,
    over: ?*WindowSpec = null,
    /// A call that is not in the text (a rewrite of the parser).
    synthetic: bool = false,
    /// The name of the column of a call written with a special syntax
    /// (substring(x FROM a) is "substring", not "substr").
    label: ?[]const u8 = null,
};

pub const WindowSpec = struct {
    /// OVER name, or the base window of a specification.
    base: ?Name = null,
    /// Only a name (OVER w), not a specification.
    name_only: bool = false,
    partition: []*Expr = &.{},
    order_by: []SortItem = &.{},
    frame: ?Frame = null,
};

pub const Frame = struct {
    unit: enum { rows, range, groups },
    start: Bound,
    end: ?Bound,
    exclude: enum { none, no_others, current_row, group, ties } = .none,
};

pub const Bound = struct {
    kind: enum { unbounded_preceding, preceding, current_row, following, unbounded_following },
    expr: ?*Expr = null,
};

/// A type as PostgreSQL names it: `name` is the canonical spelling
/// ("integer", "character varying", "timestamp with time zone" ...),
/// `mods` the modifiers in parentheses.
pub const TypeName = struct {
    name: []const u8,
    mods: []const i64 = &.{},
    array: bool = false,
    pos: u32,
};

pub const SortItem = struct {
    expr: *Expr,
    dir: enum { default, asc, desc } = .default,
    nulls: enum { default, first, last } = .default,
};

// ================================================================ SELECT

pub const Select = struct {
    with: ?*With = null,
    body: *Body,
    order_by: []SortItem = &.{},
    limit: ?*Expr = null,
    offset: ?*Expr = null,
    pos: u32,
};

pub const With = struct {
    recursive: bool,
    ctes: []Cte,
};

pub const Cte = struct {
    name: Name,
    cols: []Name = &.{},
    materialized: ?bool = null,
    select: *Select,
};

pub const Body = union(enum) {
    core: *Core,
    values: [][]*Expr,
    compound: Compound,
    /// A parenthesized query, with its own ORDER BY/LIMIT/WITH.
    nested: *Select,
};

pub const SetOp = enum { @"union", intersect, except };

pub const Compound = struct {
    op: SetOp,
    all: bool,
    left: *Body,
    right: *Body,
};

pub const Core = struct {
    distinct: bool = false,
    cols: []ResultCol,
    from: []FromItem = &.{},
    where: ?*Expr = null,
    group_by: []*Expr = &.{},
    having: ?*Expr = null,
    windows: []NamedWindow = &.{},
    pos: u32,
};

pub const NamedWindow = struct { name: Name, spec: *WindowSpec };

pub const ResultCol = union(enum) {
    /// `*` at this offset.
    star: u32,
    /// t.* (the names before the star).
    table_star: struct { names: []const Name, star_pos: u32 },
    expr: struct { e: *Expr, alias: ?Name },
};

pub const JoinKind = enum { none, comma, inner, left, right, full, cross };

pub const FromItem = struct {
    /// How the item joins the ones before it (none for the first).
    join: JoinKind = .none,
    natural: bool = false,
    source: Source,
    alias: ?Alias = null,
    on: ?*Expr = null,
    using: []Name = &.{},
};

pub const Source = union(enum) {
    table: QName,
    subquery: *Select,
    func: *Func,
    /// (a JOIN b ...)
    nested: []FromItem,
};

pub const Alias = struct {
    name: Name,
    cols: []Name = &.{},
};

// ============================================================ statements

pub const Stmt = union(enum) {
    select: *Select,
    insert: *Insert,
    update: *Update,
    delete: *Delete,
    begin,
    commit,
    rollback,
    savepoint: Name,
    release: Name,
    rollback_to: Name,
    create_table: *CreateTable,
    create_index: *CreateIndex,
    create_view: *CreateView,
    create_sequence: *CreateSequence,
    alter_table: *AlterTable,
    drop: *Drop,
    truncate: *Truncate,
    explain: *Stmt,
};

pub const Insert = struct {
    with: ?*With = null,
    table: QName,
    alias: ?Name = null,
    cols: []Name = &.{},
    /// null for DEFAULT VALUES.
    source: ?*Select,
    overriding: bool = false,
    on_conflict: ?*OnConflict = null,
    returning: []ResultCol = &.{},
    pos: u32,
};

pub const OnConflict = struct {
    target: []SortItem = &.{},
    target_where: ?*Expr = null,
    /// DO UPDATE (null for DO NOTHING).
    update: ?[]SetItem = null,
    where: ?*Expr = null,
};

/// `col = expr` (cols.len 1, not multi) or `(a, b) = expr`.
pub const SetItem = struct {
    cols: []Name,
    multi: bool,
    value: *Expr,
};

pub const Update = struct {
    with: ?*With = null,
    table: QName,
    alias: ?Name = null,
    sets: []SetItem,
    from: []FromItem = &.{},
    where: ?*Expr = null,
    returning: []ResultCol = &.{},
    pos: u32,
};

pub const Delete = struct {
    with: ?*With = null,
    table: QName,
    alias: ?Name = null,
    using: []FromItem = &.{},
    where: ?*Expr = null,
    returning: []ResultCol = &.{},
    pos: u32,
};

pub const CreateTable = struct {
    temp: bool = false,
    if_not_exists: bool = false,
    name: QName,
    columns: []ColumnDef = &.{},
    constraints: []TableConstraint = &.{},
    as_select: ?*Select = null,
};

pub const ColumnDef = struct {
    name: Name,
    ty: TypeName,
    collate: ?Name = null,
    constraints: []ColConstraint = &.{},
};

pub const ColConstraint = struct {
    name: ?Name = null,
    kind: union(enum) {
        not_null,
        null,
        check: *Expr,
        default: *Expr,
        primary_key,
        unique,
        references: Ref,
        identity: Identity,
        /// GENERATED ALWAYS AS (expr) STORED
        generated: *Expr,
    },
};

pub const Identity = struct {
    always: bool,
    opts: SeqOpts = .{},
};

pub const TableConstraint = struct {
    name: ?Name = null,
    kind: union(enum) {
        check: *Expr,
        unique: []Name,
        primary_key: []Name,
        foreign_key: struct { cols: []Name, ref: Ref },
    },
};

pub const RefAction = enum { none, restrict, cascade, set_null, set_default };

pub const Ref = struct {
    table: QName,
    cols: []Name = &.{},
    on_delete: RefAction = .none,
    on_update: RefAction = .none,
    deferred: bool = false,
};

pub const IndexItem = struct {
    expr: *Expr,
    collate: ?Name = null,
    desc: bool = false,
};

pub const CreateIndex = struct {
    unique: bool = false,
    if_not_exists: bool = false,
    name: ?Name = null,
    table: QName,
    items: []IndexItem,
    where: ?*Expr = null,
};

pub const CreateView = struct {
    or_replace: bool = false,
    temp: bool = false,
    name: QName,
    cols: []Name = &.{},
    select: *Select,
    /// The text of the query.
    text_start: u32,
    text_end: u32,
};

pub const SeqOpts = struct {
    start: ?i64 = null,
    increment: ?i64 = null,
    min: ?i64 = null,
    max: ?i64 = null,
    cycle: ?bool = null,
};

pub const CreateSequence = struct {
    if_not_exists: bool = false,
    name: QName,
    opts: SeqOpts = .{},
};

pub const AlterTable = struct {
    if_exists: bool = false,
    name: QName,
    action: union(enum) {
        rename_to: Name,
        rename_column: struct { old: Name, new: Name },
        add_column: struct { if_not_exists: bool, def: ColumnDef },
        drop_column: struct { if_exists: bool, name: Name },
    },
};

pub const ObjectKind = enum { table, view, index, sequence };

pub const Drop = struct {
    kind: ObjectKind,
    if_exists: bool = false,
    names: []QName,
    cascade: bool = false,
};

pub const Truncate = struct {
    tables: []QName,
    restart_identity: bool = false,
};

// ================================================================ naming

/// The name PostgreSQL gives a result column without an alias
/// (FigureColname()): the column, the function, the type of a cast of
/// a constant, "case", "exists" ..., or "?column?". Null for a column
/// reference, which SQLite names after the column itself.
pub fn columnName(e: *const Expr) ?[]const u8 {
    return switch (e.kind) {
        .column => null,
        .func => |f| f.label orelse f.name.text,
        .cast => |c| if (strongName(c.e)) |n| n else @import("types.zig").internalName(c.ty.name),
        .collate => |c| columnName(c.e) orelse null,
        .case => "case",
        .exists => "exists",
        .row => "row",
        .boolean => "bool",
        .subquery => |s| subqueryName(s),
        else => "?column?",
    };
}

/// A name a cast keeps (FigureColname()'s strength 2): of a column, a
/// call, EXISTS, ROW, a scalar subquery.
fn strongName(e: *const Expr) ?[]const u8 {
    return switch (e.kind) {
        .column => |names| names[names.len - 1].text,
        .func => |f| f.label orelse f.name.text,
        .cast => |c| strongName(c.e),
        .collate => |c| strongName(c.e),
        .exists => "exists",
        .row => "row",
        .subquery => |s| subqueryName(s),
        else => null,
    };
}

fn subqueryName(s: *const Select) []const u8 {
    if (s.body.* == .core) {
        const cols = s.body.core.cols;
        if (cols.len >= 1) switch (cols[0]) {
            .expr => |x| {
                if (x.alias) |a| return a.text;
                return strongName(x.e) orelse "?column?";
            },
            else => {},
        };
    }
    return "?column?";
}
