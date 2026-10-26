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

/// sqlite3StrBINARY.
pub const str_binary: [:0]const u8 = "BINARY";

/// Port of nocaseCollatingFunc(): ASCII case folding, then length.
fn nocaseCollatingFunc(_: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
    return std.math.order(ctype.strICmp(a, b), 0);
}

/// Port of rtrimCollFunc(): BINARY ignoring trailing spaces.
fn rtrimCollFunc(_: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
    return serial.binaryCollation(null, std.mem.trimEnd(u8, a, " "), std.mem.trimEnd(u8, b, " "));
}

/// The collations every connection has (registered by openDatabase()).
var builtin = [_]CollSeq{
    .{ .name = str_binary, .cmp = serial.binaryCollation },
    .{ .name = "NOCASE", .cmp = nocaseCollatingFunc },
    .{ .name = "RTRIM", .cmp = rtrimCollFunc },
};

/// The built-in collations, which SQLite keeps in every connection's
/// aCollSeq (for PRAGMA collation_list).
pub fn builtins() []const CollSeq {
    return &builtin;
}

/// db->pDfltColl: the BINARY collation.
pub fn defaultColl() *CollSeq {
    return &builtin[0];
}

/// Port of sqlite3FindCollSeq(): the collation named `name`, or BINARY if
/// `name` is null. With `create`, an undefined entry (null `cmp`) is made
/// for an unknown name.
pub fn findCollSeq(db: *Sqlite3, name: ?[]const u8, create: bool) ?*CollSeq {
    const z = name orelse return defaultColl();
    if (db.colls.get(z)) |c| return c;
    for (&builtin) |*c| {
        if (std.ascii.eqlIgnoreCase(c.name, z)) return c;
    }
    if (!create) return null;
    const a = db.gpa;
    const c = a.create(CollSeq) catch return null;
    const owned = a.dupeSentinel(u8, z, 0) catch {
        a.destroy(c);
        return null;
    };
    c.* = .{ .name = owned };
    db.colls.put(a, owned, c) catch {
        a.free(owned);
        a.destroy(c);
        return null;
    };
    return c;
}

/// Port of sqlite3GetCollSeq(): `coll` if defined, else look `name` up.
/// Leaves an error in `p` if there is no such collation.
pub fn getCollSeq(p: *Parse, coll: ?*CollSeq, name: []const u8) ?*CollSeq {
    const c = coll orelse findCollSeq(p.db, name, false);
    if (c == null or c.?.cmp == null) {
        util.errorMsg(p, "no such collation sequence: {s}", .{name});
        p.rc = RC.ERROR_MISSING_COLLSEQ;
        return null;
    }
    return c;
}

/// Port of sqlite3CheckCollSeq(): OK if `coll` is null or defined.
pub fn checkCollSeq(p: *Parse, coll: ?*CollSeq) i32 {
    const c = coll orelse return RC.OK;
    if (c.cmp == null and getCollSeq(p, c, c.name) == null) return RC.ERROR;
    return RC.OK;
}

/// Port of sqlite3LocateCollSeq(): the collation named `name`, or null
/// with an error left in `p`.
pub fn locateCollSeq(p: *Parse, name: []const u8) ?*CollSeq {
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
    const c = findCollSeq(db, name, true) orelse return RC.NOMEM;
    if (@intFromPtr(c) >= @intFromPtr(&builtin[0]) and @intFromPtr(c) <= @intFromPtr(&builtin[builtin.len - 1])) {
        // Built-in collations cannot be replaced; shadow them instead.
        const a = db.gpa;
        const n = a.create(CollSeq) catch return RC.NOMEM;
        const owned = a.dupeSentinel(u8, name, 0) catch {
            a.destroy(n);
            return RC.NOMEM;
        };
        n.* = .{ .name = owned, .user = user, .cmp = cmp };
        db.colls.put(a, owned, n) catch {
            a.free(owned);
            a.destroy(n);
            return RC.NOMEM;
        };
        return RC.OK;
    }
    c.user = user;
    c.cmp = cmp;
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
    try std.testing.expectEqual(std.math.Order.eq, nocaseCollatingFunc(null, "AbC", "abc"));
    try std.testing.expectEqual(std.math.Order.lt, nocaseCollatingFunc(null, "ab", "ABC"));
    try std.testing.expectEqual(std.math.Order.eq, rtrimCollFunc(null, "ab  ", "ab"));
    try std.testing.expectEqual(std.math.Order.gt, rtrimCollFunc(null, "ab c", "ab"));
}
