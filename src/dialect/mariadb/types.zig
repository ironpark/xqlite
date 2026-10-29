//! MariaDB column types: the type model, its text (as SHOW COLUMNS
//! shows it, which is also what xq_catalog records as the declared
//! type), the SQLite storage type a column gets, and the value coercion
//! that INSERT and UPDATE apply to the values they store.
//!
//! How a MariaDB table is stored (see ddl.zig): a STRICT SQLite table
//! whose columns have the storage type of storageType() (INTEGER, REAL,
//! TEXT or BLOB), an explicit COLLATE on every TEXT column, CHECK
//! constraints for JSON; the MariaDB type is in xq_catalog
//! (catalog.Key.decl_type). Range and length limits are not schema
//! constraints: they depend on sql_mode, which is per session, so the
//! frontend wraps each value an INSERT or UPDATE stores in a call of
//! mariadb_coerce(value, type, column, flags, row) (coerceFunc), which
//! converts it to the column type the way MariaDB does and, for a value
//! that does not fit:
//!  - in strict mode (STRICT_TRANS_TABLES or STRICT_ALL_TABLES, and no
//!    IGNORE) fails the statement with MariaDB's message ("Out of range
//!    value for column 'c' at row 1", "Data too long for column ...");
//!  - else stores the clipped/truncated/zero value and records a warning
//!    (SHOW WARNINGS).
//! Writes from sqlite3 or the SQLite dialect see only the STRICT types.

const std = @import("std");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const state_mod = @import("state.zig");
const Quoted = @import("../dialect.zig").Quoted;

pub const Base = enum {
    tinyint,
    smallint,
    mediumint,
    int,
    bigint,
    bit,
    decimal,
    float,
    double,
    char,
    varchar,
    binary,
    varbinary,
    tinytext,
    text,
    mediumtext,
    longtext,
    tinyblob,
    blob,
    mediumblob,
    longblob,
    @"enum",
    set,
    date,
    datetime,
    timestamp,
    time,
    year,

    pub fn isInteger(b: Base) bool {
        return switch (b) {
            .tinyint, .smallint, .mediumint, .int, .bigint => true,
            else => false,
        };
    }

    pub fn isString(b: Base) bool {
        return switch (b) {
            .char, .varchar, .tinytext, .text, .mediumtext, .longtext, .@"enum", .set => true,
            else => false,
        };
    }

    pub fn isBinary(b: Base) bool {
        return switch (b) {
            .binary, .varbinary, .tinyblob, .blob, .mediumblob, .longblob => true,
            else => false,
        };
    }
};

pub const Type = struct {
    base: Base,
    unsigned: bool = false,
    zerofill: bool = false,
    /// Display width (integers), length (strings), precision (DECIMAL,
    /// FLOAT/DOUBLE(M,D)), fractional digits (DATETIME/TIME/TIMESTAMP).
    len: ?u32 = null,
    /// Scale (DECIMAL, FLOAT/DOUBLE(M,D)).
    scale: ?u32 = null,
    /// The members of an ENUM or SET.
    members: []const []const u8 = &.{},

    /// The range of an integer type.
    pub fn intRange(t: Type) struct { i64, i64 } {
        const bits: u6 = switch (t.base) {
            .tinyint => 8,
            .smallint => 16,
            .mediumint => 24,
            .int => 32,
            else => 63,
        };
        if (bits == 63) return if (t.unsigned) .{ 0, std.math.maxInt(i64) } else .{ std.math.minInt(i64), std.math.maxInt(i64) };
        const one: i64 = 1;
        if (t.unsigned) return .{ 0, (one << bits) - 1 };
        return .{ -(one << (bits - 1)), (one << (bits - 1)) - 1 };
    }

    fn defaultWidth(t: Type) u32 {
        return switch (t.base) {
            .tinyint => if (t.unsigned) 3 else 4,
            .smallint => if (t.unsigned) 5 else 6,
            .mediumint => if (t.unsigned) 8 else 9,
            .int => if (t.unsigned) 10 else 11,
            .bigint => 20,
            else => 0,
        };
    }

    /// The maximum length of a string or binary type: characters for
    /// CHAR/VARCHAR, bytes for the TEXT and BLOB types (MariaDB's limits).
    pub fn maxLen(t: Type) ?u64 {
        return switch (t.base) {
            .char, .binary => t.len orelse 1,
            .varchar, .varbinary => if (t.len) |n| n else null,
            .tinytext, .tinyblob => 255,
            .text, .blob => 65535,
            .mediumtext, .mediumblob => 16777215,
            .longtext, .longblob => 4294967295,
            else => null,
        };
    }

    /// The type as SHOW COLUMNS shows it: int(11), varchar(20),
    /// decimal(10,2), int(10) unsigned, enum('a','b') ...
    pub fn format(t: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(@tagName(t.base));
        switch (t.base) {
            .tinyint, .smallint, .mediumint, .int, .bigint => try w.print("({d})", .{t.len orelse t.defaultWidth()}),
            .bit => try w.print("({d})", .{t.len orelse 1}),
            .decimal => try w.print("({d},{d})", .{ t.len orelse 10, t.scale orelse 0 }),
            .float, .double => if (t.len) |m| {
                if (t.scale) |d| try w.print("({d},{d})", .{ m, d }) else try w.print("({d})", .{m});
            },
            .char, .binary => try w.print("({d})", .{t.len orelse 1}),
            .varchar, .varbinary => try w.print("({d})", .{t.len orelse 0}),
            .datetime, .timestamp, .time => if (t.len) |n| if (n > 0) try w.print("({d})", .{n}),
            .year => try w.writeAll("(4)"),
            .@"enum", .set => {
                try w.writeByte('(');
                for (t.members, 0..) |m, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.print("{f}", .{Quoted('\''){ .z = m }});
                }
                try w.writeByte(')');
            },
            else => {},
        }
        if (t.unsigned or t.zerofill) try w.writeAll(" unsigned");
        if (t.zerofill) try w.writeAll(" zerofill");
    }

    /// The type of the column in the STRICT SQLite table.
    pub fn storageType(t: Type) []const u8 {
        return switch (t.base) {
            .tinyint, .smallint, .mediumint, .int, .bigint, .bit, .year => "INTEGER",
            .decimal => if ((t.scale orelse 0) == 0 and (t.len orelse 10) <= 18) "INTEGER" else "REAL",
            .float, .double => "REAL",
            .binary, .varbinary, .tinyblob, .blob, .mediumblob, .longblob => "BLOB",
            else => "TEXT",
        };
    }

    /// Whether the column compares by the collation of the column (a
    /// character string); the other TEXT-stored types (dates, JSON) are
    /// BINARY.
    pub fn hasCollation(t: Type) bool {
        return t.base.isString();
    }
};

/// Parse the text format() produces (case-insensitive), with `a` for
/// the ENUM/SET members. Null if it is not a type.
pub fn parse(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?Type {
    var i: usize = 0;
    while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
    const base = baseByName(text[0..i]) orelse return null;
    var t: Type = .{ .base = base };
    if (i < text.len and text[i] == '(') {
        i += 1;
        if (base == .@"enum" or base == .set) {
            var members: std.ArrayList([]const u8) = .empty;
            while (i < text.len and text[i] == '\'') {
                i += 1;
                var m: std.ArrayList(u8) = .empty;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\'') {
                        if (i + 1 < text.len and text[i + 1] == '\'') {
                            try m.append(a, '\'');
                            i += 1;
                        } else break;
                    } else try m.append(a, text[i]);
                }
                i += 1;
                try members.append(a, m.items);
                if (i < text.len and text[i] == ',') i += 1;
            }
            t.members = members.items;
        } else {
            t.len = number(text, &i);
            if (i < text.len and text[i] == ',') {
                i += 1;
                t.scale = number(text, &i);
            }
        }
        if (i < text.len and text[i] == ')') i += 1;
    }
    var rest = std.mem.tokenizeScalar(u8, text[i..], ' ');
    while (rest.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "unsigned")) t.unsigned = true;
        if (std.ascii.eqlIgnoreCase(word, "zerofill")) t.zerofill = true;
    }
    return t;
}

fn number(text: []const u8, i: *usize) ?u32 {
    const start = i.*;
    var v: u32 = 0;
    while (i.* < text.len and std.ascii.isDigit(text[i.*])) : (i.* += 1) v = v *| 10 +| (text[i.*] - '0');
    return if (i.* == start) null else v;
}

pub fn baseByName(name: []const u8) ?Base {
    for (std.enums.values(Base)) |b| {
        if (std.ascii.eqlIgnoreCase(@tagName(b), name)) return b;
    }
    return null;
}

// ============================================================ coercion

/// Flags of xq_coerce():
///  - coerce_ignore: INSERT/UPDATE IGNORE (never strict);
///  - coerce_not_null: a NOT NULL column: NULL fails ("Column 'c' cannot
///    be null"), or with IGNORE, or in a multi-row INSERT outside strict
///    mode, is the type's implicit default (0, '', the zero date);
///  - coerce_multi_row: a row of a multi-row INSERT;
///  - coerce_missing: the NULL stands for a NOT NULL column without a
///    DEFAULT that the INSERT leaves out ("Field 'c' doesn't have a
///    default value" in strict mode, else the implicit default).
pub const coerce_ignore = 1;
pub const coerce_not_null = 2;
pub const coerce_multi_row = 4;
pub const coerce_missing = 8;

/// The position of the flags among the arguments of xq_coerce().
pub const coerce_flags_arg = 5;

/// xq_coerce(value, type, schema, table, column, flags, row): see the
/// file comment.
pub fn coerceFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const v = argv[0];
    const flags = api.valueInt64(argv[coerce_flags_arg]);
    const is_null = api.valueType(v) == vi.SQLITE_NULL;
    if (is_null and flags & coerce_not_null == 0) return api.resultNull(ctx);
    const db = api.contextDbHandle(ctx);
    const st = &db.xq.mariadb;
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const type_text = api.valueText(argv[1]) orelse return api.resultValue(ctx, v);
    const t = cachedType(ctx, type_text) orelse
        (parse(fba.allocator(), type_text) catch null) orelse return api.resultValue(ctx, v);
    var c: Coercion = .{
        .ctx = ctx,
        .st = st,
        .schema = api.valueText(argv[2]) orelse "main",
        .table = api.valueText(argv[3]) orelse "?",
        .col = api.valueText(argv[4]) orelse "?",
        .row = api.valueInt64(argv[6]),
        .strict = st.sql_mode.strict() and flags & coerce_ignore == 0,
        .mode = st.sql_mode,
    };
    if (is_null) {
        if (flags & coerce_missing != 0) {
            if (c.problem(1364, "Field '{s}' doesn't have a default value", .{c.col})) return;
            return implicitDefault(ctx, t);
        }
        const lenient = flags & coerce_ignore != 0 or (!c.strict and flags & coerce_multi_row != 0);
        if (!lenient) {
            var msg: [state_mod.Warning.msg_max + 32]u8 = undefined;
            return api.resultError(ctx, std.fmt.bufPrint(&msg, "Column '{s}' cannot be null", .{c.col}) catch "Column cannot be null");
        }
        st.warn(.warning, 1048, "Column '{s}' cannot be null", .{c.col});
        return implicitDefault(ctx, t);
    }
    c.run(t, v);
}

/// The type argument of xq_coerce() parsed, kept with the statement
/// (sqlite3_set_auxdata()) for the rows after the first: the frontend
/// passes a constant.
const ParsedType = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    t: ?Type,

    fn destroy(pt: *ParsedType) void {
        const gpa = pt.arena.child_allocator;
        pt.arena.deinit();
        gpa.destroy(pt);
    }
};

const type_arg = 1;

/// The type `text` (argument type_arg) parsed once per statement; null if
/// it is not a type or on OOM (then the caller parses it itself).
fn cachedType(ctx: *dfunc.Context, text: []const u8) ?Type {
    if (api.getAuxdataTyped(ctx, type_arg, ParsedType.destroy)) |pt| {
        if (std.mem.eql(u8, pt.text, text)) return pt.t;
    }
    const gpa = dfunc.gpa(ctx);
    const pt = gpa.create(ParsedType) catch return null;
    pt.arena = .init(gpa);
    const a = pt.arena.allocator();
    pt.text = a.dupe(u8, text) catch {
        pt.destroy();
        return null;
    };
    pt.t = parse(a, text) catch {
        pt.destroy();
        return null;
    };
    api.setAuxdataTyped(ctx, type_arg, ParsedType.destroy, pt);
    // Outside a statement (or on OOM) setAuxdata() has freed it.
    const kept = api.getAuxdataTyped(ctx, type_arg, ParsedType.destroy) orelse return null;
    return kept.t;
}

/// The value MariaDB stores for a NULL it cannot store (INSERT IGNORE
/// into a NOT NULL column).
fn implicitDefault(ctx: *dfunc.Context, t: Type) void {
    switch (t.base) {
        .tinyint, .smallint, .mediumint, .int, .bigint, .bit, .year, .decimal => api.resultInt64(ctx, 0),
        .float, .double => api.resultDouble(ctx, 0),
        .binary, .varbinary, .tinyblob, .blob, .mediumblob, .longblob => api.resultBlob(ctx, "", .static),
        .@"enum" => api.resultText(ctx, if (t.members.len > 0) t.members[0] else "", .transient),
        .date => api.resultText(ctx, "0000-00-00", .static),
        .datetime, .timestamp => api.resultText(ctx, "0000-00-00 00:00:00", .static),
        .time => api.resultText(ctx, "00:00:00", .static),
        else => api.resultText(ctx, "", .static),
    }
}

const Coercion = struct {
    ctx: *dfunc.Context,
    st: *state_mod.State,
    schema: []const u8,
    table: []const u8,
    col: []const u8,
    row: i64,
    strict: bool,
    mode: state_mod.SqlMode,
    failed: bool = false,

    /// A value that does not fit: the statement fails in strict mode
    /// (true: stop), else a warning is recorded and the caller stores the
    /// adjusted value.
    fn problem(c: *Coercion, code: u16, comptime fmt: []const u8, args: anytype) bool {
        if (c.strict) {
            var buf: [state_mod.Warning.msg_max + 64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
            api.resultError(c.ctx, msg);
            c.failed = true;
            return true;
        }
        c.st.warn(.warning, code, fmt, args);
        return false;
    }

    fn outOfRange(c: *Coercion) bool {
        return c.problem(1264, "Out of range value for column '{s}' at row {d}", .{ c.col, c.row });
    }

    fn truncated(c: *Coercion) bool {
        return c.problem(1265, "Data truncated for column '{s}' at row {d}", .{ c.col, c.row });
    }

    /// A string too long: MariaDB's error is "Data too long", its warning
    /// "Data truncated".
    fn tooLong(c: *Coercion) bool {
        if (c.strict) return c.problem(1406, "Data too long for column '{s}' at row {d}", .{ c.col, c.row });
        return c.truncated();
    }

    fn incorrect(c: *Coercion, what: []const u8, text: []const u8) bool {
        const shown = text[0..@min(text.len, 64)];
        return c.problem(1366, "Incorrect {s} value: '{s}' for column `{s}`.`{s}`.`{s}` at row {d}", .{ what, shown, c.schema, c.table, c.col, c.row });
    }

    /// A string that is no date: MariaDB's error is "Incorrect date
    /// value", its warning "Data truncated".
    fn badTemporal(c: *Coercion, what: []const u8, text: []const u8) bool {
        if (!c.strict) return c.truncated();
        const shown = text[0..@min(text.len, 64)];
        return c.problem(1292, "Incorrect {s} value: '{s}' for column `{s}`.`{s}`.`{s}` at row {d}", .{ what, shown, c.schema, c.table, c.col, c.row });
    }

    fn run(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        switch (t.base) {
            .tinyint, .smallint, .mediumint, .int, .bigint => c.integer(t, v),
            .bit => c.bit(t, v),
            .year => c.year(v),
            .decimal => c.decimal(t, v),
            .float, .double => c.float(t, v),
            .char, .varchar, .tinytext, .text, .mediumtext, .longtext => c.string(t, v),
            .binary, .varbinary, .tinyblob, .blob, .mediumblob, .longblob => c.binary(t, v),
            .@"enum" => c.enumValue(t, v),
            .set => c.setValue(t, v),
            .date, .datetime, .timestamp => c.datetime(t, v),
            .time => c.time(t, v),
        }
    }

    /// The value as a number: an integer, a float, or the numeric prefix
    /// of a text (null after the error of a failing statement).
    fn numeric(c: *Coercion, v: *dfunc.Mem, what: []const u8) ?Num {
        switch (api.valueType(v)) {
            vi.SQLITE_INTEGER => return .{ .int = api.valueInt64(v) },
            vi.SQLITE_FLOAT => return .{ .float = api.valueDouble(v) },
            else => {
                const z = api.valueText(v) orelse "";
                const r = parseNumber(z);
                if (r.len == 0) {
                    if (c.incorrect(what, z)) return null;
                    return .{ .int = 0 };
                }
                if (!r.clean) {
                    if (c.truncated()) return null;
                }
                return r.num;
            },
        }
    }

    fn integer(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        const n = c.numeric(v, "integer") orelse return;
        const lo, const hi = t.intRange();
        var x: i64 = undefined;
        var out = false;
        switch (n) {
            .int => |i| x = i,
            .float => |f| {
                const r = @round(f);
                if (std.math.isNan(r)) {
                    x = 0;
                    out = true;
                } else if (r >= 9.2233720368547758e18) {
                    x = std.math.maxInt(i64);
                    out = true;
                } else if (r < -9.2233720368547758e18) {
                    x = std.math.minInt(i64);
                    out = true;
                } else x = @intFromFloat(r);
            },
        }
        if (x < lo or x > hi) out = true;
        if (out) {
            if (c.outOfRange()) return;
            x = std.math.clamp(x, lo, hi);
        }
        api.resultInt64(c.ctx, x);
    }

    fn bit(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        const n = c.numeric(v, "integer") orelse return;
        const bits: u6 = @intCast(@min(t.len orelse 1, 63));
        const hi: i64 = (@as(i64, 1) << bits) - 1;
        var x: i64 = switch (n) {
            .int => |i| i,
            .float => |f| if (std.math.isNan(f)) -1 else @intFromFloat(std.math.clamp(@round(f), -9.2e18, 9.2e18)),
        };
        if (x < 0 or x > hi) {
            if (c.outOfRange()) return;
            x = if (x < 0) 0 else hi;
        }
        api.resultInt64(c.ctx, x);
    }

    fn year(c: *Coercion, v: *dfunc.Mem) void {
        const is_text = api.valueType(v) == vi.SQLITE_TEXT;
        const text_len = if (is_text) std.mem.trim(u8, api.valueText(v) orelse "", " ").len else 0;
        const n = c.numeric(v, "integer") orelse return;
        var x: i64 = switch (n) {
            .int => |i| i,
            .float => |f| if (std.math.isNan(f)) -1 else @intFromFloat(std.math.clamp(@round(f), -1e9, 1e9)),
        };
        // Two-digit years; '0' and '00' as text are 2000.
        if ((x > 0 and x < 70) or (x == 0 and is_text and text_len <= 2)) {
            x += 2000;
        } else if (x >= 70 and x < 100) x += 1900;
        if (x != 0 and (x < 1901 or x > 2155)) {
            if (c.outOfRange()) return;
            x = 0;
        }
        api.resultInt64(c.ctx, x);
    }

    fn decimal(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        const n = c.numeric(v, "decimal") orelse return;
        const prec = t.len orelse 10;
        const scale = t.scale orelse 0;
        var f: f64 = switch (n) {
            .int => |i| @floatFromInt(i),
            .float => |x| x,
        };
        const p10 = std.math.pow(f64, 10, @floatFromInt(scale));
        const hi = std.math.pow(f64, 10, @floatFromInt(prec - @min(prec, scale))) - 1 / p10;
        const lo = if (t.unsigned) 0 else -hi;
        // Integers are exact when the scale is 0.
        if (n == .int and scale == 0 and prec <= 18) {
            const i = n.int;
            const hi_i: i64 = @intFromFloat(hi);
            const lo_i: i64 = if (t.unsigned) 0 else -hi_i;
            if (i < lo_i or i > hi_i) {
                if (c.outOfRange()) return;
                return api.resultInt64(c.ctx, std.math.clamp(i, lo_i, hi_i));
            }
            return api.resultInt64(c.ctx, i);
        }
        f = @round(f * p10) / p10;
        if (std.math.isNan(f) or f > hi or f < lo) {
            if (c.outOfRange()) return;
            f = if (std.math.isNan(f)) 0 else std.math.clamp(f, lo, hi);
        }
        if (scale == 0 and prec <= 18) return api.resultInt64(c.ctx, @intFromFloat(f));
        api.resultDouble(c.ctx, f);
    }

    fn float(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        const n = c.numeric(v, "double") orelse return;
        var f: f64 = switch (n) {
            .int => |i| @floatFromInt(i),
            .float => |x| x,
        };
        if (t.base == .float) {
            const max: f64 = std.math.floatMax(f32);
            if (@abs(f) > max) {
                if (c.outOfRange()) return;
                f = std.math.clamp(f, -max, max);
            }
        }
        if (t.scale) |d| {
            const p10 = std.math.pow(f64, 10, @floatFromInt(d));
            f = @round(f * p10) / p10;
        }
        if (t.unsigned and f < 0) {
            if (c.outOfRange()) return;
            f = 0;
        }
        api.resultDouble(c.ctx, f);
    }

    fn string(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        var z: []const u8 = (if (api.valueType(v) == vi.SQLITE_BLOB) api.valueBlob(v) else api.valueText(v)) orelse "";
        const max = t.maxLen().?;
        const by_chars = t.base == .char or t.base == .varchar;
        const n = if (by_chars) dfunc.charCount(z) else z.len;
        if (n > max) {
            const cut = if (by_chars) dfunc.charOffset(z, max) else utf8Floor(z, max);
            const all_spaces = std.mem.trimEnd(u8, z[cut..], " ").len == 0;
            if (all_spaces) {
                c.st.warn(.note, 1265, "Data truncated for column '{s}' at row {d}", .{ c.col, c.row });
            } else if (c.tooLong()) return;
            z = z[0..cut];
        }
        // CHAR values lose their trailing spaces (PAD_CHAR_TO_FULL_LENGTH
        // is not supported).
        if (t.base == .char) z = std.mem.trimEnd(u8, z, " ");
        api.resultText(c.ctx, z, .transient);
    }

    fn binary(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        var z: []const u8 = (if (api.valueType(v) == vi.SQLITE_BLOB) api.valueBlob(v) else api.valueText(v)) orelse "";
        const max = t.maxLen().?;
        if (z.len > max) {
            if (c.tooLong()) return;
            z = z[0..@intCast(max)];
        }
        if (t.base == .binary and z.len < max) {
            // BINARY(n) is padded with zero bytes.
            var buf: [256]u8 = @splat(0);
            @memcpy(buf[0..z.len], z);
            return api.resultBlob(c.ctx, buf[0..@intCast(max)], .transient);
        }
        api.resultBlob(c.ctx, z, .transient);
    }

    fn enumValue(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        if (api.valueType(v) == vi.SQLITE_INTEGER) {
            const i = api.valueInt64(v);
            if (i >= 1 and i <= t.members.len) return api.resultText(c.ctx, t.members[@intCast(i - 1)], .transient);
        } else {
            const z = std.mem.trimEnd(u8, api.valueText(v) orelse "", " ");
            for (t.members) |m| {
                if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, m, " "), z)) return api.resultText(c.ctx, m, .transient);
            }
        }
        if (c.truncated()) return;
        api.resultText(c.ctx, "", .static);
    }

    fn setValue(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        var mask: u64 = 0;
        var bad = false;
        if (api.valueType(v) == vi.SQLITE_INTEGER) {
            const i = api.valueInt64(v);
            const all: u64 = if (t.members.len >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(t.members.len)) - 1;
            mask = @as(u64, @bitCast(i)) & all;
            bad = @as(u64, @bitCast(i)) & ~all != 0;
        } else {
            var it = std.mem.splitScalar(u8, api.valueText(v) orelse "", ',');
            while (it.next()) |item| {
                if (item.len == 0) continue;
                for (t.members, 0..) |m, k| {
                    if (std.ascii.eqlIgnoreCase(m, item)) {
                        mask |= @as(u64, 1) << @intCast(k);
                        break;
                    }
                } else bad = true;
            }
        }
        if (bad and c.truncated()) return;
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var first = true;
        for (t.members, 0..) |m, k| {
            if (mask & (@as(u64, 1) << @intCast(k)) == 0) continue;
            if (!first) w.writeByte(',') catch {};
            w.writeAll(m) catch {};
            first = false;
        }
        api.resultText(c.ctx, w.buffered(), .transient);
    }

    fn datetime(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        var text_buf: [32]u8 = undefined;
        const z: []const u8 = switch (api.valueType(v)) {
            vi.SQLITE_INTEGER => std.fmt.bufPrint(&text_buf, "{d}", .{api.valueInt64(v)}) catch "",
            vi.SQLITE_FLOAT => std.fmt.bufPrint(&text_buf, "{d}", .{@trunc(api.valueDouble(v))}) catch "",
            else => api.valueText(v) orelse "",
        };
        const what = switch (t.base) {
            .date => "date",
            else => "datetime",
        };
        var dt = parseDateTime(z) orelse {
            if (c.badTemporal(what, z)) return;
            return api.resultText(c.ctx, if (t.base == .date) "0000-00-00" else "0000-00-00 00:00:00", .static);
        };
        if (!c.validDate(dt)) {
            if (c.badTemporal(what, z)) return;
            dt = .{};
        }
        if (t.base == .date and dt.has_time and (dt.hour != 0 or dt.minute != 0 or dt.second != 0 or dt.micro != 0)) {
            c.st.warn(.note, 1265, "Data truncated for column '{s}' at row {d}", .{ c.col, c.row });
        }
        var buf: [40]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ dt.year, dt.month, dt.day }) catch {};
        if (t.base != .date) {
            w.print(" {d:0>2}:{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute, dt.second }) catch {};
            writeFraction(&w, dt.micro, t.len orelse 0);
        }
        api.resultText(c.ctx, w.buffered(), .transient);
    }

    /// The date checks of sql_mode: real calendar dates (unless
    /// ALLOW_INVALID_DATES), zero parts and the zero date (refused in
    /// strict mode with NO_ZERO_IN_DATE/NO_ZERO_DATE).
    fn validDate(c: *Coercion, dt: DateTime) bool {
        const zero_date = dt.year == 0 and dt.month == 0 and dt.day == 0;
        if (zero_date) {
            if (c.mode.has(.NO_ZERO_DATE)) {
                if (c.strict) return false;
                c.st.warn(.warning, 1265, "Data truncated for column '{s}' at row {d}", .{ c.col, c.row });
            }
            return true;
        }
        if (dt.month > 12 or dt.day > 31) return false;
        if (dt.month == 0 or dt.day == 0) return !(c.mode.has(.NO_ZERO_IN_DATE) and c.strict);
        if (c.mode.has(.ALLOW_INVALID_DATES)) return true;
        return dt.day <= daysInMonth(dt.year, dt.month);
    }

    fn time(c: *Coercion, t: Type, v: *dfunc.Mem) void {
        var text_buf: [32]u8 = undefined;
        const z: []const u8 = switch (api.valueType(v)) {
            vi.SQLITE_INTEGER => std.fmt.bufPrint(&text_buf, "{d}", .{api.valueInt64(v)}) catch "",
            vi.SQLITE_FLOAT => std.fmt.bufPrint(&text_buf, "{d}", .{api.valueDouble(v)}) catch "",
            else => api.valueText(v) orelse "",
        };
        var tm = parseTime(z) orelse {
            if (c.badTemporal("time", z)) return;
            return api.resultText(c.ctx, "00:00:00", .static);
        };
        if (tm.hours > 838 or (tm.hours == 838 and (tm.minute > 59 or tm.second > 59))) {
            if (c.outOfRange()) return;
            tm = .{ .neg = tm.neg, .hours = 838, .minute = 59, .second = 59 };
        }
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        if (tm.neg) w.writeByte('-') catch {};
        w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ tm.hours, tm.minute, tm.second }) catch {};
        writeFraction(&w, tm.micro, t.len orelse 0);
        api.resultText(c.ctx, w.buffered(), .transient);
    }
};

/// `micro` (microseconds) to `fsp` digits, truncated (MariaDB's default
/// without TIME_ROUND_FRACTIONAL).
fn writeFraction(w: *std.Io.Writer, micro: u32, fsp: u32) void {
    if (fsp == 0) return;
    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{micro}) catch return;
    w.writeByte('.') catch {};
    w.writeAll(digits[0..@min(fsp, 6)]) catch {};
}

pub const Num = union(enum) { int: i64, float: f64 };

pub const ParsedNumber = struct {
    num: Num,
    /// Characters of the numeric prefix (after leading spaces), 0 if none.
    len: usize,
    /// Nothing but spaces after it.
    clean: bool,
};

/// MariaDB's string-to-number conversion: leading spaces, a sign,
/// digits, a fraction, an exponent; the rest is garbage (`clean` false).
pub fn parseNumber(z_in: []const u8) ParsedNumber {
    const z = std.mem.trimStart(u8, z_in, " \t\n\r");
    var i: usize = 0;
    if (i < z.len and (z[i] == '+' or z[i] == '-')) i += 1;
    const digits_start = i;
    while (i < z.len and std.ascii.isDigit(z[i])) i += 1;
    var is_float = false;
    var n_digits = i - digits_start;
    if (i < z.len and z[i] == '.') {
        const frac_start = i + 1;
        var j = frac_start;
        while (j < z.len and std.ascii.isDigit(z[j])) j += 1;
        if (n_digits > 0 or j > frac_start) {
            n_digits += j - frac_start;
            is_float = true;
            i = j;
        }
    }
    if (n_digits == 0) return .{ .num = .{ .int = 0 }, .len = 0, .clean = false };
    if (i < z.len and (z[i] == 'e' or z[i] == 'E')) {
        var j = i + 1;
        if (j < z.len and (z[j] == '+' or z[j] == '-')) j += 1;
        if (j < z.len and std.ascii.isDigit(z[j])) {
            while (j < z.len and std.ascii.isDigit(z[j])) j += 1;
            is_float = true;
            i = j;
        }
    }
    const clean = std.mem.trim(u8, z[i..], " \t\n\r").len == 0;
    const text = z[0..i];
    if (!is_float) {
        if (std.fmt.parseInt(i64, text, 10)) |v| {
            return .{ .num = .{ .int = v }, .len = i, .clean = clean };
        } else |_| {}
    }
    const f = std.fmt.parseFloat(f64, text) catch 0;
    return .{ .num = .{ .float = f }, .len = i, .clean = clean };
}

/// At most `n` bytes of `z`, not cutting a character.
fn utf8Floor(z: []const u8, n: u64) usize {
    var i: usize = @intCast(@min(n, z.len));
    while (i > 0 and i < z.len and z[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

pub const DateTime = struct {
    year: u32 = 0,
    month: u32 = 0,
    day: u32 = 0,
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    micro: u32 = 0,
    has_time: bool = false,
};

pub fn daysInMonth(y: u32, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) 29 else 28,
        else => 0,
    };
}

/// MariaDB's date and datetime literals: 'YYYY-MM-DD[ hh:mm:ss[.f]]'
/// with any punctuation as delimiter and 'T' or spaces before the time,
/// two-digit years, and the delimiter-less 'YYYYMMDD[hhmmss]' and
/// 'YYMMDD[hhmmss]'. Null if it is none of these (the calendar checks
/// are the caller's).
pub fn parseDateTime(z_in: []const u8) ?DateTime {
    const z = std.mem.trim(u8, z_in, " ");
    if (z.len == 0) return null;
    var dt: DateTime = .{};
    var all_digits = true;
    for (z) |c| {
        if (!std.ascii.isDigit(c) and c != '.') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        const int_part = z[0 .. std.mem.indexOfScalar(u8, z, '.') orelse z.len];
        const d = int_part;
        switch (d.len) {
            8, 14 => {
                dt.year = digitsVal(d[0..4]);
                dt.month = digitsVal(d[4..6]);
                dt.day = digitsVal(d[6..8]);
                if (d.len == 14) {
                    dt.has_time = true;
                    dt.hour = digitsVal(d[8..10]);
                    dt.minute = digitsVal(d[10..12]);
                    dt.second = digitsVal(d[12..14]);
                }
            },
            5, 6, 12 => {
                const off: usize = if (d.len == 5) 0 else 1;
                const yy = if (d.len == 5) digitsVal(d[0..1]) else digitsVal(d[0..2]);
                dt.year = if (yy < 70) 2000 + yy else 1900 + yy;
                dt.month = digitsVal(d[1 + off .. 3 + off]);
                dt.day = digitsVal(d[3 + off .. 5 + off]);
                if (d.len == 12) {
                    dt.has_time = true;
                    dt.hour = digitsVal(d[6..8]);
                    dt.minute = digitsVal(d[8..10]);
                    dt.second = digitsVal(d[10..12]);
                }
            },
            1 => if (digitsVal(d) == 0) return dt else return null,
            else => return null,
        }
        if (dt.hour > 23 or dt.minute > 59 or dt.second > 59) return null;
        return dt;
    }
    // Delimited: up to 6 numeric parts and a fraction.
    var parts: [6]u32 = @splat(0);
    var widths: [6]usize = @splat(0);
    var n: usize = 0;
    var i: usize = 0;
    while (i < z.len and n < 6) {
        const start = i;
        while (i < z.len and std.ascii.isDigit(z[i])) i += 1;
        if (i == start) return null;
        parts[n] = digitsVal(z[start..i]);
        widths[n] = i - start;
        n += 1;
        if (i >= z.len) break;
        if (n == 6 and z[i] == '.') break;
        if (n == 3) {
            // Date/time separator: 'T' or spaces.
            if (z[i] == 'T' or z[i] == 't' or z[i] == ' ') {
                while (i < z.len and (z[i] == ' ' or z[i] == 'T' or z[i] == 't')) i += 1;
                continue;
            }
        }
        if (!std.ascii.isPunctuation(z[i])) return null;
        i += 1;
    }
    if (n < 3) return null;
    var micro: u32 = 0;
    if (i < z.len and z[i] == '.') {
        i += 1;
        var scale: u32 = 100000;
        while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) {
            micro += (z[i] - '0') * scale;
            scale /= 10;
        }
    }
    if (std.mem.trim(u8, z[i..], " ").len != 0) return null;
    dt.year = parts[0];
    if (widths[0] <= 2) dt.year = if (parts[0] < 70) 2000 + parts[0] else 1900 + parts[0];
    dt.month = parts[1];
    dt.day = parts[2];
    if (n > 3) {
        dt.has_time = true;
        dt.hour = parts[3];
        dt.minute = parts[4];
        dt.second = parts[5];
        dt.micro = micro;
    }
    if (dt.year > 9999 or dt.hour > 23 or dt.minute > 59 or dt.second > 59) return null;
    return dt;
}

fn digitsVal(d: []const u8) u32 {
    var v: u32 = 0;
    for (d) |c| v = v *| 10 +| (c - '0');
    return v;
}

pub const Time = struct {
    neg: bool = false,
    hours: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    micro: u32 = 0,
};

/// MariaDB's time literals: '[-][D ]hh:mm[:ss[.f]]', '[-]hhmmss[.f]',
/// 'ss', or a datetime (its time part).
pub fn parseTime(z_in: []const u8) ?Time {
    var z = std.mem.trim(u8, z_in, " ");
    if (z.len == 0) return null;
    var t: Time = .{};
    // A datetime: its time part.
    if (z.len >= 10 and std.mem.indexOfScalarPos(u8, z, 1, '-') != null) {
        const dt = parseDateTime(z) orelse return null;
        return .{ .hours = dt.hour, .minute = dt.minute, .second = dt.second, .micro = dt.micro };
    }
    if (z[0] == '-') {
        t.neg = true;
        z = z[1..];
    }
    if (std.mem.indexOfScalar(u8, z, ':') == null) {
        if (std.mem.indexOfAny(u8, z, "- ") != null) {
            const dt = parseDateTime(z) orelse return null;
            return .{ .hours = dt.hour, .minute = dt.minute, .second = dt.second, .micro = dt.micro };
        }
        // [hh[mm]]ss[.f]
        const dot = std.mem.indexOfScalar(u8, z, '.') orelse z.len;
        const d = z[0..dot];
        if (d.len == 0) return null;
        for (d) |c| if (!std.ascii.isDigit(c)) return null;
        const v = digitsVal(d);
        t.second = v % 100;
        t.minute = (v / 100) % 100;
        t.hours = v / 10000;
        t.micro = fraction(z[dot..]) orelse return null;
    } else {
        var days: u32 = 0;
        if (std.mem.indexOfScalar(u8, z, ' ')) |sp| {
            for (z[0..sp]) |c| if (!std.ascii.isDigit(c)) return null;
            days = digitsVal(z[0..sp]);
            z = std.mem.trimStart(u8, z[sp..], " ");
        }
        var parts: [3]u32 = @splat(0);
        var n: usize = 0;
        var i: usize = 0;
        while (n < 3) {
            const start = i;
            while (i < z.len and std.ascii.isDigit(z[i])) i += 1;
            if (i == start) return null;
            parts[n] = digitsVal(z[start..i]);
            n += 1;
            if (i < z.len and z[i] == ':') {
                i += 1;
            } else break;
        }
        t.hours = parts[0] + days * 24;
        t.minute = parts[1];
        t.second = parts[2];
        t.micro = fraction(z[i..]) orelse return null;
    }
    if (t.minute > 59 or t.second > 59) return null;
    return t;
}

fn fraction(z: []const u8) ?u32 {
    if (z.len == 0) return 0;
    if (z[0] != '.') return null;
    var micro: u32 = 0;
    var scale: u32 = 100000;
    for (z[1..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        micro += (c - '0') * scale;
        scale /= 10;
    }
    return micro;
}

test "types: format and parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{ "int(11)", "int(10) unsigned", "tinyint(1)", "decimal(10,2)", "varchar(20)", "enum('a','b''c')", "datetime(3)", "double", "year(4)", "bigint(20) unsigned zerofill" };
    for (cases) |text| {
        const t = (try parse(a, text)).?;
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try t.format(&w);
        try std.testing.expectEqualStrings(text, w.buffered());
    }
    const e = (try parse(a, "enum('a','b''c')")).?;
    try std.testing.expectEqualStrings("b'c", e.members[1]);
    try std.testing.expectEqual(@as(i64, -128), (Type{ .base = .tinyint }).intRange()[0]);
    try std.testing.expectEqual(@as(i64, 4294967295), (Type{ .base = .int, .unsigned = true }).intRange()[1]);
}

test "types: numbers, dates and times" {
    const r = parseNumber("  12abc");
    try std.testing.expect(r.num.int == 12 and !r.clean);
    try std.testing.expect(parseNumber("1.5e2 ").num.float == 150 and parseNumber("1.5e2 ").clean);
    try std.testing.expectEqual(@as(usize, 0), parseNumber("abc").len);
    const d = parseDateTime("2024-02-29 10:20:30.5").?;
    try std.testing.expect(d.year == 2024 and d.month == 2 and d.day == 29 and d.second == 30 and d.micro == 500000);
    try std.testing.expect(parseDateTime("20240101").?.day == 1);
    try std.testing.expect(parseDateTime("24/1/2").?.year == 2024);
    try std.testing.expect(parseDateTime("2024-01-01T01:02:03").?.hour == 1);
    try std.testing.expect(parseDateTime("hello") == null);
    try std.testing.expect(parseTime("-12:30").?.neg);
    try std.testing.expectEqual(@as(u32, 1), parseTime("10203").?.hours);
    try std.testing.expectEqual(@as(u32, 50), parseTime("2 02:00:00").?.hours);
}
