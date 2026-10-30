//! The authorizer (port of auth.c): statements are checked while they
//! are compiled, against the callback the application registered
//! (Sqlite3.auth, set by sqlite3_set_authorizer()). Without one, every
//! check is a single test of a null pointer.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const prepare = @import("prepare.zig");
const walker = @import("walker.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const SrcList = int.SrcList;
const Schema = int.Schema;
const Table = int.Table;
const TK = int.TK;
const RC = int.RC;

/// The authorizer's results (SQLITE_OK, SQLITE_DENY, SQLITE_IGNORE).
pub const OK: i32 = 0;
pub const DENY: i32 = 1;
pub const IGNORE: i32 = 2;

/// The action codes passed to the authorizer (SQLITE_CREATE_INDEX ...).
pub const Code = struct {
    pub const CREATE_INDEX: i32 = 1;
    pub const CREATE_TABLE: i32 = 2;
    pub const CREATE_TEMP_INDEX: i32 = 3;
    pub const CREATE_TEMP_TABLE: i32 = 4;
    pub const CREATE_TEMP_TRIGGER: i32 = 5;
    pub const CREATE_TEMP_VIEW: i32 = 6;
    pub const CREATE_TRIGGER: i32 = 7;
    pub const CREATE_VIEW: i32 = 8;
    pub const DELETE: i32 = 9;
    pub const DROP_INDEX: i32 = 10;
    pub const DROP_TABLE: i32 = 11;
    pub const DROP_TEMP_INDEX: i32 = 12;
    pub const DROP_TEMP_TABLE: i32 = 13;
    pub const DROP_TEMP_TRIGGER: i32 = 14;
    pub const DROP_TEMP_VIEW: i32 = 15;
    pub const DROP_TRIGGER: i32 = 16;
    pub const DROP_VIEW: i32 = 17;
    pub const INSERT: i32 = 18;
    pub const PRAGMA: i32 = 19;
    pub const READ: i32 = 20;
    pub const SELECT: i32 = 21;
    pub const TRANSACTION: i32 = 22;
    pub const UPDATE: i32 = 23;
    pub const ATTACH: i32 = 24;
    pub const DETACH: i32 = 25;
    pub const ALTER_TABLE: i32 = 26;
    pub const REINDEX: i32 = 27;
    pub const ANALYZE: i32 = 28;
    pub const CREATE_VTABLE: i32 = 29;
    pub const DROP_VTABLE: i32 = 30;
    pub const FUNCTION: i32 = 31;
    pub const SAVEPOINT: i32 = 32;
    pub const RECURSIVE: i32 = 33;
};

/// The authorizer (sqlite3_xauth): the action code, up to four details
/// (null or NUL-terminated) and the trigger or view the action is coded
/// for; returns OK, DENY or IGNORE.
pub const Callback = *const fn (arg: ?*anyopaque, code: i32, a1: ?[*:0]const u8, a2: ?[*:0]const u8, a3: ?[*:0]const u8, context: ?[*:0]const u8) i32;

/// Port of sqlite3_set_authorizer(): install or remove the authorizer.
/// Prepared statements are expired, since their checks were made with
/// the previous one.
pub fn setAuthorizer(db: *int.Sqlite3, f: ?Callback, arg: ?*anyopaque) void {
    db.auth = f;
    db.auth_arg = arg;
    @import("../vdbe/aux.zig").expirePreparedStatements(db, 1);
}

/// A NUL-terminated copy of `s` in the statement's memory, for the
/// authorizer.
fn cstr(p: *Parse, s: ?[]const u8) ?[*:0]const u8 {
    const z = s orelse return null;
    const copy = p.arena.dupeSentinel(u8, z, 0) catch {
        p.db.oomFault();
        return "";
    };
    return copy.ptr;
}

/// sqliteAuthBadReturnCode().
fn badReturnCode(p: *Parse) void {
    util.errorMsg(p, "authorizer malfunction", .{});
    p.rc = RC.ERROR;
}

/// Port of sqlite3AuthReadCol(): may column `col` of table `tab` in
/// database `i_db` be read? DENY is an error; IGNORE asks the caller to
/// read NULL instead.
pub fn readCol(p: *Parse, tab: [:0]const u8, col: [:0]const u8, i_db: usize) i32 {
    const db = p.db;
    if (db.init.busy) return OK;
    const zdb = db.dbs.items[i_db].name;
    const rc = db.auth.?(db.auth_arg, Code.READ, tab.ptr, col.ptr, zdb.ptr, p.auth_context);
    if (rc == DENY) {
        if (db.dbs.items.len > 2 or i_db != 0) {
            util.errorMsg(p, "access to {s}.{s}.{s} is prohibited", .{ zdb, tab, col });
        } else {
            util.errorMsg(p, "access to {s}.{s} is prohibited", .{ tab, col });
        }
        p.rc = RC.AUTH;
    } else if (rc != IGNORE and rc != OK) {
        badReturnCode(p);
    }
    return rc;
}

/// Port of sqlite3AuthRead(): check the read of the TK_COLUMN (or
/// TK_TRIGGER) `e` of one of the tables of `tab_list`; if the authorizer
/// says IGNORE, `e` becomes a NULL.
pub fn read(p: *Parse, e: *Expr, schema: ?*Schema, tab_list: ?*SrcList) void {
    std.debug.assert(e.op == TK.COLUMN or e.op == TK.TRIGGER);
    std.debug.assert(p.db.auth != null);
    // A column of a subquery or other temporary table.
    if (schema == null) return;
    const i_db: usize = @intCast(prepare.schemaToIndex(p.db, schema));

    var t: ?*Table = null;
    if (e.op == TK.TRIGGER) {
        t = p.trigger_tab;
    } else if (tab_list) |list| {
        for (list.slice()) |*item| {
            if (e.i_table == item.i_cursor) {
                t = item.s_tab;
                break;
            }
        }
    }
    const tab = t orelse return;
    const i_col: i32 = e.i_column;
    const col: [:0]const u8 = if (i_col >= 0)
        tab.cols[@intCast(i_col)].cn_name
    else if (tab.i_pkey >= 0)
        tab.cols[@intCast(tab.i_pkey)].cn_name
    else
        "ROWID";
    if (readCol(p, tab.name, col, i_db) == IGNORE) e.op = TK.NULL;
}

/// realAuthCheck().
noinline fn realCheck(p: *Parse, code: i32, a1: ?[]const u8, a2: ?[]const u8, a3: ?[]const u8) i32 {
    const db = p.db;
    // No checks while sqlite3_declare_vtab() or ALTER parses.
    if (p.inSpecialParse()) return OK;
    var rc = db.auth.?(db.auth_arg, code, cstr(p, a1), cstr(p, a2), cstr(p, a3), p.auth_context);
    if (rc == DENY) {
        util.errorMsg(p, "not authorized", .{});
        p.rc = RC.AUTH;
    } else if (rc != OK and rc != IGNORE) {
        rc = DENY;
        badReturnCode(p);
    }
    return rc;
}

/// Port of sqlite3AuthCheck(): ask the authorizer about action `code`.
/// OK goes on; DENY (an error is left in `p`) and IGNORE skip the action.
pub inline fn check(p: *Parse, code: i32, a1: ?[]const u8, a2: ?[]const u8, a3: ?[]const u8) i32 {
    if (p.db.auth == null or p.db.init.busy) return OK;
    return realCheck(p, code, a1, a2, a3);
}

/// The saved context of contextPush() (AuthContext).
pub const Context = struct {
    parse: ?*Parse = null,
    context: ?[*:0]const u8 = null,
};

/// Port of sqlite3AuthContextPush(): the checks that follow are made on
/// behalf of trigger or view `name`.
pub fn contextPush(p: *Parse, ctx: *Context, name: ?[*:0]const u8) void {
    ctx.parse = p;
    ctx.context = p.auth_context;
    p.auth_context = name;
}

/// Port of sqlite3AuthContextPop().
pub fn contextPop(ctx: *Context) void {
    if (ctx.parse) |p| {
        p.auth_context = ctx.context;
        ctx.parse = null;
    }
}

/// authFunctions().
fn authFunctions(w: *walker.Walker, e: *Expr) walker.WRC {
    if (e.op == TK.FUNCTION) {
        const p = w.parse.?;
        if (check(p, Code.FUNCTION, null, e.token(), null) != OK) {
            errorAtFunction(p, e);
            return .Abort;
        }
    }
    return .Continue;
}

/// "not authorized to use function: %#T".
pub fn errorAtFunction(p: *Parse, e: *const Expr) void {
    util.errorMsg(p, "not authorized to use function: {s}", .{e.token()});
    @import("expr.zig").recordErrorOffsetOfExpr(p, e);
}

/// Port of sqlite3FuncAuth(): send every function `e` calls to the
/// authorizer, an error if one is refused.
pub fn funcAuth(p: *Parse, e: ?*Expr) void {
    var w: walker.Walker = .{ .parse = p, .expr_callback = authFunctions };
    _ = walker.walkExpr(&w, e);
}

// ================================================================ tests

const Conn = @import("sql_test.zig").Conn;

/// A test authorizer: logs "CODE a1 a2 a3 ctx;" and answers `answer`
/// for action `code` on `arg` (a1 or a2).
const TestAuth = struct {
    log: std.ArrayList(u8) = .empty,
    code: i32 = -1,
    arg: []const u8 = "",
    answer: i32 = OK,

    fn z(x: ?[*:0]const u8) []const u8 {
        return if (x) |y| std.mem.span(y) else "-";
    }

    fn cb(p: ?*anyopaque, code: i32, a1: ?[*:0]const u8, a2: ?[*:0]const u8, a3: ?[*:0]const u8, ctx: ?[*:0]const u8) i32 {
        const t: *TestAuth = @ptrCast(@alignCast(p.?));
        t.log.print(std.testing.allocator, "{d} {s} {s} {s} {s};", .{ code, z(a1), z(a2), z(a3), z(ctx) }) catch {};
        if (code == t.code and (std.mem.eql(u8, z(a1), t.arg) or std.mem.eql(u8, z(a2), t.arg))) return t.answer;
        return OK;
    }

    fn expectLog(t: *TestAuth, expected: []const u8) !void {
        defer t.log.clearRetainingCapacity();
        try std.testing.expectEqualStrings(expected, t.log.items);
    }
};

test "the authorizer sees reads, writes and the trigger context" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b); CREATE TABLE log(x);" ++
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES(new.b); END");
    var ta: TestAuth = .{};
    defer ta.log.deinit(std.testing.allocator);
    setAuthorizer(c.db, TestAuth.cb, &ta);
    defer setAuthorizer(c.db, null, null);

    try c.exec("INSERT INTO t VALUES(1, 'x')");
    try ta.expectLog("18 t - main -;18 log - main tr;20 t b main tr;");
    try c.expectRows("SELECT count(*) FROM t", "1\n");
    try ta.expectLog("21 - - - -;31 - count - -;20 t  - -;");
}

test "DENY is an SQLITE_AUTH error, IGNORE reads NULL" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a, b); INSERT INTO t VALUES(1, 2)");
    var ta: TestAuth = .{ .code = Code.READ, .arg = "b", .answer = IGNORE };
    defer ta.log.deinit(std.testing.allocator);
    setAuthorizer(c.db, TestAuth.cb, &ta);
    defer setAuthorizer(c.db, null, null);

    try c.expectRows("SELECT a, b FROM t", "1|NULL\n");
    ta.answer = DENY;
    try c.expectError("SELECT a, b FROM t", "access to t.b is prohibited");
    try std.testing.expectEqual(RC.AUTH, c.db.err_code);
    ta.code = Code.FUNCTION;
    ta.arg = "abs";
    try c.expectError("SELECT abs(a) FROM t", "not authorized to use function: abs");
    ta.answer = 7;
    try c.expectError("SELECT abs(a) FROM t", "not authorized to use function: abs");
    try std.testing.expectEqual(RC.ERROR, c.db.err_code);
    ta.code = Code.INSERT;
    ta.arg = "t";
    ta.answer = DENY;
    try c.expectError("INSERT INTO t VALUES(3, 4)", "not authorized");
}
