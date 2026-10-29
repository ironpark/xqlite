//! VACUUM and VACUUM INTO (port of vacuum.c).
//!
//! VACUUM rebuilds a database in a new temporary one, attached as
//! vacuum_XXXXXXXXXXXXXXXX: it creates the same tables and indexes there,
//! copies every row in order with the transfer optimization (insert.zig),
//! copies the views and triggers, and then copies the result back over
//! the original page by page (backup.copyFile()) in a transaction on the
//! original. VACUUM INTO attaches the output file instead and stops before
//! the copy back. The changes PRAGMA page_size and auto_vacuum ask for
//! take effect in the rebuilt database.
//!
//! The rebuilt database is a temporary file even with PRAGMA
//! temp_store=MEMORY; nothing of it outlives the statement.

const std = @import("std");
const int = @import("sqlite_int.zig");
const build = @import("build.zig");
const resolve = @import("resolve.zig");
const expr_code = @import("expr_code.zig");
const prepare = @import("prepare.zig");
const main_mod = @import("main.zig");
const attach = @import("attach.zig");
const backup = @import("backup.zig");
const func = @import("func.zig");
const uri = @import("uri.zig");
const util = @import("util.zig");
const btree = @import("../btree/btree.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const api = @import("../vdbe/api.zig");

const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const Vdbe = vi.Vdbe;
const Mem = vi.Mem;
const RC = int.RC;
const OP = vi.OP;

/// Port of execSql(): run `sql`. If it is a SELECT, each row's single
/// column is SQL to run in turn, but only a CREATE or an INSERT: a
/// corrupt sqlite_schema.sql must not get VACUUM to run anything else.
/// On error the connection's message goes to `v`.
fn execSql(db: *Sqlite3, v: *Vdbe, sql: []const u8) i32 {
    var stmt_opt: ?*Vdbe = null;
    var rc = prepare.prepareLang(db, sql, .sqlite, 0, &stmt_opt, null);
    if (rc != RC.OK) return rc;
    const stmt = stmt_opt orelse return RC.OK;
    while (true) {
        rc = api.step(stmt);
        if (rc != RC.ROW) break;
        std.debug.assert(std.ascii.startsWithIgnoreCase(sql, "SELECT"));
        if (api.columnText(stmt, 0)) |sub| {
            if (std.mem.startsWith(u8, sub, "CRE") or std.mem.startsWith(u8, sub, "INS")) {
                rc = execSql(db, v, sub);
                if (rc != RC.OK) break;
            }
        }
    }
    std.debug.assert(rc != RC.ROW);
    if (rc == RC.DONE) rc = RC.OK;
    if (rc != RC.OK) aux.vdbeError(v, "{s}", .{main_mod.errmsg(db)});
    _ = api.finalize(stmt);
    return rc;
}

/// Port of execSqlF(): execSql() of a formatted statement.
fn execSqlF(db: *Sqlite3, v: *Vdbe, comptime fmt: []const u8, args: anytype) i32 {
    const z = std.fmt.allocPrint(db.gpa, fmt, args) catch return RC.NOMEM;
    defer db.gpa.free(z);
    return execSql(db, v, z);
}

/// `name` quoted for use inside double quotes (%w).
const Ident = struct {
    name: []const u8,

    pub fn format(id: Ident, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (id.name) |c| {
            if (c == '"') try w.writeByte('"');
            try w.writeByte(c);
        }
    }
};

/// `s` as an SQL string literal (%Q).
const Literal = struct {
    s: []const u8,

    pub fn format(lit: Literal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('\'');
        for (lit.s) |c| {
            if (c == '\'') try w.writeByte('\'');
            try w.writeByte(c);
        }
        try w.writeByte('\'');
    }
};

/// Port of sqlite3Vacuum(): code VACUUM [name] [INTO into].
pub fn vacuum(p: *Parse, name: ?int.Token, into: ?*int.Expr) void {
    if (p.syntax_only) return;
    const v = build.getVdbe(p) orelse return;
    if (p.n_err != 0) return;
    var i_db: usize = 0;
    if (name) |nm| {
        // An unknown name is an error (not SQLITE_BUG_COMPATIBLE_20160819).
        var unqual: *const int.Token = undefined;
        i_db = build.twoPartName(p, &nm, &nm, &unqual) orelse return;
    }
    // TEMP is not vacuumed.
    if (i_db != 1) {
        var into_reg: i32 = 0;
        if (into) |e| {
            if (resolve.resolveSelfReference(p, null, .{}, e, null)) |_| {
                p.n_mem += 1;
                into_reg = p.n_mem;
                expr_code.exprCode(p, e, into_reg);
            } else |_| {}
        }
        _ = aux.addOp2(v, OP.Vacuum, @intCast(i_db), into_reg);
        aux.usesBtree(v, @intCast(i_db));
    }
}

/// The meta values VACUUM keeps, each with the increment to apply: the
/// schema cookie goes up so that other connections read the schema again.
const meta_copy = [_]struct { btree.Meta, u32 }{
    .{ .schema_version, 1 },
    .{ .default_cache_size, 0 },
    .{ .text_encoding, 0 },
    .{ .user_version, 0 },
    .{ .application_id, 0 },
};

/// Port of sqlite3RunVacuum(), the work of OP_Vacuum: vacuum database
/// `i_db`, or write the vacuumed copy to the file named by `out` (VACUUM
/// INTO). Errors go to `v`.
pub fn runVacuum(v: *Vdbe, db: *Sqlite3, i_db: usize, out: ?*Mem) i32 {
    if (!db.auto_commit) {
        aux.vdbeError(v, "cannot VACUUM from within a transaction", .{});
        return RC.ERROR;
    }
    if (db.n_vdbe_active > 1) {
        aux.vdbeError(v, "cannot VACUUM - SQL statements in progress", .{});
        return RC.ERROR;
    }
    const saved_open_flags = db.open_flags;
    var z_out: []const u8 = "";
    if (out) |m| {
        if (api.valueType(m) != vi.SQLITE_TEXT) {
            aux.vdbeError(v, "non-text filename", .{});
            return RC.ERROR;
        }
        z_out = api.valueText(m) orelse "";
        db.open_flags.read_only = false;
        db.open_flags.create = true;
    }

    // Write the schema, skip CHECK and foreign key constraints.
    const saved_flags = db.flags;
    const saved_m_db_flags = db.m_db_flags;
    const saved_n_change = db.n_change;
    const saved_n_total_change = db.n_total_change;
    db.flags.WriteSchema = true;
    db.flags.IgnoreChecks = true;
    db.flags.Comments = true;
    db.flags.AttachCreate = true;
    db.flags.AttachWrite = true;
    db.m_db_flags.PreferBuiltin = true;
    db.m_db_flags.Vacuum = true;
    db.flags.ForeignKeys = false;
    db.flags.ReverseOrder = false;
    db.flags.Defensive = false;
    db.flags.CountRows = false;

    const db_main = db.dbs.items[i_db].name;
    const main = db.dbs.items[i_db].bt.?;
    const is_mem_db = main.isMemdb();

    // Attach the temporary database as vacuum_XXXXXX. It is not
    // recovered after a crash, so synchronous can be off; the original
    // is protected by its own transaction around the copy back.
    var random: [8]u8 = undefined;
    func.randomness(db, &random);
    var name_buf: [42]u8 = undefined;
    const db_vacuum = std.fmt.bufPrint(&name_buf, "vacuum_{x:0>16}", .{std.mem.readInt(u64, &random, .little)}) catch unreachable;
    const n_db = db.dbs.items.len;
    var temp: ?*btree.Btree = null;
    var rc = execSqlF(db, v, "ATTACH {f} AS {s}", .{ Literal{ .s = z_out }, db_vacuum });
    db.open_flags = saved_open_flags;
    run: {
        if (rc != RC.OK) break :run;
        std.debug.assert(db.dbs.items.len - 1 == n_db);
        std.debug.assert(std.mem.eql(u8, db.dbs.items[n_db].name, db_vacuum));
        const t = db.dbs.items[n_db].bt.?;
        temp = t;
        var n_res = main.getRequestedReserve();
        var level: @import("../pager/pager.zig").Synchronous = .off;
        var full_fsync = false;
        var ckpt_full_fsync = false;
        if (out != null) {
            const size = t.pager.fd.fileSize() catch 1;
            if (size > 0) {
                rc = RC.ERROR;
                aux.vdbeError(v, "output file already exists", .{});
                break :run;
            }
            db.m_db_flags.VacuumInto = true;
            // The output gets the pager flags of the database vacuumed
            // (with cache spill on).
            level = switch (db.dbs.items[i_db].safety_level & 0x07) {
                1 => .off,
                2 => .normal,
                4 => .extra,
                else => .full,
            };
            full_fsync = db.flags.FullFSync;
            ckpt_full_fsync = db.flags.CkptFullFSync;
            // A "reserve=N" parameter of a URI output sets the reserve.
            var parsed = uri.parse(db.gpa, z_out, saved_open_flags);
            defer parsed.deinit(db.gpa);
            if (parsed.rc == RC.OK) if (parsed.parameter("reserve")) |z| {
                var n_new: i64 = n_res;
                if (util.decOrHexToI64(z, &n_new) != .ok) n_new = n_res;
                if (n_new >= 0 and n_new <= 255) n_res = @intCast(n_new);
            };
        }
        t.setCacheSize(db.dbs.items[i_db].schema.cache_size);
        _ = t.setSpillSize(@intCast(main.setSpillSize(0)));
        t.setPagerFlags(level, full_fsync, ckpt_full_fsync, true);

        // Lock the original now, before its page size is read: a WAL
        // database cannot change it.
        rc = execSql(db, v, "BEGIN");
        if (rc != RC.OK) break :run;
        main.beginTrans(if (out == null) .exclusive else .read, @intCast(db.n_savepoint)) catch |err| {
            rc = int.errorCode(err);
            break :run;
        };
        if (main.pager.journal_mode == .wal and out == null) db.next_pagesize = 0;

        if (setPageSize(t, main.getPageSize(), n_res) or
            (!is_mem_db and setPageSize(t, db.next_pagesize, n_res)) or db.malloc_failed)
        {
            rc = RC.NOMEM;
            break :run;
        }
        t.setAutoVacuum(if (db.next_autovac >= 0) @fromBackingInt(@intCast(db.next_autovac)) else main.getAutoVacuum()) catch {};

        // The same schema in the new database: its CREATE statements go
        // to vacuum_db.
        db.init.i_db = @intCast(n_db);
        rc = execSqlF(db, v, "SELECT sql FROM \"{f}\".sqlite_schema WHERE type='table'AND name<>'sqlite_sequence' AND coalesce(rootpage,1)>0", .{Ident{ .name = db_main }});
        if (rc != RC.OK) break :run;
        rc = execSqlF(db, v, "SELECT sql FROM \"{f}\".sqlite_schema WHERE type='index'", .{Ident{ .name = db_main }});
        if (rc != RC.OK) break :run;
        db.init.i_db = 0;

        // Copy each table with INSERT INTO vacuum_db.x SELECT * FROM
        // main.x.
        rc = execSqlF(db, v, "SELECT'INSERT INTO {s}.'||quote(name)||' SELECT*FROM\"{f}\".'||quote(name)FROM {s}.sqlite_schema WHERE type='table'AND coalesce(rootpage,1)>0", .{ db_vacuum, Ident{ .name = db_main }, db_vacuum });
        std.debug.assert(db.m_db_flags.Vacuum);
        db.m_db_flags.Vacuum = false;
        if (rc != RC.OK) break :run;

        // Views, triggers and virtual tables have no content: their
        // sqlite_schema rows are all there is to copy.
        rc = execSqlF(db, v, "INSERT INTO {s}.sqlite_schema SELECT*FROM \"{f}\".sqlite_schema WHERE type IN('view','trigger') OR(type='table'AND rootpage=0)", .{ db_vacuum, Ident{ .name = db_main } });
        if (rc != RC.OK) break :run;

        // Both databases have a write transaction now (the original only
        // a read one for VACUUM INTO). copyFile() commits the original,
        // the commit below the new one.
        std.debug.assert(t.txnState() == .write);
        std.debug.assert(out != null or main.txnState() == .write);
        for (meta_copy) |m| {
            // Page 1 of both is loaded and the new one writable: this
            // cannot fail.
            const meta = main.getMeta(m[0]);
            t.updateMeta(m[0], meta +% m[1]) catch |err| {
                rc = int.errorCode(err);
                break :run;
            };
        }
        if (out == null) rc = backup.copyFile(main, t, db);
        if (rc != RC.OK) break :run;
        t.commit() catch |err| {
            rc = int.errorCode(err);
            break :run;
        };
        if (out == null) main.setAutoVacuum(t.getAutoVacuum()) catch {};

        if (out == null) {
            n_res = t.getRequestedReserve();
            main.setPageSize(t.getPageSize(), n_res, true) catch |err| {
                rc = int.errorCode(err);
            };
        }
    }

    // Restore the connection.
    db.init.i_db = 0;
    db.m_db_flags = saved_m_db_flags;
    db.flags = saved_flags;
    db.n_change = saved_n_change;
    db.n_total_change = saved_n_total_change;
    // (C passes -1: only the reserve, then fix the page size.)
    main.setPageSize(std.math.maxInt(u32), 0, true) catch {};

    // The SQL transaction of BEGIN is only open on the temporary
    // database now (the original was committed by the b-tree): end it by
    // hand, and detach the temporary database, which deletes its journal.
    db.auto_commit = true;
    if (temp != null) attach.closeDb(db, n_db);
    // This both clears the schemas and drops the detached entry.
    build.resetAllSchemasOfConnection(db);
    return rc;
}

/// sqlite3BtreeSetPageSize() as VACUUM tests it: true if it failed
/// (ReadOnly does not happen on the fresh temporary database).
fn setPageSize(bt: *btree.Btree, page_size: u32, n_res: u8) bool {
    bt.setPageSize(page_size, n_res, false) catch return true;
    return false;
}
