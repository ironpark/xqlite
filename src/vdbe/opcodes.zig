//! The VDBE opcodes and what is known of each. One opcode is one member
//! of `OP` and one entry of `table` (which must name every opcode), and
//! the handler that runs it (exec.zig, which must have exactly one).
//!
//! The numbers are those SQLite 3.54.1 gives its opcodes; they show in no
//! output (EXPLAIN and bytecode() print names) but are kept anyway. What
//! code relies on in them is checked at the end: the opcodes that vdbe.c
//! marks "same as TK_xxx" equal that token (OP.fromTk()), and OP_Ne ..
//! OP_Ge and OP_SeekLT .. OP_SeekGT are consecutive, in that order
//! (OP.compareIndex(), OP.seekIsGeOrGt()). A new opcode takes the next
//! free number.

const std = @import("std");
const TK = @import("../sql/tk.zig").TK;
const Kind = @import("operand.zig").Kind;
const P5Family = @import("p5.zig").Family;

/// The opcodes (OP_*).
pub const OP = enum(u8) {
    Savepoint = 0,
    AutoCommit = 1,
    Transaction = 2,
    Checkpoint = 3,
    JournalMode = 4,
    Vacuum = 5,
    VFilter = 6,
    VUpdate = 7,
    Init = 8,
    Goto = 9,
    Gosub = 10,
    InitCoroutine = 11,
    Yield = 12,
    MustBeInt = 13,
    Jump = 14,
    Once = 15,
    If = 16,
    IfNot = 17,
    IsType = 18,
    Not = 19,
    IfNullRow = 20,
    SeekLT = 21,
    SeekLE = 22,
    SeekGE = 23,
    SeekGT = 24,
    IfNoHope = 25,
    NoConflict = 26,
    NotFound = 27,
    Found = 28,
    SeekRowid = 29,
    NotExists = 30,
    Last = 31,
    IfSizeBetween = 32,
    SorterSort = 33,
    Sort = 34,
    Rewind = 35,
    IfEmpty = 36,
    SorterNext = 37,
    Prev = 38,
    Next = 39,
    IdxLE = 40,
    IdxGT = 41,
    IdxLT = 42,
    Or = 43,
    And = 44,
    IdxGE = 45,
    IFindKey = 46,
    RowSetRead = 47,
    RowSetTest = 48,
    Program = 49,
    FkIfZero = 50,
    IsNull = 51,
    NotNull = 52,
    Ne = 53,
    Eq = 54,
    Gt = 55,
    Le = 56,
    Lt = 57,
    Ge = 58,
    ElseEq = 59,
    IfPos = 60,
    IfNotZero = 61,
    DecrJumpZero = 62,
    IncrVacuum = 63,
    VNext = 64,
    Filter = 65,
    PureFunc = 66,
    Function = 67,
    Return = 68,
    EndCoroutine = 69,
    HaltIfNull = 70,
    Halt = 71,
    Integer = 72,
    Int64 = 73,
    String = 74,
    BeginSubrtn = 75,
    Null = 76,
    SoftNull = 77,
    Blob = 78,
    Variable = 79,
    Move = 80,
    Copy = 81,
    SCopy = 82,
    IntCopy = 83,
    FkCheck = 84,
    ResultRow = 85,
    CollSeq = 86,
    AddImm = 87,
    RealAffinity = 88,
    Cast = 89,
    Permutation = 90,
    Compare = 91,
    IsTrue = 92,
    ZeroOrNull = 93,
    Offset = 94,
    Column = 95,
    TypeCheck = 96,
    Affinity = 97,
    MakeRecord = 98,
    Count = 99,
    ReadCookie = 100,
    SetCookie = 101,
    ReopenIdx = 102,
    BitAnd = 103,
    BitOr = 104,
    ShiftLeft = 105,
    ShiftRight = 106,
    Add = 107,
    Subtract = 108,
    Multiply = 109,
    Divide = 110,
    Remainder = 111,
    Concat = 112,
    OpenRead = 113,
    OpenWrite = 114,
    BitNot = 115,
    OpenDup = 116,
    OpenAutoindex = 117,
    String8 = 118,
    OpenEphemeral = 119,
    SorterOpen = 120,
    SequenceTest = 121,
    OpenPseudo = 122,
    Close = 123,
    ColumnsUsed = 124,
    SeekScan = 125,
    SeekHit = 126,
    Sequence = 127,
    NewRowid = 128,
    Insert = 129,
    RowCell = 130,
    Delete = 131,
    ResetCount = 132,
    SorterCompare = 133,
    SorterData = 134,
    RowData = 135,
    Rowid = 136,
    NullRow = 137,
    SeekEnd = 138,
    IdxInsert = 139,
    SorterInsert = 140,
    IdxDelete = 141,
    DeferredSeek = 142,
    IdxRowid = 143,
    FinishSeek = 144,
    Destroy = 145,
    Clear = 146,
    ResetSorter = 147,
    CreateBtree = 148,
    SqlExec = 149,
    ParseSchema = 150,
    LoadAnalysis = 151,
    DropTable = 152,
    DropIndex = 153,
    Real = 154,
    DropTrigger = 155,
    IntegrityCk = 156,
    RowSetAdd = 157,
    Param = 158,
    FkCounter = 159,
    MemMax = 160,
    OffsetLimit = 161,
    AggInverse = 162,
    AggStep = 163,
    AggStep1 = 164,
    AggValue = 165,
    AggFinal = 166,
    Expire = 167,
    CursorLock = 168,
    CursorUnlock = 169,
    TableLock = 170,
    VBegin = 171,
    VCreate = 172,
    VDestroy = 173,
    VOpen = 174,
    VCheck = 175,
    VInitIn = 176,
    VColumn = 177,
    VRename = 178,
    Pagecount = 179,
    MaxPgcnt = 180,
    ClrSubtype = 181,
    GetSubtype = 182,
    SetSubtype = 183,
    FilterAdd = 184,
    Trace = 185,
    CursorHint = 186,
    ReleaseReg = 187,
    Noop = 188,
    Explain = 189,
    Abortable = 190,
    // Not in SQLite: the queue of a recursive CTE (queue.zig).
    OpenQueue = 191,
    QueuePush = 192,
    QueuePop = 193,

    /// The number of the opcode (u8).
    pub inline fn int(op: OP) u8 {
        return @backingInt(op);
    }

    /// The opcode numbered like token `tk`, for code that uses an
    /// operator as the opcode (C passes pExpr->op to
    /// sqlite3VdbeAddOp*()): no conversion at all, since each opcode in
    /// `same_as_tk` has the value of its token. `tk` must be one of those
    /// tokens.
    pub inline fn fromTk(tk: u8) OP {
        std.debug.assert(tk_is_op[tk]);
        return @fromBackingInt(tk);
    }

    /// What is known of the opcode.
    pub inline fn info(op: OP) Info {
        return infos[op.int()];
    }

    /// The OPFLG_* properties of the opcode (sqlite3OpcodeProperty[]).
    pub inline fn props(op: OP) Props {
        return infos[op.int()].props;
    }

    /// What P1, P2 and P3 of the opcode are.
    pub inline fn kinds(op: OP) [3]Kind {
        return infos[op.int()].p;
    }

    /// The type of P5 of the opcode (p5.zig).
    pub fn P5(comptime op: OP) type {
        return op.info().p5.Type();
    }

    /// The name of the opcode without "OP_" (sqlite3OpcodeName()).
    pub fn name(op: OP) [:0]const u8 {
        return @tagName(op);
    }

    /// The place of a comparison opcode in the order OP_Ne, OP_Eq,
    /// OP_Gt, OP_Le, OP_Lt, OP_Ge, which indexes sqlite3aLTb[],
    /// sqlite3aEQb[] and sqlite3aGTb[] (C: `pOp->opcode - OP_Ne`). The
    /// six are consecutive because TK_NE..TK_GE are.
    pub inline fn compareIndex(op: OP) u3 {
        std.debug.assert(op.int() >= OP.Ne.int() and op.int() <= OP.Ge.int());
        return @intCast(op.int() - OP.Ne.int());
    }

    /// For OP_SeekLT, OP_SeekLE, OP_SeekGE and OP_SeekGT, which are
    /// consecutive in that order: whether the seek moves forward, that
    /// is, it is OP_SeekGE or OP_SeekGT (C: `oc>=OP_SeekGE`).
    pub inline fn seekIsGeOrGt(op: OP) bool {
        return op.int() >= OP.SeekGE.int();
    }
};

/// The properties of an opcode (C's OPFLG_*, in the same bits).
pub const Props = packed struct(u8) {
    /// P2 is where the opcode may jump (OPFLG_JUMP): the same as P2's
    /// kind being `.jump`, from which `table` sets it.
    jump: bool = false,
    /// P1, P2 and P3 are registers the opcode reads (OPFLG_IN1 ... IN3).
    in1: bool = false,
    in2: bool = false,
    in3: bool = false,
    /// P2 and P3 are registers the opcode writes (OPFLG_OUT2, OUT3).
    out2: bool = false,
    out3: bool = false,
    /// The opcode's cycles count toward the scan status of its cursor P1
    /// (OPFLG_NCYCLE).
    ncycle: bool = false,
    /// The opcode may jump to P2 while P2 is still 0 (OPFLG_JUMP0).
    jump0: bool = false,
};

/// What makes a statement one that reads or writes the database
/// (aux.resolveP2Values()).
pub const Access = enum {
    none,
    /// The statement reads the database (Vdbe.is_reader).
    read,
    /// It reads and writes the database (not Vdbe.read_only).
    write,
    /// It reads, and writes when P2 is not 0 (OP_Transaction).
    write_if_p2,
};

/// What is known of an opcode.
pub const Info = struct {
    /// What P1, P2 and P3 are (operand.zig). An operand that is a
    /// register only in some uses of the opcode (OP_Clear's P3,
    /// OP_OpenWrite's P2 with OpenP5.p2_is_reg) is `.int`.
    p: [3]Kind,
    /// The properties; `jump` is not written in `table` but follows from
    /// `p`.
    props: Props = .{},
    /// The opcode opens a cursor on a b-tree of the schema, which
    /// bytecode()'s tables_used lists (OP_OpenWrite only without
    /// OpenP5.p2_is_reg).
    opens_table: bool = false,
    access: Access = .none,
    /// What P5 is (p5.zig).
    p5: P5Family = .number,
};

/// What is known of each opcode, by number.
const infos: [n_opcodes]Info = blk: {
    @setEvalBranchQuota(100_000);
    var a = std.enums.directEnumArray(OP, Info, 0, table);
    for (&a, 0..) |*x, value| {
        if (x.props.jump) @compileError("table: P2 of a jump is .jump, not .jump = true: OP_" ++ @tagName(@as(OP, @fromBackingInt(value))));
        x.props.jump = x.p[1] == .jump;
    }
    break :blk a;
};

pub const n_opcodes = @typeInfo(OP).@"enum".field_names.len;

/// For each opcode: its operands (`.p`), its other properties, and the
/// facts of `Info`.
const table: std.enums.EnumFieldStruct(OP, Info, null) = blk: {
    const i = Kind.int;
    const r = Kind.reg;
    const c = Kind.cursor;
    const j = Kind.jump;
    const a = Kind.addr;
    break :blk .{
        // Transactions and the schema.
        .Savepoint = .{ .p = .{ i, i, i }, .access = .read },
        .AutoCommit = .{ .p = .{ i, i, i }, .access = .read },
        .Transaction = .{ .p = .{ i, i, i }, .access = .write_if_p2 },
        .SetCookie = .{ .p = .{ i, i, i } },
        .TableLock = .{ .p = .{ i, i, i } },
        .Checkpoint = .{ .p = .{ i, i, r }, .access = .write },
        .JournalMode = .{ .p = .{ i, r, i }, .props = .{ .out2 = true }, .access = .write },
        .Vacuum = .{ .p = .{ i, r, i }, .access = .write },
        .ReadCookie = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Pagecount = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .MaxPgcnt = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Destroy = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .CreateBtree = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Clear = .{ .p = .{ i, i, i } },
        .SqlExec = .{ .p = .{ i, i, i } },
        .ParseSchema = .{ .p = .{ i, i, i } },
        .LoadAnalysis = .{ .p = .{ i, i, i } },
        .DropTable = .{ .p = .{ i, i, i } },
        .DropIndex = .{ .p = .{ i, i, i } },
        .DropTrigger = .{ .p = .{ i, i, i } },
        .Expire = .{ .p = .{ i, i, i } },
        .IntegrityCk = .{ .p = .{ r, i, r } },

        // Control.
        .Init = .{ .p = .{ i, j, i }, .props = .{ .jump0 = true } },
        .Goto = .{ .p = .{ i, j, i } },
        .Once = .{ .p = .{ i, j, i } },
        .ElseEq = .{ .p = .{ i, j, i } },
        .FkIfZero = .{ .p = .{ i, j, i } },
        .IncrVacuum = .{ .p = .{ i, j, i } },
        .Gosub = .{ .p = .{ r, j, i } },
        .Yield = .{ .p = .{ r, j, i }, .props = .{ .in1 = true, .jump0 = true } },
        .MustBeInt = .{ .p = .{ r, j, i }, .props = .{ .in1 = true, .jump0 = true } },
        .If = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        .IfNot = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        .IsNull = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        .NotNull = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        // P3 is where the co-routine starts.
        .InitCoroutine = .{ .p = .{ r, j, a }, .props = .{ .jump0 = true } },
        .IfPos = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        .IfNotZero = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        .DecrJumpZero = .{ .p = .{ r, j, i }, .props = .{ .in1 = true } },
        .Jump = .{ .p = .{ a, j, a } },
        // P2 of OP_Return, if any, is the start of the subroutine (for the
        // indentation of EXPLAIN).
        .Return = .{ .p = .{ r, a, i }, .props = .{ .in1 = true } },
        .EndCoroutine = .{ .p = .{ r, i, i }, .props = .{ .in1 = true } },
        .HaltIfNull = .{ .p = .{ i, i, r }, .props = .{ .in3 = true }, .p5 = .halt },
        // P3 is the register of RAISE's message, if any.
        .Halt = .{ .p = .{ i, i, r }, .p5 = .halt },
        .FkCheck = .{ .p = .{ i, i, i } },
        .FkCounter = .{ .p = .{ i, i, i } },
        .ResetCount = .{ .p = .{ i, i, i } },
        .Permutation = .{ .p = .{ i, i, i } },
        .Trace = .{ .p = .{ i, i, i } },
        .Noop = .{ .p = .{ i, i, i } },
        .Explain = .{ .p = .{ i, i, i } },
        .Abortable = .{ .p = .{ i, i, i } },
        .Program = .{ .p = .{ r, j, r }, .props = .{ .jump0 = true } },
        .Param = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },

        // Constants and registers.
        .Integer = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Int64 = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Real = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Blob = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .Variable = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        // P3, if any, is the counter of a LIKE optimization's loop
        // (whereLikeOptimizationStringFixup()): equal to P5, the string
        // is a BLOB.
        .String8 = .{ .p = .{ i, r, r }, .props = .{ .out2 = true } },
        .String = .{ .p = .{ i, r, r }, .props = .{ .out2 = true } },
        // P3, if any, is the last register of a run set to NULL (OP_Null;
        // OP_BeginSubrtn, which runs as it, sets one).
        .Null = .{ .p = .{ i, r, r }, .props = .{ .out2 = true } },
        .BeginSubrtn = .{ .p = .{ i, r, r } },
        .SoftNull = .{ .p = .{ r, i, i } },
        .RealAffinity = .{ .p = .{ r, i, i }, .props = .{ .in1 = true } },
        .ClrSubtype = .{ .p = .{ r, i, i }, .props = .{ .in1 = true } },
        .VRename = .{ .p = .{ r, i, i } },
        .CollSeq = .{ .p = .{ r, i, i } },
        .Move = .{ .p = .{ r, r, i } },
        .Copy = .{ .p = .{ r, r, i }, .p5 = .copy },
        .SCopy = .{ .p = .{ r, r, i }, .props = .{ .out2 = true } },
        .IntCopy = .{ .p = .{ r, r, i }, .props = .{ .out2 = true } },
        .Not = .{ .p = .{ r, r, i }, .props = .{ .in1 = true, .out2 = true } },
        .BitNot = .{ .p = .{ r, r, i }, .props = .{ .in1 = true, .out2 = true } },
        .MemMax = .{ .p = .{ r, r, i }, .props = .{ .in2 = true } },
        .GetSubtype = .{ .p = .{ r, r, i }, .props = .{ .in1 = true, .out2 = true } },
        .SetSubtype = .{ .p = .{ r, r, i }, .props = .{ .in1 = true, .out2 = true } },
        .RowSetAdd = .{ .p = .{ r, r, i }, .props = .{ .in1 = true, .in2 = true } },
        .ResultRow = .{ .p = .{ r, i, i } },
        .AddImm = .{ .p = .{ r, i, i }, .props = .{ .in1 = true } },
        .Cast = .{ .p = .{ r, i, i }, .props = .{ .in1 = true } },
        .TypeCheck = .{ .p = .{ r, i, i } },
        .Affinity = .{ .p = .{ r, i, i } },
        .ReleaseReg = .{ .p = .{ r, i, i } },
        .Compare = .{ .p = .{ r, r, i }, .p5 = .compare },
        .IsTrue = .{ .p = .{ r, r, i }, .props = .{ .in1 = true, .out2 = true } },
        .MakeRecord = .{ .p = .{ r, i, r } },

        // Arithmetic, comparisons and logic.
        .Or = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .And = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .BitAnd = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .BitOr = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .ShiftLeft = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .ShiftRight = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .Add = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .Subtract = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .Multiply = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .Divide = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .Remainder = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .Concat = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .out3 = true } },
        .ZeroOrNull = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in2 = true, .in3 = true, .out2 = true } },
        .OffsetLimit = .{ .p = .{ r, r, r }, .props = .{ .in1 = true, .in3 = true, .out2 = true } },
        .Ne = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true }, .p5 = .compare_jump },
        .Eq = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true }, .p5 = .compare_jump },
        .Gt = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true }, .p5 = .compare_jump },
        .Le = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true }, .p5 = .compare_jump },
        .Lt = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true }, .p5 = .compare_jump },
        .Ge = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true }, .p5 = .compare_jump },

        // Functions and aggregates.
        .PureFunc = .{ .p = .{ i, r, r } },
        .Function = .{ .p = .{ i, r, r } },
        .AggInverse = .{ .p = .{ i, r, r } },
        .AggStep = .{ .p = .{ i, r, r } },
        .AggStep1 = .{ .p = .{ i, r, r } },
        // P3 of OP_AggValue is the register of the result; OP_AggFinal,
        // which runs as it with P3 0, has none.
        .AggValue = .{ .p = .{ r, i, r } },
        .AggFinal = .{ .p = .{ r, i, r } },

        // Opening and closing cursors.
        .OpenRead = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true }, .opens_table = true, .p5 = .open },
        .OpenWrite = .{ .p = .{ c, i, i }, .opens_table = true, .p5 = .open },
        .ReopenIdx = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true }, .opens_table = true, .p5 = .open },
        .SorterOpen = .{ .p = .{ c, i, i } },
        // P3, if any, is a register that is set to NULL.
        .OpenAutoindex = .{ .p = .{ c, i, r }, .props = .{ .ncycle = true } },
        .OpenEphemeral = .{ .p = .{ c, i, r }, .props = .{ .ncycle = true } },
        .OpenDup = .{ .p = .{ c, c, i }, .props = .{ .ncycle = true } },
        .OpenPseudo = .{ .p = .{ c, r, i } },
        // Not in SQLite (queue.zig): OP_OpenQueue opens P1 as an empty
        // FIFO of records, or empties it if it is open; OP_QueuePush
        // appends the record in register P2; OP_QueuePop moves the oldest
        // record into the register of pseudo cursor P3, or jumps to P2 if
        // there is none.
        .OpenQueue = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true } },
        .QueuePush = .{ .p = .{ c, r, i }, .props = .{ .in2 = true } },
        .QueuePop = .{ .p = .{ c, j, c }, .props = .{ .ncycle = true } },
        .Close = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true } },
        .ColumnsUsed = .{ .p = .{ c, i, i } },
        .NullRow = .{ .p = .{ c, i, i } },
        .SeekEnd = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true } },
        .FinishSeek = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true } },
        .ResetSorter = .{ .p = .{ c, i, i } },
        .CursorLock = .{ .p = .{ c, i, i } },
        .CursorUnlock = .{ .p = .{ c, i, i } },
        .CursorHint = .{ .p = .{ c, i, i } },
        .SequenceTest = .{ .p = .{ c, i, i } },
        .SeekHit = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true } },
        .Delete = .{ .p = .{ c, i, i }, .p5 = .delete },

        // Moving cursors.
        .SeekLT = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true, .jump0 = true } },
        .SeekLE = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true, .jump0 = true } },
        .SeekGE = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true, .jump0 = true } },
        .SeekGT = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true, .jump0 = true } },
        .IfNoHope = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true } },
        .NoConflict = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true } },
        .NotFound = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true } },
        .Found = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true } },
        .SeekRowid = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true, .jump0 = true } },
        .NotExists = .{ .p = .{ c, j, r }, .props = .{ .in3 = true, .ncycle = true } },
        .IdxLE = .{ .p = .{ c, j, r }, .props = .{ .ncycle = true } },
        .IdxGT = .{ .p = .{ c, j, r }, .props = .{ .ncycle = true } },
        .IdxLT = .{ .p = .{ c, j, r }, .props = .{ .ncycle = true } },
        .IdxGE = .{ .p = .{ c, j, r }, .props = .{ .ncycle = true } },
        .IFindKey = .{ .p = .{ c, j, r }, .props = .{ .in3 = true } },
        .IfNullRow = .{ .p = .{ c, j, r } },
        .Last = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true, .jump0 = true } },
        .IfSizeBetween = .{ .p = .{ c, j, i } },
        .SorterSort = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true } },
        .Sort = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true } },
        .Rewind = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true, .jump0 = true } },
        .IfEmpty = .{ .p = .{ c, j, i } },
        .SorterNext = .{ .p = .{ c, j, i }, .p5 = .counter },
        .Prev = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true }, .p5 = .counter },
        .Next = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true }, .p5 = .counter },
        .SeekScan = .{ .p = .{ i, i, i }, .props = .{ .ncycle = true } },
        .IsType = .{ .p = .{ i, j, i } },

        // Reading and writing rows.
        .Column = .{ .p = .{ c, i, r }, .props = .{ .ncycle = true }, .p5 = .column },
        .Offset = .{ .p = .{ c, i, r }, .props = .{ .out3 = true } },
        .Count = .{ .p = .{ c, r, i }, .props = .{ .out2 = true } },
        .Sequence = .{ .p = .{ c, r, i }, .props = .{ .out2 = true } },
        .Rowid = .{ .p = .{ c, r, i }, .props = .{ .out2 = true, .ncycle = true } },
        .RowData = .{ .p = .{ c, r, i } },
        // P3 is not used; the sorter of an ORDER BY takes OP_IdxInsert's operands.
        .SorterInsert = .{ .p = .{ c, r, r }, .props = .{ .in2 = true } },
        .NewRowid = .{ .p = .{ c, r, r }, .props = .{ .out2 = true } },
        .Insert = .{ .p = .{ c, r, r }, .p5 = .insert },
        .IdxInsert = .{ .p = .{ c, r, r }, .props = .{ .in2 = true }, .p5 = .insert },
        .RowCell = .{ .p = .{ c, c, r } },
        // P2 is an address, never a label (the opcode does not jump).
        .SorterCompare = .{ .p = .{ c, a, r } },
        .SorterData = .{ .p = .{ c, r, c }, .props = .{ .ncycle = true } },
        // P3, if any, is the register of a record: an entry that is that
        // record stays.
        .IdxDelete = .{ .p = .{ c, r, r } },
        .DeferredSeek = .{ .p = .{ c, i, c }, .props = .{ .ncycle = true } },
        .IdxRowid = .{ .p = .{ c, r, i }, .props = .{ .out2 = true, .ncycle = true } },

        // RowSets and Bloom filters.
        .RowSetRead = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .out3 = true } },
        .RowSetTest = .{ .p = .{ r, j, r }, .props = .{ .in1 = true, .in3 = true } },
        .Filter = .{ .p = .{ r, j, r } },
        .FilterAdd = .{ .p = .{ r, i, r } },

        // Virtual tables.
        .VFilter = .{ .p = .{ c, j, r }, .props = .{ .ncycle = true } },
        .VUpdate = .{ .p = .{ i, i, r } },
        .VNext = .{ .p = .{ c, j, i }, .props = .{ .ncycle = true } },
        .VBegin = .{ .p = .{ i, i, i } },
        .VDestroy = .{ .p = .{ i, i, i } },
        .VCreate = .{ .p = .{ i, r, i } },
        .VCheck = .{ .p = .{ i, r, i }, .props = .{ .out2 = true } },
        .VOpen = .{ .p = .{ c, i, i }, .props = .{ .ncycle = true } },
        .VInitIn = .{ .p = .{ c, r, r }, .props = .{ .out2 = true, .ncycle = true } },
        .VColumn = .{ .p = .{ c, i, r }, .props = .{ .ncycle = true }, .p5 = .column },
    };
};

/// The opcodes that vdbe.c marks "same as TK_xxx", with their tokens.
pub const same_as_tk = [_]struct { op: OP, tk: u8 }{
    .{ .op = .Real, .tk = TK.FLOAT },
    .{ .op = .String8, .tk = TK.STRING },
    .{ .op = .Concat, .tk = TK.CONCAT },
    .{ .op = .Add, .tk = TK.PLUS },
    .{ .op = .Subtract, .tk = TK.MINUS },
    .{ .op = .Multiply, .tk = TK.STAR },
    .{ .op = .Divide, .tk = TK.SLASH },
    .{ .op = .Remainder, .tk = TK.REM },
    .{ .op = .BitAnd, .tk = TK.BITAND },
    .{ .op = .BitOr, .tk = TK.BITOR },
    .{ .op = .ShiftLeft, .tk = TK.LSHIFT },
    .{ .op = .ShiftRight, .tk = TK.RSHIFT },
    .{ .op = .Eq, .tk = TK.EQ },
    .{ .op = .Ne, .tk = TK.NE },
    .{ .op = .Lt, .tk = TK.LT },
    .{ .op = .Le, .tk = TK.LE },
    .{ .op = .Gt, .tk = TK.GT },
    .{ .op = .Ge, .tk = TK.GE },
    .{ .op = .ElseEq, .tk = TK.ESCAPE },
    .{ .op = .And, .tk = TK.AND },
    .{ .op = .Or, .tk = TK.OR },
    .{ .op = .Not, .tk = TK.NOT },
    .{ .op = .BitNot, .tk = TK.BITNOT },
    .{ .op = .IsNull, .tk = TK.ISNULL },
    .{ .op = .NotNull, .tk = TK.NOTNULL },
};

/// tk_is_op[tk]: whether some opcode is numbered like token `tk`.
const tk_is_op = blk: {
    var t: [256]bool = @splat(false);
    for (same_as_tk) |s| t[s.tk] = true;
    break :blk t;
};

comptime {
    @setEvalBranchQuota(100_000);
    const assert = std.debug.assert;
    // The numbers run from 0 without a gap (`infos`).
    for (@typeInfo(OP).@"enum".field_values) |value| assert(value < n_opcodes);
    for (same_as_tk) |s| assert(s.op.int() == s.tk);
    for ([_]OP{ .Ne, .Eq, .Gt, .Le, .Lt, .Ge }, 0..) |op, k| assert(op.compareIndex() == k);
    for ([_]OP{ .SeekLT, .SeekLE, .SeekGE, .SeekGT }, 0..) |op, k| assert(op.int() == OP.SeekLT.int() + k);
    assert(!OP.SeekLT.seekIsGeOrGt() and !OP.SeekLE.seekIsGeOrGt() and OP.SeekGE.seekIsGeOrGt() and OP.SeekGT.seekIsGeOrGt());
    // The registers the properties name are registers in `p`.
    for (infos, 0..) |x, value| {
        const p = x.props;
        const op_name = @tagName(@as(OP, @fromBackingInt(value)));
        if (p.in1 and x.p[0] != .reg) @compileError("in1: " ++ op_name);
        if ((p.in2 or p.out2) and x.p[1] != .reg) @compileError("p2: " ++ op_name);
        if ((p.in3 or p.out3) and x.p[2] != .reg) @compileError("p3: " ++ op_name);
    }
}

test "the properties are OPFLG_* of C" {
    // Bits as sqlite3OpcodeProperty[] has them.
    try std.testing.expectEqual(@as(u8, 0xc9), @as(u8, @bitCast(OP.SeekLT.props())));
    try std.testing.expectEqual(@as(u8, 0x26), @as(u8, @bitCast(OP.Add.props())));
    try std.testing.expectEqual(@as(u8, 0x83), @as(u8, @bitCast(OP.Yield.props())));
    try std.testing.expectEqual(@as(u8, 0x12), @as(u8, @bitCast(OP.SetSubtype.props())));
    try std.testing.expectEqualStrings("SeekLT", OP.SeekLT.name());
}
