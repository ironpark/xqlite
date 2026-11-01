//! The Microsoft SQL Server (T-SQL) dialect (Phase 7): the frontend (a
//! tokenizer and a recursive-descent parser that read T-SQL into the
//! syntax tree IR of src/ir/tree.zig, lowered by src/ir/lower.zig) and
//! the hooks (the dialect's functions, the engine functions its trees
//! use, the case-insensitive default collation).
//!
//! The pieces:
//!  - lexer.zig: tokens ([brackets], "quotes", N'...', @var, @@var,
//!    nested comments, 0x..., GO);
//!  - parser.zig: parser core, expressions, SELECT (TOP, OFFSET/FETCH);
//!    functions.zig: function calls, CAST/CONVERT; dml.zig: INSERT,
//!    UPDATE, DELETE, MERGE, TRUNCATE; ddl.zig: CREATE/DROP/ALTER;
//!    session.zig: DECLARE, SET, transactions, PRINT, USE, sp_rename;
//!    schemas.zig: CREATE/DROP/ALTER SCHEMA and the schema functions;
//!    catalog_views.zig: INFORMATION_SCHEMA and sys views;
//!  - types.zig: SQL Server types, their storage and checks;
//!    runtime.zig: the dialect's functions; state.zig: the session;
//!  - JSON: json.zig (text, paths), json_func.zig (the functions, FOR
//!    JSON's aggregate), json_sql.zig (the parser's side), openjson.zig
//!    (OPENJSON, an engine table-valued function).
//!
//! Names keep the case they are written in and compare
//! case-insensitively; comparisons without a collation are
//! case-insensitive (Hooks.default_collation NOCASE, SQL Server's default
//! SQL_Latin1_General_CP1_CI_AS folding ASCII letters only), and DDL
//! names the collation of every character column so that indexes agree.
//! T-SQL needs no semicolons: a statement ends at `;`, at GO, or before
//! a word that starts another one. Foreign keys are enforced, as in SQL
//! Server: the dialect turns PRAGMA foreign_keys on.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const sequence = @import("../../catalog/sequence.zig");
const api = @import("../../vdbe/api.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const parser = @import("parser.zig");
const dml = @import("dml.zig");
const ddl = @import("ddl.zig");
const session = @import("session.zig");
const rt = @import("runtime.zig");
const schemas = @import("schemas.zig");
const jf = @import("json_func.zig");
const shared = @import("../shared_funcs.zig");

pub const frontend: dialect.Frontend = .{ .run = run };

const Parser = parser.Parser;
const Error = parser.Error;

/// The version string of @@VERSION.
pub const version = "Microsoft SQL Server 2022 (xqlite " ++ @import("../../sql/func/func.zig").sqlite_version ++ ")";

/// Compile the first statement of `sql` (dialect.Frontend's contract).
pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    var s: Parser = .init(p, sql);
    while (s.isOp(";") or s.tok.kind == .go) s.advance();
    if (s.tok.kind == .eof) {
        p.tail = sql[sql.len..];
        return;
    }
    // An element of the CREATE SCHEMA compiled before: in its schema.
    const st = &p.db.xq.mssql;
    const element: ?[]const u8 = if (st.schema_element) |e| try p.arena.dupe(u8, e) else null;
    if (st.schema_element) |e| {
        p.db.gpa.free(e);
        st.schema_element = null;
    }
    if (element != null and schemas.isElement(&s)) s.element_schema = element;
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
    // More elements of the same CREATE SCHEMA follow.
    if (s.element_schema) |e| if (schemas.isElement(&s)) {
        @TypeOf(st.*).setText(p.db.gpa, &st.schema_element, e) catch return error.OutOfMemory;
    };
    if (s.isOp(";") or s.tok.kind == .go) {
        s.advance();
        p.tail = sql[@intFromPtr(s.prev_end) - @intFromPtr(sql.ptr) ..];
    } else if (s.tok.kind == .eof) {
        p.tail = sql[sql.len..];
    } else p.tail = sql[@intFromPtr(s.tok.text.ptr) - @intFromPtr(sql.ptr) ..];
    ir.stmt.finishCoding(p);
}

fn statement(s: *Parser) Error!void {
    const t = s.tok;
    if (t.isKw("WITH")) {
        const w = try s.withClause();
        if (s.isKw("SELECT") or s.isOp("(")) return selectStatement(s, w);
        if (s.isKw("INSERT")) return s.lowerStmt(try dml.insert(s, w));
        if (s.isKw("UPDATE")) return s.lowerStmt(try dml.update(s, w));
        if (s.isKw("DELETE")) return s.lowerStmt(try dml.delete(s, w));
        if (s.isKw("MERGE")) return s.fail("xqlite: WITH ... MERGE is not supported", .{});
        return s.syntaxError();
    }
    if (t.isKw("SELECT") or t.is("(")) return selectStatement(s, null);
    if (t.isKw("INSERT")) return s.lowerStmt(try dml.insert(s, null));
    if (t.isKw("UPDATE")) return s.lowerStmt(try dml.update(s, null));
    if (t.isKw("DELETE")) return s.lowerStmt(try dml.delete(s, null));
    if (t.isKw("MERGE")) return dml.merge(s);
    if (t.isKw("TRUNCATE")) return s.lowerStmt(try dml.truncate(s));
    if (t.isKw("CREATE")) return ddl.create(s);
    if (t.isKw("DROP")) return ddl.drop(s);
    if (t.isKw("ALTER")) return ddl.alter(s);
    if (t.isKw("BEGIN")) return session.begin(s);
    if (t.isKw("COMMIT")) return session.commit(s);
    if (t.isKw("ROLLBACK")) return session.rollback(s);
    if (t.isKw("SAVE")) return session.save(s);
    if (t.isKw("SET")) return session.set(s);
    if (t.isKw("DECLARE")) return session.declare(s);
    if (t.isKw("PRINT")) return session.print(s);
    if (t.isKw("USE")) return session.use(s);
    if (t.isKw("EXEC") or t.isKw("EXECUTE")) return session.exec(s);
    if (t.isAnyKw(&.{ "GRANT", "REVOKE", "DENY" })) {
        if (s.element_schema != null) return schemas.skipPermission(s);
        return s.fail("xqlite: {s} is not supported (xqlite has no permissions)", .{t.text});
    }
    if (t.isAnyKw(&.{ "IF", "WHILE", "RETURN", "GOTO", "BREAK", "CONTINUE", "TRY", "THROW", "RAISERROR", "WAITFOR" })) {
        return s.fail("xqlite: {s} is not supported (T-SQL control flow is not)", .{t.text});
    }
    return s.syntaxError();
}

/// SELECT: rows, or the assignment of variables (SELECT @x = ...), or a
/// new table (SELECT ... INTO t).
fn selectStatement(s: *Parser, with: ?*tree.With) Error!void {
    s.assigns = null;
    s.into = null;
    const sel = try s.selectStmt();
    if (with) |w| {
        if (sel.with != null) return s.syntaxError();
        sel.with = w;
    }
    if (s.assigns) |as| return assignStatement(s, sel, as);
    if (s.into) |q| {
        const temp = q.name.text.len > 0 and q.name.text[0] == '#';
        return s.lowerStmt(.{ .create_table = try s.new(tree.CreateTable, .{
            .temp = temp,
            .name = if (temp) .{ .name = q.name } else .{ .schema = q.schema orelse .{ .text = "main" }, .name = q.name },
            .as_select = sel,
        }) });
    }
    return s.lowerStmt(.{ .select = sel });
}

/// SELECT @a = x, @b = y FROM ... [ORDER BY ...]: the values are
/// assigned row after row (the last row's stay), and no row is returned:
///
///     SELECT 1 FROM (SELECT x AS xq_a0, y AS xq_a1 FROM ... ORDER BY ...
///       LIMIT -1) AS xq_assign WHERE xq_tsql_assign('a', xq_a0, 'b', xq_a1)
///
/// (xq_tsql_assign() is false; the LIMIT keeps the subquery's order).
fn assignStatement(s: *Parser, sel: *tree.Select, as: []const parser.Assign) Error!void {
    const pos = sel.pos;
    const core = sel.body.core;
    var cols: std.ArrayList(tree.ResultCol) = .empty;
    var args: std.ArrayList(*tree.Expr) = .empty;
    for (as, 0..) |a, i| {
        const v = s.p.db.xq.mssql.get(a.name) orelse return s.failState(.numbered("42P02", 137), "Must declare the scalar variable \"@{s}\".", .{a.name});
        const ty = try s.a.dupe(u8, v.type);
        const al: tree.Name = .{ .text = try std.fmt.allocPrint(s.a, "xq_a{d}", .{i}), .pos = pos };
        const value = try session.asType(s, a.value, ty);
        try cols.append(s.a, .{ .expr = .{ .e = value, .alias = al } });
        try args.append(s.a, try s.str(pos, a.name));
        try args.append(s.a, try tree.expr(s.a, pos, pos, .{ .column = try s.a.dupe(tree.Name, &.{al}) }));
    }
    const inner_core = try s.new(tree.Core, .{
        .distinct = core.distinct,
        .cols = cols.items,
        .from = core.from,
        .where = core.where,
        .group_by = core.group_by,
        .having = core.having,
        .pos = core.pos,
    });
    const inner = try s.new(tree.Select, .{ .with = sel.with, .body = try s.new(tree.Body, .{ .core = inner_core }), .order_by = sel.order_by, .limit = sel.limit, .offset = sel.offset, .pos = pos });
    if (inner.order_by.len > 0 and inner.limit == null) inner.limit = try s.int_(pos, -1);
    const from = try s.a.dupe(tree.FromItem, &.{.{ .source = .{ .subquery = inner }, .alias = .{ .name = .{ .text = "xq_assign", .pos = pos } } }});
    const where = try s.func(pos, "xq_tsql_assign", args.items);
    const outer = try s.new(tree.Core, .{ .cols = try s.a.dupe(tree.ResultCol, &.{.{ .expr = .{ .e = try s.int_(pos, 1) } }}), .from = from, .where = where, .pos = pos });
    return s.lowerStmt(.{ .select = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = outer }), .pos = pos }) });
}

/// SQLite's messages for common failures in SQL Server's words.
fn translateError(p: *int.Parse) int.Oom!void {
    const m: []const u8 = p.err_msg orelse return;
    // SQL Server's numbers of the engine's errors.
    dialect.numberError(p, &.{
        .{ "42P01".*, 208 },  .{ "42703".*, 207 },  .{ "42702".*, 209 },
        .{ "42883".*, 195 },  .{ "42P07".*, 2714 }, .{ "42601".*, 102 },
        .{ "42704".*, 3701 },
    }, if (std.mem.startsWith(u8, m, "no such column: ") and std.mem.indexOfScalar(u8, m["no such column: ".len..], '.') != null) 4104 else null);
    const rules = [_]struct { []const u8, []const u8, []const u8 }{
        // prefix, before the name, after it
        .{ "no such table: ", "Invalid object name '", "'." },
        .{ "no such view: ", "Invalid object name '", "'." },
        .{ "no such function: ", "'", "' is not a recognized built-in function name." },
        .{ "ambiguous column name: ", "Ambiguous column name '", "'." },
        .{ "no such index: ", "Cannot drop the index '", "', because it does not exist or you do not have permission." },
    };
    for (rules) |r| if (std.mem.startsWith(u8, m, r[0])) {
        var name = m[r[0].len..];
        // main.t: the user wrote dbo.t (the parser keeps an unqualified
        // name unqualified).
        const dbo = std.mem.startsWith(u8, name, "main.") and std.mem.startsWith(u8, r[1], "Invalid");
        if (std.mem.startsWith(u8, name, "main.")) name = name[5..];
        p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "{s}{s}{s}{s}", .{ r[1], if (dbo) "dbo." else "", name, r[2] }, 0);
        return;
    };
    if (std.mem.startsWith(u8, m, "no such column: ")) {
        const name = m["no such column: ".len..];
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |_| {
            p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "The multi-part identifier \"{s}\" could not be bound.", .{name}, 0);
        } else {
            p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "Invalid column name '{s}'.", .{name}, 0);
        }
        return;
    }
    inline for (.{ "table ", "view " }) |kind| {
        if (std.mem.startsWith(u8, m, kind) and std.mem.endsWith(u8, m, " already exists")) {
            var name = m[kind.len .. m.len - " already exists".len];
            if (std.mem.startsWith(u8, name, "main.")) name = name[5..];
            if (name.len > 1 and name[0] == '"') name = name[1 .. name.len - 1];
            p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "There is already an object named '{s}' in the database.", .{name}, 0);
            return;
        }
    }
}

// ================================================================ hooks

pub const hooks: dialect.Hooks = .{
    .foreign_keys = true,
    .arith = .{
        .div_zero = .{ .msg = "Divide by zero error encountered.", .state = .numbered("22012", 8134) },
        .int_overflow = .{ .msg = "Arithmetic overflow error converting expression to data type bigint.", .state = .numbered("22003", 8115) },
    },
    .functions = &functions,
    .engine_functions = &engine_functions,
    .table_function = @import("openjson.zig").register,
    // SQL_Latin1_General_CP1_CI_AS: case-insensitive.
    .default_collation = "NOCASE",
    // The names of the type checks (ddl.zig's typeCheck()).
    .check_errors = &.{
        .{ .prefix = "String or binary data would be truncated", .state = .numbered("22001", 8152) },
        .{ .prefix = "Arithmetic overflow error converting", .state = .numbered("22003", 8115) },
    },
};

const det: dfunc.Options = .{ .deterministic = true };
const direct: dfunc.Options = .{ .direct_only = true };

const functions = [_]int.FuncDef{
    // Identity columns (the IR calls nextval()) and sequences.
    dfunc.scalar("nextval", 1, .{ .unsafe = true }, rt.nextvalFunc),
    dfunc.scalar("xq_tsql_next_value", 1, .{ .unsafe = true }, sequence.nextvalFunc),
    dfunc.scalar("scope_identity", 0, .{}, rt.scopeIdentityFunc),
    dfunc.scalar("ident_current", 1, .{}, rt.identCurrentFunc),
    // The session (never in the schema: variables are not allowed there).
    dfunc.scalar("xq_tsql_getvar", 1, .{}, rt.getvarFunc),
    dfunc.scalar("xq_tsql_setvar", 2, direct, rt.setvarFunc),
    dfunc.scalar("xq_tsql_declare", 3, direct, rt.declareFunc),
    dfunc.scalar("xq_tsql_assign", -1, direct, assignFunc),
    dfunc.scalar("xq_tsql_identity_insert", 2, direct, rt.identityInsertFunc),
    dfunc.scalar("xq_tsql_identity_seen", 2, direct, rt.identitySeenFunc),
    dfunc.scalar("xq_tsql_trancount", 0, .{}, rt.trancountFunc),
    dfunc.scalar("xq_tsql_tran", 2, direct, rt.tranFunc),
    dfunc.scalar("xq_tsql_merge", 2, direct, rt.mergeFunc),
    dfunc.scalar("typeinfo", 2, det, rt.typeinfoFunc),
    // Strings.
    dfunc.scalar("charindex", 2, det, rt.charindexFunc),
    dfunc.scalar("charindex", 3, det, rt.charindexFunc),
    dfunc.scalar("replace", 3, det, rt.replaceFunc),
    dfunc.scalar("left", 2, det, shared.leftFunc),
    dfunc.scalar("right", 2, det, shared.rightFunc),
    dfunc.scalar("reverse", 1, det, shared.reverseFunc),
    dfunc.scalar("replicate", 2, det, shared.repeatFunc),
    dfunc.scalar("space", 1, det, shared.spaceFunc),
    dfunc.scalar("stuff", 4, det, rt.stuffFunc),
    dfunc.scalar("ascii", 1, det, shared.asciiFunc),
    dfunc.scalar("isnumeric", 1, det, rt.isnumericFunc),
    dfunc.scalar("isdate", 1, det, rt.isdateFunc),
    // Math.
    dfunc.scalar("floor", 1, det, shared.floorFunc),
    dfunc.scalar("ceiling", 1, det, shared.ceilFunc),
    dfunc.scalar("round", 1, det, shared.roundFunc),
    dfunc.scalar("round", 2, det, shared.roundFunc),
    dfunc.scalar("truncate", 2, det, shared.truncateFunc),
    dfunc.scalar("power", 2, det, rt.powerFunc),
    dfunc.scalar("sqrt", 1, det, shared.sqrtFunc),
    dfunc.scalar("exp", 1, det, shared.expFunc),
    dfunc.scalar("ln", 1, det, shared.lnFunc),
    dfunc.scalar("log", 2, det, shared.logFunc),
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
    // Dates.
    dfunc.scalar("dateadd", 3, det, rt.dateaddFunc),
    dfunc.scalar("datediff", 3, det, rt.datediffFunc),
    dfunc.scalar("datepart", 2, det, rt.datepartFunc),
    dfunc.scalar("datename", 2, det, rt.datenameFunc),
    dfunc.scalar("eomonth", 1, det, rt.eomonthFunc),
    dfunc.scalar("eomonth", 2, det, rt.eomonthFunc),
    dfunc.scalar("datefromparts", 3, det, rt.datefrompartsFunc),
    // Schemas (schemas.zig).
    dfunc.scalar("xq_tsql_default_schema", 1, direct, schemas.defaultSchemaFunc),
    dfunc.scalar("xq_tsql_schema_id", 0, .{}, schemas.schemaIdFunc),
    dfunc.scalar("xq_tsql_schema_id", 1, .{}, schemas.schemaIdFunc),
    dfunc.scalar("xq_tsql_schema_name", 0, .{}, schemas.schemaNameFunc),
    dfunc.scalar("xq_tsql_schema_name", 1, .{}, schemas.schemaNameFunc),
    dfunc.scalar("xq_tsql_object_name", 1, .{}, schemas.objectNameFunc),
    dfunc.scalar("xq_tsql_object_schema_name", 1, .{}, schemas.objectSchemaNameFunc),
    dfunc.scalar("xq_tsql_schema_of", 1, .{}, schemas.schemaOfFunc),
    dfunc.scalar("xq_tsql_bare_name", 1, .{}, schemas.bareNameFunc),
};

/// The functions the parser's trees call where SQL Server's semantics
/// have no SQLite spelling: visible in every dialect
/// (dialect.Hooks.engine_functions), so that the schema may keep them.
const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_tsql_add", 2, det, rt.addFunc),
    dfunc.scalar("xq_tsql_like", 2, det, rt.likeFunc),
    dfunc.scalar("xq_tsql_like", 3, det, rt.likeFunc),
    dfunc.scalar("xq_tsql_cast", 2, .{ .deterministic = true, .user_data = rt.user_cast }, rt.convertFunc),
    dfunc.scalar("xq_tsql_try_cast", 2, .{ .deterministic = true, .user_data = rt.user_try }, rt.convertFunc),
    dfunc.scalar("xq_tsql_store", 2, .{ .deterministic = true, .user_data = rt.user_store }, rt.convertFunc),
    dfunc.scalar("xq_tsql_newid", 0, .{}, rt.newidFunc),
    dfunc.aggregate("xq_tsql_avg", 1, det, rt.avgStep, rt.avgFinal),
    // JSON (json_func.zig).
    dfunc.scalar("xq_tsql_json_value", 2, det, jf.jsonValueFunc),
    dfunc.scalar("xq_tsql_json_query", 1, det, jf.jsonQueryFunc),
    dfunc.scalar("xq_tsql_json_query", 2, det, jf.jsonQueryFunc),
    dfunc.scalar("xq_tsql_json_modify", 4, det, jf.jsonModifyFunc),
    dfunc.scalar("xq_tsql_json_path_exists", 2, det, jf.jsonPathExistsFunc),
    dfunc.scalar("xq_tsql_isjson", 2, det, jf.isjsonFunc),
    dfunc.scalar("xq_tsql_json_escape", 1, det, jf.jsonEscapeFunc),
    dfunc.scalar("xq_tsql_json_object", -1, det, jf.jsonObjectFunc),
    dfunc.scalar("xq_tsql_json_array", -1, det, jf.jsonArrayFunc),
    dfunc.aggregate("xq_tsql_for_json", -1, det, jf.forJsonStep, jf.forJsonFinal),
};

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&engine_functions);
}

/// xq_tsql_assign(name, value, ...): give each variable its value;
/// false (the statement of SELECT @x = ... returns no row).
fn assignFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 2) {
        const name = api.valueText(argv[i]) orelse continue;
        db.xq.mssql.assign(name, argv[i + 1]) catch |err| switch (err) {
            error.OutOfMemory => return api.resultErrorNomem(ctx),
            error.Undeclared => {
                var buf: [160]u8 = undefined;
                return api.resultErrorState(ctx, .numbered("42P02", 137), std.fmt.bufPrint(&buf, "Must declare the scalar variable \"@{s}\".", .{name[0..@min(name.len, 100)]}) catch "undeclared variable");
            },
        };
    }
    api.resultInt64(ctx, 0);
}

test {
    _ = @import("lexer.zig");
    _ = @import("types.zig");
    _ = @import("runtime.zig");
    _ = @import("json.zig");
    _ = @import("json_func.zig");
    _ = @import("openjson.zig");
    _ = @import("test.zig");
}
