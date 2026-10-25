//! ALTER TABLE (port of alter.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;
const Token = int.Token;
const SrcList = int.SrcList;
const Expr = int.Expr;

/// Port of sqlite3RenameTokenMap(): remember which token an object name
/// came from, for ALTER TABLE ... RENAME. Only used in rename mode.
pub fn renameTokenMap(p: *Parse, ptr: anytype, t: Token) void {
    _ = .{ p, ptr, t };
}

/// Port of sqlite3RenameTokenRemap().
pub fn renameTokenRemap(p: *Parse, to: ?*const anyopaque, from: ?*const anyopaque) void {
    _ = .{ p, to, from };
}

/// Port of sqlite3AlterRenameTable().
pub fn renameTable(p: *Parse, src: ?*SrcList, name: Token) void {
    _ = .{ src, name };
    pending.notYet(p, "ALTER TABLE RENAME");
}

/// Port of sqlite3AlterBeginAddColumn().
pub fn beginAddColumn(p: *Parse, src: ?*SrcList) void {
    _ = src;
    pending.notYet(p, "ALTER TABLE ADD COLUMN");
}

/// Port of sqlite3AlterFinishAddColumn().
pub fn finishAddColumn(p: *Parse, col_def: Token) void {
    _ = .{ p, col_def };
}

/// Port of sqlite3AlterDropColumn().
pub fn dropColumn(p: *Parse, src: ?*SrcList, name: Token) void {
    _ = .{ src, name };
    pending.notYet(p, "ALTER TABLE DROP COLUMN");
}

/// Port of sqlite3AlterRenameColumn().
pub fn renameColumn(p: *Parse, src: ?*SrcList, old: Token, new: Token) void {
    _ = .{ src, old, new };
    pending.notYet(p, "ALTER TABLE RENAME COLUMN");
}

/// Port of sqlite3AlterDropConstraint().
pub fn dropConstraint(p: *Parse, src: ?*SrcList, cons: ?Token, col: ?Token) void {
    _ = .{ src, cons, col };
    pending.notYet(p, "ALTER TABLE DROP CONSTRAINT");
}

/// Port of sqlite3AlterSetNotNull().
pub fn setNotNull(p: *Parse, src: ?*SrcList, col: Token, first: Token) void {
    _ = .{ src, col, first };
    pending.notYet(p, "ALTER TABLE SET NOT NULL");
}

/// Port of sqlite3AlterAddConstraint().
pub fn addConstraint(p: *Parse, src: ?*SrcList, first: Token, cons: ?Token, text: [*]const u8, n: usize, e: ?*Expr) void {
    _ = .{ src, first, cons, text, n, e };
    pending.notYet(p, "ALTER TABLE ADD CONSTRAINT");
}
