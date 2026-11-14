//! Core types of the virtual machine (vdbe.h and vdbeInt.h): memory cells,
//! cursors, instructions and the Vdbe itself.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const btree = @import("xqlite_storage").btree;
pub const opcodes = @import("opcodes.zig");
pub const p5 = @import("p5.zig");
pub const InsertP5 = p5.InsertP5;
pub const DeleteP5 = p5.DeleteP5;
pub const OpenP5 = p5.OpenP5;
pub const ColumnP5 = p5.ColumnP5;
pub const CmpP5 = p5.CmpP5;
pub const CompareP5 = p5.CompareP5;
pub const CopyP5 = p5.CopyP5;
pub const HaltP5 = p5.HaltP5;
pub const TypeMaskP5 = p5.TypeMaskP5;
pub const FuncP5 = p5.FuncP5;
pub const StmtStatus = p5.StmtStatus;
const operand = @import("operand.zig");
const flags = @import("xqlite_base").flags;

pub const OP = opcodes.OP;
pub const Sqlite3 = int.Sqlite3;
pub const Parse = int.Parse;
pub const FuncDef = int.FuncDef;
pub const CollSeq = int.CollSeq;
pub const Table = int.Table;
pub const Index = int.Index;
pub const Pgno = int.Pgno;
pub const Allocator = std.mem.Allocator;

/// Port of sqlite3TempInMemory() for SQLITE_TEMP_STORE=1: temporary
/// files are in memory only with PRAGMA temp_store=MEMORY.
pub fn tempInMemory(db: *const Sqlite3) bool {
    return db.temp_store == 2;
}

/// The most memory, in bytes, that a sorter holds before it writes a PMA
/// (mxPmaSize in vdbesort.c), and the queue of a recursive CTE before it
/// writes chunks to its file (queue.zig): the cache size of the main
/// database, at least SQLITE_SORTER_PMASZ (250) pages and at most
/// SQLITE_MAX_PMASZ (512 MiB). Null if they never spill: with
/// temp_store=MEMORY, or without a main b-tree (hand-built test programs).
pub fn spillSize(db: *const Sqlite3) ?usize {
    const sorter_pmasz = 250;
    const max_pmasz = 1 << 29;
    if (tempInMemory(db) or db.dbs.items.len == 0) return null;
    const bt = db.dbs.items[0].bt orelse return null;
    const pgsz: usize = bt.getPageSize();
    const cache_size = db.dbs.items[0].schema.cache_size;
    // A negative cache size is in KiB.
    const cache: usize = if (cache_size < 0) @as(usize, @abs(cache_size)) * 1024 else @as(usize, @intCast(cache_size)) * pgsz;
    return @max(sorter_pmasz * pgsz, @min(cache, max_pmasz));
}

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
    /// The fields compared (C: aMem, nField). serial.recordUnpack()
    /// decodes up to fields.len of them and leaves it the number decoded.
    fields: []Mem,
    /// Cache of fields[0] for the specialized comparators.
    u: extern union { z: ?[*]u8, i: i64 } = .{ .i = 0 },
    n: i32 = 0,
    /// Result when the keys are equal.
    default_rc: i8 = 0,
    /// Results for lhs < rhs and lhs > rhs (inverted for DESC b-trees).
    r1: i8 = -1,
    r2: i8 = 1,
    /// An equal comparison was seen.
    eq_seen: bool = false,
};

// =========================================================== instructions

/// One instruction (VdbeOp). As in C built without
/// SQLITE_ENABLE_EXPLAIN_COMMENTS, it is 24 bytes: the P4 type fits in
/// the padding before p5, and P4 is a single word. Extern, so that
/// OpFor() can lay its fields out the same way.
pub const Op = extern struct {
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
            .intarray => |a| blk: {
                std.debug.assert(a.len > a[0]);
                break :blk .{ .intarray = a.ptr };
            },
            inline else => |x, t| @unionInit(P4Union, @tagName(t), x),
        };
    }

    /// The fourth operand with its type, strings and arrays as slices:
    /// for code where the cost of the lengths does not matter.
    pub fn getP4(op: *const Op) P4 {
        return switch (op.p4type) {
            .notused => .notused,
            .z => .{ .z = std.mem.span(op.p4.z) },
            .intarray => .{ .intarray = op.p4.intarray[0 .. op.p4.intarray[0] + 1] },
            inline else => |t| @unionInit(P4, @tagName(t), @field(op.p4, @tagName(t))),
        };
    }

    /// The fourth operand, which must be of type `t`.
    pub inline fn p4As(op: *const Op, comptime t: P4Type) @FieldType(P4Union, @tagName(t)) {
        std.debug.assert(op.p4type == t);
        return @field(op.p4, @tagName(t));
    }

    /// The elements of a P4_INTARRAY fourth operand, without the count
    /// that comes first.
    pub inline fn p4IntArray(op: *const Op) []u32 {
        const a = op.p4As(.intarray);
        return a[1..][0..a[0]];
    }

    /// P5 as a `T`, which must be the type of the opcode's (OP.P5()).
    pub inline fn p5As(op: *const Op, comptime T: type) T {
        std.debug.assert(op.opcode.info().p5 == comptime p5.Family.of(T));
        return p5.from(T, op.p5);
    }

    /// Set P5 to `x`: an integer if the opcode's P5 is a number, else a
    /// value of the type of its family (OP.P5()).
    pub inline fn setP5(op: *Op, x: anytype) void {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .int, .comptime_int => {
                std.debug.assert(op.opcode.info().p5 == .number);
                op.p5 = @intCast(x);
            },
            else => {
                std.debug.assert(op.opcode.info().p5 == comptime p5.Family.of(T));
                op.p5 = p5.int(x);
            },
        }
    }
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(Op) == 24);
}

/// The instruction of opcode `opc` as its handler takes it (exec.zig): an
/// Op whose P1, P2 and P3 have the types OP.kinds() gives them
/// (operand.zig: Reg, Cursor, Jump, Addr, or i32 for a number) and whose
/// P5 has the type OP.P5() (p5.zig). Opcodes with the same kinds and P5
/// have the same instruction type: a handler of OP_Eq .. OP_Ge takes
/// `*OpFor(.Eq)`.
pub fn OpFor(comptime opc: OP) type {
    return Instruction(opc.kinds(), opc.P5());
}

/// OpFor() by what it depends on, so that equal operands make one type.
fn Instruction(comptime kinds: [3]operand.Kind, comptime P5: type) type {
    return extern struct {
        opcode: OP,
        p4type: P4Type,
        p5: P5,
        p1: OperandOf(kinds[0]),
        p2: OperandOf(kinds[1]),
        p3: OperandOf(kinds[2]),
        p4: P4Union,

        const Self = @This();

        comptime {
            std.debug.assert(@sizeOf(Self) == @sizeOf(Op));
            for (@typeInfo(Op).@"struct".field_names) |name| {
                std.debug.assert(@offsetOf(Self, name) == @offsetOf(Op, name));
            }
        }

        /// The instruction with its operands as numbers.
        pub inline fn raw(op: *Self) *Op {
            return @ptrCast(op);
        }

        pub inline fn p4As(op: *const Self, comptime t: P4Type) @FieldType(P4Union, @tagName(t)) {
            return @as(*const Op, @ptrCast(op)).p4As(t);
        }

        pub inline fn p4IntArray(op: *const Self) []u32 {
            return @as(*const Op, @ptrCast(op)).p4IntArray();
        }

        pub inline fn setP4(op: *Self, p4: P4) void {
            op.raw().setP4(p4);
        }
    };
}

/// Instruction `o`, which is an `opc`, with the operands of that opcode.
pub inline fn opAs(o: *Op, comptime opc: OP) *OpFor(opc) {
    std.debug.assert(o.opcode == opc);
    return @ptrCast(o);
}

fn OperandOf(comptime kind: operand.Kind) type {
    return switch (kind) {
        .int => i32,
        .reg => operand.Reg,
        .cursor => operand.Cursor,
        .jump => operand.Jump,
        .addr => operand.Addr,
    };
}

/// The type of the fourth operand (P4_*).
pub const P4Type = enum(u8) {
    notused,
    z,
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
/// VdbeOp): one word, read as the field Op.p4type names (Op.p4As()).
/// Memory behind the pointers belongs to the Vdbe (its arena), not the
/// instruction.
pub const P4Union = extern union {
    p: ?*anyopaque,
    /// A NUL-terminated string (P4_STATIC, P4_DYNAMIC in the arena).
    z: [*:0]const u8,
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
    i_addr: operand.Addr = .from(0),
    reg_return: operand.Reg = .none,
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

/// A cursor of the VM (VdbeCursor). What only one kind of cursor has is
/// in `kind`; the rest, OP_Column's cache of the record above all, is
/// that of any cursor that reads records.
pub const VdbeCursor = struct {
    kind: Kind,
    i_db: i8,
    /// On a row with no data (e.g. the NULL row of a LEFT JOIN).
    null_row: bool = false,
    is_ephemeral: bool = false,
    use_random_rowid: bool = false,
    is_ordered: bool = false,
    no_reuse: bool = false,
    seek_hit: u16 = 0,
    seq_count: i64 = 0,
    /// Column cache valid while equal to Vdbe.cache_ctr.
    cache_status: u32 = cache_stale,
    key_info: ?*KeyInfo = null,
    /// Offset of the next unparsed byte of the record header.
    i_hdr_offset: u32 = 0,
    /// Header fields parsed so far.
    n_hdr_parsed: u16 = 0,
    /// Offsets of the fields (nField() + 1 entries).
    offsets: []u32,
    /// The record, if it is all on one page.
    row: ?[*]const u8 = null,
    payload_size: u32 = 0,
    /// Bytes available at `row`.
    sz_row: u32 = 0,
    /// Serial types of the fields, one per field of the cursor.
    types: []u32,

    /// The number of fields of the cursor's records (nField).
    pub fn nField(c: *const VdbeCursor) i32 {
        return @intCast(c.types.len);
    }

    /// The cursor's kind (eCurType, CURTYPE_*) and what it reads (uc). A
    /// cursor keeps its kind, from its allocation to its close. `queue` is
    /// not in C.
    pub const Kind = union(enum) {
        btree: OnBtree,
        sorter: *@import("sorter.zig").Sorter,
        vtab: *@import("../sql/vtab.zig").VtabCursor,
        /// The register that holds the record (OP_OpenPseudo's P2), or
        /// none for the cursor of OP_NullRow that only has NULL rows (C:
        /// seekResult 0, IsNullCursor()).
        pseudo: operand.Reg,
        /// The FIFO of a recursive CTE (OP_OpenQueue). It reads no record:
        /// OP_QueuePop hands each one to a pseudo cursor.
        queue: *@import("queue.zig").Queue,

        /// What a cursor of kind `t` reads, or null if it is of another
        /// kind.
        pub inline fn as(k: *Kind, comptime t: std.meta.Tag(Kind)) ?*@FieldType(Kind, @tagName(t)) {
            return if (k.* == t) &@field(k, @tagName(t)) else null;
        }
    };
};

/// A cursor on a b-tree (a table, an index or an ephemeral table).
pub const OnBtree = struct {
    /// Open from the cursor's allocation to its close (in its
    /// BtreeCursorBox).
    cursor: *btree.Cursor,
    /// The root page.
    pgno_root: Pgno,
    /// A rowid table rather than an index (no KeyInfo).
    is_table: bool,
    /// Opened with OPFLAG_SEEKEQ (BTREE_SEEK_EQ): only equality seeks.
    seek_eq: bool = false,
    /// A seek to `moveto_target` is pending (OP_DeferredSeek).
    deferred_moveto: bool = false,
    moveto_target: i64 = 0,
    /// Table to index column mapping (aAltMap): the elements of a
    /// P4_INTARRAY.
    alt_map: ?[]const u32 = null,
    alt_cursor: ?*VdbeCursor = null,
    /// The separate b-tree of an ephemeral table, shared with OP_OpenDup
    /// cursors. It closes itself with its last cursor (BTREE_SINGLE).
    btx: ?*btree.Btree = null,
    /// How the key of the last seek compares with the entry it left the
    /// cursor at (C's seekResult -1, 0, 1), for an OP_Insert or
    /// OP_IdxInsert with OPFLAG_USESEEKRESULT; null if there was no seek,
    /// or the entry was deleted since (C: 0 as well, which there is also
    /// "equal").
    seek_result: ?std.math.Order = null,
};

/// The allocation of a cursor: the VdbeCursor and the arrays of its
/// column cache.
pub const CursorBox = struct {
    vc: VdbeCursor,
    /// The one allocation that `vc.types` and `vc.offsets` are slices of.
    cache: []u32,
};

/// The allocation of a b-tree cursor, with its b-tree cursor
/// (OnBtree.cursor).
pub const BtreeCursorBox = struct {
    box: CursorBox,
    bc: btree.Cursor,
};

/// VdbeCursor.cache_status value that is never current (CACHE_STALE).
pub const cache_stale: u32 = 0;

// ================================================================ frames

/// A stack frame of a trigger program (VdbeFrame).
pub const VdbeFrame = struct {
    v: *Vdbe,
    parent: ?*VdbeFrame,
    /// The caller's program, registers and cursors, restored on return.
    ops: []Op,
    mem: []Mem,
    csr: []?*VdbeCursor,
    once: []u8,
    token: ?*anyopaque,
    last_rowid: i64,
    aux_data: ?*AuxData,
    /// The address of the OP_Program that called the frame.
    pc: u32,
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
    /// What its error is (api.resultErrorState()), if known.
    err_state: ?int.ErrorState = null,
    enc: u8 = ENC.UTF8,
    skip_flag: bool = false,
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

    /// The program is complete: ready, running or halted (C:
    /// `eVdbeState>=VDBE_READY_STATE`).
    pub fn built(s: VdbeState) bool {
        return s != .init;
    }
};

/// Whether a statement is out of date (Vdbe.expired; C's 0, 1, 2, which
/// sqlite3_expired() returns).
pub const Expired = enum(u2) {
    no = 0,
    /// Compile it again before it runs again, and abort a run at its next
    /// OP_OpenRead or OP_OpenWrite.
    now = 1,
    /// Compile it again before it runs again; a run goes on to its end.
    when_convenient = 2,
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
    /// The main program: built while the statement is compiled, fixed
    /// from makeReady() on.
    ops: std.ArrayList(Op) = .empty,
    /// The instructions of the program running (aOp): those of `ops`, or
    /// of the trigger program of the innermost frame while one runs.
    /// Set by makeReady() and when a frame is entered or left.
    prog: []Op = &.{},
    col_names: []Mem = &.{},
    /// The COLNAME_DATABASE, COLNAME_TABLE and COLNAME_COLUMN names
    /// (SQLITE_ENABLE_COLUMN_METADATA), laid out like col_names; empty
    /// until asked for (prepare.columnMetadata()).
    col_meta: []Mem = &.{},
    /// xqlite: the type of each result column, where the statement knows
    /// it (Expr.xq_type, sql/typing.zig): n_res_column entries, .unknown
    /// where not known; empty if no column's is (so always for SQLite's
    /// dialect). Values, not ids: they do not depend on the connection.
    xq_col_types: []@import("../sql/types.zig").Type = &.{},
    /// xqlite: the type of each parameter (by number - 1) where the
    /// statement gives it one (Parse.xq_param_types, sql/typing.zig):
    /// vars.len entries, .unknown where not known; empty if none is known.
    xq_param_types: []@import("../sql/types.zig").Type = &.{},
    /// xqlite: the text of the statement this one runs, when it is not
    /// its own (PostgreSQL's EXECUTE of a prepared statement): what a
    /// protocol names the command after (engine.commandSql()). Empty
    /// for its own text. In the Vdbe's memory.
    xq_command_sql: []const u8 = "",
    /// Parse.xq_exact_numeric of the statement.
    xq_exact_numeric: bool = false,
    /// Parse.xq_values_coroutine of the statement.
    xq_values_coroutine: bool = false,
    /// A query of no result columns (Parse.xq_no_columns): its rows are
    /// its result, though it has no column.
    xq_no_columns: bool = false,
    /// Parse.xq_binary_rows: the rows of a FETCH from a binary cursor,
    /// which a wire protocol sends in the binary format
    /// (engine.binaryRows()).
    xq_binary_rows: bool = false,
    /// xqlite: the notices the statement reports each time it runs
    /// (Parse.xq_notices, int.Notice), in the program's memory.
    xq_notices: []const int.Notice = &.{},
    /// The current row (the n_res_column registers of OP_ResultRow), if
    /// the statement is on one.
    result_row: ?[]Mem = null,
    /// What api.columnMem() returns outside a row (C: a static const
    /// nullMem, which callers may not write; here they may).
    null_mem: Mem = .{ .flags = .{ .Null = true } },
    /// What aux.getOp() returns after an allocation failure (C: a static
    /// VdbeOp), so that writes through it go nowhere.
    dummy_op: Op = .{ .opcode = @fromBackingInt(0) },
    err_msg: ?[:0]u8 = null,
    /// What err_msg is (int.ErrorState), if known.
    err_state: ?int.ErrorState = null,
    /// Names of named parameters.
    vlist: []const int.VListEntry = &.{},
    n_res_column: u16 = 0,
    error_action: int.OE = .Abort,
    min_write_file_format: u8 = 255,
    prep_flags: int.PrepFlags = .{},
    /// xqlite: the language (dialect and frontend) the statement was
    /// compiled in, and is recompiled in.
    xq_lang: @import("../dialect/dialect.zig").Lang = .{},
    /// xqlite: the dialect's error of the foreign key violation that made
    /// the count not zero (the P4 of an OP_FkCounter,
    /// dialect/constraint.zig).
    xq_fk_error: ?[*:0]const u8 = null,
    /// xqlite: xq_fk_error written with the values of its key
    /// (OP_FkCounter), owned (the connection's gpa).
    xq_fk_owned: ?[:0]u8 = null,
    e_vdbe_state: VdbeState = .init,
    expired: Expired = .no,
    explain: int.Explain = .none,
    change_cnt_on: bool = false,
    uses_stmt_journal: bool = false,
    read_only: bool = true,
    is_reader: bool = false,
    have_eqp_ops: bool = false,
    /// Databases used, and those needing locks.
    btree_mask: u32 = 0,
    lock_mask: u32 = 0,
    /// sqlite3_stmt_status() counters.
    counters: std.EnumArray(StmtStatus, u32) = .initFill(0),
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

    /// The number of columns col_names has room for (nResAlloc), which
    /// n_res_column is but for the listing of EXPLAIN.
    pub fn nColNames(v: *const Vdbe) usize {
        return v.col_names.len / COLNAME_N;
    }

    /// The slot of name `var_` (COLNAME_*) of column `i`: in col_names
    /// for COLNAME_NAME and COLNAME_DECLTYPE, in col_meta for the origin
    /// names, each array holding one kind of name for every column, then
    /// the next. Null if that array was not allocated.
    pub fn colNameSlot(v: *const Vdbe, i: usize, var_: usize) ?*Mem {
        const names, const k = if (var_ < COLNAME_N) .{ v.col_names, var_ } else .{ v.col_meta, var_ - COLNAME_N };
        if (names.len == 0) return null;
        return &names[i + k * v.nColNames()];
    }
};
