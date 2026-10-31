//! The MariaDB dialect (Phase 6): the frontend (a tokenizer and a
//! recursive-descent parser that read MariaDB SQL into the syntax tree
//! IR of src/ir/tree.zig, lowered by src/ir/lower.zig) and the hooks (the
//! dialect's functions, the engine functions its trees use, the
//! case-insensitive default collation).
//!
//! The pieces:
//!  - lexer.zig: tokens (backticks, MariaDB strings and escapes, `#` and
//!    `-- ` comments, executable comments, X'..', 0x.., b'..', @vars);
//!  - state.zig: the session (sql_mode, warnings, user variables) in
//!    dialect.ConnState.mariadb;
//!  - parser.zig: parser core, expressions, SELECT; functions.zig:
//!    function calls; dml.zig: INSERT/REPLACE/UPDATE/DELETE; ddl.zig:
//!    CREATE/DROP/ALTER (the IR renders them as SQLite text and records
//!    xq_catalog; ddl.zig adds MariaDB's indexes and catalog keys);
//!    session.zig: SET, transactions, SHOW, DESCRIBE (SHOW and
//!    DESCRIBE are SQLite queries over the schema, lowered as text);
//!  - databases.zig: CREATE/DROP DATABASE, USE, SHOW DATABASES/TABLES:
//!    MariaDB's databases are SQLite's (main, ATTACH) and named schemas
//!    in main (catalog/schema.zig), names resolved by Parser.relation();
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
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const parser = @import("parser.zig");
const dml = @import("dml.zig");
const ddl = @import("ddl.zig");
const session = @import("session.zig");
const databases = @import("databases.zig");
const types = @import("types.zig");
const rt = @import("runtime.zig");
const shared = @import("../shared_funcs.zig");
const json = @import("json.zig");

pub const frontend: dialect.Frontend = .{ .run = run };

const Parser = parser.Parser;
const Error = parser.Error;

/// Compile the first statement of `sql` (dialect.Frontend's contract).
pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
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
    if (!ok) {
        p.tail = sql[sql.len..];
        try translateError(p);
        return error.ParseFailed;
    }
    if (s.isOp(";")) {
        s.advance();
        p.tail = sql[@intFromPtr(s.prev_end) - @intFromPtr(sql.ptr) ..];
    } else p.tail = sql[sql.len..];
    ir.stmt.finishCoding(p);
}

/// SQLite's "no such table: x" (from lowering) in MariaDB's words:
/// "Table 'db.x' doesn't exist". A name without a database is in the
/// current one; a mangled name "db.x" (Parser.relation()) reads the same.
fn translateError(p: *int.Parse) int.Oom!void {
    const m: []const u8 = p.err_msg orelse return;
    const prefix = "no such table: ";
    if (!std.mem.startsWith(u8, m, prefix)) return;
    const name = m[prefix.len..];
    const db: []const u8 = if (std.mem.indexOfScalar(u8, name, '.') != null) "" else p.db.xq.mariadb.currentDatabase() orelse "main";
    p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "Table '{s}{s}{s}' doesn't exist", .{ db, if (db.len > 0) "." else "", name }, 0);
}

/// SHOW WARNINGS and friends look at the warnings of the statement
/// before.
fn keepsWarnings(s: *Parser) bool {
    const n = s.peek();
    if (s.isKw("SHOW")) return n.isAnyKw(&.{ "WARNINGS", "ERRORS", "COUNT" });
    if (s.isKw("SELECT") and n.kind == .sys_var) {
        return std.ascii.endsWithIgnoreCase(n.text, "warning_count") or std.ascii.endsWithIgnoreCase(n.text, "error_count");
    }
    return false;
}

fn statement(s: *Parser) Error!void {
    const t = s.tok;
    if (t.isKw("SELECT") or t.isKw("WITH") or t.is("(") or t.isKw("VALUES")) {
        return s.lowerStmt(.{ .select = try s.selectStmt() });
    }
    if (t.isKw("INSERT") or t.isKw("REPLACE")) return s.lowerStmt(try dml.insert(s));
    if (t.isKw("UPDATE")) return s.lowerStmt(try dml.update(s));
    if (t.isKw("DELETE")) return s.lowerStmt(try dml.delete(s));
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
    if (t.isAnyKw(&.{ "START", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE" })) {
        return session.transaction(s);
    }
    if (t.isKw("SET")) return session.set(s);
    if (t.isKw("SHOW")) return session.show(s);
    if (t.isKw("USE")) return databases.use(s);
    if (t.isAnyKw(&.{ "DESCRIBE", "DESC", "EXPLAIN" })) {
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
    if (t.isKw("LOCK") or t.isKw("UNLOCK")) return session.lockTables(s);
    if (t.isKw("ANALYZE")) return session.analyzeTable(s);
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
    if (!temp and (s.isKw("DATABASE") or s.isKw("SCHEMA"))) return databases.create(s, or_replace);
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
    while (s.isAnyKw(&.{ "ALGORITHM", "DEFINER", "SQL" })) {
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
    if (s.isAnyKw(&.{ "TRIGGER", "PROCEDURE", "FUNCTION", "EVENT" })) {
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
    if (s.isKw("DATABASE") or s.isKw("SCHEMA")) return databases.drop(s);
    return s.syntaxError();
}

// ================================================================ hooks

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
    .engine_functions = &engine_functions,
    .engine_modules = &.{.{ .name = "xq_maria_json_table", .module = &@import("json_table.zig").module }},
    // utf8mb4_general_ci and the like: case-insensitive.
    .default_collation = "NOCASE",
};

const det: dfunc.Options = .{ .deterministic = true };
/// JSON functions: read and set the JSON subtype (json.zig).
const jdet: dfunc.Options = .{ .deterministic = true, .subtype = true, .result_subtype = true };

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
    dfunc.scalar("concat", -1, det, concatFunc),
    dfunc.scalar("nextval", 1, .{ .unsafe = true }, sequence.nextvalFunc),
    dfunc.scalar("lastval", 1, .{ .unsafe = true }, lastvalFunc),
    dfunc.scalar("setval", 2, .{ .unsafe = true }, sequence.setvalFunc),
    dfunc.scalar("setval", 3, .{ .unsafe = true }, sequence.setvalFunc),
    // Variables (never in the schema: MariaDB refuses them there).
    dfunc.scalar("xq_sysvar", 1, .{}, session.sysvarFunc),
    dfunc.scalar("xq_set_sysvar", 2, .{ .direct_only = true }, session.setSysvarFunc),
    dfunc.scalar("xq_uservar", 1, .{}, session.uservarFunc),
    dfunc.scalar("xq_set_uservar", 2, .{ .direct_only = true }, session.setUservarFunc),
    dfunc.scalar("xq_maria_use", 1, .{ .direct_only = true }, databases.useFunc),
    // Math.
    dfunc.scalar("floor", 1, det, shared.floorFunc),
    dfunc.scalar("ceil", 1, det, shared.ceilFunc),
    dfunc.scalar("ceiling", 1, det, shared.ceilFunc),
    dfunc.scalar("pow", 2, det, rt.powFunc),
    dfunc.scalar("power", 2, det, rt.powFunc),
    dfunc.scalar("sqrt", 1, det, shared.sqrtFunc),
    dfunc.scalar("exp", 1, det, shared.expFunc),
    dfunc.scalar("ln", 1, det, shared.lnFunc),
    dfunc.scalar("log", 1, det, shared.logFunc),
    dfunc.scalar("log", 2, det, shared.logFunc),
    dfunc.scalar("log2", 1, det, shared.log2Func),
    dfunc.scalar("log10", 1, det, shared.log10Func),
    dfunc.scalar("pi", 0, det, shared.piFunc),
    dfunc.scalar("sin", 1, det, shared.sinFunc),
    dfunc.scalar("cos", 1, det, shared.cosFunc),
    dfunc.scalar("tan", 1, det, shared.tanFunc),
    dfunc.scalar("asin", 1, det, shared.asinFunc),
    dfunc.scalar("acos", 1, det, shared.acosFunc),
    dfunc.scalar("atan", 1, det, shared.atanFunc),
    dfunc.scalar("degrees", 1, det, shared.degreesFunc),
    dfunc.scalar("radians", 1, det, shared.radiansFunc),
    dfunc.scalar("truncate", 2, det, shared.truncateFunc),
    dfunc.scalar("round", 1, det, shared.roundFunc),
    dfunc.scalar("round", 2, det, shared.roundFunc),
    // Strings.
    dfunc.scalar("left", 2, det, shared.leftFunc),
    dfunc.scalar("right", 2, det, shared.rightFunc),
    dfunc.scalar("repeat", 2, det, shared.repeatFunc),
    dfunc.scalar("space", 1, det, shared.spaceFunc),
    dfunc.scalar("reverse", 1, det, shared.reverseFunc),
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
    dfunc.scalar("ascii", 1, det, shared.asciiFunc),
    // JSON (json.zig); JSON_VALID is SQLite's json_valid().
    dfunc.scalar("json_extract", -1, jdet, json.extractFunc),
    dfunc.scalar("json_value", 2, jdet, json.valueFunc),
    dfunc.scalar("json_query", 2, jdet, json.queryFunc),
    dfunc.scalar("json_unquote", 1, jdet, json.unquoteFunc),
    dfunc.scalar("json_quote", 1, jdet, json.quoteFunc),
    dfunc.scalar("json_object", -1, jdet, json.objectFunc),
    dfunc.scalar("json_array", -1, jdet, json.arrayFunc),
    dfunc.scalar("json_contains", 2, jdet, json.containsFunc),
    dfunc.scalar("json_contains", 3, jdet, json.containsFunc),
    dfunc.scalar("json_contains_path", -1, jdet, json.containsPathFunc),
    dfunc.scalar("json_exists", 2, jdet, json.existsFunc),
    dfunc.scalar("json_keys", 1, jdet, json.keysFunc),
    dfunc.scalar("json_keys", 2, jdet, json.keysFunc),
    dfunc.scalar("json_length", 1, jdet, json.lengthFunc),
    dfunc.scalar("json_length", 2, jdet, json.lengthFunc),
    dfunc.scalar("json_depth", 1, jdet, json.depthFunc),
    dfunc.scalar("json_type", 1, jdet, json.typeFunc),
    dfunc.scalar("json_set", -1, jdet, json.setFunc),
    dfunc.scalar("json_insert", -1, jdet, json.insertFunc),
    dfunc.scalar("json_replace", -1, jdet, json.replaceFunc),
    dfunc.scalar("json_remove", -1, jdet, json.removeFunc),
    dfunc.scalar("json_array_append", -1, jdet, json.arrayAppendFunc),
    dfunc.scalar("json_array_insert", -1, jdet, json.arrayInsertFunc),
    dfunc.scalar("json_merge", -1, jdet, json.mergePreserveFunc),
    dfunc.scalar("json_merge_preserve", -1, jdet, json.mergePreserveFunc),
    dfunc.scalar("json_merge_patch", -1, jdet, json.mergePatchFunc),
    dfunc.scalar("json_search", -1, jdet, json.searchFunc),
    dfunc.scalar("json_compact", 1, jdet, json.compactFunc),
    dfunc.scalar("json_loose", 1, jdet, json.looseFunc),
    dfunc.scalar("json_detailed", 1, jdet, json.detailedFunc),
    dfunc.scalar("json_detailed", 2, jdet, json.detailedFunc),
    dfunc.scalar("json_pretty", 1, jdet, json.detailedFunc),
    dfunc.scalar("json_pretty", 2, jdet, json.detailedFunc),
    dfunc.scalar("json_equals", 2, jdet, json.equalsFunc),
    dfunc.scalar("json_normalize", 1, jdet, json.normalizeFunc),
    dfunc.scalar("json_overlaps", 2, jdet, json.overlapsFunc),
    dfunc.aggregate("json_arrayagg", 1, jdet, json.arrayaggStep, json.arrayaggFinal),
    dfunc.aggregate("json_arrayagg", 2, jdet, json.arrayaggStep, json.arrayaggFinal),
    dfunc.aggregate("json_objectagg", 2, jdet, json.objectaggStep, json.objectaggFinal),
};

/// The functions the IR's semantic nodes lower and render to (Coerce,
/// Div .int, Cast .typed), MariaDB's XOR operators and the functions the
/// parser rewrites MariaDB's syntax and names to (INTERVAL, EXTRACT,
/// TIMESTAMPDIFF, STDDEV ...): visible in every dialect
/// (dialect.Hooks.engine_functions), so that the schema may keep them.
const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_coerce", 7, .{}, types.coerceFunc),
    dfunc.scalar("xq_div", 2, det, rt.divFunc),
    dfunc.scalar("xq_xor", 2, det, rt.xorFunc),
    dfunc.scalar("xq_bitxor", 2, det, rt.bitxorFunc),
    dfunc.scalar("xq_cast", 2, det, rt.castFunc),
    dfunc.scalar("xq_date_add", 3, det, rt.dateAddFunc),
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
    // What the parser adds around JSON (json.zig, json_table.zig).
    dfunc.scalar("xq_maria_json_bool", 1, jdet, json.boolFunc),
    dfunc.scalar("xq_maria_json_col", 1, jdet, json.colFunc),
    dfunc.scalar("xq_maria_json_cmp", 1, jdet, json.cmpFunc),
};

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&engine_functions);
}

/// The version string of MariaDB's VERSION().
pub const version = "11.8.0-MariaDB-xqlite-" ++ @import("../../sql/func/func.zig").sqlite_version;

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}

/// CONCAT(str, ...): the arguments as text, NULL if any is NULL.
fn concatFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    const gpa = dfunc.gpa(ctx);
    var out: std.ArrayList(u8) = .empty;
    // Empty once resultOwned() has it.
    defer out.deinit(gpa);
    for (argv) |m| {
        const z = dfunc.text(ctx, m) orelse return;
        out.appendSlice(gpa, z) catch return api.resultErrorNomem(ctx);
    }
    dfunc.resultOwned(ctx, &out);
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
    _ = @import("json.zig");
    _ = @import("test.zig");
}
