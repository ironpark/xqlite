//! The operands of VDBE instructions as types of their own: a register,
//! a cursor, a label and an address are all numbers in the program, but
//! the code generator should not be able to pass one for another.
//! `kinds()` says what each operand of each opcode is, and `aux.emit()`
//! checks its arguments against it when the statement is compiled.
//!
//! The code generator was ported from C with `i32` for all of these. A
//! file moves to these types on its own; `.int()` and `.from()` convert
//! where it meets one that has not moved yet.

const std = @import("std");
const opcodes = @import("opcodes.zig");
const OP = opcodes.OP;

/// A register: r[1] is the first, `none` (0) is no register.
pub const Reg = enum(i32) {
    none = 0,
    _,

    pub fn from(i: i32) Reg {
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(r: Reg) i32 {
        return @backingInt(r);
    }

    /// The register `i` after this one, of a run of registers.
    pub fn at(r: Reg, i: anytype) Reg {
        return @fromBackingInt(@intCast(@backingInt(r) + @as(i32, @intCast(i))));
    }

    pub fn isNone(r: Reg) bool {
        return r == .none;
    }
};

/// A cursor number.
pub const Cursor = enum(i32) {
    _,

    pub fn from(i: i32) Cursor {
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(c: Cursor) i32 {
        return @backingInt(c);
    }

    /// The cursor `i` after this one (the indexes of a table follow it).
    pub fn at(c: Cursor, i: anytype) Cursor {
        return @fromBackingInt(@intCast(@backingInt(c) + @as(i32, @intCast(i))));
    }
};

/// A place in the program that is not known yet (aux.newLabel()): a
/// negative number until the program is finished.
pub const Label = enum(i32) {
    _,

    pub fn from(i: i32) Label {
        std.debug.assert(i < 0);
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(l: Label) i32 {
        return @backingInt(l);
    }
};

/// The address of an instruction.
pub const Addr = enum(i32) {
    _,

    pub fn from(i: i32) Addr {
        return @fromBackingInt(@intCast(i));
    }

    pub fn int(a: Addr) i32 {
        return @backingInt(a);
    }

    /// The instruction `n` after this one.
    pub fn plus(a: Addr, n: i32) Addr {
        return @fromBackingInt(@intCast(@backingInt(a) + n));
    }
};

/// What an operand is.
pub const Kind = enum {
    /// A number, or not used.
    int,
    reg,
    cursor,
    /// Where to jump: a Label or an Addr.
    jump,
};

/// What P1, P2 and P3 of `op` are. An operand that is a register only in
/// some uses of the opcode (OP_Clear's P3, OP_OpenRead's P2 with
/// OPFLAG_P2ISREG) is `.int`.
pub fn kinds(op: OP) [3]Kind {
    const i = Kind.int;
    const r = Kind.reg;
    const c = Kind.cursor;
    const j = Kind.jump;
    return switch (op) {
        // Transactions and the schema.
        .Savepoint, .AutoCommit, .Transaction, .SetCookie, .TableLock => .{ i, i, i },
        .Checkpoint => .{ i, i, r },
        .JournalMode, .Vacuum, .ReadCookie, .Pagecount, .MaxPgcnt => .{ i, r, i },
        .Destroy, .CreateBtree => .{ i, r, i },
        .Clear, .SqlExec, .ParseSchema, .LoadAnalysis, .DropTable, .DropIndex, .DropTrigger, .Expire => .{ i, i, i },
        .IntegrityCk => .{ r, i, r },

        // Control.
        .Init, .Goto, .Once, .ElseEq, .FkIfZero, .IncrVacuum => .{ i, j, i },
        .Gosub, .InitCoroutine, .Yield, .MustBeInt, .If, .IfNot, .IsNull, .NotNull => .{ r, j, i },
        .IfPos, .IfNotZero, .DecrJumpZero => .{ r, j, i },
        .Jump => .{ i, j, i },
        .Return, .EndCoroutine => .{ r, i, i },
        .HaltIfNull => .{ i, i, r },
        .Halt, .FkCheck, .FkCounter, .ResetCount, .Permutation, .Trace, .Noop, .Explain, .Abortable => .{ i, i, i },
        .Program => .{ r, j, r },
        .Param => .{ i, r, i },

        // Constants and registers.
        .Integer, .Int64, .Real, .String8, .String, .Blob, .Variable, .BeginSubrtn => .{ i, r, i },
        .Null => .{ i, r, r },
        .SoftNull, .RealAffinity, .ClrSubtype, .VRename, .CollSeq => .{ r, i, i },
        .Move, .Copy => .{ r, r, i },
        .SCopy, .IntCopy, .Not, .BitNot, .MemMax, .GetSubtype, .SetSubtype, .RowSetAdd => .{ r, r, i },
        .ResultRow, .AddImm, .Cast, .TypeCheck, .Affinity, .ReleaseReg => .{ r, i, i },
        .Compare, .IsTrue => .{ r, r, i },
        .MakeRecord => .{ r, i, r },

        // Arithmetic, comparisons and logic.
        .Or, .And, .BitAnd, .BitOr, .ShiftLeft, .ShiftRight => .{ r, r, r },
        .Add, .Subtract, .Multiply, .Divide, .Remainder, .Concat => .{ r, r, r },
        .ZeroOrNull, .OffsetLimit => .{ r, r, r },
        .Ne, .Eq, .Gt, .Le, .Lt, .Ge => .{ r, j, r },

        // Functions and aggregates.
        .PureFunc, .Function, .AggInverse, .AggStep, .AggStep1 => .{ i, r, r },
        .AggValue => .{ r, i, r },
        .AggFinal => .{ r, i, i },

        // Opening and closing cursors.
        .OpenRead, .OpenWrite, .ReopenIdx, .OpenAutoindex, .OpenEphemeral, .SorterOpen => .{ c, i, i },
        .OpenDup => .{ c, c, i },
        .OpenPseudo => .{ c, r, i },
        .Close, .ColumnsUsed, .NullRow, .SeekEnd, .FinishSeek, .ResetSorter, .CursorLock, .CursorUnlock, .CursorHint => .{ c, i, i },
        .SequenceTest, .SeekHit, .Delete => .{ c, i, i },

        // Moving cursors.
        .SeekLT, .SeekLE, .SeekGE, .SeekGT, .IfNoHope, .NoConflict, .NotFound, .Found => .{ c, j, r },
        .SeekRowid, .NotExists, .IdxLE, .IdxGT, .IdxLT, .IdxGE, .IFindKey, .IfNullRow => .{ c, j, r },
        .Last, .IfSizeBetween, .SorterSort, .Sort, .Rewind, .IfEmpty, .SorterNext, .Prev, .Next => .{ c, j, i },
        .SeekScan => .{ i, i, i },
        .IsType => .{ i, j, i },

        // Reading and writing rows.
        .Column, .Offset => .{ c, i, r },
        .Count, .Sequence, .Rowid, .RowData, .SorterInsert => .{ c, r, i },
        .NewRowid, .Insert, .IdxInsert => .{ c, r, r },
        .RowCell => .{ c, c, r },
        // P2 is an address, never a label (the opcode is not OPFLG_JUMP).
        .SorterCompare => .{ c, i, r },
        .SorterData => .{ c, r, c },
        .IdxDelete => .{ c, r, i },
        .DeferredSeek => .{ c, i, c },
        .IdxRowid => .{ c, r, i },

        // RowSets and Bloom filters.
        .RowSetRead, .RowSetTest, .Filter => .{ r, j, r },
        .FilterAdd => .{ r, i, r },

        // Virtual tables.
        .VFilter => .{ c, j, r },
        .VUpdate => .{ i, i, r },
        .VNext => .{ c, j, i },
        .VBegin, .VDestroy => .{ i, i, i },
        .VCreate, .VCheck => .{ i, r, i },
        .VOpen => .{ c, i, i },
        .VInitIn => .{ c, r, r },
        .VColumn => .{ c, i, r },
    };
}

comptime {
    // P2 is a jump exactly where the opcode table says so, and the
    // registers it knows of (OPFLG_IN1 ... OUT3) are registers here.
    @setEvalBranchQuota(20_000);
    for (std.enums.values(OP)) |op| {
        const k = kinds(op);
        const prop = opcodes.properties[@backingInt(op)];
        const F = opcodes.OPFLG;
        if ((prop & F.JUMP != 0) != (k[1] == .jump)) @compileError("jump: " ++ @tagName(op));
        if (prop & F.IN1 != 0 and k[0] != .reg) @compileError("in1: " ++ @tagName(op));
        if (prop & (F.IN2 | F.OUT2) != 0 and k[1] != .reg) @compileError("p2: " ++ @tagName(op));
        if (prop & (F.IN3 | F.OUT3) != 0 and k[2] != .reg) @compileError("p3: " ++ @tagName(op));
    }
}

/// The number of an argument of aux.emit() for an operand of `kind`.
pub inline fn value(comptime op: OP, comptime n: usize, comptime kind: Kind, arg: anytype) i32 {
    const T = @TypeOf(arg);
    const name = @tagName(op) ++ " P" ++ .{'1' + n};
    // 0 is "not used" for an operand of any kind.
    if (T == comptime_int) {
        if (arg != 0 and kind != .int) @compileError(name ++ " is a " ++ @tagName(kind) ++ ", not a number");
        return arg;
    }
    switch (kind) {
        .int => switch (@typeInfo(T)) {
            .int => return @intCast(arg),
            .bool => return @intFromBool(arg),
            else => @compileError(name ++ " is a number, not " ++ @typeName(T)),
        },
        .reg => if (T != Reg) @compileError(name ++ " is a register, not " ++ @typeName(T)),
        .cursor => if (T != Cursor) @compileError(name ++ " is a cursor, not " ++ @typeName(T)),
        .jump => if (T != Label and T != Addr) @compileError(name ++ " is a jump (Label or Addr), not " ++ @typeName(T)),
    }
    return @backingInt(arg);
}
