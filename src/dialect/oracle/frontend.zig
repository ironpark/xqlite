//! The Oracle Database dialect (Phase 8).
//!
//! The frontend reads one statement (lexer.zig; parser.zig for queries
//! and expressions, stmt.zig for the statements, dates.zig for date
//! arithmetic: the syntax tree IR of src/ir/tree.zig with Oracle's
//! semantics resolved) and lowers it with src/ir/lower.zig. MERGE and
//! INSERT ALL lower as several statements in one program. PRAGMA, ATTACH,
//! VACUUM and the other SQLite commands of dialect.runParser() pass
//! through as SQLite.
//!
//! Transactions: Oracle has no BEGIN; a transaction starts with the
//! first INSERT, UPDATE, DELETE or MERGE and lasts until COMMIT or
//! ROLLBACK. In SQLite terms the DML runs as a statement of its own and,
//! if the connection was in autocommit mode, ends by turning autocommit
//! off (OP_AutoCommit 0, guarded by xq_ora_autocommit() at run time, so
//! a statement prepared in one mode runs right in the other): its changes
//! and those after it stay in the open transaction. COMMIT and ROLLBACK
//! without a transaction do nothing, as in Oracle. DDL does not commit
//! (SQLite's DDL is transactional).
//!
//! Errors use Oracle's codes where it is cheap (ORA-00942, ORA-00904 ...);
//! errors found while the statement runs keep SQLite's words, except the
//! ones xq_ora_coerce() raises.
//!
//! The engine side: the function table (funcs.zig and the sequence
//! functions) and the engine functions xq_ora_*.
//!
//! What is supported and what is not: docs/oracle.md.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const sequence = @import("../../catalog/sequence.zig");
const catalog = @import("../../catalog/catalog.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const build = @import("../../sql/build.zig");
const aux = @import("../../vdbe/aux.zig");
const parser = @import("parser.zig");
const tokenized = @import("../tokenized.zig");
const stmt_mod = @import("stmt.zig");
const dates = @import("dates.zig");
const funcs = @import("funcs.zig");
const jsonfuncs = @import("jsonfuncs.zig");
const session = @import("session.zig");

const RC = int.RC;
const OP = @import("../../vdbe/vdbe_int.zig").OP;

pub const frontend: dialect.Frontend = .{ .run = run };

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
    .engine_functions = &engine_functions,
    .engine_modules = &.{.{ .name = jsonfuncs.json_table_name, .module = &jsonfuncs.json_table_module }},
};

const engine_functions = funcs.engine_functions ++ jsonfuncs.engine_functions;

const functions = funcs.functions ++ sequence.functions ++ session.functions;

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&engine_functions);
}

pub const run = tokenized.run(parser, compile, translateError);

fn compile(p: *int.Parse, sql: [:0]const u8, ps: *parser.Parser) lower.Error!void {
    ps.p = p;
    // CREATE/DROP/ALTER USER, ALTER SESSION SET CURRENT_SCHEMA.
    const done = session.statement(ps) catch |err| switch (err) {
        error.OutOfMemory, error.ParseFailed => |e| return parseError(p, sql, ps, e),
        error.Failed => return error.Failed,
    };
    if (done) return;
    const s = stmt_mod.statement(ps) catch |err| return parseError(p, sql, ps, err);
    dates.statement(ps, s) catch |err| return parseError(p, sql, ps, err);
    var l: lower.Lowerer = .init(p, sql);
    switch (s) {
        .tree => |t| switch (t) {
            .create_table, .create_index, .create_view, .create_sequence, .alter_table, .drop => try ddl(&l, t),
            .insert, .update, .delete => {
                try l.statement(t);
                implicitTransaction(p);
            },
            .commit, .rollback => endTransaction(p, t == .rollback),
            .explain => |inner| switch (inner.*) {
                .select, .insert, .update, .delete => try l.statement(t),
                else => return fail(p, sql, "xqlite: EXPLAIN PLAN of this statement is not supported"),
            },
            else => try l.statement(t),
        },
        .multi => |list| {
            for (list) |t| try l.statement(t);
            implicitTransaction(p);
        },
        .ddl => |list| for (list) |t| try ddl(&l, t),
        .comment => |c| {
            const t = try l.findTable(c.table) orelse return l.fail(c.table.name.pos, "ORA-00942: table or view does not exist", .{});
            const col: []const u8 = if (c.column) |n| blk: {
                const i = build.columnIndex(t, n.text);
                if (i < 0) return l.fail(n.pos, "ORA-00904: \"{s}\": invalid identifier", .{n.text});
                break :blk t.cols[@intCast(i)].name();
            } else "";
            const schema = catalog.schemaName(p.db, t);
            catalog.codeSet(p, schema, t.name, col, "oracle.comment", c.text);
        },
        .noop => _ = build.getVdbe(p) orelse return error.Failed,
    }
}

const parseError = tokenized.parseFailed;

fn fail(p: *int.Parse, sql: [:0]const u8, msg: []const u8) lower.Error {
    ir.stmt.errorMsgAt(p, sql.ptr, "{s}", .{msg});
    return error.Failed;
}

// ======================================================= transactions

/// The code that keeps a transaction open after a DML statement run in
/// autocommit mode: if xq_ora_autocommit() then OP_AutoCommit 0 (which
/// ends the statement, leaving its changes in the transaction).
fn implicitTransaction(p: *int.Parse) void {
    if (p.explain != 0 or p.n_err > 0) return;
    const v = build.getVdbe(p) orelse return;
    const r = autocommitRegister(p) orelse return;
    const skip = aux.addOp2(v, OP.IfNot, r, 0);
    _ = aux.addOp2(v, OP.AutoCommit, 0, 0);
    aux.jumpHere(v, skip);
}

/// COMMIT/ROLLBACK, which do nothing without a transaction (xq_ora_
/// autocommit() is 1).
fn endTransaction(p: *int.Parse, rollback: bool) void {
    const v = build.getVdbe(p) orelse return;
    const r = autocommitRegister(p) orelse return;
    const skip = aux.addOp2(v, OP.If, r, 0);
    _ = aux.addOp2(v, OP.AutoCommit, 1, @intFromBool(rollback));
    aux.jumpHere(v, skip);
}

/// A register with xq_ora_autocommit().
fn autocommitRegister(p: *int.Parse) ?i32 {
    const defs = dialect.engineFunctionSearch("xq_ora_autocommit");
    if (defs.len == 0) return null;
    p.n_mem += 1;
    const r: i32 = @intCast(p.n_mem);
    _ = aux.addFunctionCall(p, 0, 0, r, 0, &defs[0], 0);
    return r;
}

// ================================================================ DDL

/// DDL with Oracle's checks first (what Oracle reports at compile time,
/// in its words).
fn ddl(l: *lower.Lowerer, s: tree.Stmt) lower.Error!void {
    const p = l.p;
    ir.stmt.readSchema(p) catch return error.Failed;
    switch (s) {
        .create_table => |ct| {
            const schema: []const u8 = if (ct.temp) "temp" else if (ct.name.schema) |x| x.text else "main";
            if (build.findTable(p.db, ct.name.name.text, schema) != null) {
                if (ct.if_not_exists) return;
                return l.fail(ct.name.name.pos, "ORA-00955: name is already used by an existing object", .{});
            }
            for (ct.columns) |c| for (c.constraints) |cc| if (cc.kind == .identity) {
                if (sequenceExists(p.db, cc.kind.identity.sequence)) return l.fail(c.name.pos, "ORA-00955: name is already used by an existing object", .{});
            };
            try l.createTable(ct);
        },
        .create_index => |ci| {
            if (relationExists(p.db, ci.name.name.text, if (ci.name.schema) |x| x.text else "main")) {
                if (ci.if_not_exists) return;
                return l.fail(ci.name.name.pos, "ORA-00955: name is already used by an existing object", .{});
            }
            const q: tree.QName = .{ .schema = ci.name.schema, .name = ci.table };
            if (try l.findTable(q) == null) return l.fail(ci.table.pos, "ORA-00942: table or view does not exist", .{});
            try l.createIndex(ci);
        },
        .create_view => |v| {
            const t = build.findTable(p.db, v.name.name.text, if (v.name.schema) |x| x.text else null);
            if (t) |x| if (!v.or_replace or !x.isView()) return l.fail(v.name.name.pos, "ORA-00955: name is already used by an existing object", .{});
            try l.createView(v);
        },
        .create_sequence => |cs| {
            const name = cs.name.name.text;
            if (relationExists(p.db, name, catalog.main_schema) or sequenceExists(p.db, name)) {
                if (cs.if_not_exists) return;
                return l.fail(cs.name.name.pos, "ORA-00955: name is already used by an existing object", .{});
            }
            l.createSequence(cs);
        },
        .alter_table => |a| {
            const tab = try l.findTable(a.name) orelse return l.fail(a.name.name.pos, "ORA-00942: table or view does not exist", .{});
            switch (a.action) {
                .add_column => |ac| if (build.columnIndex(tab, ac.def.name.text) >= 0) {
                    return l.fail(ac.def.name.pos, "ORA-01430: column being added already exists in table", .{});
                },
                .drop_column => |dc| if (build.columnIndex(tab, dc.name.text) < 0) {
                    return l.fail(dc.name.pos, "ORA-00904: \"{s}\": invalid identifier", .{dc.name.text});
                },
                .rename_column => |rc| if (build.columnIndex(tab, rc.old.text) < 0) {
                    return l.fail(rc.old.pos, "ORA-00904: \"{s}\": invalid identifier", .{rc.old.text});
                },
                .rename_to => |n| if (relationExists(p.db, n.text, catalog.schemaName(p.db, tab))) {
                    return l.fail(n.pos, "ORA-00955: name is already used by an existing object", .{});
                },
            }
            try l.alterTable(a);
        },
        .drop => |d| {
            const name = d.name.name.text;
            switch (d.kind) {
                .table, .view => {
                    const t = build.findTable(p.db, name, if (d.name.schema) |x| x.text else null);
                    if (t == null or (d.kind == .view) != t.?.isView()) {
                        if (d.if_exists) return;
                        if (t != null and d.kind == .view) return l.fail(d.name.name.pos, "ORA-00942: table or view does not exist", .{});
                        return l.fail(d.name.name.pos, "ORA-00942: table or view does not exist", .{});
                    }
                },
                .sequence => if (!sequenceExists(p.db, name)) {
                    if (d.if_exists) return;
                    return l.fail(d.name.name.pos, "ORA-02289: sequence does not exist", .{});
                },
                .index => if (!indexExists(p.db, name)) {
                    if (d.if_exists) return;
                    return l.fail(d.name.name.pos, "ORA-01418: specified index does not exist", .{});
                },
            }
            try l.drop(d);
        },
        else => unreachable,
    }
}

fn relationExists(db: *int.Sqlite3, name: []const u8, schema: []const u8) bool {
    if (build.findTable(db, name, schema) != null) return true;
    const i = build.findDbName(db, schema) orelse return false;
    return db.dbs.items[i].schema.idx_hash.get(name) != null;
}

fn indexExists(db: *int.Sqlite3, name: []const u8) bool {
    for (db.dbs.items) |*d| if (d.schema.idx_hash.get(name) != null) return true;
    return false;
}

const sequenceExists = parser.sequenceExists;

// ============================================================= errors

/// SQLite's messages for common failures at compile time in Oracle's
/// words.
fn translateError(p: *int.Parse) int.Oom!void {
    const m: []const u8 = p.err_msg orelse return;
    if (std.mem.startsWith(u8, m, "ORA-") or std.mem.startsWith(u8, m, "xqlite:")) return;
    const Rule = struct { []const u8, []const u8, []const u8 };
    const rules = [_]Rule{
        // prefix, before the name, after it
        .{ "no such table: ", "ORA-00942: table or view \"", "\" does not exist" },
        .{ "no such view: ", "ORA-00942: table or view \"", "\" does not exist" },
        .{ "no such column: ", "ORA-00904: \"", "\": invalid identifier" },
        .{ "no such function: ", "ORA-00904: \"", "\": invalid identifier" },
        .{ "no such index: ", "ORA-01418: specified index does not exist", "" },
        .{ "ambiguous column name: ", "ORA-00918: column ambiguously defined", "" },
        .{ "wrong number of arguments to function ", "ORA-00909: invalid number of arguments", "" },
        .{ "misuse of aggregate", "ORA-00934: group function is not allowed here", "" },
        .{ "misuse of window function", "ORA-30483: window functions are not allowed here", "" },
    };
    for (rules) |r| if (std.mem.startsWith(u8, m, r[0])) {
        if (r[2].len == 0) {
            p.err_msg = try p.arena.dupeSentinel(u8, r[1], 0);
            return;
        }
        var name = m[r[0].len..];
        if (std.mem.startsWith(u8, name, "main.")) name = name[5..];
        p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "{s}{s}{s}", .{ r[1], name, r[2] }, 0);
        return;
    };
    if (std.mem.startsWith(u8, m, "cannot insert a non-DEFAULT value into column")) {
        p.err_msg = try p.arena.dupeSentinel(u8, "ORA-32795: cannot insert into a generated always identity column", 0);
        return;
    }
    if (std.mem.endsWith(u8, m, "can only be updated to DEFAULT")) {
        p.err_msg = try p.arena.dupeSentinel(u8, "ORA-32796: cannot update a generated always identity column", 0);
        return;
    }
    if (std.mem.endsWith(u8, m, " already exists")) {
        p.err_msg = try p.arena.dupeSentinel(u8, "ORA-00955: name is already used by an existing object", 0);
        return;
    }
    if (std.mem.indexOf(u8, m, " values for ") != null or std.mem.indexOf(u8, m, " values were supplied") != null) {
        const msg: []const u8 = if (std.mem.indexOf(u8, m, "but") != null and valuesFewer(m)) "ORA-00947: not enough values" else "ORA-00913: too many values";
        p.err_msg = try p.arena.dupeSentinel(u8, msg, 0);
        return;
    }
}

/// "table t has 3 columns but 2 values were supplied": fewer values.
fn valuesFewer(m: []const u8) bool {
    var nums: [2]u64 = .{ 0, 0 };
    var k: usize = 0;
    var it = std.mem.tokenizeScalar(u8, m, ' ');
    while (it.next()) |w| {
        if (std.fmt.parseUnsigned(u64, w, 10)) |n| {
            if (k < 2) nums[k] = n;
            k += 1;
        } else |_| {}
    }
    return k >= 2 and nums[1] < nums[0];
}

test {
    _ = @import("lexer.zig");
    _ = @import("types.zig");
    _ = @import("datetime.zig");
    _ = @import("funcs.zig");
    _ = @import("json.zig");
    _ = @import("session.zig");
    _ = @import("jsonfuncs.zig");
    _ = @import("test.zig");
}
