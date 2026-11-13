//! Failed constraints in the words of the dialect a statement is compiled
//! in (dialect.Constraint, Hooks.constraint).
//!
//! The message is decided when the statement is compiled, where the code
//! generator (insert.zig, build.zig, fkey.zig) codes the OP_Halt of a
//! constraint: the dialect's Constraint.message turns a Violation (the
//! table, the columns, the constraint's name) into its message and
//! ErrorState, which go into P4 (encode()) with HaltP5.dialect. The
//! program then only decodes it when the constraint fails, and the
//! values of the key or the row, in the registers the P4 lists, are
//! written at dialect.value_mark. In SQLite's dialect (and the engine's own SQL,
//! compiled in it) nothing changes: the program and its messages are
//! SQLite's.
//!
//! Foreign keys mostly fail when the statement ends (the counter of
//! OP_FkCounter is not zero): each OP_FkCounter that counts a violation
//! carries the message in P4, and the one that made the count not zero
//! is the error (Vdbe.xq_fk_error), as PostgreSQL reports the first row
//! that fails. A deferred one found at COMMIT, by another
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
const build = @import("../sql/build.zig");

const Parse = int.Parse;
const Table = int.Table;
const Index = int.Index;
const FKey = int.FKey;
const Violation = dialect.Violation;
const Failure = dialect.Failure;
const Type = @import("../sql/types.zig").Type;
const Logical = @import("../sql/types.zig").Logical;
const Reg = @import("../vdbe/operand.zig").Reg;

/// Between the ErrorState and the message in P4.
const unit_sep = '\x1f';

/// A value a message shows at dialect.value_mark: the register that holds
/// it while the program runs, and its type in the catalog (null: not
/// known), by which the dialect writes it (Constraint.value_text).
pub const Value = struct { reg: i32, type: ?Type = null };

/// The values of a message: of a key, or of the whole row (`row`: the
/// dialect may shorten each, as PostgreSQL's "Failing row contains").
pub const Values = struct { values: []const Value = &.{}, row: bool = false };

/// The P4 of a dialect's error: the SQLSTATE, the number, the offsets
/// of PostgreSQL's fields in the message if it has them (",detail,hint,
/// context"; ErrorState.fields), the values the message shows at
/// dialect.value_mark if it does (";r" for a row, then ";REG" or
/// ";REG:logical:scale:length:element" each), unit_sep, the message.
fn encode(p: *Parse, f: Failure, vals: Values) ?[:0]const u8 {
    return encodeAlloc(p.arena, f, vals) catch {
        p.db.oomFault();
        return null;
    };
}

fn encodeAlloc(a: std.mem.Allocator, f: Failure, vals: Values) error{OutOfMemory}![:0]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    const out = &w.writer;
    const at = f.state.fields;
    out.print("{s}{d}", .{ &f.state.sqlstate, f.state.number }) catch return error.OutOfMemory;
    if (at.any()) out.print(",{d},{d},{d}", .{ at.detail, at.hint, at.context }) catch return error.OutOfMemory;
    if (std.mem.indexOfScalar(u8, f.msg, dialect.value_mark) != null and vals.values.len > 0) {
        if (vals.row) out.writeAll(";r") catch return error.OutOfMemory;
        for (vals.values) |v| {
            out.print(";{d}", .{v.reg}) catch return error.OutOfMemory;
            if (v.type) |t| out.print(":{t}:{?d}:{?d}:{t}", .{ t.logical, t.scale, t.length, t.element }) catch return error.OutOfMemory;
        }
    }
    out.print("{c}{s}", .{ unit_sep, f.msg }) catch return error.OutOfMemory;
    return w.toOwnedSliceSentinel(0);
}

/// The P4 of an error whose values are written (render()), in `gpa`.
pub fn encodeError(gpa: std.mem.Allocator, state: int.ErrorState, msg: []const u8) error{OutOfMemory}![:0]u8 {
    return encodeAlloc(gpa, .{ .msg = msg, .state = state }, .{});
}

/// A P4 of encode().
pub const Decoded = struct {
    state: int.ErrorState,
    msg: []const u8,
    /// The values (Values) as encode() wrote them, without the first ";".
    values: []const u8 = "",

    /// The values the message shows (Values), in the order written.
    pub fn valueIterator(d: Decoded) ValueIterator {
        var it: ValueIterator = .{ .items = std.mem.splitScalar(u8, d.values, ';') };
        if (d.values.len == 0) it.items.index = null;
        if (std.mem.startsWith(u8, d.values, "r")) {
            it.row = true;
            _ = it.items.next();
        }
        return it;
    }
};

pub const ValueIterator = struct {
    items: std.mem.SplitIterator(u8, .scalar),
    row: bool = false,

    pub fn next(it: *ValueIterator) ?Value {
        const item = it.items.next() orelse return null;
        var parts = std.mem.splitScalar(u8, item, ':');
        const reg = std.fmt.parseInt(i32, parts.next().?, 10) catch return .{ .reg = 0 };
        const logical = std.meta.stringToEnum(Logical, parts.next() orelse return .{ .reg = reg }) orelse return .{ .reg = reg };
        const scale = std.fmt.parseInt(u8, parts.next() orelse "", 10) catch null;
        const length = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch null;
        const element = std.meta.stringToEnum(Logical, parts.next() orelse "") orelse .unknown;
        return .{ .reg = reg, .type = .{ .logical = logical, .scale = scale, .length = length, .element = element } };
    }
};

pub fn decode(z: []const u8) Decoded {
    const sep = std.mem.indexOfScalar(u8, z, unit_sep) orelse return .{ .state = .of("23000"), .msg = z };
    if (sep < 5) return .{ .state = .of("23000"), .msg = z[sep + 1 ..] };
    const head = z[5..sep];
    const semi = std.mem.indexOfScalar(u8, head, ';') orelse head.len;
    var nums = std.mem.splitScalar(u8, head[0..semi], ',');
    var n: [4]u32 = .{ 0, 0, 0, 0 };
    for (&n) |*x| x.* = std.fmt.parseInt(u32, nums.next() orelse break, 10) catch 0;
    return .{
        .state = .{ .sqlstate = z[0..5].*, .number = n[0], .fields = .{ .detail = n[1], .hint = n[2], .context = n[3] } },
        .msg = z[sep + 1 ..],
        .values = if (semi < head.len) head[semi + 1 ..] else "",
    };
}

test "decode: offsets of the fields and the values" {
    const d = decode("235050,9,0,0\x1fduplicate\nDETAIL:  Key");
    try std.testing.expectEqualStrings("23505", &d.state.sqlstate);
    try std.testing.expectEqual(@as(u32, 9), d.state.fields.detail);
    try std.testing.expectEqualStrings("duplicate\nDETAIL:  Key", d.msg);
    const e = decode("2350142\x1fx");
    try std.testing.expectEqual(@as(u32, 42), e.state.number);
    try std.testing.expect(!e.state.fields.any());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const z = try encodeAlloc(arena.allocator(), .{ .msg = "m\x01", .state = .of("23514") }, .{ .row = true, .values = &.{ .{ .reg = 3, .type = .{ .logical = .numeric, .scale = 2 } }, .{ .reg = 4 } } });
    try std.testing.expectEqualStrings("235140;r;3:numeric:2:null:unknown;4\x1fm\x01", z);
    var it = decode(z).valueIterator();
    try std.testing.expect(it.row);
    const v = it.next().?;
    try std.testing.expectEqual(@as(i32, 3), v.reg);
    try std.testing.expectEqual(Logical.numeric, v.type.?.logical);
    try std.testing.expectEqual(@as(?u8, 2), v.type.?.scale);
    try std.testing.expectEqual(@as(?i32, 4), if (it.next()) |w| w.reg else null);
    try std.testing.expect(it.next() == null);
}

/// The error of P4 `d` of a failed constraint as the program says it:
/// the values at dialect.value_mark, from the registers the P4 lists
/// (`regs.reg()`), written as the dialect `dia` shows them
/// (Constraint.value_text). A value the dialect does not write leaves
/// out the field of the message (a DETAIL) that would show it. The text
/// is in `gpa`, the caller's.
pub fn render(gpa: std.mem.Allocator, dia: dialect.Dialect, d: Decoded, regs: anytype) error{OutOfMemory}!struct { [:0]u8, int.ErrorState } {
    const mem = @import("../vdbe/mem.zig");
    const ENC = @import("../vdbe/vdbe_int.zig").ENC;
    const mark = std.mem.indexOfScalar(u8, d.msg, dialect.value_mark) orelse return .{ try gpa.dupeSentinel(u8, d.msg, 0), d.state };
    const c = &dialect.spec(dia).hooks.constraint;
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    const out = &w.writer;
    out.writeAll(d.msg[0..mark]) catch return error.OutOfMemory;
    const util = @import("../sql/util.zig");
    var f = util.splitFields(d.msg, d.state.fields);
    // A value the dialect does not write leaves out the field it is in;
    // in the message itself, it is SQLite's text.
    const in_field = d.state.fields.any() and mark >= f.message.len;
    var shown = true;
    var it = d.valueIterator();
    var i: usize = 0;
    while (it.next()) |v| : (i += 1) {
        if (i > 0) out.writeAll(c.value_separator) catch return error.OutOfMemory;
        const m = regs.reg(.from(v.reg));
        if (c.value_text) |text_of| {
            if (text_of(gpa, out, v.type, m, it.row) catch return error.OutOfMemory) continue;
            if (in_field) {
                shown = false;
                break;
            }
        }
        if (m.flags.Null) {
            out.writeAll("NULL") catch return error.OutOfMemory;
        } else {
            const z = try mem.valueText(m, ENC.UTF8);
            out.writeAll(if (z) |s| std.mem.span(s) else "") catch return error.OutOfMemory;
        }
    }
    out.writeAll(d.msg[mark + 1 ..]) catch return error.OutOfMemory;
    const delta = @as(isize, @intCast(w.written().len)) - @as(isize, @intCast(d.msg.len));
    if (shown) return .{ try w.toOwnedSliceSentinel(0), d.state.withFields(d.state.fields.moved(mark + 1, delta)) };
    // Without the field that shows the values.
    const at = d.state.fields;
    // The last field that starts before the mark.
    if (at.context != 0 and mark > at.context) f.context = null else if (at.hint != 0 and mark > at.hint) f.hint = null else f.detail = null;
    const text, const st = try util.joinFields(gpa, d.state, f);
    return .{ text, st };
}

/// The Constraint hooks of the dialect `p` compiles in, if it words its
/// constraint errors.
fn hooksOf(p: *Parse) ?*const dialect.Constraint {
    const c = &dialect.hooks(p.db).constraint;
    if (c.message == null) return null;
    return c;
}

/// The P4 of the error of `v` in the dialect `p` compiles in; null if it
/// keeps SQLite's. The message may show the values `vals`: of a key
/// (Violation.has_value) or of the row (Violation.has_row).
fn violation(p: *Parse, v: Violation, vals: Values) ?[:0]const u8 {
    const c = hooksOf(p) orelse return null;
    var with = v;
    with.has_value = vals.values.len > 0 and !vals.row;
    with.has_row = vals.values.len > 0 and vals.row;
    const f = c.message.?(p.arena, with) catch {
        p.db.oomFault();
        return null;
    };
    return encode(p, f, vals);
}

/// The values of the row of `t` in the registers from `reg_new` (its
/// rowid, then its columns: a STORED generated column's computed before
/// the constraints are checked), with their types; none for a table with
/// VIRTUAL columns (which PostgreSQL may not show), or for a dialect
/// that writes no values of its own (Constraint.value_text), whose
/// messages show no row.
fn rowValues(p: *Parse, t: *Table, reg_new: Reg) Values {
    if (reg_new.isNone() or t.tab_flags.HasVirtual or hooksOf(p).?.value_text == null) return .{};
    const m = tableMeta(p, t);
    const vals = p.arena.alloc(Value, t.cols.len) catch return .{};
    for (vals, t.cols, 0..) |*v, *c, i| v.* = .{
        .reg = build.columnRegister(t, reg_new, @intCast(i)).int(),
        .type = columnType(m, c.name()),
    };
    return .{ .values = vals, .row = true };
}

/// The values of the columns `i_cols` of `t` (-1: the rowid, XN_EXPR: an
/// expression) in the registers from `reg` (if any), with their types.
fn keyValues(p: *Parse, t: *Table, i_cols: []const i16, reg: Reg) Values {
    if (reg.isNone()) return .{};
    const m = if (hooksOf(p).?.value_text != null) tableMeta(p, t) else null;
    const vals = p.arena.alloc(Value, i_cols.len) catch return .{};
    for (vals, i_cols, 0..) |*v, i_col, i| v.* = .{
        .reg = reg.at(i).int(),
        .type = if (i_col == int.XN_EXPR) null else columnType(m, columnName(t, i_col)),
    };
    return .{ .values = vals };
}

/// What the catalog says of `t`, if it is known; for the types of the
/// values a dialect writes (Constraint.value_text).
fn tableMeta(p: *Parse, t: *Table) ?*const catalog.TableMeta {
    return catalog.metaOf(p.db, t) catch null;
}

/// The type of column `name` in the catalog `m`.
/// By name: the catalog's columns are in the order of its keys.
fn columnType(m: ?*const catalog.TableMeta, name: []const u8) ?Type {
    const c = (m orelse return null).column(name) orelse return null;
    return c.type;
}

fn database(p: *Parse, t: *const Table) []const u8 {
    return catalog.schemaName(p.db, t);
}

fn columnName(t: *const Table, i: i32) []const u8 {
    if (i < 0) return if (t.i_pkey >= 0) t.cols[@intCast(t.i_pkey)].name() else "rowid";
    return t.cols[@intCast(i)].name();
}

// ============================================================== the kinds

/// NOT NULL of column `c` of `t`, whose new row is in the registers from
/// `reg_new` (its rowid, then its columns; none: not known).
pub fn notNull(p: *Parse, t: *Table, c: *const int.Column, is_update: bool, reg_new: Reg) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const cols = p.arena.dupe([]const u8, &.{c.name()}) catch return oom(p);
    return violation(p, .{ .kind = .not_null, .op = if (is_update) .update else .insert, .database = database(p, t), .table = t.name, .columns = cols }, rowValues(p, t, reg_new));
}

/// The CHECK constraint `name` of `t` (SQLite's name: an unnamed one's is
/// its text). A dialect's type check (Hooks.check_errors, named after
/// its message) is that message, in any dialect but SQLite's.
/// The new row is in the registers from `reg_new`, as notNull()'s.
pub fn check(p: *Parse, t: *Table, name: ?[]const u8, is_update: bool, reg_new: Reg) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    if (name) |n| if (dialect.checkState(n)) |st| return encode(p, .{ .msg = n, .state = st }, .{});
    const named: ?[]const u8 = if (name) |n| (if (Violation.unnamedCheck(n)) null else n) else null;
    return violation(p, .{ .kind = .check, .op = if (is_update) .update else .insert, .database = database(p, t), .table = t.name, .name = named }, rowValues(p, t, reg_new));
}

/// A duplicate key of the UNIQUE or PRIMARY KEY index `idx`, its values
/// in the registers from `reg_key` (none: CREATE UNIQUE INDEX found it).
pub fn unique(p: *Parse, idx: *Index, reg_key: Reg) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const t = idx.table;
    const i_cols = idx.ai_column[0..idx.n_key_col];
    const cols = p.arena.alloc([]const u8, i_cols.len) catch return oom(p);
    for (cols, i_cols) |*c, i_col| c.* = if (i_col == int.XN_EXPR) "expression" else columnName(t, i_col);
    const kind: Violation.Kind = switch (idx.idx_type) {
        .appdef => .unique_index,
        .primarykey => .primary_key,
        else => .unique,
    };
    const name: ?[]const u8 = switch (kind) {
        .unique_index => idx.name,
        else => recordedName(p, t, kind, cols),
    };
    return violation(p, .{ .kind = kind, .op = if (!reg_key.isNone()) .insert else .create_index, .database = database(p, t), .table = t.name, .columns = cols, .name = name }, keyValues(p, t, i_cols, reg_key));
}

/// A duplicate rowid of `t`: its INTEGER PRIMARY KEY, in register
/// `reg_rowid` (none: not in a register).
pub fn rowid(p: *Parse, t: *Table, reg_rowid: Reg) ?[:0]const u8 {
    if (hooksOf(p) == null) return null;
    const cols = p.arena.dupe([]const u8, &.{columnName(t, -1)}) catch return oom(p);
    return violation(p, .{ .kind = .primary_key, .op = .insert, .database = database(p, t), .table = t.name, .columns = cols, .name = recordedName(p, t, .primary_key, cols) }, keyValues(p, t, &.{-1}, reg_rowid));
}

/// Foreign key `fk` of a child row (`kind` foreign_key) or of a parent
/// row (referenced) of the parent table `parent`, whose key is `idx`
/// (null: its INTEGER PRIMARY KEY). The row is in the registers from
/// `reg_data` (its rowid, then its columns; none: not known); `ai_col` maps
/// the parent key's columns to the child's (fkey.zig's aiCol; null: the
/// one column of the foreign key).
pub fn foreignKey(p: *Parse, kind: Violation.Kind, op: @FieldType(Violation, "op"), fk: *FKey, parent: *Table, idx: ?*Index, reg_data: Reg, ai_col: ?[]const i32) ?[:0]const u8 {
    const hk = hooksOf(p) orelse return null;
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
    // The key's values: the child's columns, or the parent's key.
    var vals: Values = .{};
    if (!reg_data.isNone()) {
        const values = p.arena.alloc(Value, fk.cols.len) catch return oom(p);
        const t, const names = if (kind == .foreign_key) .{ child, cols } else .{ parent, pcols };
        const m = if (hk.value_text != null) tableMeta(p, t) else null;
        for (values, names, 0..) |*v, n, i| {
            const i_col: i32 = if (kind == .foreign_key)
                (if (ai_col) |a| a[i] else fk.cols[0].i_from)
            else if (idx) |ix| ix.ai_column[i] else -1;
            v.* = .{ .reg = build.columnRegister(t, reg_data, @intCast(i_col)).int(), .type = columnType(m, n) };
        }
        vals = .{ .values = values };
    }
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
    }, vals);
}

/// A foreign key failure whose constraint is not known (DROP TABLE of a
/// parent table): Constraint.foreign_key.
pub fn foreignKeyUnknown(p: *Parse) ?[:0]const u8 {
    const c = hooksOf(p) orelse return null;
    return encode(p, c.foreign_key orelse return null, .{});
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
