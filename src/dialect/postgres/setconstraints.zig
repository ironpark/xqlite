//! PostgreSQL's SET CONSTRAINTS {ALL | name [, ...]} {DEFERRED | IMMEDIATE}
//! for its foreign keys, each on its own (commands.zig parses it).
//!
//! SQLite decides when it compiles a statement whether a foreign key's
//! violations are deferred (counted in the connection's counter, checked
//! at COMMIT) or immediate (the statement's counter): fkey.zig asks
//! dialect.fkDeferred(), which in PostgreSQL's dialect is deferred()
//! here. The connection keeps the modes SET CONSTRAINTS gave in the open
//! transaction (Modes, in state.State): ALL's, and those of the foreign
//! keys named after it, which take precedence (PostgreSQL's
//! SetConstraintState). Only a DEFERRABLE foreign key (FKey.is_deferrable,
//! or INITIALLY DEFERRED) follows them; the others are immediate. Each
//! change, and the end of the transaction that forgets them, expires the
//! compiled statements, which compile again with the new modes. SQLite's
//! dialect never asks: its programs are SQLite's.
//!
//! A constraint is known by its database, its table's SQLite name and
//! its name in pg_constraint (fkName(): the name the user gave, recorded
//! in xq_catalog, else <table>_<columns>_fkey).
//!
//! SET CONSTRAINTS ... IMMEDIATE checks the violations already deferred
//! of the foreign keys it makes immediate (PostgreSQL fires their
//! pending triggers): the connection counts deferred violations, not of
//! which key, so each of those keys is checked as PRAGMA
//! foreign_key_check checks it (once for a table's keys), if the count
//! is not zero; the first row found is the error, in PostgreSQL's words
//! of a child row ("insert or update on table ..."), as the key's own
//! check at COMMIT would say.
//!
//! The modes are a savepoint's, as PostgreSQL's are a subtransaction's:
//! ROLLBACK TO gives back those of when the savepoint was made (the
//! first change in it saves them, Saved).

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const prepare = @import("../../sql/prepare.zig");
const main_mod = @import("../../sql/main.zig");
const util = @import("../../sql/util.zig");
const catalog = @import("../../catalog/catalog.zig");
const dconstraint = @import("../constraint.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const pg_state = @import("state.zig");

const Allocator = std.mem.Allocator;
const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const Table = int.Table;
const FKey = int.FKey;
const RC = int.RC;
const Parser = parser.Parser;
const Mem = dfunc.Mem;
const Context = dfunc.Context;
const nsp = catalog.schemas;
const Quoted = dialect.Quoted('"');

// ================================================================ the modes

/// The mode SET CONSTRAINTS gave a foreign key.
const Named = struct {
    /// Its database: "main", "temp" or an attached one's name.
    db: []u8,
    /// Its table's SQLite name.
    table: []u8,
    /// Its name (pg_constraint.conname).
    name: []u8,
    deferred: bool,

    fn deinit(n: Named, gpa: Allocator) void {
        gpa.free(n.db);
        gpa.free(n.table);
        gpa.free(n.name);
    }
};

/// The modes of a transaction (PostgreSQL's SetConstraintState).
const Set = struct {
    /// ALL's mode, if SET CONSTRAINTS ALL ran (true: DEFERRED).
    all: ?bool = null,
    /// The foreign keys named since, each once.
    named: std.ArrayList(Named) = .empty,

    fn isEmpty(s: *const Set) bool {
        return s.all == null and s.named.items.len == 0;
    }

    fn deinit(s: *Set, gpa: Allocator) void {
        for (s.named.items) |n| n.deinit(gpa);
        s.named.deinit(gpa);
        s.* = .{};
    }

    fn clone(s: *const Set, gpa: Allocator) error{OutOfMemory}!Set {
        var out: Set = .{ .all = s.all };
        errdefer out.deinit(gpa);
        for (s.named.items) |n| try out.add(gpa, n.db, n.table, n.name, n.deferred);
        return out;
    }

    /// Whether a foreign key of table `table` of database `db` may be
    /// named in `s`: asked before its name is (fkName()).
    fn hasTable(s: *const Set, db: []const u8, table: []const u8) bool {
        for (s.named.items) |n| {
            if (eql(n.db, db) and std.ascii.eqlIgnoreCase(n.table, table)) return true;
        }
        return false;
    }

    fn find(s: *const Set, db: []const u8, table: []const u8, name: []const u8) ?*Named {
        for (s.named.items) |*n| {
            if (eql(n.db, db) and std.ascii.eqlIgnoreCase(n.table, table) and eql(n.name, name)) return n;
        }
        return null;
    }

    fn add(s: *Set, gpa: Allocator, db: []const u8, table: []const u8, name: []const u8, mode: bool) error{OutOfMemory}!void {
        if (s.find(db, table, name)) |n| {
            n.deferred = mode;
            return;
        }
        const d = try gpa.dupe(u8, db);
        errdefer gpa.free(d);
        const t = try gpa.dupe(u8, table);
        errdefer gpa.free(t);
        const nm = try gpa.dupe(u8, name);
        errdefer gpa.free(nm);
        try s.named.append(gpa, .{ .db = d, .table = t, .name = nm, .deferred = mode });
    }
};

/// The modes as they were before the first SET CONSTRAINTS made with
/// `depth` savepoints open.
const Saved = struct { depth: u32, set: Set };

/// SET CONSTRAINTS of the connection's open transaction
/// (state.State.constraints).
pub const Modes = struct {
    cur: Set = .{},
    /// By depth, from the lowest.
    saved: std.ArrayList(Saved) = .empty,

    pub fn deinit(m: *Modes, gpa: Allocator) void {
        m.cur.deinit(gpa);
        m.dropSaved(gpa, 0);
        m.saved.deinit(gpa);
        m.* = .{};
    }

    /// Forget the saved modes from index `from` on.
    fn dropSaved(m: *Modes, gpa: Allocator, from: usize) void {
        for (m.saved.items[from..]) |*x| x.set.deinit(gpa);
        m.saved.shrinkRetainingCapacity(from);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn modesOf(db: *Sqlite3) *Modes {
    return &db.xq.postgres.constraints;
}

/// Whether SET CONSTRAINTS may make `fk` deferred or immediate.
fn deferrable(fk: *const FKey) bool {
    return fk.is_deferrable or fk.is_deferred;
}

/// A foreign key looked up in a Set, its name (fkName()) computed when
/// one of its table's is named, once.
const Ref = struct {
    /// Its database: "main", "temp" or an attached one's name.
    db: []const u8,
    fk: *const FKey,
    name: ?[]const u8 = null,

    fn of(sq: *Sqlite3, fk: *const FKey) Ref {
        return .{ .db = catalog.schemaName(sq, fk.from), .fk = fk };
    }

    /// Its entry in `s`, if it has one.
    fn in(r: *Ref, s: *const Set, a: Allocator, sq: *Sqlite3) error{OutOfMemory}!?*Named {
        const table = r.fk.from.name;
        if (!s.hasTable(r.db, table)) return null;
        if (r.name == null) r.name = try fkName(a, sq, r.fk);
        return s.find(r.db, table, r.name.?);
    }
};

/// The mode of deferrable foreign key `r` in `s`; null: its own.
fn modeIn(s: *const Set, a: Allocator, db: *Sqlite3, r: *Ref) error{OutOfMemory}!?bool {
    if (try r.in(s, a, db)) |n| return n.deferred;
    return s.all;
}

/// dialect.fkDeferred() in PostgreSQL's dialect: the mode SET CONSTRAINTS
/// gave `fk` in the open transaction, if it is deferrable; null: its own.
pub fn deferred(p: *Parse, fk: *const FKey) ?bool {
    const m = modesOf(p.db);
    if (m.cur.isEmpty() or !deferrable(fk)) return null;
    var r: Ref = .of(p.db, fk);
    return modeIn(&m.cur, p.arena, p.db, &r) catch {
        p.db.oomFault();
        return null;
    };
}

/// The compiled statements compile again (with the modes now).
fn expire(db: *Sqlite3) void {
    @import("../../vdbe/aux.zig").expirePreparedStatements(db, .now);
}

/// The transaction ended (dialect.transactionEnded()): its modes go.
pub fn transactionEnded(db: *Sqlite3) void {
    const m = modesOf(db);
    if (m.cur.isEmpty() and m.saved.items.len == 0) return;
    const changed = !m.cur.isEmpty();
    m.deinit(db.gpa);
    if (changed) expire(db);
}

const savepoints = pg_state.savepoints;

/// A RELEASE or ROLLBACK TO ran (dialect.savepointEnded()): a rollback
/// gives back the modes of when the savepoint was made; a release makes
/// the ones saved in it its parent's.
pub fn savepointEnded(db: *Sqlite3, rolled_back: bool) void {
    const m = modesOf(db);
    if (m.saved.items.len == 0) return;
    const gpa = db.gpa;
    const n = savepoints(db);
    if (rolled_back) {
        // ROLLBACK TO keeps the savepoint: the n-th is the one rolled
        // back to, and what changed in it was at a depth of n or more.
        for (m.saved.items, 0..) |*x, i| if (x.depth >= n) {
            m.cur.deinit(gpa);
            m.cur = x.set;
            x.set = .{};
            m.dropSaved(gpa, i);
            expire(db);
            return;
        };
        return;
    }
    // The saved modes of the released savepoints are now the parent's
    // (the lowest one kept of each depth); none of the transaction.
    var keep: usize = 0;
    for (m.saved.items) |*x| {
        const depth = @min(x.depth, n);
        if (depth == 0 or (keep > 0 and m.saved.items[keep - 1].depth == depth)) {
            x.set.deinit(gpa);
            continue;
        }
        m.saved.items[keep] = .{ .depth = depth, .set = x.set };
        keep += 1;
    }
    m.saved.shrinkRetainingCapacity(keep);
}

// ================================================================ the names

/// The name of `fk` in pg_constraint (as pgcatalog.zig names it): the
/// one the user gave, recorded in xq_catalog, else
/// <table>_<columns>_fkey (constraints.fkeyName()). In `a`.
pub fn fkName(a: Allocator, db: *Sqlite3, fk: *const FKey) error{OutOfMemory}![]const u8 {
    const t = fk.from;
    const cols = try colNames(a, fk);
    const key = try dconstraint.key(a, .foreign_key, cols);
    if (catalog.metaOf(db, t) catch null) |m| {
        for (m.entries) |e| {
            if (e.col.len == 0 and std.ascii.eqlIgnoreCase(e.key, key)) return a.dupe(u8, e.value);
        }
    }
    return @import("constraints.zig").fkeyName(a, relName(db, t), cols);
}

/// The names of the columns of `fk` (its child table's), in `a`.
fn colNames(a: Allocator, fk: *const FKey) error{OutOfMemory}![]const []const u8 {
    const cols = try a.alloc([]const u8, fk.cols.len);
    for (fk.cols, cols) |c, *n| n.* = fk.from.cols[@intCast(c.i_from)].name();
    return cols;
}

/// The name of table `t` in its schema (a schema's table of main is
/// main's "schema.name": catalog/schema.zig).
fn relName(db: *Sqlite3, t: *const Table) []const u8 {
    return bareName(prepare.schemaToIndex(db, t.schema) == 0, t.name);
}

fn bareName(in_main: bool, name: []const u8) []const u8 {
    if (in_main) if (nsp.split(name)) |sp| return sp.name;
    return name;
}

/// Where a schema's tables are: a database, and for main the tables of a
/// named schema (`prefix`) or the others (public).
const Scope = struct {
    i_db: usize,
    prefix: ?[]const u8 = null,

    fn has(s: Scope, i_db: usize, t: *const Table, schemas: []const nsp.Info) bool {
        if (i_db != s.i_db) return false;
        if (i_db != 0) return true;
        const sp = nsp.split(t.name);
        const in_schema: ?[]const u8 = if (sp) |x| (if (nsp.find(schemas, x.schema) != null) x.schema else null) else null;
        if (s.prefix) |p| return in_schema != null and std.ascii.eqlIgnoreCase(in_schema.?, p);
        return in_schema == null;
    }
};

/// The scope of schema `name`; null: none (pg_catalog,
/// information_schema, pg_temp without a temp database).
fn scopeOf(db: *Sqlite3, schemas: []const nsp.Info, name: []const u8) error{NoSuchSchema}!?Scope {
    if (eql(name, "public")) return .{ .i_db = 0 };
    if (std.mem.startsWith(u8, name, "pg_temp")) return if (db.dbs.items.len > 1) .{ .i_db = 1 } else null;
    if (nsp.find(schemas, name)) |s| return .{ .i_db = 0, .prefix = s.name };
    if (@import("../../sql/build.zig").findDbName(db, name)) |i| if (i >= 2) return .{ .i_db = i };
    if (eql(name, "pg_catalog") or eql(name, "information_schema")) return null;
    return error.NoSuchSchema;
}

/// A foreign key a name matched.
const Match = struct { i_db: usize, t: *Table, fk: *FKey, name: []const u8 };

/// The foreign keys of scope `s` named `name`.
fn matchesIn(a: Allocator, db: *Sqlite3, s: Scope, schemas: []const nsp.Info, name: []const u8, out: *std.ArrayList(Match)) error{OutOfMemory}!void {
    if (s.i_db >= db.dbs.items.len) return;
    var it = db.dbs.items[s.i_db].schema.tbl_hash.valueIterator();
    while (it.next()) |tp| {
        const t = tp.*;
        if (!t.isOrdinary() or !s.has(s.i_db, t, schemas)) continue;
        var f = t.u.tab.fkey;
        while (f) |fk| : (f = fk.next_from) {
            const n = try fkName(a, db, fk);
            if (eql(n, name)) try out.append(a, .{ .i_db = s.i_db, .t = t, .fk = fk, .name = n });
        }
    }
}

/// Whether a constraint of another kind (a key, a CHECK, a NOT NULL:
/// none deferrable) has name `name` (in schema `schema`).
fn otherExists(db: *Sqlite3, schema: ?[]const u8, name: []const u8) parser.Error!bool {
    const q = "SELECT 1 FROM pg_catalog.pg_constraint c JOIN pg_catalog.pg_namespace n ON n.oid = c.connamespace " ++
        "WHERE c.conname = $1 AND c.contype <> 'f' AND ($2 IS NULL OR n.nspname = $2 OR ($2 = 'pg_temp' AND n.nspname LIKE 'pg\\_temp\\_%'))";
    var v: ?*vi.Vdbe = null;
    const rc = prepare.prepareLang(db, q, .of(.postgres), .{}, &v, null);
    const stmt = v orelse {
        if (rc == RC.NOMEM) return error.OutOfMemory;
        return false;
    };
    defer _ = api.finalize(stmt);
    if (api.bindText(stmt, 1, name) != RC.OK) return error.OutOfMemory;
    if (schema) |s| if (api.bindText(stmt, 2, s) != RC.OK) return error.OutOfMemory;
    return api.step(stmt) == RC.ROW;
}

/// The SQL argument list of SET CONSTRAINTS' foreign keys named `names`
/// (ps.c errors as PostgreSQL's AfterTriggerSetState()'s): ", 'db',
/// 'table', 'name'" for each deferrable one. A name is looked up in its
/// schema, or else in the first schema of pg_temp and the search_path
/// that has a constraint of the name; a constraint not deferrable fails
/// DEFERRED and is left out of IMMEDIATE.
pub fn resolve(ps: *Parser, names: []const parser.QName, defer_them: bool, out: *std.ArrayList(u8)) parser.Error!void {
    const a = ps.arena;
    const db = ps.p.?.db;
    try ps.readSchema();
    const schemas = try ps.registered();
    for (names) |q| {
        var scopes: std.ArrayList(Scope) = .empty;
        if (q.schema) |s| {
            const sc = scopeOf(db, schemas, s.text) catch return ps.c.failState(null, .of("3F000"), "schema \"{s}\" does not exist", .{s.text});
            if (sc) |x| try scopes.append(a, x);
        } else {
            if (db.dbs.items.len > 1) try scopes.append(a, .{ .i_db = 1 });
            for (try ps.searchPath()) |s| {
                if (scopeOf(db, schemas, s) catch null) |x| try scopes.append(a, x);
            }
        }
        var found: std.ArrayList(Match) = .empty;
        for (scopes.items) |sc| {
            try matchesIn(a, db, sc, schemas, q.name.text, &found);
            if (found.items.len > 0) break;
        }
        if (found.items.len == 0) {
            if (!try otherExists(db, if (q.schema) |s| s.text else null, q.name.text)) {
                return ps.c.failState(null, .of("42704"), "constraint \"{s}\" does not exist", .{q.name.text});
            }
            if (defer_them) return ps.c.failState(null, .of("55000"), "constraint \"{s}\" is not deferrable", .{q.name.text});
            continue;
        }
        for (found.items) |m| {
            if (!deferrable(m.fk)) {
                if (defer_them) return ps.c.failState(null, .of("55000"), "constraint \"{s}\" is not deferrable", .{q.name.text});
                continue;
            }
            for ([_][]const u8{ if (m.i_db == 1) "temp" else db.dbs.items[m.i_db].name, m.t.name, m.name }) |z| {
                try out.appendSlice(a, ", ");
                try @import("session.zig").literal(out, a, z);
            }
        }
    }
}

// ================================================================ running it

pub const functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_set_constraints", -1, .{ .unsafe = true, .direct_only = true }, setConstraintsFunc),
};

/// xq_pg_set_constraints(mode, all [, db, table, name] ...): SET
/// CONSTRAINTS when it runs, `mode` 'd' (DEFERRED) or 'i', `all` 1 for
/// ALL, else the foreign keys of resolve(). Nothing outside a transaction
/// block (pg_state.inTransactionBlock()). IMMEDIATE first checks the
/// violations deferred of the keys it makes immediate: an error leaves
/// the modes as they were.
fn setConstraintsFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (argv.len < 2 or (argv.len - 2) % 3 != 0) return api.resultError(ctx, "xq_pg_set_constraints: wrong arguments");
    api.resultInt64(ctx, 0);
    if (!pg_state.inTransactionBlock(db)) return;
    const defer_them = std.mem.eql(u8, api.valueText(argv[0]) orelse "", "d");
    const all = api.valueInt64(argv[1]) != 0;
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The keys named, in a Set of their own (in the arena).
    var keys: Set = .{};
    var i: usize = 2;
    while (i < argv.len) : (i += 3) {
        const db_name = api.valueText(argv[i]) orelse "";
        const table = api.valueText(argv[i + 1]) orelse "";
        const name = api.valueText(argv[i + 2]) orelse "";
        keys.add(a, db_name, table, name, defer_them) catch return api.resultErrorNomem(ctx);
    }
    const failed = run(db, a, defer_them, all, &keys) catch return api.resultErrorNomem(ctx);
    if (failed) |f| api.resultErrorFields(ctx, .of("23503"), f);
}

/// SET CONSTRAINTS; the error of a violation found, if one is.
fn run(db: *Sqlite3, a: Allocator, defer_them: bool, all: bool, keys: *const Set) error{OutOfMemory}!?util.ErrorFields {
    const m = modesOf(db);
    const gpa = db.gpa;
    // The keys made immediate that were deferred: their violations
    // deferred so far fail now (none if the connection counts none).
    if (!defer_them and db.n_deferred_cons > 0) {
        var check: std.ArrayList(Check) = .empty;
        for (db.dbs.items, 0..) |d, i_db| {
            var it = d.schema.tbl_hash.valueIterator();
            while (it.next()) |tp| {
                const t = tp.*;
                if (!t.isOrdinary()) continue;
                check.clearRetainingCapacity();
                var f = t.u.tab.fkey;
                var fkid: i64 = 0;
                while (f) |fk| : ({
                    f = fk.next_from;
                    fkid += 1;
                }) {
                    if (!deferrable(fk)) continue;
                    var r: Ref = .of(db, fk);
                    if (!all and try r.in(keys, a, db) == null) continue;
                    const before = (try modeIn(&m.cur, a, db, &r)) orelse fk.is_deferred;
                    if (!before) continue;
                    try check.append(a, .{ .fk = fk, .fkid = fkid, .name = r.name });
                }
                if (check.items.len == 0) continue;
                if (try firstViolation(db, a, i_db, t, check.items)) |fields| return fields;
            }
        }
    }
    // Nothing to compile again if the modes stay as they are.
    var changed = false;
    if (all) {
        changed = m.cur.named.items.len > 0 or (if (m.cur.all) |x| x != defer_them else true);
    } else for (keys.named.items) |k| {
        const n = m.cur.find(k.db, k.table, k.name) orelse {
            changed = true;
            break;
        };
        if (n.deferred != defer_them) {
            changed = true;
            break;
        }
    }
    if (!changed) return null;
    // The savepoint's first change saves the modes it found.
    const depth = savepoints(db);
    if (depth > 0 and (m.saved.items.len == 0 or m.saved.items[m.saved.items.len - 1].depth < depth)) {
        var copy = try m.cur.clone(gpa);
        errdefer copy.deinit(gpa);
        try m.saved.append(gpa, .{ .depth = depth, .set = copy });
    }
    if (all) {
        for (m.cur.named.items) |n| n.deinit(gpa);
        m.cur.named.clearRetainingCapacity();
        m.cur.all = defer_them;
    } else {
        for (keys.named.items) |k| try m.cur.add(gpa, k.db, k.table, k.name, defer_them);
    }
    expire(db);
    return null;
}

/// A foreign key whose deferred violations SET CONSTRAINTS ... IMMEDIATE
/// checks: the `fkid`-th of its table's list, its name if known.
const Check = struct { fk: *FKey, fkid: i64, name: ?[]const u8 };

/// The first violation of table `t` (database `i_db`) of its foreign keys
/// `check`, in their order, each key's first row as PRAGMA
/// foreign_key_check finds it (run once for them all): PostgreSQL's error
/// of the key, with the row's key in its DETAIL when it can be read.
/// Null: none.
fn firstViolation(db: *Sqlite3, a: Allocator, i_db: usize, t: *Table, check: []const Check) error{OutOfMemory}!?util.ErrorFields {
    const dbname = db.dbs.items[i_db].name;
    // The first row of each key, if one: its rowid (null: none, a
    // WITHOUT ROWID table's).
    const Row = struct { rowid: ?i64 };
    const rows = try a.alloc(?Row, check.len);
    @memset(rows, null);
    {
        var q = catalog.Query.initFmt(db, "PRAGMA %Q.foreign_key_check(%Q)", &.{ .{ .str = dbname }, .{ .str = t.name } }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return null;
        };
        defer q.deinit();
        var left = check.len;
        while (left > 0 and (q.step() catch false)) {
            const fkid = api.columnInt64(q.v, 3);
            for (check, rows) |c, *row| {
                if (c.fkid != fkid or row.* != null) continue;
                row.* = .{ .rowid = if (api.columnType(q.v, 1) != vi.SQLITE_NULL) api.columnInt64(q.v, 1) else null };
                left -= 1;
                break;
            }
        }
    }
    for (check, rows) |c, row| {
        const r = row orelse continue;
        const name = c.name orelse try fkName(a, db, c.fk);
        const msg = try std.fmt.allocPrint(a, "insert or update on table \"{s}\" violates foreign key constraint \"{s}\"", .{ relName(db, t), name });
        return .{ .message = msg, .detail = try keyDetail(db, a, i_db, t, c.fk, r.rowid, bareName(i_db == 0, c.fk.to)) };
    }
    return null;
}

/// `Key (cols)=(values) is not present in table "parent".` of row `rowid`
/// of `t`, its values as PostgreSQL writes them (::text); null if it
/// cannot be read.
fn keyDetail(db: *Sqlite3, a: Allocator, i_db: usize, t: *Table, fk: *FKey, rowid: ?i64, parent: []const u8) error{OutOfMemory}!?[]const u8 {
    const id = rowid orelse return null;
    const cols = try colNames(a, fk);
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "SELECT ");
    for (cols, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(a, ", ");
        try sql.print(a, "{f}::text", .{Quoted{ .z = c }});
    }
    const schema: []const u8 = if (i_db == 1) "pg_temp" else if (i_db == 0) (if (nsp.split(t.name)) |sp| sp.schema else "public") else db.dbs.items[i_db].name;
    try sql.print(a, " FROM {f}.{f} WHERE rowid = {d}", .{ Quoted{ .z = schema }, Quoted{ .z = relName(db, t) }, id });
    var v: ?*vi.Vdbe = null;
    const rc = prepare.prepareLang(db, sql.items, .of(.postgres), .{}, &v, null);
    const stmt = v orelse {
        if (rc == RC.NOMEM) return error.OutOfMemory;
        return null;
    };
    defer _ = api.finalize(stmt);
    if (api.step(stmt) != RC.ROW) return null;
    const values = try a.alloc([]const u8, cols.len);
    for (values, 0..) |*z, i| z.* = api.columnText(stmt, i) orelse "null";
    const joined = dialect.Violation.joined;
    return try std.fmt.allocPrint(a, "Key ({s})=({s}) is not present in table \"{s}\".", .{ try joined(a, cols, "{s}", ", "), try joined(a, values, "{s}", ", "), parent });
}

// ==================================================================== tests

const testing = std.testing;
const Conn = @import("../../sql/sql_test.zig").Conn;
const Dialect = dialect.Dialect;

fn pgConn(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .postgres);
    try c.exec("CREATE TABLE p (id int PRIMARY KEY);" ++
        "CREATE TABLE c (x int REFERENCES p DEFERRABLE INITIALLY DEFERRED, y int, z int REFERENCES p," ++
        " CONSTRAINT cy FOREIGN KEY (y) REFERENCES p DEFERRABLE)");
}

test "pg: SET CONSTRAINTS defers each foreign key named, until the transaction ends" {
    try Dialect.requireBuilt(&.{.postgres});
    var c: Conn = undefined;
    try pgConn(&c);
    defer c.close();
    try c.expectRows("SELECT conname, condeferrable, condeferred FROM pg_constraint WHERE contype = 'f' ORDER BY 1", "c_x_fkey|1|1\nc_z_fkey|0|0\ncy|1|0\n");
    // cy deferred, c_z_fkey (not deferrable) still immediate.
    try c.exec("BEGIN; SET CONSTRAINTS cy DEFERRED; INSERT INTO c VALUES (NULL, 6, NULL)");
    try c.expectError("INSERT INTO c VALUES (NULL, NULL, 7)", "insert or update on table \"c\" violates foreign key constraint \"c_z_fkey\"\nDETAIL:  Key (z)=(7) is not present in table \"p\".");
    try c.exec("INSERT INTO p VALUES (6); COMMIT");
    // The mode went with the transaction: cy is immediate again.
    try c.exec("BEGIN");
    try c.expectError("INSERT INTO c VALUES (NULL, 9, NULL)", "insert or update on table \"c\" violates foreign key constraint \"cy\"\nDETAIL:  Key (y)=(9) is not present in table \"p\".");
    // ALL, then a name: the name's mode wins; c_x_fkey stays deferred.
    try c.exec("SET CONSTRAINTS ALL DEFERRED; SET CONSTRAINTS public.cy IMMEDIATE; INSERT INTO c VALUES (8, NULL, NULL)");
    try c.expectError("INSERT INTO c VALUES (NULL, 8, NULL)", "insert or update on table \"c\" violates foreign key constraint \"cy\"\nDETAIL:  Key (y)=(8) is not present in table \"p\".");
    // IMMEDIATE checks the violations deferred so far.
    try c.expectError("SET CONSTRAINTS c_x_fkey IMMEDIATE", "insert or update on table \"c\" violates foreign key constraint \"c_x_fkey\"\nDETAIL:  Key (x)=(8) is not present in table \"p\".");
    try c.expectError("SET CONSTRAINTS ALL IMMEDIATE", "insert or update on table \"c\" violates foreign key constraint \"c_x_fkey\"\nDETAIL:  Key (x)=(8) is not present in table \"p\".");
    try c.exec("DELETE FROM c WHERE x = 8; SET CONSTRAINTS ALL IMMEDIATE");
    try c.expectError("INSERT INTO c VALUES (8, NULL, NULL)", "insert or update on table \"c\" violates foreign key constraint \"c_x_fkey\"\nDETAIL:  Key (x)=(8) is not present in table \"p\".");
    try c.exec("ROLLBACK");
    try c.expectRows("SELECT x, y, z FROM c", "NULL|6|NULL\n");
    // The names: PostgreSQL's errors.
    try c.exec("BEGIN");
    try c.expectError("SET CONSTRAINTS nosuch DEFERRED", "constraint \"nosuch\" does not exist");
    try c.expectError("SET CONSTRAINTS cy, c_z_fkey DEFERRED", "constraint \"c_z_fkey\" is not deferrable");
    try c.expectError("SET CONSTRAINTS p_pkey DEFERRED", "constraint \"p_pkey\" is not deferrable");
    try c.expectError("SET CONSTRAINTS nosch.cy DEFERRED", "schema \"nosch\" does not exist");
    try c.expectError("SET CONSTRAINTS pg_catalog.cy DEFERRED", "constraint \"cy\" does not exist");
    try c.exec("SET CONSTRAINTS c_z_fkey, p_pkey IMMEDIATE; ROLLBACK");
}

test "pg: SET CONSTRAINTS of a savepoint, of a statement prepared before it" {
    try Dialect.requireBuilt(&.{.postgres});
    var c: Conn = undefined;
    try pgConn(&c);
    defer c.close();
    // ROLLBACK TO gives back the modes of the savepoint; RELEASE keeps them.
    try c.exec("BEGIN; SET CONSTRAINTS ALL DEFERRED; SAVEPOINT a; SET CONSTRAINTS ALL IMMEDIATE; ROLLBACK TO a; INSERT INTO c VALUES (NULL, 1, NULL); ROLLBACK");
    try c.exec("BEGIN; SAVEPOINT a; SAVEPOINT b; SET CONSTRAINTS cy DEFERRED; RELEASE b; INSERT INTO c VALUES (NULL, 1, NULL); ROLLBACK TO a");
    try c.expectError("INSERT INTO c VALUES (NULL, 1, NULL)", "insert or update on table \"c\" violates foreign key constraint \"cy\"\nDETAIL:  Key (y)=(1) is not present in table \"p\".");
    try c.exec("ROLLBACK");
    // A statement compiled before SET CONSTRAINTS is compiled again.
    var v: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "INSERT INTO c VALUES (NULL, 2, NULL)", &v, null));
    const stmt = v.?;
    defer _ = api.finalize(stmt);
    try c.exec("BEGIN; SET CONSTRAINTS cy DEFERRED");
    try testing.expectEqual(RC.DONE, api.step(stmt));
    _ = api.reset(stmt);
    try c.exec("INSERT INTO p VALUES (2); COMMIT; DELETE FROM c; DELETE FROM p");
    // And again when the transaction has ended.
    try testing.expect(api.step(stmt) != RC.DONE);
    _ = api.reset(stmt);
}

test "pg: SET CONSTRAINTS leaves SQLite's dialect alone" {
    try Dialect.requireBuilt(&.{.postgres});
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA foreign_keys = ON; CREATE TABLE p (id INTEGER PRIMARY KEY); CREATE TABLE c (x REFERENCES p DEFERRABLE INITIALLY IMMEDIATE)");
    main_mod.setDialect(c.db, .postgres);
    try c.expectRows("SELECT condeferrable, condeferred FROM pg_constraint WHERE contype = 'f'", "1|0\n");
    try c.exec("BEGIN; SET CONSTRAINTS ALL DEFERRED");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectError("INSERT INTO c VALUES (1)", "FOREIGN KEY constraint failed");
    main_mod.setDialect(c.db, .postgres);
    try c.exec("INSERT INTO c VALUES (1); ROLLBACK");
}
