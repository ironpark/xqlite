//! Collating sequences: the built-in BINARY, NOCASE and RTRIM (main.c)
//! and their lookup (the collation half of callback.c). Only UTF-8 is
//! supported, so each name has a single CollSeq rather than one per
//! encoding.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const ctype = @import("../util/ctype.zig");
const serial = @import("../vdbe/serial.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const CollSeq = int.CollSeq;
const RC = int.RC;

/// Both names "BINARY" in one array, at addresses that cannot be merged.
const binary_names = "BINARY\x00BINARY\x00".*;

/// sqlite3StrBINARY: the name of the default collation of an index column.
/// Code tests a collation name against it by address
/// (sqlite3KeyInfoOfIndex()), so it is not the name of the BINARY CollSeq.
pub const str_binary: [:0]const u8 = binary_names[0..6 :0];

/// The name of the BINARY CollSeq: in C a copy of its own.
const binary_name: [:0]const u8 = binary_names[7..13 :0];

/// Port of nocaseCollatingFunc(): ASCII case folding up to the shorter
/// length or the first NUL, then length.
fn nocaseCollatingFunc(_: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
    const r = ctype.strNICmp(a, b, @min(a.len, b.len));
    if (r != 0) return std.math.order(r, 0);
    return std.math.order(a.len, b.len);
}

/// Port of rtrimCollFunc(): BINARY ignoring trailing spaces.
fn rtrimCollFunc(_: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
    return serial.binaryCollation(null, std.mem.trimEnd(u8, a, " "), std.mem.trimEnd(u8, b, " "));
}

/// The collations every connection has (registered by openDatabase();
/// read-only, as a connection shadows them rather than replacing them).
const builtin = [_]CollSeq{
    .{ .name = binary_name, .cmp = serial.binaryCollation },
    .{ .name = "NOCASE", .cmp = nocaseCollatingFunc },
    .{ .name = "RTRIM", .cmp = rtrimCollFunc },
};

/// The built-in collations, which SQLite keeps in the connection's
/// aCollSeq with the others (for PRAGMA collation_list).
pub fn builtins() []const CollSeq {
    return &builtin;
}

/// db->pDfltColl: the BINARY collation.
pub fn defaultColl() *const CollSeq {
    return &builtin[0];
}

/// db->pDfltColl: the collation of a value without one. BINARY, unless
/// the dialect of the connection has another default (xqlite; see
/// dialect.Hooks.default_collation).
pub fn dfltColl(db: *Sqlite3) *const CollSeq {
    const name = @import("../dialect/dialect.zig").defaultCollationName(db) orelse return defaultColl();
    return findCollSeq(db, name, false) orelse defaultColl();
}

/// Port of sqlite3FindCollSeq(): the collation named `name`, or the
/// default one (dfltColl(), BINARY) if `name` is null. With `create`, an
/// undefined entry (null `cmp`) is made for an unknown name.
pub fn findCollSeq(db: *Sqlite3, name: ?[]const u8, create: bool) ?*const CollSeq {
    const z = name orelse return dfltColl(db);
    if (db.colls.get(z)) |c| return c;
    for (&builtin) |*c| {
        if (std.ascii.eqlIgnoreCase(c.name, z)) return c;
    }
    // xqlite: then those of the connection's dialect.
    if (@import("../dialect/dialect.zig").findCollation(db, z)) |c| return c;
    if (!create) return null;
    return addCollSeq(db, z, .{ .name = undefined });
}

/// Add `c`, named `name`, to the collations of the connection (null on
/// OOM).
fn addCollSeq(db: *Sqlite3, name: []const u8, c: CollSeq) ?*CollSeq {
    const a = db.gpa;
    const new = a.create(CollSeq) catch return null;
    const owned = a.dupeSentinel(u8, name, 0) catch {
        a.destroy(new);
        return null;
    };
    new.* = c;
    new.name = owned;
    db.colls.put(a, owned, new) catch {
        a.free(owned);
        a.destroy(new);
        return null;
    };
    return new;
}

/// Port of sqlite3GetCollSeq(): `coll` if defined, else look `name` up.
/// Leaves an error in `p` if there is no such collation.
pub fn getCollSeq(p: *Parse, coll: ?*const CollSeq, name: []const u8) ?*const CollSeq {
    const c = coll orelse findCollSeq(p.db, name, false);
    if (c == null or c.?.cmp == null) {
        util.errorMsg(p, "no such collation sequence: {s}", .{name});
        p.rc = RC.ERROR_MISSING_COLLSEQ;
        return null;
    }
    return c;
}

/// Port of sqlite3CheckCollSeq(): fine if `coll` is null or defined;
/// else (C: SQLITE_ERROR) the error is in `p`.
pub fn checkCollSeq(p: *Parse, coll: ?*const CollSeq) int.ParseError!void {
    const c = coll orelse return;
    if (c.cmp == null and getCollSeq(p, c, c.name) == null) return error.ParseFailed;
}

/// Port of sqlite3LocateCollSeq(): the collation named `name`, or null
/// with an error left in `p`.
pub fn locateCollSeq(p: *Parse, name: []const u8) ?*const CollSeq {
    const db = p.db;
    const init_busy = db.init.busy;
    const coll = findCollSeq(db, name, init_busy);
    if (!init_busy and (coll == null or coll.?.cmp == null)) {
        return getCollSeq(p, coll, name);
    }
    return coll;
}

/// Port of sqlite3_create_collation_v2() without the destructor: define
/// (or redefine) a collation of the connection.
pub fn createCollation(db: *Sqlite3, name: []const u8, user: ?*anyopaque, cmp: CollSeq.CmpFn) i32 {
    if (db.n_vdbe_active != 0) {
        @import("main.zig").errorWithMsg(db, RC.BUSY, "unable to delete/modify collation sequence due to active statements", .{});
        return RC.BUSY;
    }
    @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
    // Built-in collations are not replaced but shadowed.
    if (db.colls.get(name)) |c| {
        c.user = user;
        c.cmp = cmp;
    } else if (addCollSeq(db, name, .{ .name = undefined, .user = user, .cmp = cmp }) == null) {
        return RC.NOMEM;
    }
    return RC.OK;
}

/// Free the collations of a closing connection.
pub fn freeAll(db: *Sqlite3) void {
    var it = db.colls.iterator();
    while (it.next()) |e| {
        db.gpa.free(e.value_ptr.*.name);
        db.gpa.destroy(e.value_ptr.*);
    }
    db.colls.deinit(db.gpa);
}

test "built-in collations" {
    try std.testing.expect(defaultColl().name.ptr != str_binary.ptr);
    try std.testing.expectEqualStrings(str_binary, defaultColl().name);
    try std.testing.expectEqual(std.math.Order.eq, nocaseCollatingFunc(null, "AbC", "abc"));
    try std.testing.expectEqual(std.math.Order.lt, nocaseCollatingFunc(null, "ab", "ABC"));
    // As sqlite3StrNICmp(), the comparison stops at a NUL; then length decides.
    try std.testing.expectEqual(std.math.Order.gt, nocaseCollatingFunc(null, "a\x00bb", "a\x00c"));
    try std.testing.expectEqual(std.math.Order.eq, rtrimCollFunc(null, "ab  ", "ab"));
    try std.testing.expectEqual(std.math.Order.gt, rtrimCollFunc(null, "ab c", "ab"));
}
