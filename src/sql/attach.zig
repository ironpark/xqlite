//! ATTACH and DETACH (port of attach.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3Attach().
pub fn attach(p: *Parse, file: ?*int.Expr, dbname: ?*int.Expr, key: ?*int.Expr) void {
    _ = .{ file, dbname, key };
    pending.notYet(p, "ATTACH");
}

/// Port of sqlite3Detach().
pub fn detach(p: *Parse, dbname: ?*int.Expr) void {
    _ = .{ dbname };
    pending.notYet(p, "DETACH");
}

const util = @import("util.zig");
const build = @import("build.zig");
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
    fix.w.u = .{ .ptr = fix };
}

fn fixExprCb(w: *walker.Walker, e: *Expr) u8 {
    const fix: *DbFixer = @ptrCast(@alignCast(w.u.ptr.?));
    if (!fix.temp) e.set(EP.FromDDL);
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

fn fixSelectCb(w: *walker.Walker, s: *Select) u8 {
    const fix: *DbFixer = @ptrCast(@alignCast(w.u.ptr.?));
    const db = fix.parse.db;
    const i_db = build.findDbName(db, fix.db_name);
    const list = s.src orelse return WRC.Continue;
    for (list.slice()) |*item| {
        if (!fix.temp and !item.fg.is_subquery) {
            if (!item.fg.fixed_schema) if (item.u4.database) |zdb| {
                if (i_db != build.findDbName(db, zdb)) {
                    util.errorMsg(fix.parse, "{s} {s} cannot reference objects in database {s}", .{ fix.typ, fix.name, zdb });
                    return WRC.Abort;
                }
                item.fg.not_cte = true;
                item.fg.had_schema = true;
            };
            item.u4 = .{ .schema = fix.schema };
            item.fg.from_ddl = true;
            item.fg.fixed_schema = true;
        }
        if (!item.fg.is_using and walker.walkExpr(&fix.w, item.u3.on) != 0) return WRC.Abort;
    }
    if (s.with) |with| {
        for (with.ctes.items) |*cte| {
            if (walker.walkSelect(w, cte.select) != 0) return WRC.Abort;
        }
    }
    return WRC.Continue;
}

/// Port of sqlite3FixSrcList(). True on error.
pub fn fixSrcList(fix: *DbFixer, list: ?*SrcList) bool {
    const l = list orelse return false;
    var s: Select = .{ .src = l };
    return walker.walkSelect(&fix.w, &s) != 0;
}

/// Port of sqlite3FixSelect(). True on error.
pub fn fixSelect(fix: *DbFixer, s: ?*Select) bool {
    return walker.walkSelect(&fix.w, s) != 0;
}

/// Port of sqlite3FixExpr(). True on error.
pub fn fixExpr(fix: *DbFixer, e: ?*Expr) bool {
    return walker.walkExpr(&fix.w, e) != 0;
}
