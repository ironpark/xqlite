//! The MariaDB dialect (Phase 6): the frontend (a tokenizer and a
//! recursive-descent parser that lower MariaDB SQL into the IR of
//! src/ir/ir.zig) and the hooks (the dialect's functions, the
//! case-insensitive default collation).
//!
//! The pieces:
//!  - lexer.zig: tokens (backticks, MariaDB strings and escapes, `#` and
//!    `-- ` comments, executable comments, X'..', 0x.., b'..', @vars);
//!  - state.zig: the session (sql_mode, warnings, user variables) in
//!    dialect.ConnState.mariadb;
//!  - parser.zig: parser core, expressions, SELECT; functions.zig:
//!    function calls; dml.zig: INSERT/REPLACE/UPDATE/DELETE; ddl.zig:
//!    CREATE/DROP/ALTER (rendered as SQLite text + xq_catalog);
//!    session.zig: SET, transactions, SHOW, DESCRIBE, USE, PRAGMA;
//!  - infoschema.zig: information_schema.TABLES, COLUMNS, SCHEMATA;
//!  - types.zig: MariaDB column types and the sql_mode-dependent value
//!    conversion of INSERT/UPDATE; runtime.zig: the dialect's functions.
//!
//! Identifiers: names keep the case they are written in and compare
//! case-insensitively (SQLite's rule), which is MariaDB's
//! lower_case_table_names=2 behaviour (@@lower_case_table_names is 2).
//! Comparisons without a collation are case-insensitive
//! (Hooks.default_collation NOCASE, which folds ASCII letters only), and
//! DDL names the collation of every text column so that indexes agree.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const sequence = @import("../../catalog/sequence.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const parser = @import("parser.zig");
const dml = @import("dml.zig");
const ddl = @import("ddl.zig");
const session = @import("session.zig");
const types = @import("types.zig");
const rt = @import("runtime.zig");

pub const frontend: dialect.Frontend = .{ .name = "mariadb", .run = run };

const Parser = parser.Parser;
const Error = parser.Error;

/// Compile the first statement of `sql` (dialect.Frontend's contract).
pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    p.rc = int.RC.OK;
    p.tail = sql;
    const db = p.db;
    var s: Parser = .init(p, sql, db.xq.mariadb.sql_mode);
    while (s.isOp(";")) s.advance();
    if (s.tok.kind == .eof) {
        p.tail = sql[sql.len..];
        return;
    }
    if (!keepsWarnings(&s)) db.xq.mariadb.clearWarnings();
    const ok = blk: {
        statement(&s) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => break :blk false,
        };
        if (!s.atStmtEnd()) {
            _ = s.syntaxError() catch {};
            break :blk false;
        }
        break :blk p.n_err == 0;
    };
    if (ok) {
        if (s.isOp(";")) {
            s.advance();
            p.tail = sql[@intFromPtr(s.prev_end) - @intFromPtr(sql.ptr) ..];
        } else p.tail = sql[sql.len..];
        ir.stmt.finishCoding(p);
    } else {
        p.tail = sql[sql.len..];
    }
    if (p.new_table) |t| if (!p.inSpecialParse()) {
        build.deleteTable(db, t);
        p.new_table = null;
    };
    if (p.n_err > 0 or p.err_msg != null or (p.rc != int.RC.OK and p.rc != int.RC.DONE)) {
        if (p.err_msg == null) {
            p.err_msg = try p.arena.dupeSentinel(u8, @import("../../sql/util.zig").errStr(if (p.rc == int.RC.OK or p.rc == int.RC.DONE) int.RC.ERROR else p.rc), 0);
        }
        if (p.rc == int.RC.OK or p.rc == int.RC.DONE) p.rc = int.RC.ERROR;
        return error.ParseFailed;
    }
}

/// SHOW WARNINGS and friends look at the warnings of the statement
/// before.
fn keepsWarnings(s: *Parser) bool {
    const n = s.peek();
    if (s.isKw("SHOW")) return n.isKw("WARNINGS") or n.isKw("ERRORS") or n.isKw("COUNT");
    if (s.isKw("SELECT") and n.kind == .sys_var) {
        return std.ascii.endsWithIgnoreCase(n.text, "warning_count") or std.ascii.endsWithIgnoreCase(n.text, "error_count");
    }
    return false;
}

fn statement(s: *Parser) Error!void {
    const t = s.tok;
    if (t.isKw("SELECT") or t.isKw("WITH") or t.is("(") or t.isKw("VALUES")) {
        const sel = try s.selectStmt();
        ir.stmt.select(s.p, sel);
        return s.check();
    }
    if (t.isKw("INSERT") or t.isKw("REPLACE")) return dml.insert(s);
    if (t.isKw("UPDATE")) return dml.update(s);
    if (t.isKw("DELETE")) return dml.delete(s);
    if (t.isKw("TRUNCATE")) return dml.truncate(s);
    if (t.isKw("CREATE")) return create(s);
    if (t.isKw("DROP")) return drop(s);
    if (t.isKw("ALTER")) {
        s.advance();
        if (s.isKw("ONLINE")) s.advance();
        if (s.isKw("SEQUENCE")) return s.fail("xqlite: ALTER SEQUENCE is not supported", .{});
        return ddl.alterTable(s);
    }
    if (t.isKw("RENAME")) {
        s.advance();
        return ddl.renameTableStmt(s);
    }
    if (t.isKw("START") or t.isKw("BEGIN") or t.isKw("COMMIT") or t.isKw("ROLLBACK") or t.isKw("SAVEPOINT") or t.isKw("RELEASE")) {
        return session.transaction(s);
    }
    if (t.isKw("SET")) return session.set(s);
    if (t.isKw("SHOW")) return session.show(s);
    if (t.isKw("USE")) return session.use(s);
    if (t.isKw("DESCRIBE") or t.isKw("DESC") or t.isKw("EXPLAIN")) {
        if (try session.describe(s)) return;
        s.advance();
        while (s.eatKw("EXTENDED") or s.eatKw("PARTITIONS") or s.eatKw("ANALYZE")) {}
        if (s.eatKw("FORMAT")) {
            try s.expectOp("=");
            _ = try s.anyName();
        }
        ir.stmt.setExplain(s.p, 2);
        return statement(s);
    }
    if (t.isKw("PRAGMA") or t.isKw("ATTACH") or t.isKw("DETACH") or t.isKw("VACUUM") or t.isKw("REINDEX")) {
        // SQLite commands (xqlite extensions of the dialect).
        return session.pragma(s);
    }
    if (t.isKw("LOCK") or t.isKw("UNLOCK")) return session.lockTables(s);
    if (t.isKw("DO")) {
        s.advance();
        _ = try s.exprList();
        return s.fail("xqlite: DO is not supported", .{});
    }
    return s.syntaxError();
}

fn create(s: *Parser) Error!void {
    try s.expectKw("CREATE");
    var or_replace = false;
    if (s.eatKw("OR")) {
        try s.expectKw("REPLACE");
        or_replace = true;
    }
    const temp = s.eatKw("TEMPORARY") or s.eatKw("TEMP");
    if (s.isKw("TABLE")) return ddl.createTable(s, temp, or_replace);
    if (s.isKw("SEQUENCE")) {
        if (or_replace) return s.fail("xqlite: CREATE OR REPLACE SEQUENCE is not supported", .{});
        return ddl.createSequence(s);
    }
    if (!temp) {
        const unique = s.eatKw("UNIQUE");
        if (!unique) _ = s.eatKw("FULLTEXT") or s.eatKw("SPATIAL");
        if (s.isKw("INDEX")) return ddl.createIndex(s, unique);
        if (unique) return s.syntaxError();
    }
    // View options.
    while (s.isKw("ALGORITHM") or s.isKw("DEFINER") or s.isKw("SQL")) {
        if (s.eatKw("SQL")) {
            try s.expectKw("SECURITY");
            _ = try s.anyName();
            continue;
        }
        s.advance();
        try s.expectOp("=");
        // DEFINER = user@host / CURRENT_USER.
        while (!s.atStmtEnd() and !s.isKw("VIEW") and !s.isKw("SQL") and !s.isKw("ALGORITHM")) s.advance();
    }
    if (s.isKw("VIEW")) return ddl.createView(s, or_replace, temp);
    if (s.isKw("DATABASE") or s.isKw("SCHEMA")) return s.fail("xqlite: CREATE DATABASE is not supported (use ATTACH)", .{});
    if (s.isKw("TRIGGER") or s.isKw("PROCEDURE") or s.isKw("FUNCTION") or s.isKw("EVENT")) {
        return s.fail("xqlite: CREATE {s} is not supported in the MariaDB dialect", .{s.tok.text});
    }
    return s.syntaxError();
}

fn drop(s: *Parser) Error!void {
    try s.expectKw("DROP");
    _ = s.eatKw("TEMPORARY");
    if (s.isKw("TABLE") or s.isKw("TABLES")) return ddl.dropTable(s, false);
    if (s.isKw("VIEW")) return ddl.dropTable(s, true);
    if (s.isKw("INDEX")) return ddl.dropIndex(s);
    if (s.isKw("SEQUENCE")) return ddl.dropSequence(s);
    if (s.isKw("DATABASE") or s.isKw("SCHEMA")) return s.fail("xqlite: DROP DATABASE is not supported (use DETACH)", .{});
    return s.syntaxError();
}

// ================================================================ hooks

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
    // utf8mb4_general_ci and the like: case-insensitive.
    .default_collation = "NOCASE",
};

const det: dfunc.Options = .{ .deterministic = true };

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
    dfunc.scalar("concat", -1, det, concatFunc),
    dfunc.scalar("nextval", 1, .{ .unsafe = true }, sequence.nextvalFunc),
    dfunc.scalar("lastval", 1, .{ .unsafe = true }, lastvalFunc),
    dfunc.scalar("setval", 2, .{ .unsafe = true }, sequence.setvalFunc),
    dfunc.scalar("setval", 3, .{ .unsafe = true }, sequence.setvalFunc),
    // Lowered operators and statements.
    dfunc.scalar("xq_coerce", 7, .{}, types.coerceFunc),
    dfunc.scalar("xq_sysvar", 1, .{}, session.sysvarFunc),
    dfunc.scalar("xq_set_sysvar", 2, .{ .direct_only = true }, session.setSysvarFunc),
    dfunc.scalar("xq_uservar", 1, .{}, session.uservarFunc),
    dfunc.scalar("xq_set_uservar", 2, .{ .direct_only = true }, session.setUservarFunc),
    dfunc.scalar("xq_div", 2, det, rt.divFunc),
    dfunc.scalar("xq_xor", 2, det, rt.xorFunc),
    dfunc.scalar("xq_bitxor", 2, det, rt.bitxorFunc),
    dfunc.scalar("xq_date_add", 3, det, rt.dateAddFunc),
    dfunc.scalar("xq_cast", 2, det, rt.castFunc),
    dfunc.scalar("xq_extract", 2, det, rt.extractFunc),
    dfunc.scalar("xq_timestampdiff", 3, det, rt.timestampdiffFunc),
    dfunc.scalar("xq_rand", 0, .{}, rt.randFunc),
    dfunc.scalar("xq_rand", 1, .{}, rt.randFunc),
    dfunc.scalar("xq_uuid", 0, .{}, rt.uuidFunc),
    dfunc.scalar("xq_bit_length", 1, det, rt.bitLengthFunc),
    dfunc.aggregate("xq_stddev_pop", 1, det, rt.varStep, rt.stddevPopFinal),
    dfunc.aggregate("xq_stddev_samp", 1, det, rt.varStep, rt.stddevSampFinal),
    dfunc.aggregate("xq_var_pop", 1, det, rt.varStep, rt.varPopFinal),
    dfunc.aggregate("xq_var_samp", 1, det, rt.varStep, rt.varSampFinal),
    // Math.
    dfunc.scalar("floor", 1, det, rt.floorFunc),
    dfunc.scalar("ceil", 1, det, rt.ceilFunc),
    dfunc.scalar("ceiling", 1, det, rt.ceilFunc),
    dfunc.scalar("pow", 2, det, rt.powFunc),
    dfunc.scalar("power", 2, det, rt.powFunc),
    dfunc.scalar("sqrt", 1, det, rt.sqrtFunc),
    dfunc.scalar("exp", 1, det, rt.expFunc),
    dfunc.scalar("ln", 1, det, rt.lnFunc),
    dfunc.scalar("log", 1, det, rt.logFunc),
    dfunc.scalar("log", 2, det, rt.logFunc),
    dfunc.scalar("log2", 1, det, rt.log2Func),
    dfunc.scalar("log10", 1, det, rt.log10Func),
    dfunc.scalar("pi", 0, det, rt.piFunc),
    dfunc.scalar("sin", 1, det, rt.sinFunc),
    dfunc.scalar("cos", 1, det, rt.cosFunc),
    dfunc.scalar("tan", 1, det, rt.tanFunc),
    dfunc.scalar("asin", 1, det, rt.asinFunc),
    dfunc.scalar("acos", 1, det, rt.acosFunc),
    dfunc.scalar("atan", 1, det, rt.atanFunc),
    dfunc.scalar("degrees", 1, det, rt.degreesFunc),
    dfunc.scalar("radians", 1, det, rt.radiansFunc),
    dfunc.scalar("truncate", 2, det, rt.truncateFunc),
    dfunc.scalar("round", 1, det, rt.roundFunc),
    dfunc.scalar("round", 2, det, rt.roundFunc),
    // Strings.
    dfunc.scalar("left", 2, det, rt.leftFunc),
    dfunc.scalar("right", 2, det, rt.rightFunc),
    dfunc.scalar("repeat", 2, det, rt.repeatFunc),
    dfunc.scalar("space", 1, det, rt.spaceFunc),
    dfunc.scalar("reverse", 1, det, rt.reverseFunc),
    dfunc.scalar("lpad", 2, det, rt.lpadFunc),
    dfunc.scalar("lpad", 3, det, rt.lpadFunc),
    dfunc.scalar("rpad", 2, det, rt.rpadFunc),
    dfunc.scalar("rpad", 3, det, rt.rpadFunc),
    dfunc.scalar("hex", 1, det, rt.hexFunc),
    dfunc.scalar("format", 2, det, rt.formatFunc),
    dfunc.scalar("insert", 4, det, rt.insertFunc),
    dfunc.scalar("locate", 3, det, rt.locateFunc),
    dfunc.scalar("find_in_set", 2, det, rt.findInSetFunc),
    dfunc.scalar("field", -1, det, rt.fieldFunc),
    dfunc.scalar("elt", -1, det, rt.eltFunc),
    dfunc.scalar("json_unquote", 1, det, rt.jsonUnquoteFunc),
    // Dates.
    dfunc.scalar("year", 1, det, rt.yearFunc),
    dfunc.scalar("month", 1, det, rt.monthFunc),
    dfunc.scalar("day", 1, det, rt.dayFunc),
    dfunc.scalar("dayofmonth", 1, det, rt.dayFunc),
    dfunc.scalar("hour", 1, det, rt.hourFunc),
    dfunc.scalar("minute", 1, det, rt.minuteFunc),
    dfunc.scalar("second", 1, det, rt.secondFunc),
    dfunc.scalar("microsecond", 1, det, rt.microsecondFunc),
    dfunc.scalar("dayofweek", 1, det, rt.dayofweekFunc),
    dfunc.scalar("weekday", 1, det, rt.weekdayFunc),
    dfunc.scalar("dayofyear", 1, det, rt.dayofyearFunc),
    dfunc.scalar("quarter", 1, det, rt.quarterFunc),
    dfunc.scalar("to_days", 1, det, rt.toDaysFunc),
    dfunc.scalar("datediff", 2, det, rt.datediffFunc),
    dfunc.scalar("last_day", 1, det, rt.lastDayFunc),
    dfunc.scalar("date_format", 2, det, rt.dateFormatFunc),
    dfunc.scalar("dayname", 1, det, rt.daynameFunc),
    dfunc.scalar("monthname", 1, det, rt.monthnameFunc),
    dfunc.scalar("str_to_date", 2, det, rt.strToDateFunc),
    dfunc.scalar("ascii", 1, det, rt.asciiFunc),
};

comptime {
    dfunc.checkTable(&functions);
}

/// The version string of MariaDB's VERSION().
pub const version = "11.8.0-MariaDB-xqlite-" ++ @import("../../sql/func.zig").sqlite_version;

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}

/// CONCAT(str, ...): the arguments as text, NULL if any is NULL.
fn concatFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(db.gpa);
    for (argv) |m| {
        if (api.valueType(m) == vi.SQLITE_NULL) return api.resultNull(ctx);
        const z = api.valueText(m) orelse return api.resultErrorNomem(ctx);
        out.appendSlice(db.gpa, z) catch return api.resultErrorNomem(ctx);
    }
    api.resultText(ctx, out.items, .transient);
}

/// LASTVAL(seq): the value NEXTVAL(seq) last returned on this connection,
/// NULL if none.
fn lastvalFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const v = sequence.currval(db, name) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, v);
}

test {
    _ = @import("state.zig");
    _ = @import("lexer.zig");
    _ = @import("types.zig");
    _ = @import("runtime.zig");
    _ = @import("test.zig");
}
