//! Function and collation lookup (port of callback.c).

const int = @import("sqlite_int.zig");

const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;

/// FuncDef.func_flags (SQLITE_FUNC_*).
pub const FUNC = struct {
    pub const ENCMASK: u32 = 0x0003;
    pub const LIKE: u32 = 0x0004;
    pub const CASE: u32 = 0x0008;
    pub const EPHEM: u32 = 0x0010;
    pub const NEEDCOLL: u32 = 0x0020;
    pub const LENGTH: u32 = 0x0040;
    pub const TYPEOF: u32 = 0x0080;
    pub const BYTELEN: u32 = 0x00c0;
    pub const COUNT: u32 = 0x0100;
    pub const UNLIKELY: u32 = 0x0400;
    pub const CONSTANT: u32 = 0x0800;
    pub const MINMAX: u32 = 0x1000;
    pub const SLOCHNG: u32 = 0x2000;
    pub const TEST: u32 = 0x4000;
    pub const RUNONLY: u32 = 0x8000;
    pub const WINDOW: u32 = 0x00010000;
    pub const INTERNAL: u32 = 0x00040000;
    pub const DIRECT: u32 = 0x00080000;
    pub const SUBTYPE: u32 = 0x00100000;
    pub const UNSAFE: u32 = 0x00200000;
    pub const INLINE: u32 = 0x00400000;
    pub const BUILTIN: u32 = 0x00800000;
    pub const RESULT_SUBTYPE: u32 = 0x01000000;
    pub const SELFORDER1: u32 = 0x02000000;
    pub const ANYORDER: u32 = 0x08000000;
};

/// Port of sqlite3FindFunction(). The function tables arrive with the
/// VDBE; until then no function is known.
pub fn findFunction(db: *Sqlite3, name: []const u8, n_arg: i32, enc: u8, create: bool) ?*FuncDef {
    _ = .{ db, name, n_arg, enc, create };
    return null;
}
