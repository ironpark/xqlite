//! The syntax tree IR: the dialect-neutral statement tree a frontend
//! (src/dialect/*/) parses into, with the dialect's semantics already
//! resolved into explicit nodes. Two backends consume it:
//!
//!   lower.zig   tree -> SQLite's parse tree (the builders of ir.zig),
//!               for the statement being compiled;
//!   render.zig  tree -> SQLite SQL text, for what sqlite_schema keeps
//!               (CREATE TABLE/INDEX/VIEW, CHECK, DEFAULT, generated
//!               columns, view queries).
//!
//! The contract between them (README.md, "방언 아키텍처"): for every tree
//! `t` that render.zig accepts, the SQLite frontend compiling render(t)
//! means what lower(t) means, in the SQLite dialect and in the dialect of
//! the frontend that built `t`.
//!
//! What a frontend resolves before building the tree:
//!  - names: identifiers folded or not as the dialect does, schemas
//!    mapped to SQLite database names (QName.schema is `main`, `temp` or
//!    an attached database), strings decoded;
//!  - where the dialect's semantics differ from SQLite's, the explicit
//!    node: Cast (what the conversion does), Concat (NULLs), Div (real or
//!    integer division), Compare (collation), Like (case, escape), Coerce
//!    (MariaDB's storage conversion), Func (the function the name means:
//!    a SQLite built-in or engine function, or one of a dialect's table),
//!    IdentityDefault, the boolean literal, Param;
//!  - result column names (ResultCol.name), sort order of NULLs
//!    (SortItem.nulls), the defaults of the dialect's DDL (types, checks,
//!    identity columns).
//!
//! Allocation: every node and string lives in the arena of the statement
//! (Parse.arena) or in its SQL text, and is freed with the statement.
//! There are no globals; trees may share subtrees (lowering never
//! changes a tree). `pos`/`end` are byte offsets of the source text the
//! frontend hands to lower/render (Select.src overrides it for a subtree
//! parsed from other text), used for error offsets.

const std = @import("std");
const Dialect = @import("../dialect/dialect.zig").Dialect;

/// An identifier as the frontend resolved it, and where it was written.
pub const Name = struct {
    text: []const u8,
    pos: u32 = 0,
};

/// `[schema.]name`; `schema` is a SQLite database name (main, temp, an
/// attached database), null for SQLite's search order.
pub const QName = struct {
    schema: ?Name = null,
    name: Name,
};

/// Allocate `v` in `arena` (the statement's arena).
pub fn new(arena: std.mem.Allocator, comptime T: type, v: T) error{OutOfMemory}!*T {
    const x = try arena.create(T);
    x.* = v;
    return x;
}

/// An expression node at `pos` (allocated in `arena`).
pub fn expr(arena: std.mem.Allocator, pos: u32, end: u32, kind: Kind) error{OutOfMemory}!*Expr {
    return new(arena, Expr, .{ .pos = pos, .end = end, .kind = kind });
}

// =========================================================== expressions

pub const Expr = struct {
    pos: u32,
    end: u32,
    kind: Kind,
};

pub const Kind = union(enum) {
    /// a, t.a, db.t.a (1 to 3 names; with 3 the first is a database).
    column: []const Name,
    /// The digits of an integer literal (no sign; hexadecimal as 0x...).
    integer: []const u8,
    /// The text of a real literal, as SQLite reads it.
    float: []const u8,
    /// A string literal, decoded.
    string: []const u8,
    /// A blob literal, as (an even number of) hex digits.
    blob: []const u8,
    null,
    /// TRUE/FALSE (SQLite's 1/0).
    boolean: bool,
    /// A bound parameter: ?N, or `?` (the next number) for null.
    param: ?u32,
    /// DEFAULT as a value of INSERT VALUES or UPDATE SET (possibly inside
    /// the Coerce of that value): the column's default (lower.zig,
    /// "DML defaults"). An error anywhere else.
    default,
    unary: Unary,
    binary: Binary,
    div: Div,
    compare: Compare,
    concat: Concat,
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
    /// IS [NOT] TRUE/FALSE/UNKNOWN.
    is_bool: IsBool,
    /// A row value (2 or more items; one item is that item).
    row: []*Expr,
    collate: Collate,
    coerce: Coerce,
    identity_default: IdentityDefault,
};

pub const UnOp = enum { neg, plus, not, bit_not };

pub const Unary = struct { op: UnOp, e: *Expr };

/// Operators that mean the same in SQLite and every dialect that uses
/// them (`rem` is `%`, json_get/json_get_text are `->`/`->>`).
pub const BinOp = enum {
    add,
    sub,
    mul,
    rem,
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

/// Division: `sqlite` is SQLite's `/` (integer division of integers,
/// PostgreSQL's too), `real` divides as reals (MariaDB's `/`:
/// CAST(l AS REAL) / r), `int` is MariaDB's DIV (xq_div()).
pub const Div = struct {
    kind: enum { sqlite, real, int },
    l: *Expr,
    r: *Expr,
};

/// A comparison. `is`/`is_not` are IS / IS NOT (IS NOT DISTINCT FROM /
/// IS DISTINCT FROM). `collation`: the collation the comparison uses (a
/// SQLite collation name) whatever the operands', so that it does not
/// depend on the connection's default collation; null for SQLite's rules
/// (the operands', else the default).
pub const Compare = struct {
    op: CmpOp,
    l: *Expr,
    r: *Expr,
    collation: ?[]const u8 = null,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge, is, is_not };

/// String concatenation of `args` (2 or more): `propagate` is NULL if an
/// argument is (SQLite's and PostgreSQL's `||`, MariaDB's CONCAT()),
/// `skip` leaves NULLs out (SQLite's and PostgreSQL's concat()).
pub const Concat = struct {
    args: []*Expr,
    null_policy: enum { propagate, skip },
};

/// A conversion: `target_type` is the type as the frontend names it (for
/// messages), `mode` what the conversion does in SQLite's terms.
pub const Cast = struct {
    e: *Expr,
    target_type: []const u8 = "",
    mode: CastMode,
};

pub const CastMode = union(enum) {
    /// CAST(e AS type): SQLite's conversion to an affinity (INTEGER,
    /// REAL, TEXT, BLOB, NUMERIC).
    affinity: []const u8,
    /// f(e): a one-argument SQLite built-in (date, datetime, json ...) or
    /// engine function (xq_pg_bool ...).
    func: []const u8,
    /// substr(CAST(e AS TEXT), 1, n): text cut to `n` characters.
    truncate: i64,
    /// CAST(round(e, s) AS NUMERIC).
    round: i64,
    /// f(e, 'type'): an engine function taking the target type's
    /// spelling (MariaDB's xq_cast()).
    typed: struct { func: []const u8, type_arg: []const u8 },
};

pub const Case = struct {
    operand: ?*Expr,
    /// WHEN and THEN expressions in turn.
    whens: []*Expr,
    @"else": ?*Expr,
};

/// A function call. `name` is the function the frontend resolved: a
/// SQLite built-in, an engine function (xq_*, visible in every dialect),
/// an application function, or with `dialect` set, the function of that
/// name in the table of that dialect (dialect.Hooks.functions), which
/// lowering calls by its name in that dialect and render as
/// xq_<dialect>_<name> (dialect.qualifiedFunctionSearch()).
pub const Func = struct {
    name: Name,
    dialect: ?Dialect = null,
    args: []*Expr = &.{},
    /// f(*)
    star: bool = false,
    distinct: bool = false,
    order_by: []SortItem = &.{},
    filter: ?*Expr = null,
    over: ?*WindowSpec = null,
};

pub const InList = struct { e: *Expr, not: bool, items: []*Expr };
pub const InSelect = struct { e: *Expr, not: bool, sel: *Select };
pub const Between = struct { e: *Expr, not: bool, lo: *Expr, hi: *Expr };

/// `e [NOT] LIKE pat`. `case_sensitive`: case matters (PostgreSQL's
/// LIKE), else ASCII letters fold (SQLite's LIKE, ILIKE, MariaDB's).
pub const Like = struct {
    e: *Expr,
    pat: *Expr,
    not: bool = false,
    case_sensitive: bool,
    escape: Escape,
};

pub const Escape = union(enum) {
    /// No escape character (SQLite's LIKE without ESCAPE).
    none,
    /// `\` (PostgreSQL and MariaDB without ESCAPE).
    backslash,
    /// ESCAPE expr.
    expr: *Expr,
};

pub const IsNull = struct { e: *Expr, not: bool };
/// IS [NOT] TRUE/FALSE/UNKNOWN (`value` null).
pub const IsBool = struct { e: *Expr, value: ?bool, not: bool };
/// `e COLLATE collation`, a SQLite collation name.
pub const Collate = struct { e: *Expr, collation: []const u8 };

/// MariaDB's conversion of a value stored into a column (xq_coerce(),
/// src/dialect/mariadb/types.zig): `decl_type` the column's declared
/// type, `schema`/`table`/`column` for messages, `row` the row number of
/// the INSERT (for messages). The strictness (sql_mode) is read when the
/// statement runs; `ignore` is INSERT/UPDATE IGNORE.
pub const Coerce = struct {
    e: *Expr,
    decl_type: []const u8,
    schema: []const u8,
    table: []const u8,
    column: []const u8,
    ignore: bool = false,
    not_null: bool = false,
    /// The NULL of a NOT NULL column without a default that an INSERT
    /// leaves out.
    missing: bool = false,
    multi_row: bool = false,
    row: u32 = 1,
};

/// The next value of the identity sequence `sequence`: nextval('seq').
pub const IdentityDefault = struct { sequence: []const u8 };

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

/// An ORDER BY item. `nulls` default is SQLite's (NULLs first ascending,
/// last descending); a frontend whose default differs says first/last.
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
    pos: u32 = 0,
    /// The text the positions of this query (and what it contains) are
    /// offsets of, when it is not the statement's (a query a frontend
    /// substitutes, such as PostgreSQL's catalog views).
    src: ?[:0]const u8 = null,
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
    pos: u32 = 0,
};

pub const NamedWindow = struct { name: Name, spec: *WindowSpec };

pub const ResultCol = union(enum) {
    /// `*` at this offset.
    star: u32,
    /// t.* (the names before the star).
    table_star: struct { names: []const Name, star_pos: u32 },
    /// `alias` as written (AS x); else `name` is the name the frontend
    /// gives the column (PostgreSQL's "?column?" ...), null for SQLite's
    /// (a column's name, else the expression's text in SQLite).
    expr: struct { e: *Expr, alias: ?Name = null, name: ?[]const u8 = null },
};

/// How a FROM item joins the ones before it: `none` for the first item,
/// `comma` for `a, b`, `cross` for a CROSS JOIN that the planner may
/// reorder (PostgreSQL's), `straight` for an inner join kept in this
/// order (SQLite's CROSS JOIN, MariaDB's STRAIGHT_JOIN).
pub const JoinKind = enum { none, comma, inner, left, right, full, cross, straight };

pub const FromItem = struct {
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
    /// A table-valued function (json_each(), generate_series() ...).
    func: *Func,
    /// (a JOIN b ...)
    nested: []FromItem,
};

/// `AS name [(cols)]`: `cols` renames the columns of a subquery.
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
    /// EXPLAIN QUERY PLAN of a SELECT/INSERT/UPDATE/DELETE.
    explain: *Stmt,
};

/// What an INSERT does with a row that violates a constraint (OR
/// IGNORE/REPLACE ...); `default` is the constraint's own.
pub const OnError = enum { default, rollback, abort, fail, ignore, replace };

pub const Insert = struct {
    with: ?*With = null,
    table: QName,
    alias: ?Name = null,
    /// The columns assigned; empty for all (those an INSERT may assign).
    cols: []Name = &.{},
    /// VALUES or a query; null for DEFAULT VALUES.
    source: ?*Select,
    on_error: OnError = .default,
    /// OVERRIDING SYSTEM VALUE: values for GENERATED ALWAYS identity
    /// columns are allowed.
    overriding: bool = false,
    on_conflict: ?*OnConflict = null,
    returning: []ResultCol = &.{},
    pos: u32 = 0,
};

/// ON CONFLICT [(target) [WHERE]] DO NOTHING | DO UPDATE SET ... [WHERE].
pub const OnConflict = struct {
    target: []*Expr = &.{},
    target_where: ?*Expr = null,
    /// DO UPDATE (null for DO NOTHING).
    update: ?[]SetItem = null,
    where: ?*Expr = null,
};

/// `col = expr` (cols.len 1, not multi) or `(a, b) = expr`.
pub const SetItem = struct {
    cols: []Name,
    multi: bool = false,
    value: *Expr,
};

pub const Update = struct {
    with: ?*With = null,
    table: QName,
    alias: ?Name = null,
    on_error: OnError = .default,
    sets: []SetItem,
    from: []FromItem = &.{},
    where: ?*Expr = null,
    /// ORDER BY ... LIMIT n: only the first n rows in that order (an
    /// ORDER BY without a LIMIT changes nothing).
    order_by: []SortItem = &.{},
    limit: ?*Expr = null,
    returning: []ResultCol = &.{},
    pos: u32 = 0,
};

pub const Delete = struct {
    with: ?*With = null,
    table: QName,
    alias: ?Name = null,
    /// DELETE ... USING: other tables the WHERE joins.
    using: []FromItem = &.{},
    where: ?*Expr = null,
    /// As in Update.
    order_by: []SortItem = &.{},
    limit: ?*Expr = null,
    returning: []ResultCol = &.{},
    pos: u32 = 0,
};

pub const Truncate = struct {
    table: QName,
    /// RESTART IDENTITY: the identity sequences of the table start over.
    restart_identity: bool = false,
};

// =================================================================== DDL

pub const CreateTable = struct {
    temp: bool = false,
    if_not_exists: bool = false,
    /// The table; `name.schema` main (or an attached database) is written
    /// in the text, temp tables are CREATE TEMP TABLE "name".
    name: QName,
    columns: []ColumnDef = &.{},
    constraints: []TableConstraint = &.{},
    as_select: ?*Select = null,
    strict: bool = false,
    without_rowid: bool = false,
};

pub const ColumnDef = struct {
    name: Name,
    /// The type in the SQLite text (the STRICT storage type: INTEGER,
    /// REAL, TEXT, BLOB, ANY), null for none.
    type: ?[]const u8 = null,
    /// The declared type as the dialect spells it, recorded in the
    /// catalog (catalog.Key.decl_type); null records none.
    decl_type: ?[]const u8 = null,
    /// In the order they are rendered.
    constraints: []ColConstraint = &.{},
};

pub const ColConstraint = struct {
    /// CONSTRAINT name (a CHECK's name is its message: "CHECK constraint
    /// failed: name").
    name: ?[]const u8 = null,
    kind: union(enum) {
        not_null,
        /// NULL (allowed: nothing is rendered).
        null,
        check: *Expr,
        default: *Expr,
        primary_key: struct { desc: bool = false, autoincrement: bool = false },
        unique,
        references: Ref,
        generated: struct { e: *Expr, stored: bool },
        collate: []const u8,
        /// A column numbered by sequence `sequence` (lower.zig, "Identity
        /// columns"): NOT NULL DEFAULT (nextval('seq')), the sequence
        /// created with the table and dropped with it.
        identity: Identity,
    },
};

pub const Identity = struct {
    sequence: []const u8,
    /// GENERATED ALWAYS (an INSERT may not give a value, without
    /// OVERRIDING SYSTEM VALUE) or BY DEFAULT; null for neither (SERIAL),
    /// which records no identity_kind.
    always: ?bool = null,
    opts: SeqOpts = .{},
};

pub const TableConstraint = struct {
    name: ?[]const u8 = null,
    kind: union(enum) {
        check: *Expr,
        unique: []Name,
        primary_key: []Name,
        foreign_key: struct { cols: []Name, ref: Ref },
    },
};

pub const RefAction = enum { none, restrict, cascade, set_null, set_default };

pub const Ref = struct {
    table: Name,
    cols: []Name = &.{},
    on_delete: RefAction = .none,
    on_update: RefAction = .none,
    deferred: bool = false,
};

pub const IndexItem = struct {
    expr: *Expr,
    collate: ?[]const u8 = null,
    desc: bool = false,
};

pub const CreateIndex = struct {
    unique: bool = false,
    if_not_exists: bool = false,
    /// The index; `name.schema` is its database (written in the text).
    name: QName,
    table: Name,
    items: []IndexItem,
    where: ?*Expr = null,
};

pub const CreateView = struct {
    or_replace: bool = false,
    temp: bool = false,
    if_not_exists: bool = false,
    /// The view; a database is always written in the text (main if
    /// null), but for a temp view.
    name: QName,
    cols: []Name = &.{},
    select: *Select,
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

/// ALTER TABLE with one action. IF EXISTS (of the table, of a dropped
/// column) and IF NOT EXISTS (of an added column) make the statement do
/// nothing.
pub const AlterTable = struct {
    if_exists: bool = false,
    name: QName,
    action: union(enum) {
        rename_to: Name,
        rename_column: struct { old: Name, new: Name },
        add_column: struct { if_not_exists: bool = false, def: ColumnDef },
        drop_column: struct { if_exists: bool = false, name: Name },
    },
};

pub const ObjectKind = enum { table, view, index, sequence };

/// DROP of one object.
pub const Drop = struct {
    kind: ObjectKind,
    if_exists: bool = false,
    name: QName,
};

test "tree nodes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try expr(a, 0, 1, .{ .integer = "1" });
    const two = try expr(a, 4, 5, .{ .integer = "2" });
    const sum = try expr(a, 0, 5, .{ .binary = .{ .op = .add, .l = one, .r = two } });
    try std.testing.expectEqual(BinOp.add, sum.kind.binary.op);
}
