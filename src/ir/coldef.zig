//! The column definitions of a CREATE TABLE statement as SQLite keeps it
//! (sqlite_schema.sql), read with SQLite's tokenizer, for an ALTER TABLE
//! that changes a column in place (PostgreSQL's ALTER COLUMN ... SET
//! DEFAULT, SET DATA TYPE, its ADD CONSTRAINT): the text of the schema is
//! edited, as SQLite's own ALTER TABLE edits it (alter.zig:
//! sqlite_drop_constraint(), sqlite_add_constraint()), and read again.
//!
//!     CREATE TABLE "t"("a" INTEGER NOT NULL DEFAULT (0), "b" TEXT, CHECK(...)) STRICT
//!                      |name|type---|clause--|clause------|
//!
//! A column is its name, its type (the tokens up to the first
//! constraint) and its constraints ("clauses"), each from its first
//! keyword (CONSTRAINT name included) to the next one. Parentheses are
//! one token. Table constraints come after the columns and are no
//! columns.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const lexer = @import("../dialect/sqlite/lexer.zig");
const util = @import("../sql/util.zig");
const ctype = @import("xqlite_base").ctype;

const TK = int.TK;
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, Malformed };

/// A constraint of a column: [start, end) of its text, `lead` where the
/// white space before it starts, `kind` its first keyword after any
/// CONSTRAINT name (TK.NOT, TK.DEFAULT ...), `name` that name as written.
pub const Clause = struct {
    lead: usize,
    start: usize,
    end: usize,
    kind: u8,
    name: ?[]const u8 = null,

    /// The clause's name dequoted, "" if it has none.
    pub fn dequoted(c: Clause, a: Allocator) error{OutOfMemory}![]const u8 {
        const raw = c.name orelse return "";
        return util.dequote(try a.dupeSentinel(u8, raw, 0));
    }

    /// Whether the clause is named `n` (the name dequoted, without case).
    pub fn named(c: Clause, a: Allocator, n: []const u8) Error!bool {
        if (c.name == null) return false;
        return ctype.eqlNoCase(try c.dequoted(a), n);
    }
};

pub const Column = struct {
    start: usize,
    /// The end of the name; the type is [type_start, type_end), empty if
    /// there is none (type_start == type_end == name_end).
    name_end: usize,
    type_start: usize,
    type_end: usize,
    /// The end of the definition (its last token).
    end: usize,
    clauses: []const Clause,
};

pub const Table = struct {
    columns: []const Column,
    /// The table constraints (`lead` before the "," in front of each).
    constraints: []const Clause,
    /// Where the white space before the ")" that ends the definitions
    /// starts (a table constraint goes there).
    close: usize,
};

const Tok = struct { tk: u8, start: usize, end: usize };

/// The next token at or after `at` that is not white space or a comment;
/// a "(" extends to its ")" (TK.LP).
fn next(sql: [:0]const u8, at: usize) Tok {
    var off = at;
    while (true) {
        const s = lexer.getToken(sql, off);
        if (s.tk == TK.SPACE or s.tk == TK.COMMENT) {
            off += s.len;
            continue;
        }
        const start = off;
        off += s.len;
        if (s.tk == TK.LP) {
            var nest: usize = 1;
            while (nest > 0) {
                const x = lexer.getToken(sql, off);
                if (x.tk == TK.ILLEGAL) return .{ .tk = TK.ILLEGAL, .start = start, .end = off };
                off += x.len;
                if (x.tk == TK.LP) nest += 1;
                if (x.tk == TK.RP) nest -= 1;
            }
        }
        return .{ .tk = s.tk, .start = start, .end = off };
    }
}

/// Whether a column constraint starts with keyword `tk` (`after` the
/// token that follows it, for NOT NULL).
fn startsClause(tk: u8) bool {
    return switch (tk) {
        TK.CONSTRAINT, TK.PRIMARY, TK.NOT, TK.NULL, TK.UNIQUE, TK.CHECK, TK.DEFAULT, TK.COLLATE, TK.REFERENCES, TK.GENERATED, TK.AS => true,
        else => false,
    };
}

/// The columns of CREATE TABLE statement `sql`.
pub fn parse(a: Allocator, sql: [:0]const u8) Error!Table {
    // Past the first "(".
    var off: usize = 0;
    while (true) {
        const s = lexer.getToken(sql, off);
        if (s.tk == TK.ILLEGAL) return error.Malformed;
        off += s.len;
        if (s.tk == TK.LP) break;
    }
    var cols: std.ArrayList(Column) = .empty;
    var cons: std.ArrayList(Clause) = .empty;
    // The end of the item before (of its last token).
    var prev_end: usize = off;
    while (true) {
        var t = next(sql, off);
        const first = t;
        if (t.tk == TK.ILLEGAL) return error.Malformed;
        const table_constraint = switch (t.tk) {
            TK.CONSTRAINT, TK.PRIMARY, TK.UNIQUE, TK.CHECK, TK.FOREIGN => true,
            else => false,
        };
        if (table_constraint) {
            var c: Clause = .{ .lead = prev_end, .start = t.start, .end = t.end, .kind = t.tk };
            if (t.tk == TK.CONSTRAINT) {
                const n = next(sql, t.end);
                c.name = sql[n.start..n.end];
                c.kind = next(sql, n.end).tk;
            }
            // To the "," or ")" that ends it.
            var last_end = t.end;
            while (true) {
                t = next(sql, last_end);
                if (t.tk == TK.COMMA or t.tk == TK.RP or t.tk == TK.ILLEGAL) break;
                last_end = t.end;
            }
            if (t.tk == TK.ILLEGAL) return error.Malformed;
            c.end = last_end;
            try cons.append(a, c);
            prev_end = last_end;
            if (t.tk == TK.RP) return .{ .columns = cols.items, .constraints = cons.items, .close = last_end };
            off = t.end;
            continue;
        }
        var col: Column = .{ .start = first.start, .name_end = first.end, .type_start = first.end, .type_end = first.end, .end = first.end, .clauses = &.{} };
        var clauses: std.ArrayList(Clause) = .empty;
        // The type.
        var last_end = first.end;
        t = next(sql, last_end);
        if (!startsClause(t.tk) and t.tk != TK.COMMA and t.tk != TK.RP and t.tk != TK.ILLEGAL) {
            col.type_start = t.start;
            while (!startsClause(t.tk) and t.tk != TK.COMMA and t.tk != TK.RP and t.tk != TK.ILLEGAL) {
                last_end = t.end;
                t = next(sql, last_end);
            }
            col.type_end = last_end;
        }
        // The constraints.
        var cur: ?Clause = null;
        while (t.tk != TK.COMMA and t.tk != TK.RP and t.tk != TK.ILLEGAL) {
            var starts = startsClause(t.tk);
            if (cur) |c| {
                // NULL of NOT NULL, AS of GENERATED ALWAYS AS, the kind
                // after CONSTRAINT name.
                if (t.tk == TK.NULL and c.kind == TK.NOT and c.end == last_end and std.ascii.eqlIgnoreCase(sql[c.end - 3 .. c.end], "not")) starts = false;
                if (t.tk == TK.AS and c.kind == TK.GENERATED) starts = false;
            }
            // NOT of NOT DEFERRABLE (of a REFERENCES) is not NOT NULL.
            if (t.tk == TK.NOT and next(sql, t.end).tk != TK.NULL) starts = false;
            if (starts) {
                if (cur) |c| try clauses.append(a, c);
                var c: Clause = .{ .lead = last_end, .start = t.start, .end = t.end, .kind = t.tk };
                if (t.tk == TK.CONSTRAINT) {
                    const n = next(sql, t.end);
                    if (n.tk == TK.ILLEGAL) return error.Malformed;
                    c.name = sql[n.start..n.end];
                    c.end = n.end;
                    const k = next(sql, n.end);
                    if (startsClause(k.tk) and k.tk != TK.CONSTRAINT) {
                        c.kind = k.tk;
                        c.end = k.end;
                        t = k;
                    } else t = n;
                }
                cur = c;
            } else if (cur) |*c| {
                c.end = t.end;
            } else return error.Malformed;
            last_end = t.end;
            t = next(sql, last_end);
        }
        if (cur) |c| try clauses.append(a, c);
        if (t.tk == TK.ILLEGAL) return error.Malformed;
        col.end = last_end;
        col.clauses = clauses.items;
        try cols.append(a, col);
        prev_end = last_end;
        if (t.tk == TK.RP) return .{ .columns = cols.items, .constraints = cons.items, .close = last_end };
        off = t.end;
    }
}

/// A change of the text: [start, end) becomes `text`.
pub const Edit = struct { start: usize, end: usize, text: []const u8 };

/// `sql` with `edits` (which do not overlap) made.
pub fn apply(a: Allocator, sql: []const u8, edits: []Edit) Error![:0]u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lt(_: void, x: Edit, y: Edit) bool {
            return x.start < y.start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (edits) |e| {
        if (e.start < at) return error.Malformed;
        try out.appendSlice(a, sql[at..e.start]);
        try out.appendSlice(a, e.text);
        at = e.end;
    }
    try out.appendSlice(a, sql[at..]);
    return out.toOwnedSliceSentinel(a, 0);
}

/// The clause (of a column or the table) named `n`.
pub fn find(a: Allocator, t: Table, n: []const u8) Error!?Clause {
    for (t.columns) |col| for (col.clauses) |c| if (try c.named(a, n)) return c;
    for (t.constraints) |c| if (try c.named(a, n)) return c;
    return null;
}

/// The edit that removes clause `c` (and the white space before it; the
/// "," before a table constraint).
pub fn remove(c: Clause) Edit {
    return .{ .start = c.lead, .end = c.end, .text = "" };
}

test "coldef: columns and clauses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sql = "CREATE TABLE \"t\"(\"a\" INTEGER NOT NULL DEFAULT (0) CONSTRAINT \"integer out of range\" CHECK((\"a\" BETWEEN -1 AND 1)), \"b\" TEXT DEFAULT 'x' REFERENCES \"u\"(\"id\") NOT DEFERRABLE, c, CONSTRAINT \"t_check\" CHECK(a > 0)) STRICT";
    const t = try parse(a, sql);
    try std.testing.expectEqual(3, t.columns.len);
    const c0 = t.columns[0];
    try std.testing.expectEqualStrings("\"a\"", sql[c0.start..c0.name_end]);
    try std.testing.expectEqualStrings("INTEGER", sql[c0.type_start..c0.type_end]);
    try std.testing.expectEqual(3, c0.clauses.len);
    try std.testing.expectEqual(TK.NOT, c0.clauses[0].kind);
    try std.testing.expectEqualStrings("DEFAULT (0)", sql[c0.clauses[1].start..c0.clauses[1].end]);
    try std.testing.expectEqual(TK.CHECK, c0.clauses[2].kind);
    try std.testing.expect(try c0.clauses[2].named(a, "integer out of range"));
    const c1 = t.columns[1];
    try std.testing.expectEqual(2, c1.clauses.len);
    try std.testing.expectEqualStrings("REFERENCES \"u\"(\"id\") NOT DEFERRABLE", sql[c1.clauses[1].start..c1.clauses[1].end]);
    try std.testing.expectEqual(1, t.constraints.len);
    try std.testing.expect(try t.constraints[0].named(a, "t_check"));
    try std.testing.expectEqual(TK.CHECK, t.constraints[0].kind);
    const c2 = t.columns[2];
    try std.testing.expectEqual(c2.type_start, c2.type_end);
    try std.testing.expectEqual(0, c2.clauses.len);
    var edits = [_]Edit{ remove(c0.clauses[1]), .{ .start = c1.type_start, .end = c1.type_end, .text = "INTEGER" }, .{ .start = t.close, .end = t.close, .text = ", CHECK(1)" } };
    const out = try apply(a, sql, &edits);
    var drop = [_]Edit{remove(t.constraints[0])};
    try std.testing.expectEqualStrings("CREATE TABLE \"t\"(\"a\" INTEGER NOT NULL DEFAULT (0) CONSTRAINT \"integer out of range\" CHECK((\"a\" BETWEEN -1 AND 1)), \"b\" TEXT DEFAULT 'x' REFERENCES \"u\"(\"id\") NOT DEFERRABLE, c) STRICT", try apply(a, sql, &drop));
    try std.testing.expectEqualStrings("CREATE TABLE \"t\"(\"a\" INTEGER NOT NULL CONSTRAINT \"integer out of range\" CHECK((\"a\" BETWEEN -1 AND 1)), \"b\" INTEGER DEFAULT 'x' REFERENCES \"u\"(\"id\") NOT DEFERRABLE, c, CONSTRAINT \"t_check\" CHECK(a > 0), CHECK(1)) STRICT", out);
}
