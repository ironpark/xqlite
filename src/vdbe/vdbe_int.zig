//! Core types of the virtual machine (vdbe.h and vdbeInt.h): memory cells,
//! cursors, instructions and the Vdbe itself.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const btree = @import("xqlite_storage").btree;
pub const opcodes = @import("opcodes.zig");
const flags = @import("../util/flags.zig");

pub const OP = opcodes.OP;
pub const Sqlite3 = int.Sqlite3;
pub const Parse = int.Parse;
pub const FuncDef = int.FuncDef;
pub const CollSeq = int.CollSeq;
pub const Table = int.Table;
pub const Index = int.Index;
pub const Pgno = int.Pgno;
pub const Allocator = std.mem.Allocator;

/// Text encodings (SQLITE_UTF8 etc.).
pub const ENC = struct {
    pub const UTF8: u8 = 1;
    pub const UTF16LE: u8 = 2;
    pub const UTF16BE: u8 = 3;
    pub const UTF16: u8 = 4;
    pub const ANY: u8 = 5;
    pub const UTF16_ALIGNED: u8 = 8;
};

/// Fundamental datatypes (SQLITE_INTEGER etc.).
pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;

// ================================================================ memory

/// Mem.flags (MEM_*). The VM tests these in its inner loop: a test of one
/// flag is a field, of several (C: `(flags & (MEM_Int|MEM_Real))!=0`)
/// intersects() with a literal mask, both one AND of the u16 as in C.
pub const MEM = packed struct(u16) {
    Null: bool = false,
    Str: bool = false,
    Int: bool = false,
    Real: bool = false,
    Blob: bool = false,
    /// An integer that renders as a real (e.g. 1.0 stored as 1).
    IntReal: bool = false,
    FromBind: bool = false,
    /// Free in C.
    _7: u1 = 0,
    /// NULL set by OP_Null rather than read from data.
    Cleared: bool = false,
    /// Mem.z is NUL-terminated.
    Term: bool = false,
    /// Mem.u.n_zero zero bytes follow the blob.
    Zero: bool = false,
    Subtype: bool = false,
    /// Mem.x_del must be called on Mem.z.
    Dyn: bool = false,
    /// Mem.z points to a static string.
    Static: bool = false,
    /// Mem.z points to an ephemeral string (owned by someone else).
    Ephem: bool = false,
    /// Mem.z points to an aggregate function context.
    Agg: bool = false,

    /// A cell that holds no value (released, or never set).
    pub const Undefined: MEM = .{};

    /// The bits giving the datatype, the first six.
    pub const AffMask: MEM = .{ .Null = true, .Str = true, .Int = true, .Real = true, .Blob = true, .IntReal = true };

    /// The datatype and what qualifies it: AffMask, Cleared, Zero and
    /// Subtype (and the free bit 0x80, as in C).
    pub const TypeMask: MEM = .fromInt(0x0dbf);

    /// The datatype bits as a number, to index a table by them (C:
    /// `flags & MEM_AffMask`).
    pub inline fn affIndex(f: MEM) u6 {
        return @truncate(f.int());
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
        flags.checkBits(MEM, .{
            .Null = 0x0001,
            .Str = 0x0002,
            .Int = 0x0004,
            .Real = 0x0008,
            .Blob = 0x0010,
            .IntReal = 0x0020,
            .FromBind = 0x0040,
            .Cleared = 0x0100,
            .Term = 0x0200,
            .Zero = 0x0400,
            .Subtype = 0x0800,
            .Dyn = 0x1000,
            .Static = 0x2000,
            .Ephem = 0x4000,
            .Agg = 0x8000,
        });
    }
};

/// How a string or blob handed to a Mem is managed (the xDel argument).
pub const Destructor = union(enum) {
    /// Lives as long as the Mem may (SQLITE_STATIC).
    static,
    /// Must be copied (SQLITE_TRANSIENT).
    transient,
    /// Allocated with the connection's allocator (or sqlite3_malloc());
    /// the Mem takes over the whole allocation as its buffer, whatever
    /// the length of the string (SQLITE_DYNAMIC: szMalloc is
    /// sqlite3DbMallocSize()).
    dynamic,
    /// Freed by calling this, e.g. malloc.free (sqlite3_free), which
    /// needs only the pointer, or int.destructor(f) of a typed `f`.
    func: int.DestructorFn,
};

pub const MemValue = extern union {
    r: f64,
    i: i64,
    /// Zero bytes after a MEM_Zero blob.
    n_zero: i32,
    /// Pointer type of a MEM_Null|MEM_Term|MEM_Subtype pointer value.
    z_ptype: [*:0]const u8,
    /// The function of a MEM_Agg cell.
    def: *const FuncDef,
};

/// A value: a register of the VM, a function argument or result
/// (sqlite3_value).
pub const Mem = struct {
    u: MemValue = .{ .i = 0 },
    /// String or blob value.
    z: ?[*]u8 = null,
    /// Bytes in the string or blob, excluding any terminator.
    n: i32 = 0,
    flags: MEM = .{ .Null = true },
    enc: u8 = 0,
    e_subtype: u8 = 0,
    // A shallow copy (MEMCELLSIZE) copies only the fields above.
    db: ?*Sqlite3 = null,
    /// Buffer owned by this Mem; Mem.z may point into it.
    z_malloc: []u8 = &.{},
    /// Serial type, while OP_MakeRecord runs.
    u_temp: u32 = 0,
    /// Destructor of Mem.z with MEM_Dyn.
    x_del: ?int.DestructorFn = null,

    pub fn init(db: ?*Sqlite3, f: MEM) Mem {
        return .{ .db = db, .flags = f };
    }

    pub fn szMalloc(m: *const Mem) usize {
        return m.z_malloc.len;
    }

    /// VdbeMemDynamic().
    pub fn isDynamic(m: *const Mem) bool {
        return m.flags.intersects(.{ .Agg = true, .Dyn = true });
    }

    /// The string or blob bytes.
    pub fn bytes(m: *const Mem) []u8 {
        if (m.z) |z| return z[0..@intCast(m.n)];
        return &.{};
    }

    /// MemSetTypeFlag().
    pub fn setTypeFlag(m: *Mem, f: MEM) void {
        m.flags = m.flags.without(MEM.TypeMask.with(.{ .Zero = true })).with(f);
    }

    /// MemNullNochng(): a NULL standing for an unchanged column.
    pub fn isNullNochng(m: *const Mem) bool {
        return m.flags.only(MEM.TypeMask) == MEM{ .Null = true, .Zero = true } and m.n == 0 and m.u.n_zero == 0;
    }
};

// ================================================================ keys

/// Comparison information for index keys and sorters (KeyInfo).
pub const KeyInfo = struct {
    n_ref: u32 = 1,
    enc: u8 = ENC.UTF8,
    /// Key columns.
    n_key_field: u16,
    /// Key columns plus the rest (e.g. the rowid).
    n_all_field: u16,
    db: ?*Sqlite3,
    /// KEYINFO_ORDER_* flags of each field.
    sort_flags: []u8,
    /// Collation of each field; null means BINARY.
    coll: []?*const CollSeq,
};

/// A record parsed into fields, for comparisons (UnpackedRecord).
pub const UnpackedRecord = struct {
    key_info: *KeyInfo,
    mem: [*]Mem,
    /// Cache of mem[0] for the specialized comparators.
    u: extern union { z: ?[*]u8, i: i64 } = .{ .i = 0 },
    n: i32 = 0,
    n_field: u16,
    /// Result when the keys are equal.
    default_rc: i8 = 0,
    /// Corruption (or OOM) detected while comparing (C: errCode).
    err: ?error{ Corrupt, OutOfMemory } = null,
    /// Results for lhs < rhs and lhs > rhs (inverted for DESC b-trees).
    r1: i8 = -1,
    r2: i8 = 1,
    /// An equal comparison was seen.
    eq_seen: bool = false,
};

// =========================================================== instructions

/// One instruction (VdbeOp). As in C built without
/// SQLITE_ENABLE_EXPLAIN_COMMENTS, it is 24 bytes: the P4 type fits in
/// the padding before p5, and P4 is a single word.
pub const Op = struct {
    opcode: OP,
    /// Which field of `p4` is valid (p4type).
    p4type: P4Type = .notused,
    p5: u16 = 0,
    p1: i32 = 0,
    p2: i32 = 0,
    p3: i32 = 0,
    p4: P4Union = .{ .p = null },

    /// Store `p4` as the fourth operand, replacing any (without freeing
    /// it: see aux.changeP4()).
    pub fn setP4(op: *Op, p4: P4) void {
        op.p4type = p4;
        op.p4 = switch (p4) {
            .notused => .{ .p = null },
            .z => |z| .{ .z = z.ptr },
            .dynamic => |z| .{ .dynamic = z.ptr },
            .int32 => |i| .{ .int32 = i },
            .collseq => |x| .{ .collseq = x },
            .funcdef => |x| .{ .funcdef = x },
            .keyinfo => |x| .{ .keyinfo = x },
            .mem => |x| .{ .mem = x },
            .intarray => |a| blk: {
                std.debug.assert(a.len > a[0]);
                break :blk .{ .intarray = a.ptr };
            },
            .funcctx => |x| .{ .funcctx = x },
            .subprogram => |x| .{ .subprogram = x },
            .table => |x| .{ .table = x },
            .tableref => |x| .{ .tableref = x },
            .index => |x| .{ .index = x },
            .subrtnsig => |x| .{ .subrtnsig = x },
            .vtab => |x| .{ .vtab = x },
        };
    }

    /// The fourth operand with its type, strings and arrays as slices:
    /// for code where the cost of the lengths does not matter.
    pub fn getP4(op: *const Op) P4 {
        return switch (op.p4type) {
            .notused => .notused,
            .z => .{ .z = std.mem.span(op.p4.z) },
            .dynamic => .{ .dynamic = std.mem.span(op.p4.dynamic) },
            .int32 => .{ .int32 = op.p4.int32 },
            .collseq => .{ .collseq = op.p4.collseq },
            .funcdef => .{ .funcdef = op.p4.funcdef },
            .keyinfo => .{ .keyinfo = op.p4.keyinfo },
            .mem => .{ .mem = op.p4.mem },
            .intarray => .{ .intarray = op.p4.intarray[0 .. op.p4.intarray[0] + 1] },
            .funcctx => .{ .funcctx = op.p4.funcctx },
            .subprogram => .{ .subprogram = op.p4.subprogram },
            .table => .{ .table = op.p4.table },
            .tableref => .{ .tableref = op.p4.tableref },
            .index => .{ .index = op.p4.index },
            .subrtnsig => .{ .subrtnsig = op.p4.subrtnsig },
            .vtab => .{ .vtab = op.p4.vtab },
        };
    }
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(Op) == 24);
}

/// The type of the fourth operand (P4_*).
pub const P4Type = enum(u8) {
    notused,
    z,
    dynamic,
    int32,
    collseq,
    funcdef,
    keyinfo,
    mem,
    intarray,
    funcctx,
    subprogram,
    table,
    tableref,
    index,
    subrtnsig,
    vtab,
};

/// The fourth operand as an instruction holds it (the p4 union of
/// VdbeOp): one word, read as the field Op.p4type names. Memory behind
/// the pointers belongs to the Vdbe (its arena), not the instruction,
/// except for `dynamic`.
pub const P4Union = extern union {
    p: ?*anyopaque,
    /// A NUL-terminated string (P4_STATIC, P4_DYNAMIC in the arena).
    z: [*:0]const u8,
    /// A NUL-terminated string from db.gpa that the Vdbe frees: P4_DYNAMIC
    /// memory handed over by a module (the idxStr of OP_VFilter).
    dynamic: [*:0]u8,
    int32: i32,
    collseq: *const CollSeq,
    funcdef: *const FuncDef,
    keyinfo: *KeyInfo,
    mem: *Mem,
    /// The first element is the count of those that follow
    /// (P4_INTARRAY).
    intarray: [*]u32,
    funcctx: *Context,
    subprogram: *SubProgram,
    table: *Table,
    tableref: *Table,
    index: *Index,
    subrtnsig: *SubrtnSig,
    /// A virtual table, locked while the program refers to it (P4_VTAB).
    vtab: *int.VTable,
};

/// The fourth operand as the instruction builders take it: a P4 type
/// with its value, strings and arrays as slices (see Op.setP4()).
pub const P4 = union(P4Type) {
    notused,
    z: [:0]const u8,
    dynamic: [:0]u8,
    int32: i32,
    collseq: *const CollSeq,
    funcdef: *const FuncDef,
    keyinfo: *KeyInfo,
    mem: *Mem,
    /// The first element is the count of those that follow.
    intarray: []u32,
    funcctx: *Context,
    subprogram: *SubProgram,
    table: *Table,
    tableref: *Table,
    index: *Index,
    subrtnsig: *SubrtnSig,
    vtab: *int.VTable,
};

/// SubrtnSig: a reusable IN subroutine.
pub const SubrtnSig = struct {
    sel_id: i32,
    complete: bool = false,
    aff: ?[:0]const u8 = null,
    i_table: i32 = 0,
    i_addr: i32 = 0,
    reg_return: i32 = 0,
};

/// A compiled trigger program (SubProgram).
pub const SubProgram = struct {
    ops: []Op,
    n_mem: i32,
    n_csr: i32,
    once: []u8,
    token: ?*anyopaque,
    next: ?*SubProgram = null,
    /// The memory of the program's instructions and their operands
    /// (the arena of the Vdbe it was coded in).
    mem: ?std.heap.ArenaAllocator = null,
};

/// P5 values for OP_Halt with constraint errors.
pub const P5_ConstraintNotNull: u16 = 1;
pub const P5_ConstraintUnique: u16 = 2;
pub const P5_ConstraintCheck: u16 = 3;
pub const P5_ConstraintFK: u16 = 4;

/// Column name slots (COLNAME_*).
pub const COLNAME_NAME = 0;
pub const COLNAME_DECLTYPE = 1;
pub const COLNAME_DATABASE = 2;
pub const COLNAME_TABLE = 3;
pub const COLNAME_COLUMN = 4;
/// Slots in Vdbe.col_names (the default build's COLNAME_N); the origin
/// slots are in Vdbe.col_meta.
pub const COLNAME_N = 2;

// =============================================================== cursors

pub const CurType = enum(u8) { btree = 0, sorter = 1, vtab = 2, pseudo = 3 };

/// A cursor of the VM (VdbeCursor).
pub const VdbeCursor = struct {
    e_cur_type: CurType,
    i_db: i8,
    /// On a row with no data (e.g. the NULL row of a LEFT JOIN).
    null_row: bool = false,
    /// A seek to `moveto_target` is pending.
    deferred_moveto: bool = false,
    /// A rowid table rather than an index.
    is_table: bool = false,
    is_ephemeral: bool = false,
    use_random_rowid: bool = false,
    is_ordered: bool = false,
    no_reuse: bool = false,
    seek_hit: u16 = 0,
    /// The separate b-tree of an ephemeral table, shared with OP_OpenDup
    /// cursors. It closes itself with its last cursor (BTREE_SINGLE).
    btx: ?*btree.Btree = null,
    /// Opened with OPFLAG_SEEKEQ (BTREE_SEEK_EQ): only equality seeks.
    seek_eq: bool = false,
    /// Table to index column mapping (aAltMap): a P4_INTARRAY, whose
    /// first element is the count.
    alt_map: ?[*]u32 = null,
    seq_count: i64 = 0,
    /// Column cache valid while equal to Vdbe.cache_ctr.
    cache_status: u32 = cache_stale,
    /// Result of the last seek; for pseudo cursors, the register of the
    /// record.
    seek_result: i32 = 0,
    alt_cursor: ?*VdbeCursor = null,
    uc: union(enum) { none, cursor: *btree.Cursor, sorter: *@import("sorter.zig").Sorter, pseudo, vtab: *@import("../sql/vtab.zig").VtabCursor } = .none,
    key_info: ?*KeyInfo = null,
    /// Offset of the next unparsed byte of the record header.
    i_hdr_offset: u32 = 0,
    pgno_root: Pgno = 0,
    n_field: i16,
    /// Header fields parsed so far.
    n_hdr_parsed: u16 = 0,
    moveto_target: i64 = 0,
    /// Offsets of the fields (n_field + 1 entries).
    offsets: []u32,
    /// The record, if it is all on one page.
    row: ?[*]const u8 = null,
    payload_size: u32 = 0,
    /// Bytes available at `row`.
    sz_row: u32 = 0,
    /// Serial types of the fields (n_field entries).
    types: []u32,
};

/// The allocation of a cursor: the VdbeCursor and the b-tree cursor it may
/// use. `vc.types` and `vc.offsets` share one allocation, types first.
pub const CursorBox = struct {
    vc: VdbeCursor,
    bc: btree.Cursor = undefined,
};

/// VdbeCursor.cache_status value that is never current (CACHE_STALE).
pub const cache_stale: u32 = 0;

// ================================================================ frames

/// A stack frame of a trigger program (VdbeFrame).
pub const VdbeFrame = struct {
    v: *Vdbe,
    parent: ?*VdbeFrame,
    ops: []Op,
    mem: []Mem,
    csr: []?*VdbeCursor,
    once: []u8,
    token: ?*anyopaque,
    last_rowid: i64,
    aux_data: ?*AuxData,
    pc: i32,
    n_change: i64,
    n_db_change: i64,
    /// The child frame's registers and cursors.
    child_mem: []Mem,
    child_csr: []?*VdbeCursor,
};

/// The outermost frame of a running trigger program.
pub fn rootFrame(first: *VdbeFrame) *VdbeFrame {
    var frame = first;
    while (frame.parent) |pf| frame = pf;
    return frame;
}

/// Auxiliary data a function keeps across calls (AuxData).
pub const AuxData = struct {
    i_aux_op: i32,
    i_aux_arg: i32,
    aux: ?*anyopaque,
    x_delete_aux: ?int.DestructorFn,
    next_aux: ?*AuxData,
};

/// The context of a function call (sqlite3_context).
pub const Context = struct {
    out: *Mem,
    func: *const FuncDef,
    /// The aggregate context cell.
    mem: ?*Mem = null,
    vdbe: ?*Vdbe = null,
    /// Address of the OP_Function.
    i_op: i32 = 0,
    /// Error code returned by the function.
    is_error: i32 = 0,
    enc: u8 = ENC.UTF8,
    skip_flag: bool = false,
    argc: u16 = 0,
    argv: []*Mem,
};

// ==================================================================== vm

/// Port of ScanStatus: one entry of sqlite3_stmt_scanstatus() (a loop or
/// another EXPLAIN QUERY PLAN line), recorded while the statement is
/// compiled with SQLITE_DBCONFIG_STMT_SCANSTATUS on
/// (SQLITE_ENABLE_STMT_SCANSTATUS in C).
pub const ScanStatus = struct {
    /// The OP_Explain of the loop, or 0.
    addr_explain: i32,
    /// Up to three ranges [start, end] of instructions whose cycles add
    /// up to SQLITE_SCANSTAT_NCYCLE (start 0: unused; start -1: every
    /// instruction with OPFLG_NCYCLE on cursor `end`).
    addr_range: [6]i32 = @splat(0),
    /// Instructions whose execution counts are NLOOP and NVISIT.
    addr_loop: i32,
    addr_visit: i32,
    /// Estimated rows per loop (LogEst).
    n_est: i16,
    /// The table or index scanned (in the statement's memory).
    name: ?[:0]const u8,
};

/// Port of the nExec and nCycle of VdbeOp: per instruction of the main
/// program, kept only by statements compiled for scan status
/// (Vdbe.op_stats), so that others neither carry nor update them.
pub const OpStat = struct {
    n_exec: u64 = 0,
    n_cycle: u64 = 0,
};

/// Vdbe.e_vdbe_state (VDBE_*_STATE).
pub const VdbeState = enum(u8) {
    /// Under construction.
    init = 0,
    /// Ready to run.
    ready = 1,
    run = 2,
    /// Finished; needs a reset.
    halt = 3,
};

/// A prepared statement (Vdbe).
pub const Vdbe = struct {
    db: *Sqlite3,
    /// Holds the program and everything its operands point to.
    arena: std.heap.ArenaAllocator,
    /// Other statements of the connection.
    prev: ?*Vdbe = null,
    next: ?*Vdbe = null,
    parse: ?*Parse = null,
    n_var: int.YnVar = 0,
    /// Registers; mem[0] is unused, as in C.
    mem: []Mem = &.{},
    csr: []?*VdbeCursor = &.{},
    /// Bound parameter values.
    vars: []Mem = &.{},
    cache_ctr: u32 = 1,
    pc: i32 = 0,
    rc: i32 = int.RC.OK,
    n_change: i64 = 0,
    i_statement: i32 = 0,
    i_current_time: i64 = 0,
    /// When the run started, for the profile callback (startTime;
    /// julian day times 86400000), or 0.
    start_time: i64 = 0,
    n_fk_constraint: i64 = 0,
    n_stmt_def_cons: i64 = 0,
    n_stmt_def_imm_cons: i64 = 0,
    ops: std.ArrayList(Op) = .empty,
    col_names: []Mem = &.{},
    /// The COLNAME_DATABASE, COLNAME_TABLE and COLNAME_COLUMN names
    /// (SQLITE_ENABLE_COLUMN_METADATA), laid out like col_names; empty
    /// until asked for (prepare.columnMetadata()).
    col_meta: []Mem = &.{},
    result_row: ?[*]Mem = null,
    /// What api.columnMem() returns outside a row (C: a static const
    /// nullMem, which callers may not write; here they may).
    null_mem: Mem = .{ .flags = .{ .Null = true } },
    /// What aux.getOp() returns after an allocation failure (C: a static
    /// VdbeOp), so that writes through it go nowhere.
    dummy_op: Op = .{ .opcode = @fromBackingInt(0) },
    err_msg: ?[:0]u8 = null,
    /// Names of named parameters.
    vlist: []const int.VListEntry = &.{},
    n_res_column: u16 = 0,
    n_res_alloc: u16 = 0,
    error_action: int.OE = .Abort,
    min_write_file_format: u8 = 255,
    prep_flags: u8 = 0,
    /// xqlite: the language (dialect and frontend) the statement was
    /// compiled in, and is recompiled in.
    xq_lang: @import("../dialect/dialect.zig").Lang = .{},
    e_vdbe_state: VdbeState = .init,
    expired: u2 = 0,
    explain: u2 = 0,
    change_cnt_on: bool = false,
    uses_stmt_journal: bool = false,
    read_only: bool = true,
    is_reader: bool = false,
    have_eqp_ops: bool = false,
    /// Databases used, and those needing locks.
    btree_mask: u32 = 0,
    lock_mask: u32 = 0,
    counters: [9]u32 = @splat(0),
    sql: ?[:0]const u8 = null,
    /// sqlite3_normalized_sql(), made on first use (zNormSql).
    norm_sql: ?[:0]const u8 = null,
    /// Double-quoted identifiers the resolver took as string literals,
    /// for normalized_sql (pDblStr).
    dbl_strs: std.ArrayList([]const u8) = .empty,
    frame: ?*VdbeFrame = null,
    del_frame: ?*VdbeFrame = null,
    n_frame: i32 = 0,
    expmask: u32 = 0,
    smimask: u32 = 0,
    program: ?*SubProgram = null,
    aux_data: ?*AuxData = null,
    /// Room for the arguments of xUpdate and xFilter (apArg).
    ap_arg: []*Mem = &.{},
    /// sqlite3_stmt_scanstatus(): the entries (aScan) and the counters of
    /// the instructions, both only for a statement compiled with
    /// SQLITE_DBCONFIG_STMT_SCANSTATUS (see aux.scanStatus()).
    scans: std.ArrayList(ScanStatus) = .empty,
    op_stats: []OpStat = &.{},

    pub fn alloc(v: *Vdbe) Allocator {
        return v.arena.allocator();
    }

    pub fn nOp(v: *const Vdbe) i32 {
        return @intCast(v.ops.items.len);
    }
};

/// sqlite3_stmt_status() counters (SQLITE_STMTSTATUS_*).
pub const STMTSTATUS = struct {
    pub const FULLSCAN_STEP = 1;
    pub const SORT = 2;
    pub const AUTOINDEX = 3;
    pub const VM_STEP = 4;
    pub const REPREPARE = 5;
    pub const RUN = 6;
    pub const FILTER_MISS = 7;
    pub const FILTER_HIT = 8;
    pub const MEMUSED = 99;
};

/// P5 flags of opcodes (OPFLAG_*).
pub const OPFLAG = struct {
    pub const NCHANGE: u16 = 0x01;
    pub const NOCHNG: u16 = 0x01;
    pub const EPHEM: u16 = 0x01;
    pub const LASTROWID: u16 = 0x20;
    pub const ISUPDATE: u16 = 0x04;
    pub const APPEND: u16 = 0x08;
    pub const USESEEKRESULT: u16 = 0x10;
    pub const ISNOOP: u16 = 0x40;
    pub const LENGTHARG: u16 = 0x40;
    pub const TYPEOFARG: u16 = 0x80;
    pub const BYTELENARG: u16 = 0xc0;
    pub const BULKCSR: u16 = 0x01;
    pub const SEEKEQ: u16 = 0x02;
    pub const FORDELETE: u16 = 0x08;
    pub const P2ISREG: u16 = 0x10;
    pub const PERMUTE: u16 = 0x01;
    pub const SAVEPOSITION: u16 = 0x02;
    pub const AUXDELETE: u16 = 0x04;
    pub const NOCHNG_MAGIC: u16 = 0x6d;
    pub const PREFORMAT: u16 = 0x80;
};

/// P5 flags of comparison opcodes.
pub const SQLITE_JUMPIFNULL: u16 = 0x10;
pub const SQLITE_NULLEQ: u16 = 0x80;
pub const SQLITE_NOTNULL: u16 = 0x90;
