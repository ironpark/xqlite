//! Preparing statements and reading the schema (port of prepare.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const build = @import("build.zig");
const main_mod = @import("main.zig");
const legacy = @import("legacy.zig");
const ctype = @import("../util/ctype.zig");
const numeric = @import("numeric.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const dialect = @import("../dialect/dialect.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const Schema = int.Schema;
const Vdbe = vi.Vdbe;
const RC = int.RC;

/// sqlite3InitOne() flags (INITFLAG_*).
pub const INITFLAG_AlterMask: u16 = 0x0007;
pub const INITFLAG_AlterRename: u16 = 0x0001;
pub const INITFLAG_AlterDrop: u16 = 0x0002;
pub const INITFLAG_AlterAdd: u16 = 0x0003;
pub const INITFLAG_AlterDropCons: u16 = 0x0004;

/// SQLITE_MAX_PREPARE_RETRY.
const max_prepare_retry = 25;

/// SQLITE_LIMIT_SCHEMA default: the most objects a schema may have.
const max_schema_objects: u32 = 0x7fffffff;

/// The state of reading a schema (InitData).
pub const InitData = struct {
    db: *Sqlite3,
    i_db: usize,
    err_msg: *?[:0]u8,
    rc: i32 = RC.OK,
    m_init_flags: u32 = 0,
    n_init_row: u32 = 0,
    /// Pages in the database, to check root pages against.
    mx_page: int.Pgno = 0,
};

/// Store `msg` (copied) as the error message of a schema read.
fn setErrMsg(data: *InitData, msg: []const u8) void {
    const db = data.db;
    if (data.err_msg.*) |old| db.gpa.free(old);
    data.err_msg.* = db.gpa.dupeSentinel(u8, msg, 0) catch null;
}

/// Port of corruptSchema(): record that a schema row is malformed.
fn corruptSchema(data: *InitData, obj: []const ?[:0]const u8, extra: ?[]const u8) void {
    const db = data.db;
    if (db.malloc_failed) {
        data.rc = RC.NOMEM;
    } else if (data.err_msg.* != null) {
        // Keep the first message.
    } else if (data.m_init_flags & INITFLAG_AlterMask != 0) {
        const alter_type = [_][]const u8{ "rename", "drop column", "add column", "drop constraint" };
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error in {s} {s} after {s}: {s}", .{
            obj[0] orelse "",
            obj[1] orelse "",
            alter_type[(data.m_init_flags & INITFLAG_AlterMask) - 1],
            extra orelse "",
        }) catch &buf;
        setErrMsg(data, msg);
        data.rc = RC.ERROR;
    } else if (db.flags.WriteSchema) {
        data.rc = RC.CORRUPT;
    } else {
        const name = obj[1] orelse "?";
        const msg = if (extra) |e| (if (e.len > 0)
            std.fmt.allocPrint(db.gpa, "malformed database schema ({s}) - {s}", .{ name, e })
        else
            std.fmt.allocPrint(db.gpa, "malformed database schema ({s})", .{name})) else std.fmt.allocPrint(db.gpa, "malformed database schema ({s})", .{name});
        if (msg) |m| {
            defer db.gpa.free(m);
            setErrMsg(data, m);
        } else |_| {}
        data.rc = RC.CORRUPT;
    }
}

/// Port of sqlite3InitCallback(): process one row of sqlite_schema:
/// argv is type, name, tbl_name, rootpage and sql. Also called by
/// OP_ParseSchema. Returns true to stop.
pub fn initCallback(data: *InitData, argv: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
    // No row: PRAGMA empty_result_callbacks calls back once with none.
    if (argv.len == 0) return false;
    var obj: [5]?[:0]const u8 = undefined;
    for (&obj, argv[0..5]) |*o, a| o.* = if (a) |z| std.mem.span(z) else null;
    return initRow(data, &obj);
}

fn initRow(data: *InitData, argv: *const [5]?[:0]const u8) bool {
    const db = data.db;
    const i_db = data.i_db;
    db.m_db_flags.EncodingFixed = true;
    data.n_init_row += 1;
    if (db.malloc_failed) {
        corruptSchema(data, argv, null);
        return true;
    }
    if (argv[3] == null) {
        corruptSchema(data, argv, null);
    } else if (argv[4] != null and argv[4].?.len >= 2 and
        ctype.toLower(argv[4].?[0]) == 'c' and ctype.toLower(argv[4].?[1]) == 'r')
    {
        // A CREATE TABLE, INDEX or VIEW: with init.busy set, the parser
        // only builds the schema objects.
        const saved_i_db = db.init.i_db;
        std.debug.assert(db.init.busy);
        db.init.i_db = @intCast(i_db);
        if (numeric.getUInt32(argv[3].?)) |tnum| {
            db.init.new_tnum = tnum;
        } else {
            db.init.new_tnum = 0;
        }
        db.init.orphan_trigger = false;
        db.init.az_init = .{ argv[0] orelse "", argv[1] orelse "", argv[2] orelse "" };
        var stmt: ?*Vdbe = null;
        var tail: [:0]const u8 = "";
        prepareInternal(db, argv[4].?, 0, null, &stmt, &tail) catch {};
        const rc = db.err_code;
        db.init.i_db = saved_i_db;
        if (rc != RC.OK) {
            if (!db.init.orphan_trigger) {
                if (rc > data.rc) data.rc = rc;
                if (rc == RC.NOMEM) {
                    db.oomFault();
                } else if (rc != RC.INTERRUPT and rc & 0xff != RC.LOCKED) {
                    corruptSchema(data, argv, main_mod.errmsg(db));
                }
            }
        } else if (tail.len > 0) {
            corruptSchema(data, argv, null);
        }
        db.init.az_init = .{ "", "", "" };
        if (stmt) |s| _ = aux.finalize(s);
    } else if (argv[1] == null or (argv[4] != null and argv[4].?.len > 0)) {
        corruptSchema(data, argv, null);
    } else {
        // An index of a PRIMARY KEY or UNIQUE constraint, made with its
        // CREATE TABLE: only the root page needs to be recorded.
        if (build.findIndex(db, argv[1].?, db.dbs.items[i_db].name)) |idx| {
            idx.tnum = numeric.getUInt32(argv[3].?) orelse 0;
        } else {
            corruptSchema(data, argv, "orphan index");
        }
    }
    if (data.err_msg.* == null) {
        const s = db.dbs.items[i_db].schema;
        if (s.tbl_hash.count() + s.idx_hash.count() + s.trig_hash.count() > max_schema_objects) {
            setErrMsg(data, "too many schema objects");
            data.rc = RC.ERROR;
            return true;
        }
    }
    return false;
}

/// Port of sqlite3InitOne(): read the schema of database `i_db`. On error
/// returns the code and sets `err_msg` (owned by the caller, from gpa).
pub fn initOne(db: *Sqlite3, i_db: usize, err_msg: *?[:0]u8, m_flags: u32) i32 {
    std.debug.assert(!db.m_db_flags.SchemaKnownOk);
    // C: mask = (mDbFlags & DBFLAG_EncodingFixed) | ~DBFLAG_EncodingFixed.
    const encoding_was_fixed = db.m_db_flags.EncodingFixed;
    db.init.busy = true;
    defer db.init.busy = false;
    var rc: i32 = RC.OK;

    // The schema table itself, made by the parser from its definition.
    const schema_tab_name = int.schemaTable(i_db);
    var data: InitData = .{ .db = db, .i_db = i_db, .err_msg = err_msg, .m_init_flags = m_flags };
    const arg = [5]?[:0]const u8{
        "table",
        schema_tab_name,
        schema_tab_name,
        "1",
        "CREATE TABLE x(type text,name text,tbl_name text,rootpage int,sql text)",
    };
    _ = initRow(&data, &arg);
    // mDbFlags &= mask: reading the schema table does not fix the encoding.
    if (!encoding_was_fixed) db.m_db_flags.EncodingFixed = false;
    if (data.rc != RC.OK) {
        rc = data.rc;
        return initError(db, i_db, rc);
    }

    const pdb = &db.dbs.items[i_db];
    const bt = pdb.bt orelse {
        std.debug.assert(i_db == 1);
        pdb.schema.schema_flags.SchemaLoaded = true;
        return RC.OK;
    };

    var opened_transaction = false;
    if (bt.txnState() == .none) {
        bt.beginTrans(.read, 0) catch |err| {
            rc = int.errorCode(err);
            setErrMsg(&data, util.errStr(rc));
            return initError(db, i_db, rc);
        };
        opened_transaction = true;
    }
    defer if (opened_transaction) bt.commit() catch {};

    // meta[0..5]: schema cookie, file format, cache size, largest root
    // page, text encoding.
    var meta: [5]u32 = undefined;
    for (&meta, 1..) |*m, i| m.* = bt.getMeta(@fromBackingInt(@intCast(i)));
    if (db.flags.ResetDatabase) meta = @splat(0);
    pdb.schema.schema_cookie = @bitCast(meta[0]);

    // The text encoding of a non-empty database.
    if (meta[4] != 0) {
        var enc: u8 = @intCast(meta[4] & 3);
        if (enc == 0) enc = 1;
        if (i_db == 0 and !db.m_db_flags.EncodingFixed) {
            if (enc != 1) {
                setErrMsg(&data, "UTF-16 databases are not supported");
                return initError(db, i_db, RC.ERROR);
            }
            db.enc = enc;
        } else if (enc != db.enc) {
            setErrMsg(&data, "attached databases must use the same text encoding as main database");
            return initError(db, i_db, RC.ERROR);
        }
    }
    pdb.schema.enc = db.enc;

    if (pdb.schema.cache_size == 0) {
        var size: i32 = @intCast(@abs(@as(i32, @bitCast(meta[2]))));
        if (size == 0) size = int.DEFAULT_CACHE_SIZE;
        pdb.schema.cache_size = size;
        bt.setCacheSize(size);
    }

    pdb.schema.file_format = @truncate(meta[1]);
    if (pdb.schema.file_format == 0) pdb.schema.file_format = 1;
    if (pdb.schema.file_format > int.MAX_FILE_FORMAT) {
        setErrMsg(&data, "unsupported file format");
        return initError(db, i_db, RC.ERROR);
    }
    // Newer file formats must not be downgraded by VACUUM.
    if (i_db == 0 and meta[1] >= 4) db.flags.LegacyFileFmt = false;

    // Read the schema rows.
    data.mx_page = bt.lastPage();
    const sql = @import("printf.zig").mprintf(db.gpa, "SELECT*FROM\"%w\".%s ORDER BY rowid", &.{ .{ .str = pdb.name }, .{ .str = schema_tab_name } }) catch {
        db.oomFault();
        return initError(db, i_db, RC.NOMEM);
    };
    {
        // The schema is read without the authorizer.
        const x_auth = db.auth;
        db.auth = null;
        defer db.auth = x_auth;
        rc = legacy.execWith(db, sql, &data, initCallback, null);
    }
    db.gpa.free(sql);
    if (rc == RC.OK) rc = data.rc;
    if (rc == RC.OK) _ = @import("analyze.zig").analysisLoad(db, i_db);

    if (db.malloc_failed) {
        rc = RC.NOMEM;
        build.resetAllSchemasOfConnection(db);
    } else if (rc == RC.OK or (db.flags.NoSchemaError and rc != RC.NOMEM)) {
        // With NoSchemaError the schema is used as far as it was read.
        db.dbs.items[i_db].schema.schema_flags.SchemaLoaded = true;
        rc = RC.OK;
    }
    if (rc != RC.OK) return initError(db, i_db, rc);
    return RC.OK;
}

/// The error_out path of sqlite3InitOne().
fn initError(db: *Sqlite3, i_db: usize, rc: i32) i32 {
    if (rc == RC.NOMEM) db.oomFault();
    build.resetOneSchema(db, i_db);
    return rc;
}

/// Port of sqlite3Init(): read every schema not yet loaded, main first
/// and TEMP last.
pub fn init(db: *Sqlite3, err_msg: *?[:0]u8) i32 {
    const commit_internal = !db.m_db_flags.SchemaChange;
    std.debug.assert(!db.init.busy);
    db.enc = db.dbs.items[0].schema.enc;
    if (db.enc == 0) db.enc = 1;
    if (!db.dbs.items[0].schema.schema_flags.SchemaLoaded) {
        const rc = initOne(db, 0, err_msg, 0);
        if (rc != RC.OK) return rc;
    }
    var i = db.dbs.items.len;
    while (i > 1) {
        i -= 1;
        if (!db.dbs.items[i].schema.schema_flags.SchemaLoaded) {
            const rc = initOne(db, i, err_msg, 0);
            if (rc != RC.OK) return rc;
        }
    }
    if (commit_internal) main_mod.commitInternalChanges(db);
    return RC.OK;
}

/// Port of sqlite3ReadSchema(): make sure the schema is loaded. On
/// failure the error is in `p`, with the result code of init() in
/// Parse.rc.
pub fn readSchema(p: *Parse) int.ParseError!void {
    const db = p.db;
    if (p.syntax_only) return;
    if (!db.init.busy) {
        var msg: ?[:0]u8 = null;
        const rc = init(db, &msg);
        if (msg) |m| {
            defer db.gpa.free(m);
            p.err_msg = p.arena.dupeSentinel(u8, m, 0) catch null;
        }
        if (rc != RC.OK) {
            p.rc = rc;
            p.n_err += 1;
            return error.ParseFailed;
        }
        db.m_db_flags.SchemaKnownOk = true;
    }
}

/// Port of schemaIsValid(): if a schema cookie changed, set p.rc to
/// SQLITE_SCHEMA and forget that schema.
fn schemaIsValid(p: *Parse) void {
    const db = p.db;
    std.debug.assert(p.check_schema);
    for (db.dbs.items, 0..) |*d, i_db| {
        const bt = d.bt orelse continue;
        var opened = false;
        if (bt.txnState() == .none) {
            bt.beginTrans(.read, 0) catch |err| {
                if (err == error.OutOfMemory) {
                    db.oomFault();
                    p.rc = RC.NOMEM;
                }
                return;
            };
            opened = true;
        }
        const cookie: i32 = @bitCast(bt.getMeta(.schema_version));
        if (cookie != d.schema.schema_cookie) {
            if (d.schema.schema_flags.SchemaLoaded) p.rc = RC.SCHEMA;
            build.resetOneSchema(db, i_db);
        }
        if (opened) bt.commit() catch {};
    }
}

/// Port of sqlite3SchemaToIndex(): the database of a schema; -32768 for
/// null (a transient table of a subquery).
pub fn schemaToIndex(db: *Sqlite3, s: ?*Schema) i32 {
    const schema = s orelse return -32768;
    for (db.dbs.items, 0..) |d, i| {
        if (d.schema == schema) return @intCast(i);
    }
    unreachable;
}

/// The lookaside part of sqlite3ParseObjectReset(): undo the
/// disableLookaside() calls made while parsing `p`.
pub fn parseObjectResetLookaside(p: *Parse) void {
    const db = p.db;
    std.debug.assert(db.lookaside.b_disable >= p.disable_lookaside);
    db.lookaside.b_disable -= p.disable_lookaside;
    db.lookaside.sz = if (db.lookaside.b_disable != 0) 0 else db.lookaside.sz_true;
    p.disable_lookaside = 0;
}

/// Port of sqlite3Prepare(): compile the first statement of `sql`. The
/// statement (null for blank input) goes to `stmt` and the text after it
/// to `tail`. The result is also left in the connection, as the error
/// code (db.err_code, possibly an extended code) and message.
fn prepareInternal(db: *Sqlite3, sql: [:0]const u8, prep_flags: u8, old: ?*Vdbe, stmt: *?*Vdbe, tail: *[:0]const u8) int.Error!void {
    stmt.* = null;
    var arena_state = std.heap.ArenaAllocator.init(db.gpa);
    defer arena_state.deinit();
    var p: Parse = .{ .db = db, .arena = arena_state.allocator() };
    defer build.releaseTableRefs(&p);
    defer build.deleteReturning(&p);
    p.outer_parse = db.parse;
    db.parse = &p;
    defer db.parse = p.outer_parse;
    defer parseObjectResetLookaside(&p);
    if (old) |r| p.explain = r.explain;
    if (db.malloc_failed) {
        db.err_code = RC.NOMEM;
        return error.OutOfMemory;
    }
    // A long-lived statement keeps out of lookaside.
    if (prep_flags & aux.PREPARE_PERSISTENT != 0) {
        p.disable_lookaside += 1;
        @import("malloc.zig").disableLookaside(db);
    }
    p.prep_flags = prep_flags;

    if (db.disconnect != null) @import("vtab.zig").unlockList(db);

    // Compile in the language of the statement being recompiled, else in
    // the connection's (xqlite: sqlite3RunParser() is the frontend of the
    // dialect, see dialect.zig). A PRAGMA xq_dialect compiled here
    // changes the connection's language for the statements after it.
    const lang = if (old) |r| r.xq_lang else db.xq.lang;
    const saved_lang = dialect.swapLang(db, lang);
    defer if (std.meta.eql(db.xq.lang, lang)) {
        db.xq.lang = saved_lang;
    };
    dialect.runParser(&p, sql) catch |err| switch (err) {
        error.OutOfMemory => db.oomFault(),
        error.ParseFailed => {},
    };
    const consumed = @intFromPtr(p.tail.ptr) - @intFromPtr(sql.ptr);
    tail.* = sql[consumed..];

    if (!db.init.busy) if (p.vdbe) |v| aux.setSql(v, sql[0..consumed], prep_flags);
    if (db.malloc_failed) {
        p.rc = RC.NOMEM;
        p.check_schema = false;
    }
    if (p.rc != RC.OK and p.rc != RC.DONE) {
        if (p.check_schema and !db.init.busy) schemaIsValid(&p);
        if (p.vdbe) |v| _ = aux.finalize(v);
        const rc = p.rc;
        if (p.err_msg) |m| {
            main_mod.errorWithMsg(db, rc, "{s}", .{m});
        } else {
            main_mod.setError(db, rc);
        }
        return int.codeError(rc);
    }
    if (p.vdbe) |v| {
        v.parse = null;
        v.xq_lang = lang;
    }
    stmt.* = p.vdbe;
    main_mod.errorClear(db);
}

/// Port of sqlite3LockAndPrepare(): prepare, retrying after a schema
/// change was detected.
fn lockAndPrepare(db: *Sqlite3, sql: [:0]const u8, prep_flags: u8, old: ?*Vdbe, stmt: *?*Vdbe, tail: *[:0]const u8) i32 {
    var rc: i32 = RC.OK;
    var cnt: u32 = 0;
    stmt.* = null;
    while (true) {
        prepareInternal(db, sql, prep_flags, old, stmt, tail) catch |err| {
            rc = int.resultCode(err, db.err_code);
            if (db.malloc_failed) break;
            cnt += 1;
            if (rc == RC.ERROR_RETRY and cnt <= max_prepare_retry) continue;
            if (rc == RC.SCHEMA) {
                build.resetOneSchema(db, null);
                if (cnt == 1) continue;
            }
            break;
        };
        rc = RC.OK;
        break;
    }
    rc = main_mod.apiExit(db, rc);
    db.busy_handler.n_busy = 0;
    return rc;
}

/// Port of sqlite3_prepare_v2() and sqlite3_prepare_v3(): compile the
/// first statement of `sql`, keeping its text so a schema change
/// reprepares it. `stmt` is null for blank input; `tail` (if given)
/// receives the rest of `sql`.
pub fn prepareV3(db: *Sqlite3, sql: []const u8, prep_flags: u8, stmt: *?*Vdbe, tail: ?*[]const u8) i32 {
    stmt.* = null;
    // The parser needs a NUL-terminated copy.
    if (sql.len > @as(usize, @intCast(db.limit(.sql_length)))) {
        main_mod.errorWithMsg(db, RC.TOOBIG, "statement too long", .{});
        return main_mod.apiExit(db, RC.TOOBIG);
    }
    const copy = db.gpa.dupeSentinel(u8, sql, 0) catch {
        db.oomFault();
        return main_mod.apiExit(db, RC.NOMEM);
    };
    defer db.gpa.free(copy);
    var t: [:0]const u8 = "";
    const rc = prepareV3Z(db, copy, prep_flags, stmt, &t);
    if (tail) |out| out.* = sql[sql.len - t.len ..];
    return rc;
}

/// prepareV3() for NUL-terminated text, which is parsed in place (as
/// sqlite3_prepare_v3() with nByte < 0).
pub fn prepareV3Z(db: *Sqlite3, sql: [:0]const u8, prep_flags: u8, stmt: *?*Vdbe, tail: ?*[:0]const u8) i32 {
    var t: [:0]const u8 = "";
    const rc = lockAndPrepare(db, sql, aux.PREPARE_SAVESQL | (prep_flags & aux.PREPARE_MASK), null, stmt, &t);
    if (tail) |out| out.* = t;
    return rc;
}

pub fn prepareV2(db: *Sqlite3, sql: []const u8, stmt: *?*Vdbe, tail: ?*[]const u8) i32 {
    return prepareV3(db, sql, 0, stmt, tail);
}

/// prepareV3() in the language `lang` whatever the connection's (and the
/// statement keeps it when recompiled): Lang.sqlite for SQL that the
/// engine or the catalog generates (xqlite; no C counterpart).
pub fn prepareLang(db: *Sqlite3, sql: []const u8, lang: dialect.Lang, prep_flags: u8, stmt: *?*Vdbe, tail: ?*[]const u8) i32 {
    const saved = dialect.swapLang(db, lang);
    defer _ = dialect.swapLang(db, saved);
    return prepareV3(db, sql, prep_flags, stmt, tail);
}

/// Port of sqlite3Reprepare(): recompile a statement after a schema
/// change. Returns OK, or the error.
pub fn reprepare(v: *Vdbe) i32 {
    const db = v.db;
    const sql = v.sql orelse return RC.SCHEMA;
    var new: ?*Vdbe = null;
    var tail: [:0]const u8 = "";
    const rc = lockAndPrepare(db, sql, v.prep_flags, v, &new, &tail);
    if (rc != RC.OK) {
        if (rc == RC.NOMEM) db.oomFault();
        return rc;
    }
    const n = new.?;
    aux.swap(n, v);
    aux.transferBindings(n, v);
    aux.resetStepResult(n);
    _ = aux.finalize(n);
    return RC.OK;
}

/// The second half of OP_ParseSchema: read the schema rows of `i_db`
/// that match `where` into the in-memory schema. The caller sets
/// init.busy.
pub fn parseSchemaWhere(db: *Sqlite3, i_db: usize, where: [:0]const u8, err_msg: *?[:0]u8) i32 {
    var data: InitData = .{ .db = db, .i_db = i_db, .err_msg = err_msg };
    if (db.dbs.items[i_db].bt) |bt| data.mx_page = bt.lastPage();
    const sql = @import("printf.zig").mprintf(db.gpa, "SELECT*FROM\"%w\".%s WHERE %s ORDER BY rowid", &.{
        .{ .str = db.dbs.items[i_db].name },
        .{ .str = int.LEGACY_SCHEMA_TABLE },
        .{ .str = where },
    }) catch return RC.NOMEM;
    defer db.gpa.free(sql);
    var rc = legacy.execWith(db, sql, &data, initCallback, null);
    if (rc == RC.OK) rc = data.rc;
    // At least one row must match, else sqlite_schema is corrupt.
    if (rc == RC.OK and data.n_init_row == 0) rc = RC.CORRUPT;
    return rc;
}
