//! Session and introspection statements: SET (system and user
//! variables), transactions, USE, SHOW, DESCRIBE, EXPLAIN, LOCK TABLES.
//! PRAGMA and SQLite's other commands go to SQLite's grammar before this
//! frontend runs (dialect.runParser()).
//!
//! SET runs when the statement runs (it calls xq_set_sysvar() or
//! xq_set_uservar() for each assignment), so the value may be any
//! expression: SET sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES'). A
//! parser-level mode affects the statements compiled after that.
//!
//! The SHOW statements are SQLite SELECTs over the schema, the pragma
//! table-valued functions and xq_catalog, lowered as SQLite text.
//! SHOW WARNINGS lists the warnings recorded when the statement is
//! compiled (normally right after the statement that produced them).

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");
const lexer = @import("lexer.zig");
const frontend = @import("frontend.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = int.Expr;
const TK = int.TK;
const irTok = parser.irTok;

// ===================================================== system variables

const Var = struct {
    name: []const u8,
    /// The value of a variable xqlite does not track (shown as is).
    value: Value = .{ .text = "" },
    /// Whether SET accepts it (and ignores the value, unless handled).
    settable: bool = true,

    const Value = union(enum) { text: []const u8, int: i64, dynamic: Dynamic };

    /// The variables whose value is the session's (sysvarFunc()).
    const Dynamic = enum { sql_mode, autocommit, foreign_key_checks, warning_count, last_insert_id, in_transaction };
};

/// The system variables a MariaDB session can read; SET accepts the
/// settable ones and ignores the value of those xqlite does not use.
const vars = [_]Var{
    .{ .name = "sql_mode", .value = .{ .dynamic = .sql_mode } },
    .{ .name = "autocommit", .value = .{ .dynamic = .autocommit } },
    .{ .name = "foreign_key_checks", .value = .{ .dynamic = .foreign_key_checks } },
    .{ .name = "warning_count", .value = .{ .dynamic = .warning_count }, .settable = false },
    .{ .name = "error_count", .value = .{ .int = 0 }, .settable = false },
    .{ .name = "last_insert_id", .value = .{ .dynamic = .last_insert_id } },
    .{ .name = "identity", .value = .{ .dynamic = .last_insert_id } },
    .{ .name = "version", .value = .{ .text = frontend.version }, .settable = false },
    .{ .name = "version_comment", .value = .{ .text = "xqlite" }, .settable = false },
    .{ .name = "version_compile_os", .value = .{ .text = @tagName(@import("builtin").os.tag) }, .settable = false },
    .{ .name = "version_compile_machine", .value = .{ .text = @tagName(@import("builtin").cpu.arch) }, .settable = false },
    .{ .name = "character_set_client", .value = .{ .text = "utf8mb4" } },
    .{ .name = "character_set_connection", .value = .{ .text = "utf8mb4" } },
    .{ .name = "character_set_results", .value = .{ .text = "utf8mb4" } },
    .{ .name = "character_set_server", .value = .{ .text = "utf8mb4" } },
    .{ .name = "character_set_database", .value = .{ .text = "utf8mb4" } },
    .{ .name = "collation_connection", .value = .{ .text = "utf8mb4_general_ci" } },
    .{ .name = "collation_server", .value = .{ .text = "utf8mb4_general_ci" } },
    .{ .name = "collation_database", .value = .{ .text = "utf8mb4_general_ci" } },
    .{ .name = "names", .value = .{ .text = "utf8mb4" } },
    .{ .name = "time_zone", .value = .{ .text = "+00:00" } },
    .{ .name = "system_time_zone", .value = .{ .text = "UTC" }, .settable = false },
    .{ .name = "lower_case_table_names", .value = .{ .int = 2 }, .settable = false },
    .{ .name = "max_allowed_packet", .value = .{ .int = 16777216 } },
    .{ .name = "net_buffer_length", .value = .{ .int = 16384 } },
    .{ .name = "auto_increment_increment", .value = .{ .int = 1 }, .settable = false },
    .{ .name = "auto_increment_offset", .value = .{ .int = 1 }, .settable = false },
    .{ .name = "tx_isolation", .value = .{ .text = "SERIALIZABLE" } },
    .{ .name = "transaction_isolation", .value = .{ .text = "SERIALIZABLE" } },
    .{ .name = "tx_read_only", .value = .{ .int = 0 } },
    .{ .name = "transaction_read_only", .value = .{ .int = 0 } },
    .{ .name = "unique_checks", .value = .{ .int = 1 } },
    .{ .name = "sql_notes", .value = .{ .int = 1 } },
    .{ .name = "sql_warnings", .value = .{ .int = 0 } },
    .{ .name = "sql_quote_show_create", .value = .{ .int = 1 } },
    .{ .name = "sql_safe_updates", .value = .{ .int = 0 } },
    .{ .name = "sql_select_limit", .value = .{ .int = std.math.maxInt(i64) } },
    .{ .name = "sql_auto_is_null", .value = .{ .int = 0 } },
    .{ .name = "sql_log_bin", .value = .{ .int = 1 } },
    .{ .name = "big_tables", .value = .{ .int = 0 } },
    .{ .name = "wait_timeout", .value = .{ .int = 28800 } },
    .{ .name = "interactive_timeout", .value = .{ .int = 28800 } },
    .{ .name = "net_read_timeout", .value = .{ .int = 30 } },
    .{ .name = "net_write_timeout", .value = .{ .int = 60 } },
    .{ .name = "max_execution_time", .value = .{ .int = 0 } },
    .{ .name = "max_statement_time", .value = .{ .int = 0 } },
    .{ .name = "default_storage_engine", .value = .{ .text = "InnoDB" } },
    .{ .name = "storage_engine", .value = .{ .text = "InnoDB" } },
    .{ .name = "default_tmp_storage_engine", .value = .{ .text = "" } },
    .{ .name = "explicit_defaults_for_timestamp", .value = .{ .int = 1 } },
    .{ .name = "old_passwords", .value = .{ .int = 0 } },
    .{ .name = "hostname", .value = .{ .text = "localhost" }, .settable = false },
    .{ .name = "port", .value = .{ .int = 0 }, .settable = false },
    .{ .name = "socket", .value = .{ .text = "" }, .settable = false },
    .{ .name = "datadir", .value = .{ .text = "" }, .settable = false },
    .{ .name = "have_ssl", .value = .{ .text = "DISABLED" }, .settable = false },
    .{ .name = "license", .value = .{ .text = "MIT" }, .settable = false },
    .{ .name = "read_only", .value = .{ .int = 0 }, .settable = false },
    .{ .name = "server_id", .value = .{ .int = 1 }, .settable = false },
    .{ .name = "in_transaction", .value = .{ .dynamic = .in_transaction }, .settable = false },
    .{ .name = "group_concat_max_len", .value = .{ .int = 1048576 } },
    .{ .name = "div_precision_increment", .value = .{ .int = 4 } },
    .{ .name = "sql_big_selects", .value = .{ .int = 1 } },
    .{ .name = "profiling", .value = .{ .int = 0 } },
    .{ .name = "note_verbosity", .value = .{ .text = "basic,explain" } },
    .{ .name = "sql_require_primary_key", .value = .{ .int = 0 } },
    .{ .name = "check_constraint_checks", .value = .{ .int = 1 } },
    .{ .name = "innodb_strict_mode", .value = .{ .int = 1 } },
    .{ .name = "default_week_format", .value = .{ .int = 0 } },
    .{ .name = "lc_time_names", .value = .{ .text = "en_US" } },
    .{ .name = "sql_slave_skip_counter", .value = .{ .int = 0 } },
    .{ .name = "time_format", .value = .{ .text = "%H:%i:%s" }, .settable = false },
    .{ .name = "date_format", .value = .{ .text = "%Y-%m-%d" }, .settable = false },
    .{ .name = "datetime_format", .value = .{ .text = "%Y-%m-%d %H:%i:%s" }, .settable = false },
};

fn findVar(name: []const u8) ?*const Var {
    for (&vars) |*v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v;
    return null;
}

pub fn isSysVar(name: []const u8) bool {
    return findVar(name) != null;
}

/// xq_sysvar(name): the value of a system variable.
pub fn sysvarFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const v = findVar(name) orelse return api.resultNull(ctx);
    switch (v.value) {
        .text => |z| api.resultText(ctx, z, .static),
        .int => |i| api.resultInt64(ctx, i),
        .dynamic => |d| switch (d) {
            .sql_mode => {
                var buf: [state.SqlMode.max_text]u8 = undefined;
                api.resultText(ctx, db.xq.mariadb.sql_mode.format(&buf), .transient);
            },
            .autocommit => api.resultInt64(ctx, 1),
            .in_transaction => api.resultInt64(ctx, @intFromBool(!db.auto_commit)),
            .foreign_key_checks => api.resultInt64(ctx, @intFromBool(db.flags.ForeignKeys)),
            .warning_count => api.resultInt64(ctx, db.xq.mariadb.n_warnings),
            .last_insert_id => api.resultInt64(ctx, db.last_rowid),
        },
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// xq_set_sysvar(name, value): SET name = value. NULL (from SET x =
/// DEFAULT) restores the default.
pub fn setSysvarFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const st = &db.xq.mariadb;
    const is_default = api.valueType(argv[1]) == vi.SQLITE_NULL;
    var msg_buf: [256]u8 = undefined;
    if (eq(name, "sql_mode")) {
        if (is_default) {
            st.sql_mode = .default;
            return api.resultNull(ctx);
        }
        const z = api.valueText(argv[1]) orelse "";
        var bad: []const u8 = "";
        st.sql_mode = state.SqlMode.parse(z, &bad) orelse {
            return api.resultError(ctx, std.fmt.bufPrint(&msg_buf, "Variable 'sql_mode' can't be set to the value of '{s}'", .{bad[0..@min(bad.len, 64)]}) catch "bad sql_mode");
        };
        return api.resultNull(ctx);
    }
    if (eq(name, "autocommit")) {
        if (!is_default and !truthy(argv[1])) return api.resultError(ctx, "xqlite: autocommit=0 is not supported (use START TRANSACTION)");
        return api.resultNull(ctx);
    }
    if (eq(name, "foreign_key_checks")) {
        // As PRAGMA foreign_keys: no effect inside a transaction.
        const on = is_default or truthy(argv[1]);
        if (db.auto_commit and db.flags.ForeignKeys != on) {
            db.flags.ForeignKeys = on;
            @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
        }
        return api.resultNull(ctx);
    }
    // Accepted and ignored.
    api.resultNull(ctx);
}

fn truthy(m: *dfunc.Mem) bool {
    if (api.valueType(m) == vi.SQLITE_TEXT) {
        const z = api.valueText(m) orelse "";
        return std.ascii.eqlIgnoreCase(z, "on") or std.ascii.eqlIgnoreCase(z, "true") or
            (std.fmt.parseInt(i64, z, 10) catch 0) != 0;
    }
    return api.valueInt64(m) != 0;
}

/// xq_uservar(name): the value of @name, NULL if never set.
pub fn uservarFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const v = db.xq.mariadb.userVar(name) orelse return api.resultNull(ctx);
    api.resultValue(ctx, v);
}

/// xq_set_uservar(name, value): @name := value, which it returns.
pub fn setUservarFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    db.xq.mariadb.setUserVar(db.gpa, name, argv[1]) catch return api.resultErrorNomem(ctx);
    api.resultValue(ctx, argv[1]);
}

// ================================================================== SET

/// SET assignments, SET NAMES, SET CHARACTER SET, SET TRANSACTION.
pub fn set(s: *Parser) Error!void {
    try s.expectKw("SET");
    var scope_global = false;
    if (s.eatKw("GLOBAL")) {
        scope_global = true;
    } else _ = s.eatKw("SESSION") or s.eatKw("LOCAL");
    if (s.eatKw("TRANSACTION")) {
        // ISOLATION LEVEL ... / READ ONLY|WRITE: accepted, ignored
        // (transactions are serializable).
        while (!s.atStmtEnd()) s.advance();
        return emptyStatement(s);
    }
    if (scope_global) return s.fail("xqlite: SET GLOBAL is not supported", .{});
    var calls: std.ArrayList(*Expr) = .empty;
    while (true) {
        if (s.isKw("NAMES") or ((s.isKw("CHARACTER") or s.isKw("CHARSET")))) {
            // SET NAMES cs [COLLATE c], SET CHARACTER SET cs: accepted.
            if (s.eatKw("CHARACTER")) try s.expectKw("SET") else s.advance();
            if (s.eatKw("DEFAULT")) {} else if (s.tok.kind == .string) {
                _ = try s.stringLiteral();
            } else _ = try s.anyName();
            if (s.eatKw("COLLATE")) {
                if (s.tok.kind == .string) _ = try s.stringLiteral() else _ = try s.anyName();
            }
        } else if (s.tok.kind == .user_var) {
            const t = s.tok;
            s.advance();
            if (!(s.eatOp("=") or s.eatOp(":="))) return s.syntaxError();
            const name = try std.ascii.allocLowerString(s.a, try userVarText(s, t));
            const v = try s.expr();
            try calls.append(s.a, try s.call("xq_set_uservar", &.{ try s.stringExpr(name), v }));
        } else {
            var name_text: []const u8 = undefined;
            if (s.tok.kind == .sys_var) {
                name_text = s.tok.text[2..];
                for ([_][]const u8{ "global.", "session.", "local." }) |scope| {
                    if (std.ascii.startsWithIgnoreCase(name_text, scope)) {
                        if (scope[0] == 'g') return s.fail("xqlite: SET GLOBAL is not supported", .{});
                        name_text = name_text[scope.len..];
                    }
                }
                s.advance();
            } else {
                const n = try s.anyName();
                name_text = try s.nameText(n);
            }
            const v = findVar(name_text) orelse return s.fail("Unknown system variable '{s}'", .{name_text});
            if (!v.settable) return s.fail("Variable '{s}' is a read only variable", .{v.name});
            if (!(s.eatOp("=") or s.eatOp(":="))) return s.syntaxError();
            var value: *Expr = undefined;
            if (s.isKw("DEFAULT")) {
                s.advance();
                value = try ir.expr.leaf(s.a, TK.NULL, null);
            } else if (s.isKw("ON") or s.isKw("OFF")) {
                value = try s.intExpr(@intFromBool(s.isKw("ON")));
                s.advance();
            } else if (s.tok.kind == .ident and !s.peek().is("(") and !s.peek().is(".") and !parser.isReserved(s.tok)) {
                // SET sql_mode = ANSI: a word is a string.
                value = try s.stringExpr(s.tok.text);
                s.advance();
            } else value = try s.expr();
            try calls.append(s.a, try s.call("xq_set_sysvar", &.{ try s.stringExpr(v.name), value }));
        }
        if (!s.eatOp(",")) break;
    }
    try s.check();
    try codeEval(s, calls.items);
}

fn userVarText(s: *Parser, t: lexer.Token) Error![]const u8 {
    const z = t.text[1..];
    if (z.len > 0 and z[0] == '`') return lexer.identValue(s.a, .{ .kind = .quoted_ident, .text = z });
    if (z.len > 0 and (z[0] == '\'' or z[0] == '"')) return lexer.stringValue(s.a, .{ .kind = .string, .text = z }, false);
    return z;
}

/// Code a statement that evaluates `exprs` for their effects and
/// returns no rows.
fn codeEval(s: *Parser, exprs: []const *Expr) Error!void {
    _ = build.getVdbe(s.p) orelse return error.ParseFailed;
    for (exprs) |e| {
        var nc: int.NameContext = .{ .parse = s.p };
        @import("../../sql/resolve.zig").resolveExprNames(&nc, e) catch return error.ParseFailed;
        s.p.n_mem += 1;
        @import("../../sql/expr_code.zig").exprCode(s.p, e, s.p.n_mem);
    }
}

/// A statement that does nothing (SET NAMES, LOCK TABLES ...).
pub fn emptyStatement(s: *Parser) Error!void {
    _ = build.getVdbe(s.p) orelse return error.ParseFailed;
}

// ========================================================= transactions

/// START TRANSACTION, BEGIN [WORK], COMMIT, ROLLBACK [TO SAVEPOINT],
/// SAVEPOINT, RELEASE SAVEPOINT.
pub fn transaction(s: *Parser) Error!void {
    if (s.eatKw("START")) {
        try s.expectKw("TRANSACTION");
        while (!s.atStmtEnd()) s.advance(); // READ ONLY|WRITE, WITH CONSISTENT SNAPSHOT
        return ir.txn.begin(s.p, TK.DEFERRED);
    }
    if (s.eatKw("BEGIN")) {
        _ = s.eatKw("WORK");
        return ir.txn.begin(s.p, TK.DEFERRED);
    }
    if (s.eatKw("COMMIT")) {
        _ = s.eatKw("WORK");
        try chainRelease(s);
        return ir.txn.end(s.p, TK.COMMIT);
    }
    if (s.eatKw("ROLLBACK")) {
        _ = s.eatKw("WORK");
        if (s.eatKw("TO")) {
            _ = s.eatKw("SAVEPOINT");
            const n = try s.name();
            return ir.txn.savepoint(s.p, .ROLLBACK, irTok(n));
        }
        try chainRelease(s);
        return ir.txn.end(s.p, TK.ROLLBACK);
    }
    if (s.eatKw("SAVEPOINT")) {
        const n = try s.name();
        // Outside a transaction a savepoint ends with its statement in
        // MariaDB; SQLite's would open a transaction.
        if (s.p.db.auto_commit) return emptyStatement(s);
        return ir.txn.savepoint(s.p, .BEGIN, irTok(n));
    }
    if (s.eatKw("RELEASE")) {
        try s.expectKw("SAVEPOINT");
        const n = try s.name();
        return ir.txn.savepoint(s.p, .RELEASE, irTok(n));
    }
    return s.syntaxError();
}

fn chainRelease(s: *Parser) Error!void {
    if (s.eatKw("AND")) {
        _ = s.eatKw("NO");
        try s.expectKw("CHAIN");
    }
    if (s.isKw("NO") or s.isKw("RELEASE")) {
        _ = s.eatKw("NO");
        try s.expectKw("RELEASE");
    }
}

// ================================================================= misc

/// USE db: the database must exist; the default schema stays main.
pub fn use(s: *Parser) Error!void {
    try s.expectKw("USE");
    const n = try s.anyName();
    const name = try s.nameText(n);
    if (build.findDbName(s.p.db, name) == null) return s.fail("Unknown database '{s}'", .{name});
    return emptyStatement(s);
}

/// LOCK TABLES ... / UNLOCK TABLES: accepted, nothing to do (the
/// database file is locked by transactions).
pub fn lockTables(s: *Parser) Error!void {
    while (!s.atStmtEnd()) s.advance();
    return emptyStatement(s);
}

/// Lower SQLite text (in p.arena) as part of this statement.
pub fn lowerText(s: *Parser, text: [:0]const u8) Error!void {
    try ir.stmt.lowerSqliteText(s.p, text);
    try s.check();
}

fn lowerFmt(s: *Parser, comptime fmt: []const u8, args: anytype) Error!void {
    const text = try std.fmt.allocPrintSentinel(s.a, fmt, args, 0);
    try lowerText(s, text);
}

/// SQLite string literal.
pub const Q = dialect.Quoted('\'');

/// SQLite identifier.
pub const Id = dialect.Quoted('"');

// ================================================================= SHOW

/// SHOW ..., DESCRIBE t, DESC t, EXPLAIN t.
pub fn show(s: *Parser) Error!void {
    try s.expectKw("SHOW");
    const full = s.eatKw("FULL");
    if (s.eatKw("TABLES")) return showTables(s, full);
    if (s.eatKw("COLUMNS") or s.eatKw("FIELDS")) {
        if (!(s.eatKw("FROM") or s.eatKw("IN"))) return s.syntaxError();
        const n1, const n2 = try s.qualifiedName();
        var schema: ?[]const u8 = if (n2.n != 0) try s.tokName(n1) else null;
        if (s.eatKw("FROM") or s.eatKw("IN")) schema = try s.nameText(try s.anyName());
        var like: ?[]const u8 = null;
        if (s.eatKw("LIKE")) like = try s.stringLiteral();
        return showColumns(s, try s.tokName(if (n2.n != 0) n2 else n1), schema, like);
    }
    if (s.eatKw("INDEX") or s.eatKw("INDEXES") or s.eatKw("KEYS")) {
        if (!(s.eatKw("FROM") or s.eatKw("IN"))) return s.syntaxError();
        const n1, const n2 = try s.qualifiedName();
        var schema: ?[]const u8 = if (n2.n != 0) try s.tokName(n1) else null;
        if (s.eatKw("FROM") or s.eatKw("IN")) schema = try s.nameText(try s.anyName());
        return showIndex(s, try s.tokName(if (n2.n != 0) n2 else n1), schema);
    }
    if (s.eatKw("CREATE")) {
        if (s.eatKw("TABLE") or s.eatKw("VIEW")) {
            const n1, const n2 = try s.qualifiedName();
            return showCreate(s, try s.tokName(if (n2.n != 0) n2 else n1), if (n2.n != 0) try s.tokName(n1) else null);
        }
        return s.syntaxError();
    }
    if (s.eatKw("WARNINGS")) return showWarnings(s, false);
    if (s.eatKw("ERRORS")) return showWarnings(s, true);
    if (s.eatKw("DATABASES") or s.eatKw("SCHEMAS")) {
        var like: ?[]const u8 = null;
        if (s.eatKw("LIKE")) like = try s.stringLiteral();
        return lowerFmt(s, "SELECT name AS \"Database\" FROM pragma_database_list{s} ORDER BY seq", .{try likeClause(s, " WHERE name", like)});
    }
    _ = s.eatKw("SESSION");
    if (s.eatKw("VARIABLES")) {
        var like: ?[]const u8 = null;
        if (s.eatKw("LIKE")) like = try s.stringLiteral();
        return showVariables(s, like);
    }
    if (s.eatKw("COUNT")) {
        try s.expectOp("(");
        try s.expectOp("*");
        try s.expectOp(")");
        const errors = s.eatKw("ERRORS");
        if (!errors) try s.expectKw("WARNINGS");
        const st = &s.p.db.xq.mariadb;
        var n: u32 = 0;
        if (errors) {
            for (st.storedWarnings()) |w| n += @intFromBool(w.level == .@"error");
        } else n = st.n_warnings;
        return lowerFmt(s, "SELECT {d} AS \"@@session.{s}_count\"", .{ n, if (errors) "error" else "warning" });
    }
    return s.fail("xqlite: this SHOW statement is not supported", .{});
}

/// DESCRIBE t [col] / DESC t / EXPLAIN t: SHOW COLUMNS; DESCRIBE/EXPLAIN
/// of a statement: EXPLAIN QUERY PLAN.
pub fn describe(s: *Parser) Error!bool {
    const n = s.peek();
    const is_stmt = n.isAnyKw(&.{ "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "WITH", "EXTENDED", "PARTITIONS", "FORMAT", "ANALYZE" }) or
        n.is("(");
    if (is_stmt) return false;
    s.advance();
    const n1, const n2 = try s.qualifiedName();
    var like: ?[]const u8 = null;
    if (s.tok.kind == .string) like = try s.stringLiteral() else if (s.isName()) like = try s.nameText(try s.name());
    try showColumns(s, try s.tokName(if (n2.n != 0) n2 else n1), if (n2.n != 0) try s.tokName(n1) else null, like);
    return true;
}

fn showTables(s: *Parser, full: bool) Error!void {
    var schema: []const u8 = "main";
    if (s.eatKw("FROM") or s.eatKw("IN")) schema = try s.nameText(try s.anyName());
    if (build.findDbName(s.p.db, schema) == null) return s.fail("Unknown database '{s}'", .{schema});
    var like: ?[]const u8 = null;
    if (s.eatKw("LIKE")) like = try s.stringLiteral();
    if (s.isKw("WHERE")) return s.fail("xqlite: SHOW TABLES WHERE is not supported", .{});
    const col = try std.fmt.allocPrint(s.a, "Tables_in_{s}", .{schema});
    return lowerFmt(s, "SELECT name AS {f}{s} FROM {f}.sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name" ++ catalog.not_catalog_table ++ "{s} ORDER BY name COLLATE BINARY", .{
        Id{ .z = col },
        if (full) ", CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS Table_type" else "",
        Id{ .z = schema },
        try likeClause(s, " AND name", like),
    });
}

/// `<prefix> LIKE 'pattern'`, or nothing.
fn likeClause(s: *Parser, prefix: []const u8, like: ?[]const u8) Error![]const u8 {
    const l = like orelse return "";
    return std.fmt.allocPrint(s.a, "{s} LIKE {f}", .{ prefix, Q{ .z = l } });
}

fn resolveTable(s: *Parser, name: []const u8, schema: ?[]const u8) Error!struct { *int.Table, []const u8 } {
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, name, schema) orelse
        return s.fail("Table '{s}.{s}' doesn't exist", .{ schema orelse "main", name });
    return .{ tab, try s.a.dupe(u8, catalog.schemaName(s.p.db, tab)) };
}

fn showColumns(s: *Parser, name: []const u8, schema_in: ?[]const u8, like: ?[]const u8) Error!void {
    const tab, const schema = try resolveTable(s, name, schema_in);
    const tn = try s.a.dupe(u8, tab.name);
    const has_cat = catalog.exists(s.p.db, schema);
    var w: std.Io.Writer.Allocating = .init(s.a);
    const o = &w.writer;
    const cat = struct {
        fn sub(out: *std.Io.Writer, on: bool, sch: []const u8, t: []const u8, key: []const u8) !void {
            if (!on) return out.writeAll("NULL");
            try out.print("(SELECT value FROM {f}.xq_catalog WHERE tbl={f} AND col=ti.name AND key={f})", .{ Id{ .z = sch }, Q{ .z = t }, Q{ .z = key } });
        }
    };
    o.writeAll("SELECT ti.name AS Field, coalesce(") catch return error.OutOfMemory;
    cat.sub(o, has_cat, schema, tn, catalog.Key.decl_type) catch return error.OutOfMemory;
    o.print(
        \\, lower(ti.type)) AS Type, CASE WHEN ti."notnull" OR ti.pk THEN 'NO' ELSE 'YES' END AS "Null", CASE WHEN ti.pk THEN 'PRI' WHEN EXISTS(SELECT 1 FROM pragma_index_list({f},{f}) il WHERE il."unique" AND (SELECT count(*) FROM pragma_index_info(il.name,{f}))=1 AND (SELECT name FROM pragma_index_info(il.name,{f}))=ti.name) THEN 'UNI' WHEN EXISTS(SELECT 1 FROM pragma_index_list({f},{f}) il, pragma_index_info(il.name,{f}) ii WHERE ii.seqno=0 AND ii.name=ti.name) THEN 'MUL' ELSE '' END AS "Key", coalesce(
    , .{ Q{ .z = tn }, Q{ .z = schema }, Q{ .z = schema }, Q{ .z = schema }, Q{ .z = tn }, Q{ .z = schema }, Q{ .z = schema } }) catch return error.OutOfMemory;
    cat.sub(o, has_cat, schema, tn, catalog.Key.default) catch return error.OutOfMemory;
    o.writeAll(", ti.dflt_value) AS \"Default\", trim(CASE WHEN ") catch return error.OutOfMemory;
    cat.sub(o, has_cat, schema, tn, "mariadb.auto_increment") catch return error.OutOfMemory;
    o.writeAll(" IS NOT NULL THEN 'auto_increment' ELSE '' END || CASE WHEN ") catch return error.OutOfMemory;
    cat.sub(o, has_cat, schema, tn, "mariadb.on_update") catch return error.OutOfMemory;
    o.writeAll(" IS NOT NULL THEN ' on update current_timestamp()' ELSE '' END || CASE ti.hidden WHEN 2 THEN ' VIRTUAL GENERATED' WHEN 3 THEN ' STORED GENERATED' ELSE '' END) AS Extra") catch return error.OutOfMemory;
    o.print(" FROM pragma_table_xinfo({f},{f}) ti WHERE ti.hidden IN (0,2,3)", .{ Q{ .z = tn }, Q{ .z = schema } }) catch return error.OutOfMemory;
    if (like) |l| o.print(" AND ti.name LIKE {f}", .{Q{ .z = l }}) catch return error.OutOfMemory;
    o.writeAll(" ORDER BY ti.cid") catch return error.OutOfMemory;
    const text = try w.toOwnedSliceSentinel(0);
    try lowerText(s, text);
}

fn showIndex(s: *Parser, name: []const u8, schema_in: ?[]const u8) Error!void {
    const tab, const schema = try resolveTable(s, name, schema_in);
    const tn = try s.a.dupe(u8, tab.name);
    // The rowid PRIMARY KEY has no index of its own.
    var ipk: []const u8 = "";
    if (tab.i_pkey >= 0) {
        const c = tab.cols[@intCast(tab.i_pkey)].name();
        ipk = try std.fmt.allocPrint(s.a, "SELECT {f} AS \"Table\", 0 AS Non_unique, 'PRIMARY' AS Key_name, 1 AS Seq_in_index, {f} AS Column_name, 'A' AS Collation, NULL AS Cardinality, NULL AS Sub_part, NULL AS Packed, '' AS \"Null\", 'BTREE' AS Index_type, '' AS Comment, '' AS Index_comment, 'NO' AS Ignored, -1 AS o1, 0 AS o2 UNION ALL ", .{ Q{ .z = tn }, Q{ .z = c } });
    }
    const prefix = try std.fmt.allocPrint(s.a, "{s}$", .{tn});
    try lowerFmt(s,
        \\SELECT "Table", Non_unique, Key_name, Seq_in_index, Column_name, Collation, Cardinality, Sub_part, Packed, "Null", Index_type, Comment, Index_comment, Ignored FROM ({s}SELECT {f} AS "Table", NOT il."unique" AS Non_unique, CASE WHEN il.origin='pk' THEN 'PRIMARY' WHEN substr(il.name,1,{d})={f} THEN substr(il.name,{d}) ELSE il.name END AS Key_name, ii.seqno+1 AS Seq_in_index, ii.name AS Column_name, CASE WHEN ii."desc" THEN 'D' ELSE 'A' END AS Collation, NULL AS Cardinality, NULL AS Sub_part, NULL AS Packed, CASE WHEN ti."notnull" OR ti.pk THEN '' ELSE 'YES' END AS "Null", 'BTREE' AS Index_type, '' AS Comment, '' AS Index_comment, 'NO' AS Ignored, il.seq AS o1, ii.seqno AS o2 FROM pragma_index_list({f},{f}) il, pragma_index_xinfo(il.name,{f}) ii LEFT JOIN pragma_table_info({f},{f}) ti ON ti.name=ii.name WHERE ii.key) ORDER BY Key_name<>'PRIMARY', Non_unique, o1 DESC, o2
    , .{ ipk, Q{ .z = tn }, prefix.len, Q{ .z = prefix }, prefix.len + 1, Q{ .z = tn }, Q{ .z = schema }, Q{ .z = schema }, Q{ .z = tn }, Q{ .z = schema } });
}

/// SHOW CREATE TABLE: the CREATE TABLE as MariaDB would show it, made
/// from the catalog (for a MariaDB table) or SQLite's schema text.
fn showCreate(s: *Parser, name: []const u8, schema_in: ?[]const u8) Error!void {
    const tab, const schema = try resolveTable(s, name, schema_in);
    const text = try @import("ddl.zig").showCreateTable(s, tab, schema);
    const col = if (tab.isView()) "Create View" else "Create Table";
    try lowerFmt(s, "SELECT {f} AS {f}, {f} AS {f}", .{ Q{ .z = tab.name }, Id{ .z = if (tab.isView()) "View" else "Table" }, Q{ .z = text }, Id{ .z = col } });
}

fn showWarnings(s: *Parser, errors_only: bool) Error!void {
    if (s.isKw("LIMIT")) {
        while (!s.atStmtEnd()) s.advance();
    }
    const st = &s.p.db.xq.mariadb;
    var w: std.Io.Writer.Allocating = .init(s.a);
    const o = &w.writer;
    var n: usize = 0;
    for (st.storedWarnings()) |*x| {
        if (errors_only and x.level != .@"error") continue;
        if (n > 0) o.writeAll(" UNION ALL ") catch return error.OutOfMemory;
        o.print("SELECT {f} AS Level, {d} AS Code, {f} AS Message", .{ Q{ .z = x.levelName() }, x.code, Q{ .z = x.message() } }) catch return error.OutOfMemory;
        n += 1;
    }
    if (n == 0) o.writeAll("SELECT NULL AS Level, NULL AS Code, NULL AS Message WHERE 0") catch return error.OutOfMemory;
    try lowerText(s, try w.toOwnedSliceSentinel(0));
}

fn showVariables(s: *Parser, like: ?[]const u8) Error!void {
    var w: std.Io.Writer.Allocating = .init(s.a);
    const o = &w.writer;
    o.writeAll("SELECT Variable_name, Value FROM (") catch return error.OutOfMemory;
    for (vars, 0..) |v, i| {
        if (i > 0) o.writeAll(" UNION ALL ") catch return error.OutOfMemory;
        o.print("SELECT {f} AS Variable_name, CAST(xq_sysvar({f}) AS TEXT) AS Value", .{ Q{ .z = v.name }, Q{ .z = v.name } }) catch return error.OutOfMemory;
    }
    o.writeAll(")") catch return error.OutOfMemory;
    if (like) |l| o.print(" WHERE Variable_name LIKE {f}", .{Q{ .z = l }}) catch return error.OutOfMemory;
    o.writeAll(" ORDER BY Variable_name") catch return error.OutOfMemory;
    try lowerText(s, try w.toOwnedSliceSentinel(0));
}
