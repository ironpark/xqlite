//! ATTACH and DETACH (port of attach.c).
//!
//! As in C, the statements code a call of an internal SQL function,
//! sqlite_attach(file, name, key) or sqlite_detach(name), which does the
//! work when the statement runs. Code that needs a database of its own
//! (VACUUM) runs an ATTACH statement and later drops the entry with
//! closeDb().

const std = @import("std");
const int = @import("sqlite_int.zig");
const btree = @import("../btree/btree.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const api = @import("../vdbe/api.zig");
const expr_mod = @import("expr.zig");
const expr_code = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const prepare = @import("prepare.zig");
const main_mod = @import("main.zig");
const malloc = @import("malloc.zig");
const uri = @import("uri.zig");
const ctype = @import("../util/ctype.zig");

const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const Mem = vi.Mem;
const Context = vi.Context;
const RC = int.RC;
const OP = vi.OP;

/// Port of resolveAttachExpr(): a bare identifier at the root of an
/// ATTACH or DETACH operand is a string, not a column name.
fn resolveAttachExpr(nc: *int.NameContext, e_arg: ?*Expr) int.ParseError!void {
    const e = e_arg orelse return;
    if (e.op != TK.ID) {
        try resolve.resolveExprNames(nc, e);
    } else {
        e.op = TK.STRING;
    }
}

/// Port of detachTempTriggers(): TEMP triggers on tables of `schema` now
/// refer to TEMP itself.
fn detachTempTriggers(db: *Sqlite3, schema: *Schema) void {
    var it = db.dbs.items[1].schema.trig_hash.valueIterator();
    while (it.next()) |trig| {
        if (trig.*.tab_schema == schema) trig.*.tab_schema = trig.*.schema;
    }
}

/// sqlite3_result_error() with a message made by `fmt`.
fn resultErrorFmt(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        // A long name: the message is made in memory instead.
        const db = api.contextDbHandle(ctx);
        const m = std.fmt.allocPrint(db.gpa, fmt, args) catch {
            api.resultErrorNomem(ctx);
            return;
        };
        defer db.gpa.free(m);
        api.resultError(ctx, m);
        return;
    };
    api.resultError(ctx, msg);
}

/// Port of attachFunc(): sqlite_attach(file, name, key), the work of
/// ATTACH DATABASE file AS name KEY key. The key is ignored.
fn attachFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const gpa = db.gpa;
    const file: [:0]const u8 = api.valueText(argv[0]) orelse "";
    const name: [:0]const u8 = api.valueText(argv[1]) orelse "";

    // Too many attached databases, or the name is taken.
    const limit = db.limit(.attached);
    if (db.dbs.items.len >= @as(usize, @intCast(limit)) + 2) {
        return resultErrorFmt(ctx, "too many attached databases - max {d}", .{limit});
    }
    for (0..db.dbs.items.len) |i| {
        if (dbIsNamed(db, i, name)) return resultErrorFmt(ctx, "database {s} is already in use", .{name});
    }

    // The new entry of db.dbs.
    db.dbs.ensureUnusedCapacity(gpa, 1) catch return db.oomFault();

    // Open the database file.
    var flags = db.open_flags;
    var parsed = uri.parse(gpa, file, flags);
    defer parsed.deinit(gpa);
    if (parsed.rc != RC.OK) {
        if (parsed.rc == RC.NOMEM) db.oomFault();
        api.resultError(ctx, parsed.err_msg orelse "");
        return;
    }
    flags = parsed.flags;
    if (!db.flags.AttachWrite) {
        flags.read_only = true;
        flags.create = false;
    } else if (!db.flags.AttachCreate) {
        flags.create = false;
    }
    const path_name = parsed.filename();
    const path: ?[]const u8 = if (flags.memory or path_name.len == 0 or std.mem.eql(u8, path_name, ":memory:")) null else path_name;
    var rc: i32 = RC.OK;
    var err_dyn: ?[:0]u8 = null;
    defer if (err_dyn) |m| gpa.free(m);
    const bt: ?*btree.Btree = btree.Btree.open(malloc.allocator, db.vfs.?, path, .{
        .read_only = flags.read_only,
        .create = flags.create and !flags.read_only,
        .cell_size_check = db.flags.CellSizeCk,
        .n_vdbe_read = &db.n_vdbe_read,
        .autovac_pages = main_mod.btreeAutovacPages(db),
        .busy_handler = main_mod.btreeBusyHandler(db),
    }) catch |err| blk: {
        rc = int.errorCode(err);
        break :blk null;
    };
    const schema = gpa.create(Schema) catch {
        if (bt) |b| b.close(main_mod.pagerConn(db));
        return db.oomFault();
    };
    schema.* = .{ .enc = 1 };
    const db_name = gpa.dupeSentinel(u8, name, 0) catch {
        gpa.destroy(schema);
        if (bt) |b| b.close(main_mod.pagerConn(db));
        return db.oomFault();
    };
    db.dbs.appendAssumeCapacity(.{ .name = db_name, .bt = bt, .schema = schema });
    if (bt) |b| {
        // The pager settings of main.
        if (db.dbs.items[0].bt) |main_bt| _ = b.secureDelete(main_bt.secureDelete(null));
        b.setPagerFlags(.full, db.flags.FullFSync, db.flags.CkptFullFSync, db.flags.CacheSpill);
    }
    // SQLITE_DEFAULT_SYNCHRONOUS+1.
    db.dbs.items[db.dbs.items.len - 1].safety_level = 3;

    // Read the schema of the new database. If that fails, or opening it
    // did, put everything back the way it was.
    if (rc == RC.OK) {
        db.init.i_db = 0;
        db.m_db_flags.SchemaKnownOk = false;
        rc = prepare.init(db, &err_dyn);
    }
    if (rc != RC.OK) {
        const i_db = db.dbs.items.len - 1;
        std.debug.assert(i_db >= 2);
        if (db.dbs.items[i_db].bt) |b| {
            b.close(main_mod.pagerConn(db));
            db.dbs.items[i_db].bt = null;
        }
        build.resetAllSchemasOfConnection(db);
        // The entry is gone unless schema resets are deferred.
        if (db.dbs.items.len > i_db) dropEntry(db, i_db);
        if (rc == RC.NOMEM or rc == RC.IOERR | (12 << 8)) {
            db.oomFault();
            if (err_dyn) |m| gpa.free(m);
            err_dyn = gpa.dupeSentinel(u8, "out of memory", 0) catch null;
        } else if (err_dyn == null) {
            err_dyn = std.fmt.allocPrintSentinel(gpa, "unable to open database: {s}", .{file}, 0) catch null;
        }
        if (err_dyn) |m| api.resultError(ctx, m);
        api.resultErrorCode(ctx, rc);
    }
}

/// Port of detachFunc(): sqlite_detach(name), the work of DETACH
/// DATABASE name.
fn detachFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name: [:0]const u8 = api.valueText(argv[0]) orelse "";
    const i = for (db.dbs.items, 0..) |d, i| {
        if (d.bt == null) continue;
        if (dbIsNamed(db, i, name)) break i;
    } else return detachError(ctx, "no such database: {s}", name);
    if (i < 2) return detachError(ctx, "cannot detach database {s}", name);
    const d = &db.dbs.items[i];
    if (d.bt.?.txnState() != .none or d.bt.?.isInBackup()) return detachError(ctx, "database {s} is locked", name);
    closeDb(db, i);
}

/// The detach_error path of detachFunc(): the message is made with
/// sqlite3_snprintf() into a buffer of 128 bytes, so it is cut short.
fn detachError(ctx: *Context, comptime fmt: []const u8, name: []const u8) void {
    var buf: [127]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, .{name}) catch {};
    api.resultError(ctx, w.buffered());
}

/// Close attached database `i_db` and remove it from db.dbs (DETACH, and
/// the end of VACUUM's sqlite3BtreeClose() and
/// sqlite3ResetAllSchemasOfConnection() of its temporary database). TEMP
/// triggers on its tables stay with TEMP. The database must have no
/// transaction open.
pub fn closeDb(db: *Sqlite3, i_db: usize) void {
    std.debug.assert(i_db >= 2);
    const d = &db.dbs.items[i_db];
    detachTempTriggers(db, d.schema);
    if (d.bt) |b| b.close(main_mod.pagerConn(db));
    d.bt = null;
    collapseDatabaseArray(db);
}

/// Free the schema and name of entry `i_db` of db.dbs, whose b-tree is
/// closed, and remove it.
fn dropEntry(db: *Sqlite3, i_db: usize) void {
    const d = db.dbs.items[i_db];
    std.debug.assert(i_db >= 2 and d.bt == null);
    build.schemaFree(db, d.schema);
    db.gpa.destroy(d.schema);
    db.gpa.free(d.name);
    _ = db.dbs.orderedRemove(i_db);
}

/// Port of sqlite3CollapseDatabaseArray() (build.c): remove the attached
/// databases whose b-tree is closed. Their schemas are freed here (in C
/// the b-tree owns its schema).
pub fn collapseDatabaseArray(db: *Sqlite3) void {
    var i = db.dbs.items.len;
    while (i > 2) {
        i -= 1;
        if (db.dbs.items[i].bt == null) dropEntry(db, i);
    }
}

/// The attachFunc() and detachFunc() wrappers (C: static FuncDefs).
const attach_func: FuncDef = .{ .n_arg = 3, .x_sfunc = attachFunc, .name = "sqlite_attach" };
const detach_func: FuncDef = .{ .n_arg = 1, .x_sfunc = detachFunc, .name = "sqlite_detach" };

/// SQLITE_ATTACH or SQLITE_DETACH, for the authorizer.
const AuthCode = enum { attach, detach };

/// Port of codeAttach(): code one call of sqlite_attach() or
/// sqlite_detach().
fn codeAttach(p: *Parse, typ: AuthCode, func: *const FuncDef, auth_arg: ?*Expr, filename: ?*Expr, dbname: ?*Expr, key: ?*Expr) void {
    prepare.readSchema(p) catch return;
    if (p.n_err != 0) return;
    var nc: int.NameContext = .{ .parse = p };
    resolveAttachExpr(&nc, filename) catch return;
    resolveAttachExpr(&nc, dbname) catch return;
    resolveAttachExpr(&nc, key) catch return;

    if (auth_arg) |a| {
        const arg: ?[]const u8 = if (a.op == TK.STRING) a.token() else null;
        const code = if (typ == .attach) auth.Code.ATTACH else auth.Code.DETACH;
        if (auth.check(p, code, arg, null, null) != auth.OK) return;
    }

    const v = build.getVdbe(p);
    const reg_args = expr_mod.getTempRange(p, 4);
    expr_code.exprCode(p, filename, reg_args);
    expr_code.exprCode(p, dbname, reg_args + 1);
    expr_code.exprCode(p, key, reg_args + 2);
    if (v) |vm| {
        _ = aux.addFunctionCall(p, 0, reg_args + 3 - func.n_arg, reg_args + 3, func.n_arg, func, 0);
        // ATTACH expires only this statement, DETACH all of them.
        _ = aux.addOp1(vm, OP.Expire, @intFromBool(typ == .attach));
    }
}

/// Port of sqlite3Attach(): ATTACH DATABASE file AS dbname KEY key.
pub fn attach(p: *Parse, file: ?*Expr, dbname: ?*Expr, key: ?*Expr) void {
    if (p.syntax_only) return;
    codeAttach(p, .attach, &attach_func, file, file, dbname, key);
}

/// Port of sqlite3Detach(): DETACH DATABASE dbname.
pub fn detach(p: *Parse, dbname: ?*Expr) void {
    if (p.syntax_only) return;
    codeAttach(p, .detach, &detach_func, dbname, null, null, dbname);
}

/// sqlite3DbIsNamed().
pub const dbIsNamed = build.dbIsNamed;

const util = @import("util.zig");
const build = @import("build.zig");
const auth = @import("auth.zig");
const walker = @import("walker.zig");

const Expr = int.Expr;
const Select = int.Select;
const SrcList = int.SrcList;
const Schema = int.Schema;
const TK = int.TK;
const EP = int.EP;
const WRC = walker.WRC;

/// A DbFixer: ties the table references of a view, trigger or index
/// to the database of that object, which (unless it is TEMP) they may
/// not leave.
pub const DbFixer = struct {
    parse: *Parse,
    db_name: [:0]const u8,
    schema: *Schema,
    /// "view", "trigger" or "index", for error messages.
    typ: []const u8,
    /// The name of the object: a token of the statement, or a copy of it
    /// (C: pName, a Token, quoted with %T).
    name: []const u8,
    temp: bool,
    w: walker.Walker,
};

/// Port of sqlite3FixInit(). `fix` must stay in place while used.
pub fn fixInit(fix: *DbFixer, p: *Parse, i_db: usize, typ: []const u8, name: []const u8) void {
    const d = &p.db.dbs.items[i_db];
    fix.* = .{
        .parse = p,
        .db_name = d.name,
        .schema = d.schema,
        .typ = typ,
        .name = name,
        .temp = i_db == 1,
        .w = .{
            .parse = p,
            .expr_callback = fixExprCb,
            .select_callback = fixSelectCb,
            .select_callback2 = walker.walkWinDefnDummyCallback,
        },
    };
    fix.w.u = .{ .fix = fix };
}

fn fixExprCb(w: *walker.Walker, e: *Expr) WRC {
    const fix = w.u.fix;
    if (!fix.temp) e.flags.FromDDL = true;
    if (e.op == TK.VARIABLE) {
        if (fix.parse.db.init.busy) {
            e.op = TK.NULL;
        } else {
            util.errorMsg(fix.parse, "{s} cannot use variables", .{fix.typ});
            return WRC.Abort;
        }
    }
    return WRC.Continue;
}

fn fixSelectCb(w: *walker.Walker, s: *Select) WRC {
    const fix = w.u.fix;
    const db = fix.parse.db;
    const i_db = build.findDbName(db, fix.db_name);
    const list = s.src orelse return WRC.Continue;
    for (list.slice()) |*item| {
        if (!fix.temp and !item.fg.is_subquery) {
            if (!item.fg.fixed_schema) if (item.u4.database) |zdb| {
                if (i_db != build.findDbName(db, zdb)) {
                    util.errorMsgAt(fix.parse, if (fix.name.len != 0) fix.name.ptr else null, "{s} {s} cannot reference objects in database {s}", .{ fix.typ, fix.name, zdb });
                    return WRC.Abort;
                }
                item.fg.not_cte = true;
                item.fg.had_schema = true;
            };
            item.u4 = .{ .schema = fix.schema };
            item.fg.from_ddl = true;
            item.fg.fixed_schema = true;
        }
        if (!item.fg.is_using and walker.walkExpr(&fix.w, item.u3.on) != .Continue) return WRC.Abort;
    }
    if (s.with) |with| {
        for (with.ctes.items) |*cte| {
            if (walker.walkSelect(w, cte.select) != .Continue) return WRC.Abort;
        }
    }
    return WRC.Continue;
}

/// Port of sqlite3FixSrcList(). True on error.
pub fn fixSrcList(fix: *DbFixer, list: ?*SrcList) bool {
    const l = list orelse return false;
    var s: Select = .{ .src = l };
    return walker.walkSelect(&fix.w, &s) != .Continue;
}

/// Port of sqlite3FixSelect(). True on error.
pub fn fixSelect(fix: *DbFixer, s: ?*Select) bool {
    return walker.walkSelect(&fix.w, s) != .Continue;
}

/// Port of sqlite3FixExpr(). True on error.
pub fn fixExpr(fix: *DbFixer, e: ?*Expr) bool {
    return walker.walkExpr(&fix.w, e) != .Continue;
}

/// Port of sqlite3FixTriggerStep(). True on error.
pub fn fixTriggerStep(fix: *DbFixer, step_list: ?*int.TriggerStep) bool {
    var it = step_list;
    while (it) |step| : (it = step.next) {
        if (walker.walkSelect(&fix.w, step.select) != .Continue or
            walker.walkExpr(&fix.w, step.where) != .Continue or
            walker.walkExprList(&fix.w, step.expr_list) != .Continue or
            fixSrcList(fix, step.src))
        {
            return true;
        }
        var up = step.upsert;
        while (up) |u| : (up = u.next) {
            if (walker.walkExprList(&fix.w, u.target) != .Continue or
                walker.walkExpr(&fix.w, u.target_where) != .Continue or
                walker.walkExprList(&fix.w, u.set) != .Continue or
                walker.walkExpr(&fix.w, u.where) != .Continue)
            {
                return true;
            }
        }
    }
    return false;
}
