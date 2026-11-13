//! Collating sequences: the built-in BINARY, NOCASE and RTRIM (main.c)
//! and their lookup (the collation half of callback.c). As in SQLite a
//! name may have a definition for each text encoding (CollSeq.enc); the
//! lookup takes the one of the database encoding, else one of another
//! encoding (synthCollSeq()), whose comparisons then convert the values
//! (serial.compareMemString()). Unlike C, the substitute is used as it
//! is rather than copied into an entry of its own.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const ctype = @import("xqlite_base").ctype;
const serial = @import("../vdbe/serial.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const CollSeq = int.CollSeq;
const RC = int.RC;
const ENC = @import("../vdbe/vdbe_int.zig").ENC;

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

/// The collations every connection has (registered by openDatabase():
/// BINARY for each encoding, NOCASE and RTRIM for UTF-8; read-only, as a
/// connection shadows them rather than replacing them).
const builtin = [_]CollSeq{
    .{ .name = binary_name, .cmp = serial.binaryCollation, .enc = ENC.UTF8 },
    .{ .name = binary_name, .cmp = serial.binaryCollation, .enc = ENC.UTF16LE },
    .{ .name = binary_name, .cmp = serial.binaryCollation, .enc = ENC.UTF16BE },
    .{ .name = "NOCASE", .cmp = nocaseCollatingFunc },
    .{ .name = "RTRIM", .cmp = rtrimCollFunc },
};

/// The built-in collations, one entry for each name, which SQLite keeps
/// in the connection's aCollSeq with the others (for PRAGMA
/// collation_list).
pub fn builtins() []const CollSeq {
    return builtin[2..];
}

/// The BINARY collation of UTF-8.
pub fn defaultColl() *const CollSeq {
    return &builtin[0];
}

/// The BINARY collation of encoding `enc`.
fn binaryColl(enc: u8) *const CollSeq {
    return &builtin[enc - 1];
}

/// db->pDfltColl: the collation of a value without one. BINARY of the
/// database encoding, unless the dialect of the connection has another
/// default (xqlite; see dialect.Hooks.default_collation).
pub fn dfltColl(db: *Sqlite3) *const CollSeq {
    return dialectColl(db) orelse binaryColl(db.enc);
}

/// Port of sqlite3SetTextEncoding() (callback.c): change the text
/// encoding of the connection, and with it the default collation.
pub fn setTextEncoding(db: *Sqlite3, enc: u8) void {
    std.debug.assert(enc == ENC.UTF8 or enc == ENC.UTF16LE or enc == ENC.UTF16BE);
    db.enc = enc;
    @import("../vdbe/aux.zig").expirePreparedStatements(db, .when_convenient);
}

/// xqlite: the default collation of the connection's dialect, null if it
/// has none (BINARY, as in the SQLite dialect).
pub fn dialectColl(db: *Sqlite3) ?*const CollSeq {
    const name = @import("../dialect/dialect.zig").defaultCollationName(db) orelse return null;
    return findCollSeq(db, name, false);
}

/// Port of sqlite3FindCollSeq() and synthCollSeq(): the collation named
/// `name` for the database encoding, or the default one (dfltColl(),
/// BINARY) if `name` is null. A name defined only for other encodings
/// gives such a definition (UTF-16be, then UTF-16le, then UTF-8, the
/// order of synthCollSeq()). With `create`, an undefined entry (null
/// `cmp`) is made for an unknown name.
pub fn findCollSeq(db: *Sqlite3, name: ?[]const u8, create: bool) ?*const CollSeq {
    const z = name orelse return dfltColl(db);
    const enc = db.enc;
    const user = db.colls.get(z);
    // Those of the connection first: they shadow the built-in ones. An
    // entry without a function (deleted, or made by `create`) gives way
    // to a definition for another encoding (synthCollSeq()).
    if (userCollSeq(db, z, enc)) |c| if (c.cmp != null) return c;
    if (builtinColl(z, enc)) |c| return c;
    for ([_]u8{ ENC.UTF16BE, ENC.UTF16LE, ENC.UTF8 }) |e| {
        if (e == enc) continue;
        var it = user;
        while (it) |c| : (it = c.next) if (c.enc == e and c.cmp != null) return c;
        if (builtinColl(z, e)) |c| return c;
    }
    if (user) |c| return c;
    // xqlite: then those of the connection's dialect.
    if (@import("../dialect/dialect.zig").findCollation(db, z)) |c| return c;
    if (!create) return null;
    return addCollSeq(db, z, .{ .name = undefined, .enc = enc });
}

/// The built-in collation `name` for encoding `enc`, if any.
fn builtinColl(name: []const u8, enc: u8) ?*const CollSeq {
    for (&builtin) |*c| if (c.enc == enc and std.ascii.eqlIgnoreCase(c.name, name)) return c;
    return null;
}

/// The definition of collation `name` for encoding `enc` made by the
/// connection, if any.
fn userCollSeq(db: *Sqlite3, name: []const u8, enc: u8) ?*CollSeq {
    var it = db.colls.get(name);
    while (it) |c| : (it = c.next) if (c.enc == enc) return c;
    return null;
}

/// Add `c`, named `name`, to the collations of the connection (null on
/// OOM): a new name, or another encoding of a name it has.
fn addCollSeq(db: *Sqlite3, name: []const u8, c: CollSeq) ?*CollSeq {
    const a = db.gpa;
    const new = a.create(CollSeq) catch return null;
    new.* = c;
    if (db.colls.get(name)) |first| {
        new.name = first.name;
        new.next = first.next;
        first.next = new;
        return new;
    }
    const owned = a.dupeSentinel(u8, name, 0) catch {
        a.destroy(new);
        return null;
    };
    new.name = owned;
    new.next = null;
    new.seq = db.colls.count();
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
    var c = coll orelse findCollSeq(p.db, name, false);
    if (c == null or c.?.cmp == null) {
        // None is defined: the collation-needed callback may define it.
        callCollNeeded(p.db, name);
        c = findCollSeq(p.db, name, false);
    }
    if (c == null or c.?.cmp == null) {
        util.errorMsgState(p, null, .of("42704"), "no such collation sequence: {s}", .{name});
        p.rc = RC.ERROR_MISSING_COLLSEQ;
        return null;
    }
    return c;
}

/// Port of callCollNeeded(): ask the application to define collation
/// `name` (sqlite3_collation_needed()).
fn callCollNeeded(db: *Sqlite3, name: []const u8) void {
    const f = db.coll_needed orelse return;
    const z = db.gpa.dupeSentinel(u8, name, 0) catch return db.oomFault();
    defer db.gpa.free(z);
    f(db.coll_needed_arg, db, z);
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
/// (or redefine) a collation of the connection, for UTF-8.
pub fn createCollation(db: *Sqlite3, name: []const u8, user: ?*anyopaque, cmp: CollSeq.CmpFn) i32 {
    return createCollationEnc(db, name, ENC.UTF8, user, cmp);
}

/// Port of createCollation() (main.c) without the destructor: define,
/// redefine or (`cmp` null) undefine collation `name` for encoding `enc`
/// (SQLITE_UTF8, UTF16LE or UTF16BE).
pub fn createCollationEnc(db: *Sqlite3, name: []const u8, enc: u8, user: ?*anyopaque, cmp: ?CollSeq.CmpFn) i32 {
    std.debug.assert(enc >= ENC.UTF8 and enc <= ENC.UTF16BE);
    // Only replacing or removing a collation (one with a function for
    // this encoding) disturbs the statements; adding one does not.
    const user_coll = userCollSeq(db, name, enc);
    const existing = if (user_coll) |c| c.cmp != null else builtinColl(name, enc) != null;
    if (existing) {
        if (db.n_vdbe_active != 0) {
            @import("main.zig").errorWithMsg(db, RC.BUSY, "unable to delete/modify collation sequence due to active statements", .{});
            return RC.BUSY;
        }
        @import("../vdbe/aux.zig").expirePreparedStatements(db, .now);
    }
    // Built-in collations are not replaced but shadowed.
    if (user_coll) |c| {
        c.user = user;
        c.cmp = cmp;
    } else if (addCollSeq(db, name, .{ .name = undefined, .enc = enc, .user = user, .cmp = cmp }) == null) {
        return RC.NOMEM;
    }
    return RC.OK;
}

/// Free the collations of a closing connection.
pub fn freeAll(db: *Sqlite3) void {
    var it = db.colls.iterator();
    while (it.next()) |e| {
        db.gpa.free(e.value_ptr.*.name);
        var c: ?*CollSeq = e.value_ptr.*;
        while (c) |x| {
            c = x.next;
            db.gpa.destroy(x);
        }
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
