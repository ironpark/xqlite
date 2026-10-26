//! Foreign keys (port of fkey.c). Only the schema bookkeeping is ported
//! so far; enforcement comes with INSERT, UPDATE and DELETE.

const int = @import("sqlite_int.zig");

/// Port of sqlite3FkDelete(): unlink the foreign keys of a table being
/// freed from its schema's fkey_hash. Their memory belongs to the table.
pub fn fkDelete(db: *int.Sqlite3, t: *int.Table) void {
    _ = db;
    std.debug.assert(t.isOrdinary());
    var fk_opt = t.u.tab.fkey;
    while (fk_opt) |fk| : (fk_opt = fk.next_from) {
        if (fk.prev_to) |prev| {
            prev.next_to = fk.next_to;
        } else if (t.schema) |s| {
            if (fk.next_to) |next| {
                if (s.fkey_hash.getPtr(next.to)) |slot| slot.* = next;
            } else {
                _ = s.fkey_hash.remove(fk.to);
            }
        }
        if (fk.next_to) |next| next.prev_to = fk.prev_to;
    }
}

const std = @import("std");

const pending = @import("pending.zig");
const Parse = int.Parse;
const Table = int.Table;

/// Port of sqlite3FkReferences(): the foreign keys that refer to `t`.
pub fn fkReferences(t: *Table) ?*int.FKey {
    const s = t.schema orelse return null;
    return s.fkey_hash.get(t.name);
}

/// Port of sqlite3FkRequired(): nonzero if writing `t` needs foreign key
/// processing (2 if a parent key may change). Enforcement is not ported
/// yet, so it is an error while PRAGMA foreign_keys is on.
pub fn fkRequired(p: *Parse, t: *Table, ai_chng: ?[]const i32, chng_rowid: bool) u8 {
    _ = .{ ai_chng, chng_rowid };
    notPorted(p, t);
    return 0;
}

/// Port of sqlite3FkCheck(). Enforcement is not ported yet: an error while
/// PRAGMA foreign_keys is on and `t` has or is the parent of foreign keys.
pub fn fkCheck(p: *Parse, t: *Table, reg_old: i32, reg_new: i32, ai_chng: ?[]const i32, chng_rowid: bool) void {
    _ = .{ reg_old, reg_new, ai_chng, chng_rowid };
    notPorted(p, t);
}

fn notPorted(p: *Parse, t: *Table) void {
    if (p.db.flags & int.DbFlag.ForeignKeys == 0 or !t.isOrdinary()) return;
    if (t.u.tab.fkey != null or fkReferences(t) != null) pending.notYet(p, "foreign key enforcement");
}

/// Port of sqlite3FkActions().
pub fn fkActions(p: *Parse, t: *Table, changes: ?*int.ExprList, reg_old: i32, ai_chng: ?[]const i32, chng_rowid: bool) void {
    _ = .{ p, t, changes, reg_old, ai_chng, chng_rowid };
}

/// Port of sqlite3FkOldmask().
pub fn fkOldmask(p: *Parse, t: *Table) u32 {
    _ = .{ p, t };
    return 0;
}
