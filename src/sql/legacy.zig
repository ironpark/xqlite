//! sqlite3_exec() (port of legacy.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const main_mod = @import("main.zig");
const prepare = @import("prepare.zig");
const api = @import("../vdbe/api.zig");
const aux = @import("../vdbe/aux.zig");
const ctype = @import("../util/ctype.zig");

const Sqlite3 = int.Sqlite3;
const RC = int.RC;

/// The callback of exec(): the values of one result row (null for NULL)
/// and the column names. Returning true aborts the statement.
pub const Callback = *const fn (ctx: ?*anyopaque, values: []const ?[*:0]const u8, names: []const [*:0]const u8) bool;

/// Port of sqlite3_exec(): run every statement of `sql`, passing each
/// result row to `callback`. On error, `err_msg` (if given) receives a
/// copy of the message, allocated with db.gpa.
pub fn exec(db: *Sqlite3, sql_arg: []const u8, callback: ?Callback, ctx: ?*anyopaque, err_msg: ?*?[:0]u8) i32 {
    var rc: i32 = RC.OK;
    main_mod.setError(db, RC.OK);
    // One NUL-terminated copy, parsed in place statement by statement.
    const copy: ?[:0]u8 = db.gpa.dupeSentinel(u8, sql_arg, 0) catch blk: {
        db.malloc_failed = true;
        rc = RC.NOMEM;
        break :blk null;
    };
    defer if (copy) |z| db.gpa.free(z);
    var sql: [:0]const u8 = copy orelse "";
    var cols: std.ArrayList(?[*:0]const u8) = .empty;
    defer cols.deinit(db.gpa);
    var names: std.ArrayList([*:0]const u8) = .empty;
    defer names.deinit(db.gpa);

    outer: while (rc == RC.OK and sql.len > 0) {
        var stmt_opt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
        var leftover: [:0]const u8 = "";
        rc = prepare.prepareV3Z(db, sql, 0, &stmt_opt, &leftover);
        if (rc != RC.OK) continue;
        const stmt = stmt_opt orelse {
            // A comment or white space.
            sql = leftover;
            continue;
        };
        var callback_is_init = false;
        while (true) {
            rc = api.step(stmt);
            if (callback) |cb| if (rc == RC.ROW or (rc == RC.DONE and !callback_is_init and db.flags & int.DbFlag.NullCallback != 0)) {
                const n_col = api.columnCount(stmt);
                if (!callback_is_init) {
                    names.clearRetainingCapacity();
                    for (0..n_col) |i| {
                        names.append(db.gpa, api.columnName(stmt, i).?.ptr) catch {
                            db.malloc_failed = true;
                            _ = aux.finalize(stmt);
                            break :outer;
                        };
                    }
                    callback_is_init = true;
                }
                cols.clearRetainingCapacity();
                if (rc == RC.ROW) {
                    for (0..n_col) |i| {
                        const t = api.columnText(stmt, i);
                        if (t == null and api.columnType(stmt, i) != @import("../vdbe/vdbe_int.zig").SQLITE_NULL) {
                            db.malloc_failed = true;
                            _ = aux.finalize(stmt);
                            break :outer;
                        }
                        cols.append(db.gpa, if (t) |z| z.ptr else null) catch {
                            db.malloc_failed = true;
                            _ = aux.finalize(stmt);
                            break :outer;
                        };
                    }
                }
                if (cb(ctx, cols.items, names.items)) {
                    rc = RC.ABORT;
                    _ = aux.finalize(stmt);
                    main_mod.setError(db, RC.ABORT);
                    break :outer;
                }
            };
            if (rc != RC.ROW) {
                rc = aux.finalize(stmt);
                sql = leftover;
                while (sql.len > 0 and ctype.isSpace(sql[0])) sql = sql[1..];
                break;
            }
        }
    }

    rc = main_mod.apiExit(db, rc);
    if (err_msg) |out| {
        if (rc != RC.OK) {
            out.* = db.gpa.dupeSentinel(u8, main_mod.errmsg(db), 0) catch blk: {
                rc = RC.NOMEM;
                main_mod.setError(db, RC.NOMEM);
                break :blk null;
            };
        } else {
            out.* = null;
        }
    }
    return rc;
}

/// sqlite3_exec() without a callback: run every statement of `sql`.
pub fn execNoCallback(db: *Sqlite3, sql: [:0]const u8, err_msg: *?[:0]u8) i32 {
    return exec(db, sql, null, null, err_msg);
}
