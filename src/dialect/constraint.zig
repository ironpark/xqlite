//! Failed constraints in the words of the dialect a statement is compiled
//! in (dialect.Constraint, Hooks.constraint).
//!
//! The message is decided when the statement is compiled, where the code
//! generator (insert.zig, build.zig, fkey.zig) codes the OP_Halt of a
//! constraint: the dialect's Constraint.message turns a Violation (the
//! table, the columns, the constraint's name) into its message and
//! ErrorState, which go into P4 (encode()) with P5_ConstraintDialect. The
//! program then only decodes it when the constraint fails, and a
//! duplicate key's values, held in registers from P3, are written at
//! dialect.value_mark. In SQLite's dialect (and the engine's own SQL,
//! compiled in it) nothing changes: the program and its messages are
//! SQLite's.
//!
//! Foreign keys mostly fail when the statement ends (the counter of
//! OP_FkCounter is not zero): each OP_FkCounter that counts a violation
//! carries the message in P4, and the last one counted is the error
//! (Vdbe.xq_fk_error). A deferred one found at COMMIT, by another
//! statement, is Constraint.foreign_key.
//!
//! The names SQLite does not keep (those the user gave UNIQUE, PRIMARY
//! KEY and FOREIGN KEY constraints) are recorded at CREATE TABLE in
//! xq_catalog (catalog.Key.constraint, lower.zig) and read here
//! (recordedName()).

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const dialect = @import("dialect.zig");
const catalog = @import("../catalog/catalog.zig");
const ctype = @import("xqlite_base").ctype;

const Parse = int.Parse;
const Table = int.Table;
const Index = int.Index;
const FKey = int.FKey;
const Violation = dialect.Violation;
const Failure = dialect.Failure;

/// Between the ErrorState and the message in P4.
const unit_sep = '\x1f';

/// The P4 of a dialect's error: the SQLSTATE, the number, unit_sep, the
/// message.
fn encode(p: *Parse, f: Failure) ?[:0]const u8 {
    return std.fmt.allocPrintSentinel(p.arena, "{s}{d}{c}{s}", .{ &f.state.sqlstate, f.state.number, unit_sep, f.msg }, 0) catch {
        p.db.oomFault();
        return null;
    };
}

/// A P4 of encode().
pub const Decoded = struct { state: int.ErrorState, msg: []const u8 };

pub fn decode(z: []const u8) Decoded {
    const sep = std.mem.indexOfScalar(u8, z, unit_sep) orelse return .{ .state = .of("23000"), .msg = z };
    if (sep < 5) return .{ .state = .of("23000"), .msg = z[sep + 1 ..] };
    return .{
        .state = .{ .sqlstate = z[0..5].*, .number = std.fmt.parseInt(u32, z[5..sep], 10) catch 0 },
        .msg = z[sep + 1 ..],
    };
}

/// The Constraint hooks of the dialect `p` compiles in, if it words its
/// constraint errors.
fn hooksOf(p: *Parse) ?*const dialect.Constraint {
    const c = &dialect.hooks(p.db).constraint;
    if (c.message == null) return null;
    return c;
}

/// The P4 of the error of `v` in the dialect `p` compiles in; null if it
/// keeps SQLite's.
fn violation(p: *Parse, v: Violation) ?[:0]const u8 {
    const c = hooksOf(p) orelse return null;
    const f = c.message.?(p.arena, v) catch {
        p.db.oomFault();
        return null;
    };
    return encode(p, f);
}

fn database(p: *Parse, t: *const Table) []const u8 {
    return catalog.schemaName(p.db, t);
}

fn columnName(t: *const Table, i: i32) []const u8 {
    if (i < 0) return if (t.i_pkey >= 0) t.cols[@intCast(t.i_pkey)].name() else "rowid";
    return t.cols[@intCast(i)].name();
}

// ============================================================== the kinds

/// NOT NULL of column `c` of `t`.
pub fn notNull(p: *Parse, t: *Table, c: *const int.Column, is_update: bool) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const cols = p.arena.dupe([]const u8, &.{c.name()}) catch return oom(p);
    return violation(p, .{ .kind = .not_null, .op = if (is_update) .update else .insert, .database = database(p, t), .table = t.name, .columns = cols });
}

/// The CHECK constraint `name` of `t` (SQLite's name: an unnamed one's is
/// its text). A dialect's type check (Hooks.check_errors, named after
/// its message) is that message, in any dialect but SQLite's.
pub fn check(p: *Parse, t: *Table, name: ?[]const u8, is_update: bool) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    if (name) |n| if (dialect.checkState(n)) |st| return encode(p, .{ .msg = n, .state = st });
    const named: ?[]const u8 = if (name) |n| (if (Violation.unnamedCheck(n)) null else n) else null;
    return violation(p, .{ .kind = .check, .op = if (is_update) .update else .insert, .database = database(p, t), .table = t.name, .name = named });
}

/// A duplicate key of the UNIQUE or PRIMARY KEY index `idx` (`has_value`:
/// its values are in registers; else CREATE UNIQUE INDEX found it).
pub fn unique(p: *Parse, idx: *Index, has_value: bool) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const t = idx.table;
    const n: usize = idx.n_key_col;
    const cols = p.arena.alloc([]const u8, n) catch return oom(p);
    for (cols, 0..) |*c, i| c.* = if (idx.ai_column[i] == int.XN_EXPR) "expression" else columnName(t, idx.ai_column[i]);
    const kind: Violation.Kind = switch (idx.idx_type) {
        .appdef => .unique_index,
        .primarykey => .primary_key,
        else => .unique,
    };
    const name: ?[]const u8 = switch (kind) {
        .unique_index => idx.name,
        else => recordedName(p, t, kind, cols),
    };
    return violation(p, .{ .kind = kind, .op = if (has_value) .insert else .create_index, .database = database(p, t), .table = t.name, .columns = cols, .name = name, .has_value = has_value });
}

/// A duplicate rowid of `t`: its INTEGER PRIMARY KEY.
pub fn rowid(p: *Parse, t: *Table, has_value: bool) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const cols = p.arena.dupe([]const u8, &.{columnName(t, -1)}) catch return oom(p);
    return violation(p, .{ .kind = .primary_key, .op = .insert, .database = database(p, t), .table = t.name, .columns = cols, .name = recordedName(p, t, .primary_key, cols), .has_value = has_value });
}

/// Foreign key `fk` of a child row (`kind` foreign_key) or of a parent
/// row (referenced) of the parent table `parent`, whose key is `idx`
/// (null: its INTEGER PRIMARY KEY).
pub fn foreignKey(p: *Parse, kind: Violation.Kind, op: @FieldType(Violation, "op"), fk: *FKey, parent: *Table, idx: ?*Index) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const child = fk.from;
    const cols = p.arena.alloc([]const u8, fk.cols.len) catch return oom(p);
    const pcols = p.arena.alloc([]const u8, fk.cols.len) catch return oom(p);
    for (fk.cols, 0..) |c, i| {
        cols[i] = columnName(child, c.i_from);
        pcols[i] = if (idx) |ix| columnName(parent, ix.ai_column[i]) else if (c.col) |z| z else columnName(parent, -1);
    }
    var ordinal: u32 = 1;
    var it = fk.next_from;
    while (it) |x| : (it = x.next_from) ordinal += 1;
    return violation(p, .{
        .kind = kind,
        .op = op,
        .database = database(p, child),
        .table = child.name,
        .columns = cols,
        .name = recordedName(p, child, .foreign_key, cols),
        .parent = parent.name,
        .parent_columns = pcols,
        .ordinal = ordinal,
    });
}

/// A foreign key failure whose constraint is not known (DROP TABLE of a
/// parent table): Constraint.foreign_key.
pub fn foreignKeyUnknown(p: *Parse) ?[:0]const u8 {
    const c = hooksOf(p) orelse return null;
    return encode(p, c.foreign_key orelse return null);
}

fn oom(p: *Parse) ?[:0]const u8 {
    p.db.oomFault();
    return null;
}

// =================================================== the recorded names

/// The xq_catalog key of the name of a `kind` constraint on columns
/// `cols` (catalog.Key.constraint): "constraint:unique:a,b".
pub fn key(a: std.mem.Allocator, kind: Violation.Kind, cols: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, catalog.Key.constraint);
    try out.append(a, ':');
    try out.appendSlice(a, @tagName(kind));
    try out.append(a, ':');
    for (cols, 0..) |c, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, c);
    }
    return out.items;
}

/// The name the user gave the `kind` constraint of `t` on `cols`, as
/// CREATE TABLE recorded it (the catalog in memory, catalog.metaOf());
/// null if none.
fn recordedName(p: *Parse, t: *Table, kind: Violation.Kind, cols: []const []const u8) ?[]const u8 {
    const k = key(p.arena, kind, cols) catch return null;
    const m = (catalog.metaOf(p.db, t) catch return null) orelse return null;
    for (m.entries) |e| {
        // Copied: the catalog in memory may be dropped while compiling.
        if (e.col.len == 0 and ctype.eqlNoCase(e.key, k)) return p.arena.dupe(u8, e.value) catch null;
    }
    return null;
}

test decode {
    const d = decode("235051062\x1fDuplicate entry");
    try std.testing.expectEqualStrings("23505", &d.state.sqlstate);
    try std.testing.expectEqual(@as(u32, 1062), d.state.number);
    try std.testing.expectEqualStrings("Duplicate entry", d.msg);
    try std.testing.expect(Violation.unnamedCheck("a > 0"));
    try std.testing.expect(!Violation.unnamedCheck("t_a_check"));
}
