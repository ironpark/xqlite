//! What P5 of an instruction is. For most opcodes it is a number (an
//! argument count, a database, the width of an integer ...); for the
//! families here it is a set of flags, each a `packed struct(u16)` with
//! the bits of C's OPFLAG_* and SQLITE_* constants (EXPLAIN and bytecode()
//! print P5 as the number). Each opcode's family is `p5` of its entry in
//! opcodes.zig's table. The code generator passes P5 to aux.emit5() and
//! its family as a value of the opcode's type, checked at compile time
//! (aux.changeP5(), for an opcode chosen at run time, asserts it), and a
//! handler reads it with that type (vi.OpFor()).

const std = @import("std");
const flags = @import("xqlite_base").flags;
const Aff = @import("../sql/sqlite_int.zig").Aff;
const NC = @import("../sql/sqlite_int.zig").NC;

/// The kind of P5 an opcode has.
pub const Family = enum {
    /// A number, or not used.
    number,
    insert,
    delete,
    open,
    column,
    compare_jump,
    compare,
    copy,
    halt,
    counter,
    type_mask,
    func,
    clear,

    /// The type of P5 of an opcode of the family.
    pub fn Type(comptime f: Family) type {
        return switch (f) {
            .number => u16,
            .insert => InsertP5,
            .delete => DeleteP5,
            .open => OpenP5,
            .column => ColumnP5,
            .compare_jump => CmpP5,
            .compare => CompareP5,
            .copy => CopyP5,
            .halt => HaltP5,
            .counter => StmtStatus,
            .type_mask => TypeMaskP5,
            .func => FuncP5,
            .clear => ClearP5,
        };
    }

    /// The family whose P5 is a `T`.
    pub fn of(comptime T: type) Family {
        inline for (comptime std.enums.values(Family)) |f| {
            if (f.Type() == T) return f;
        }
        @compileError(@typeName(T) ++ " is not the P5 of an opcode");
    }
};

/// P5 as the number an instruction stores.
pub inline fn int(x: anytype) u16 {
    const T = @TypeOf(x);
    return switch (@typeInfo(T)) {
        .@"enum" => @backingInt(x),
        .@"struct" => @bitCast(x),
        .int => x,
        else => @compileError("not a P5: " ++ @typeName(T)),
    };
}

/// The number `n` as P5 of type `T`.
pub inline fn from(comptime T: type, n: u16) T {
    return switch (@typeInfo(T)) {
        .@"enum" => @fromBackingInt(n),
        .@"struct" => @bitCast(n),
        .int => n,
        else => @compileError("not a P5: " ++ @typeName(T)),
    };
}

/// OP_Insert and OP_IdxInsert.
pub const InsertP5 = packed struct(u16) {
    /// Count the row in sqlite3_changes() (OPFLAG_NCHANGE).
    nchange: bool = false,
    /// Keep the cursor where it is (OPFLAG_SAVEPOSITION).
    save_position: bool = false,
    /// The insert of an UPDATE, for the update hook (OPFLAG_ISUPDATE).
    is_update: bool = false,
    /// The key is likely to go at the end (OPFLAG_APPEND).
    append: bool = false,
    /// The cursor is where the last seek left it (OPFLAG_USESEEKRESULT).
    use_seek_result: bool = false,
    /// Set sqlite3_last_insert_rowid() (OPFLAG_LASTROWID).
    last_rowid: bool = false,
    /// OPFLAG_ISNOOP, which only the pre-update hook reads.
    _6: u1 = 0,
    /// The record is a cell already (OP_RowCell before it,
    /// OPFLAG_PREFORMAT).
    preformat: bool = false,
    _8: u8 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const with = ops.with;
    pub const without = ops.without;
    pub const isEmpty = ops.isEmpty;

    comptime {
        flags.checkBits(InsertP5, .{ .nchange = 0x01, .save_position = 0x02, .is_update = 0x04, .append = 0x08, .use_seek_result = 0x10, .last_rowid = 0x20, .preformat = 0x80 });
    }
};

/// OP_Delete (whose P2 has OPFLAG_NCHANGE, the count of sqlite3_changes()).
pub const DeleteP5 = packed struct(u16) {
    _0: u1 = 0,
    /// Keep the cursor where it is (OPFLAG_SAVEPOSITION).
    save_position: bool = false,
    /// A delete that the b-tree may do as part of another one: the
    /// cursor need not end up anywhere in particular (OPFLAG_AUXDELETE).
    aux_delete: bool = false,
    _3: u13 = 0,

    comptime {
        flags.checkBits(DeleteP5, .{ .save_position = 0x02, .aux_delete = 0x04 });
    }
};

/// OP_OpenRead, OP_OpenWrite and OP_ReopenIdx.
pub const OpenP5 = packed struct(u16) {
    /// The cursor will insert many rows in order (OPFLAG_BULKCSR).
    bulk_csr: bool = false,
    /// Only equality seeks (OPFLAG_SEEKEQ).
    seek_eq: bool = false,
    _2: u1 = 0,
    /// The cursor is opened to delete (OPFLAG_FORDELETE).
    for_delete: bool = false,
    /// C's OPFLAG_P2ISREG (0x10) is OP_OpenWriteReg here.
    _4: u12 = 0,

    comptime {
        flags.checkBits(OpenP5, .{ .bulk_csr = 0x01, .seek_eq = 0x02, .for_delete = 0x08 });
    }
};

/// What OP_Column is to load of a column: all of it, or only what
/// length(), typeof() or octet_length() reads (OPFLAG_LENGTHARG,
/// OPFLAG_TYPEOFARG, OPFLAG_BYTELENARG).
pub const ColumnArg = enum(u2) { none = 0, length = 1, typeof = 2, octet_length = 3 };

/// OP_Column and OP_VColumn.
pub const ColumnP5 = packed struct(u16) {
    /// OP_VColumn: the column is not changed by the UPDATE; xColumn may
    /// leave it unset (OPFLAG_NOCHNG).
    nochng: bool = false,
    _1: u5 = 0,
    /// OP_Column.
    arg: ColumnArg = .none,
    _8: u8 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;

    /// The flags of Expr.op2 of a column (the low byte of P5).
    pub fn fromByte(b: u8) ColumnP5 {
        return fromInt(b);
    }

    /// The flags as Expr.op2 holds them (update.zig).
    pub fn byte(c: ColumnP5) u8 {
        return @intCast(c.int());
    }

    comptime {
        flags.checkBits(ColumnP5, .{ .nochng = 0x01, .arg = 0xc0 });
    }
};

/// OP_Eq, OP_Ne, OP_Lt, OP_Le, OP_Gt and OP_Ge. The affinity (an
/// SQLITE_AFF_* character, or 0 for none) is in the bits of
/// SQLITE_AFF_MASK (0x47), around the two flags: read and write it with
/// affinity() and init().
pub const CmpP5 = packed struct(u16) {
    aff_low: u3 = 0,
    _3: u1 = 0,
    /// Jump if either operand is NULL (SQLITE_JUMPIFNULL).
    jump_if_null: bool = false,
    _5: u1 = 0,
    aff_high: u1 = 0,
    /// NULL equals NULL and nothing else, as IS does; only OP_Eq and
    /// OP_Ne (SQLITE_NULLEQ).
    null_eq: bool = false,
    _8: u8 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const fromInt = ops.fromInt;

    /// `nulls` (its flags) with affinity `aff`.
    pub fn init(aff: u8, nulls: CmpP5) CmpP5 {
        std.debug.assert(aff & ~Aff.mask == 0 and nulls.affinity() == 0);
        return fromInt(nulls.int() | aff);
    }

    pub fn affinity(c: CmpP5) u8 {
        return @intCast(c.int() & Aff.mask);
    }

    comptime {
        // aff_low and aff_high are SQLITE_AFF_MASK; SQLITE_NOTNULL is
        // both flags.
        flags.checkBits(CmpP5, .{ .aff_low = 0x07, .jump_if_null = 0x10, .aff_high = 0x40, .null_eq = 0x80 });
        std.debug.assert(Aff.mask == 0x47);
    }
};

/// OP_Clear.
pub const ClearP5 = packed struct(u16) {
    /// Count the rows in sqlite3_changes() (C: P3 not 0).
    nchange: bool = false,
    _1: u15 = 0,
};

/// OP_Compare.
pub const CompareP5 = packed struct(u16) {
    /// P4 of the OP_Permutation before it orders the fields
    /// (OPFLAG_PERMUTE).
    permute: bool = false,
    _1: u15 = 0,

    comptime {
        flags.checkBits(CompareP5, .{ .permute = 0x01 });
    }
};

/// OP_Copy.
pub const CopyP5 = packed struct(u16) {
    /// The query planner must not merge this copy with another; not read
    /// when it runs.
    no_merge: bool = false,
    /// Clear the subtype of the copy.
    clear_subtype: bool = false,
    _2: u14 = 0,

    comptime {
        flags.checkBits(CopyP5, .{ .no_merge = 0x01, .clear_subtype = 0x02 });
    }
};

/// The constraint whose violation an OP_Halt reports (P5_Constraint*).
pub const Constraint = enum(u4) {
    none = 0,
    not_null = 1,
    unique = 2,
    check = 3,
    foreign_key = 4,

    /// How the error message names the constraint.
    pub fn words(c: Constraint) ?[]const u8 {
        return switch (c) {
            .none => null,
            .not_null => "NOT NULL",
            .unique => "UNIQUE",
            .check => "CHECK",
            .foreign_key => "FOREIGN KEY",
        };
    }
};

/// OP_Halt and OP_HaltIfNull.
pub const HaltP5 = packed struct(u16) {
    /// The kind of the error, which words its message.
    constraint: Constraint = .none,
    /// xqlite: P4 is the error of the dialect the statement was compiled
    /// in (dialect/constraint.zig), with the values of the key or row in
    /// the registers it lists.
    dialect: bool = false,
    _5: u11 = 0,

    comptime {
        // P5_ConstraintNotNull .. P5_ConstraintFK are 1 .. 4 (Constraint).
        flags.checkBits(HaltP5, .{ .constraint = 0x0f, .dialect = 0x10 });
    }
};

/// OP_IsType: the types of value that jump, a bit for each fundamental
/// datatype t (SQLITE_INTEGER .. SQLITE_NULL) at 1 << (t - 1).
pub const TypeMaskP5 = packed struct(u16) {
    integer: bool = false,
    float: bool = false,
    text: bool = false,
    blob: bool = false,
    null: bool = false,
    _5: u11 = 0,

    const ops = flags.Ops(@This());
    pub const int = ops.int;
    pub const intersects = ops.intersects;

    /// The fundamental datatype `t` (sqlite3_value_type()) alone.
    pub fn of(t: i32) TypeMaskP5 {
        return ops.fromInt(@as(u16, 1) << @intCast(t - 1));
    }

    pub const any: TypeMaskP5 = .{ .integer = true, .float = true, .text = true, .blob = true, .null = true };

    comptime {
        flags.checkBits(TypeMaskP5, .{ .integer = 0x01, .float = 0x02, .text = 0x04, .blob = 0x08, .null = 0x10 });
    }
};

/// OP_PureFunc and OP_Function: what the expression of an OP_PureFunc is
/// in, for the error of a non-deterministic function (the bits of
/// NC_SelfRef of NameContext.nc_flags, at the same places).
pub const FuncP5 = packed struct(u16) {
    _0: u1 = 0,
    part_idx: bool = false,
    is_check: bool = false,
    gen_col: bool = false,
    _4: u1 = 0,
    idx_expr: bool = false,
    _6: u10 = 0,

    pub const isEmpty = flags.Ops(@This()).isEmpty;

    /// The NC_SelfRef flags of `nc` (NameContext.nc_flags, or Expr.op2
    /// of a function, which holds them).
    pub fn fromNC(nc: NC) FuncP5 {
        return @bitCast(@as(u16, @intCast(nc.only(NC.SelfRef).int())));
    }

    comptime {
        flags.checkBits(FuncP5, .{
            .part_idx = NC.int(.{ .PartIdx = true }),
            .is_check = NC.int(.{ .IsCheck = true }),
            .gen_col = NC.int(.{ .GenCol = true }),
            .idx_expr = NC.int(.{ .IdxExpr = true }),
        });
        std.debug.assert(NC.SelfRef.int() == 0x2e);
    }
};

/// The counters of sqlite3_stmt_status() (SQLITE_STMTSTATUS_*, which are
/// these numbers), and the P5 of OP_Next, OP_Prev and OP_SorterNext: the
/// counter of each step after the first.
pub const StmtStatus = enum(u16) {
    /// P5 of a loop that counts nothing. Its counter is never read.
    none = 0,
    fullscan_step = 1,
    sort = 2,
    autoindex = 3,
    vm_step = 4,
    reprepare = 5,
    run = 6,
    filter_miss = 7,
    filter_hit = 8,
};

// The bit layouts are checked by flags.checkBits() in each type; these are
// the values inside a field of several bits.
test "P5 values are those of C" {
    const t = std.testing;
    // OPFLAG_LENGTHARG, OPFLAG_TYPEOFARG, OPFLAG_BYTELENARG.
    try t.expectEqual(@as(u16, 0x40), int(ColumnP5{ .arg = .length }));
    try t.expectEqual(@as(u16, 0x80), int(ColumnP5{ .arg = .typeof }));
    try t.expectEqual(@as(u16, 0xc0), int(ColumnP5{ .arg = .octet_length }));
    try t.expectEqual(@as(u16, 0x43 | 0x10), int(CmpP5.init(Aff.numeric, .{ .jump_if_null = true })));
    try t.expectEqual(Aff.text, CmpP5.init(Aff.text, .{ .null_eq = true }).affinity());
    try t.expectEqual(Aff.none, CmpP5.init(Aff.none, .{}).affinity());
    try t.expectEqual(@as(u16, 1), int(HaltP5{ .constraint = .not_null }));
    try t.expectEqual(@as(u16, 2), int(HaltP5{ .constraint = .unique }));
    try t.expectEqual(@as(u16, 3), int(HaltP5{ .constraint = .check }));
    try t.expectEqual(@as(u16, 4), int(HaltP5{ .constraint = .foreign_key }));
    try t.expectEqual(@as(u16, 1), int(StmtStatus.fullscan_step));
    try t.expectEqual(@as(u16, 3), int(StmtStatus.autoindex));
    try t.expectEqual(@as(u16, 8), int(StmtStatus.filter_hit));
}
