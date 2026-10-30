//! Session statements: DECLARE and SET of variables, SET options, SET
//! IDENTITY_INSERT, transactions (BEGIN/COMMIT/ROLLBACK/SAVE TRANSACTION
//! and their nesting), PRINT, USE, EXEC sp_rename.
//!
//! A statement that changes the session does so when it runs, through a
//! function of the dialect (xq_tsql_declare(), xq_tsql_setvar() ...,
//! runtime.zig) that the statement evaluates for its effect; the
//! statements compiled after it see the change (a variable's type, the
//! table IDENTITY_INSERT is on for, the transaction nesting).
//!
//! Variables are the session's (state.zig): SQL Server's are the batch's,
//! but xqlite has no batches (GO ends a statement only), so a variable
//! lives until it is declared again or the connection closes.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const tree = @import("../../ir/tree.zig");
const parser = @import("parser.zig");
const functions = @import("functions.zig");
const types = @import("types.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;

/// Code a statement that evaluates `exprs` (lowered by the IR) for their
/// effects and returns no rows.
pub fn codeEval(s: *Parser, exprs: []const *Expr) Error!void {
    _ = build.getVdbe(s.p) orelse return error.ParseFailed;
    var l = s.lowerer();
    for (exprs) |x| {
        const e = l.expr(x) catch |err| return parser.lowered(err);
        var nc: int.NameContext = .{ .parse = s.p };
        @import("../../sql/resolve.zig").resolveExprNames(&nc, e) catch return error.ParseFailed;
        s.p.n_mem += 1;
        @import("../../sql/expr_code.zig").exprCode(s.p, e, s.p.n_mem);
    }
}

/// A statement that does nothing (SET NOCOUNT ON ...).
pub fn emptyStatement(s: *Parser) Error!void {
    _ = build.getVdbe(s.p) orelse return error.ParseFailed;
}

/// `e` converted to the type of a variable, as SET converts (a string
/// is cut to the variable's length, silently).
pub fn asType(s: *Parser, e: *Expr, ty: []const u8) Error!*Expr {
    if (e.kind == .null) return e;
    return s.mk(e.pos, .{ .cast = .{ .e = e, .target_type = ty, .mode = .{ .typed = .{ .func = "xq_tsql_cast", .type_arg = ty } } } });
}

// ============================================================ DECLARE

/// DECLARE @x type [= value] [, ...].
pub fn declare(s: *Parser) Error!void {
    try s.expectKw("DECLARE");
    var calls: std.ArrayList(*Expr) = .empty;
    while (true) {
        if (s.tok.kind != .variable) return s.syntaxError();
        const vt = s.tok;
        const pos = s.here();
        s.advance();
        _ = s.eatKw("AS");
        if (s.isKw("TABLE")) return s.fail("xqlite: table variables are not supported", .{});
        if (s.isKw("CURSOR")) return s.fail("xqlite: cursors are not supported", .{});
        const ty = try functions.typeNameOf(s, true);
        var value: *Expr = try s.mk(pos, .null);
        if (s.eatOp("=")) value = try asType(s, try s.expr(), ty.text);
        try calls.append(s.a, try s.func(pos, "xq_tsql_declare", &.{ try s.str(pos, try parser.varName(s.a, vt.text)), try s.str(pos, ty.text), value }));
        if (!s.eatOp(",")) break;
    }
    try codeEval(s, calls.items);
}

// ================================================================ SET

/// SET @x = value, SET IDENTITY_INSERT t ON|OFF, SET <option> ...
pub fn set(s: *Parser) Error!void {
    try s.expectKw("SET");
    if (s.tok.kind == .variable) {
        const vt = s.tok;
        const pos = s.here();
        s.advance();
        const op = s.tok;
        if (op.kind != .op or !(op.is("=") or (op.text.len == 2 and op.text[1] == '='))) return s.syntaxError();
        s.advance();
        const name = try parser.varName(s.a, vt.text);
        const v = s.p.db.xq.mssql.get(name) orelse return s.fail("Must declare the scalar variable \"{s}\".", .{vt.text});
        const ty = try s.a.dupe(u8, v.type);
        var e = try s.expr();
        if (op.text.len == 2) e = try s.compoundAssign(op.text[0], try s.variableRef(vt, pos), e);
        return codeEval(s, &.{try s.func(pos, "xq_tsql_setvar", &.{ try s.str(pos, name), try asType(s, e, ty) })});
    }
    if (s.eatKw("IDENTITY_INSERT")) {
        const pos = s.here();
        const q = try s.qualifiedName();
        const on = if (s.eatKw("ON")) true else if (s.eatKw("OFF")) false else return s.syntaxError();
        const t = try s.target(q);
        if (t.tab == null) return s.fail("Cannot find the object \"{s}\" because it does not exist or you do not have permissions.", .{q.name.text});
        if (t.identity() == null) return s.fail("Table '{s}' does not have the identity property. Cannot perform SET operation.", .{t.bare});
        const key = try std.ascii.allocLowerString(s.a, try std.fmt.allocPrint(s.a, "{s}.{s}", .{ t.schema, t.name }));
        return codeEval(s, &.{try s.func(pos, "xq_tsql_identity_insert", &.{ try s.str(pos, key), try s.int_(pos, @intFromBool(on)) })});
    }
    if (s.eatKw("ROWCOUNT")) {
        const e = try s.expr();
        if (!(e.kind == .integer and std.mem.eql(u8, e.kind.integer, "0"))) return s.fail("xqlite: SET ROWCOUNT is not supported", .{});
        return emptyStatement(s);
    }
    if (s.isKw("IMPLICIT_TRANSACTIONS") and s.peek().isKw("ON")) return s.fail("xqlite: SET IMPLICIT_TRANSACTIONS ON is not supported", .{});
    if (s.tok.kind != .ident) return s.syntaxError();
    // An option: accepted and ignored (NOCOUNT, ANSI_NULLS, XACT_ABORT,
    // TRANSACTION ISOLATION LEVEL, DATEFORMAT ...).
    while (!s.atStmtEnd() or s.isKw("SET")) {
        if (s.tok.kind == .eof) break;
        s.advance();
    }
    return emptyStatement(s);
}

// ======================================================= transactions

fn tranWord(s: *Parser) void {
    _ = s.eatKw("TRAN") or s.eatKw("TRANSACTION") or s.eatKw("WORK");
}

/// A transaction or savepoint name (or @variable, not supported).
fn tranName(s: *Parser) Error!?tree.Name {
    if (s.tok.kind == .variable) return s.fail("xqlite: transaction names in variables are not supported", .{});
    if (s.isName()) return try s.nameOf(try s.name());
    return null;
}

fn tranCall(s: *Parser, op: i64, name: ?tree.Name) Error!void {
    const pos = s.here();
    const n: *Expr = if (name) |x| try s.str(pos, x.text) else try s.mk(pos, .null);
    try codeEval(s, &.{try s.func(pos, "xq_tsql_tran", &.{ try s.int_(pos, op), n })});
}

/// BEGIN TRAN[SACTION] [name]: a transaction, or one level deeper in the
/// one open (@@TRANCOUNT), as in SQL Server.
pub fn begin(s: *Parser) Error!void {
    try s.expectKw("BEGIN");
    if (s.isKw("DISTRIBUTED")) return s.fail("xqlite: distributed transactions are not supported", .{});
    if (!(s.isKw("TRAN") or s.isKw("TRANSACTION"))) {
        return s.fail("xqlite: BEGIN ... END blocks (and TRY/CATCH) are not supported", .{});
    }
    s.advance();
    const name = try tranName(s);
    if (s.eatKw("WITH")) {
        try s.expectKw("MARK");
        if (s.tok.kind == .string) s.advance();
    }
    if (s.p.db.auto_commit) {
        try s.lowerStmt(.begin);
        return tranCall(s, 0, name);
    }
    return tranCall(s, 1, null);
}

/// COMMIT [TRAN[SACTION] | WORK] [name]: the innermost level; the
/// outermost commits.
pub fn commit(s: *Parser) Error!void {
    try s.expectKw("COMMIT");
    tranWord(s);
    _ = try tranName(s);
    const st = &s.p.db.xq.mssql;
    if (s.p.db.auto_commit) return s.fail("The COMMIT TRANSACTION request has no corresponding BEGIN TRANSACTION.", .{});
    if (st.tran_nest > 0) return tranCall(s, 2, null);
    try s.lowerStmt(.commit);
    return tranCall(s, 3, null);
}

/// ROLLBACK [TRAN[SACTION] | WORK] [name]: the whole transaction, or
/// back to savepoint `name`.
pub fn rollback(s: *Parser) Error!void {
    try s.expectKw("ROLLBACK");
    tranWord(s);
    const name = try tranName(s);
    const st = &s.p.db.xq.mssql;
    if (s.p.db.auto_commit) return s.fail("The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.", .{});
    if (name) |n| {
        const outer = if (st.tran_name) |tn| std.ascii.eqlIgnoreCase(tn, n.text) else false;
        if (!outer) return s.lowerStmt(.{ .rollback_to = n });
    }
    try s.lowerStmt(.rollback);
    return tranCall(s, 3, null);
}

/// SAVE TRAN[SACTION] name: a savepoint.
pub fn save(s: *Parser) Error!void {
    try s.expectKw("SAVE");
    if (!(s.eatKw("TRAN") or s.eatKw("TRANSACTION"))) return s.syntaxError();
    const name = (try tranName(s)) orelse return s.syntaxError();
    if (s.p.db.auto_commit) return s.fail("The SAVE TRANSACTION request has no corresponding BEGIN TRANSACTION.", .{});
    return s.lowerStmt(.{ .savepoint = name });
}

// =============================================================== misc

/// PRINT expr: evaluated, nothing is shown.
pub fn print(s: *Parser) Error!void {
    try s.expectKw("PRINT");
    const e = try s.expr();
    return codeEval(s, &.{e});
}

/// USE db: the database must exist (main, temp, an attached one); the
/// default schema stays dbo (main).
pub fn use(s: *Parser) Error!void {
    try s.expectKw("USE");
    const n = try s.nameText(try s.anyName());
    if (!std.ascii.eqlIgnoreCase(n, "master") and build.findDbName(s.p.db, n) == null) {
        return s.fail("Database '{s}' does not exist. Make sure that the name is entered correctly.", .{n});
    }
    return emptyStatement(s);
}

/// EXEC sp_rename 'old', 'new' [, 'OBJECT' | 'COLUMN']: ALTER TABLE ...
/// RENAME. Any other procedure is not supported.
pub fn exec(s: *Parser) Error!void {
    s.advance(); // EXEC/EXECUTE
    const pname = try s.nameText(try s.anyName());
    var proc = pname;
    while (s.eatOp(".")) proc = try s.nameText(try s.anyName());
    if (!std.ascii.eqlIgnoreCase(proc, "sp_rename")) return s.fail("xqlite: EXEC {s} is not supported (stored procedures are not)", .{proc});
    var args: std.ArrayList([]const u8) = .empty;
    while (true) {
        if (s.tok.kind == .ident and s.peek().is("=")) {
            s.advance();
            s.advance();
        }
        try args.append(s.a, try s.stringLiteral());
        if (!s.eatOp(",")) break;
    }
    if (args.items.len < 2 or args.items.len > 3) return s.fail("Procedure or function 'sp_rename' expects parameter '@newname', which was not supplied.", .{});
    const kind = if (args.items.len == 3) args.items[2] else "OBJECT";
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, args.items[0], '.');
    while (it.next()) |p| try parts.append(s.a, std.mem.trim(u8, p, "[]"));
    const ps = parts.items;
    const pos = s.here();
    if (std.ascii.eqlIgnoreCase(kind, "COLUMN")) {
        if (ps.len < 2) return s.fail("Either the parameter @objname is ambiguous or the claimed @objtype (COLUMN) is wrong.", .{});
        const table = try s.resolveParts(try names(s, ps[0 .. ps.len - 1], pos), .lookup);
        const at = try s.new(tree.AlterTable, .{ .name = table, .action = .{ .rename_column = .{ .old = .{ .text = ps[ps.len - 1], .pos = pos }, .new = .{ .text = args.items[1], .pos = pos } } } });
        return s.lowerStmt(.{ .alter_table = at });
    }
    if (!std.ascii.eqlIgnoreCase(kind, "OBJECT")) return s.fail("xqlite: sp_rename of an {s} is not supported", .{kind});
    if (ps.len > 3) return s.fail("xqlite: sp_rename of '{s}' is not supported", .{args.items[0]});
    const table = try s.resolveParts(try names(s, ps, pos), .lookup);
    // The object stays in its schema.
    const old = table.name.text;
    const new = try std.fmt.allocPrint(s.a, "{s}{s}", .{ old[0 .. old.len - (try s.bareName(old)).len], args.items[1] });
    const at = try s.new(tree.AlterTable, .{ .name = table, .action = .{ .rename_to = .{ .text = new, .pos = pos } } });
    return s.lowerStmt(.{ .alter_table = at });
}

/// Parts of a name (1 to 3) as Names at `pos`.
fn names(s: *Parser, ps: []const []const u8, pos: u32) Error![]tree.Name {
    if (ps.len == 0 or ps.len > 3) return s.fail("Either the parameter @objname is ambiguous or the claimed @objtype (COLUMN) is wrong.", .{});
    const out = try s.a.alloc(tree.Name, ps.len);
    for (ps, out) |p, *n| n.* = .{ .text = p, .pos = pos };
    return out;
}

/// The declared type of a variable, for types.parseText().
pub fn varType(s: *Parser, name: []const u8) ?types.Type {
    const v = s.p.db.xq.mssql.get(name) orelse return null;
    return types.parseText(v.type);
}
