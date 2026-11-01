//! What a statement does, from its text, for the reports the protocols
//! send when it completes: PostgreSQL's command tag (`INSERT 0 3`,
//! `UPDATE 2`, `CREATE TABLE`), MySQL's OK packet, TDS's DONE token.
//!
//! The leading keywords decide, after comments and a WITH clause: the
//! statement `WITH x AS (...) DELETE FROM t ...` is a DELETE. The scan
//! knows the quotes of every dialect ('...', "...", `...`, [...]) so that
//! a keyword inside a string or name is not taken for the statement's.
//! (Which rows a statement changes is the engine's to say:
//! Stmt.countsChanges().)

const std = @import("std");

pub const Verb = enum {
    select,
    insert,
    update,
    delete,
    merge,
    /// A VALUES statement (a query).
    values,
    create,
    drop,
    alter,
    truncate,
    begin,
    commit,
    rollback,
    savepoint,
    release,
    set,
    show,
    explain,
    pragma,
    attach,
    detach,
    vacuum,
    analyze,
    reindex,
    use,
    declare,
    execute,
    other,
};

pub const Command = struct {
    verb: Verb,
    /// For CREATE, DROP and ALTER, the kind of object, upper case and
    /// without modifiers (`CREATE UNIQUE INDEX` is "INDEX", `CREATE OR
    /// REPLACE VIEW` is "VIEW"); empty for another verb or a kind not
    /// known. Static.
    object: []const u8 = "",

    /// The words of the command upper case, as PostgreSQL's command tag
    /// has them ("CREATE TABLE", "SELECT"; START TRANSACTION is "BEGIN").
    pub fn format(c: *const Command, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var name: [16]u8 = undefined;
        try w.writeAll(std.ascii.upperString(&name, @tagName(c.verb)));
        if (c.object.len > 0) try w.print(" {s}", .{c.object});
    }
};

/// The verbs written otherwise than their name.
const aliases = std.StaticStringMap(Verb).initComptime(.{
    .{ "start", .begin },
    .{ "end", .commit },
    .{ "abort", .rollback },
    .{ "replace", .insert },
    .{ "upsert", .insert },
    .{ "exec", .execute },
    .{ "call", .execute },
    .{ "desc", .show },
    .{ "describe", .show },
    .{ "table", .select },
    .{ "save", .savepoint },
});

/// The words that may come between CREATE and the kind of object.
const modifiers = std.StaticStringMap(void).initComptime(.{
    .{"or"},        .{"replace"},     .{"temp"},         .{"temporary"},      .{"unique"},
    .{"global"},    .{"local"},       .{"unlogged"},     .{"virtual"},        .{"if"},
    .{"not"},       .{"exists"},      .{"definer"},      .{"algorithm"},      .{"public"},
    .{"private"},   .{"editionable"}, .{"force"},        .{"noneditionable"}, .{"noforce"},
    .{"recursive"}, .{"clustered"},   .{"nonclustered"},
});

/// The kinds of object by their (first) word, with the second word of
/// those of two.
const objects = std.StaticStringMap(struct { []const u8, []const u8 }).initComptime(.{
    .{ "table", .{ "TABLE", "" } },
    .{ "index", .{ "INDEX", "" } },
    .{ "view", .{ "VIEW", "" } },
    .{ "trigger", .{ "TRIGGER", "" } },
    .{ "schema", .{ "SCHEMA", "" } },
    .{ "database", .{ "DATABASE", "" } },
    .{ "sequence", .{ "SEQUENCE", "" } },
    .{ "function", .{ "FUNCTION", "" } },
    .{ "procedure", .{ "PROCEDURE", "" } },
    .{ "proc", .{ "PROCEDURE", "" } },
    .{ "type", .{ "TYPE", "" } },
    .{ "domain", .{ "DOMAIN", "" } },
    .{ "extension", .{ "EXTENSION", "" } },
    .{ "user", .{ "USER", "" } },
    .{ "role", .{ "ROLE", "" } },
    .{ "synonym", .{ "SYNONYM", "" } },
    .{ "package", .{ "PACKAGE", "" } },
    .{ "materialized", .{ "MATERIALIZED VIEW", "view" } },
    .{ "foreign", .{ "FOREIGN TABLE", "table" } },
});

/// The command of the statement `sql` (one statement: the text from its
/// first token; empty statements before it are skipped).
pub fn classify(sql: []const u8) Command {
    var s: Scanner = .{ .text = std.mem.trimStart(u8, sql, " \t\r\n;") };
    var buf: [16]u8 = undefined;
    const first = lower(&buf, s.word() orelse return .{ .verb = .other });
    if (std.mem.eql(u8, first, "with")) return .{ .verb = afterWith(&s) };
    const verb = aliases.get(first) orelse std.meta.stringToEnum(Verb, first) orelse return .{ .verb = .other };
    return switch (verb) {
        .create, .drop, .alter => .{ .verb = verb, .object = object(&s) },
        else => .{ .verb = verb },
    };
}

fn object(s: *Scanner) []const u8 {
    var buf: [16]u8 = undefined;
    var w = lower(&buf, s.word() orelse return "");
    while (modifiers.has(w)) w = lower(&buf, s.word() orelse return "");
    const kind, const second = objects.get(w) orelse return "";
    if (second.len > 0) {
        const w2 = s.word() orelse return "";
        if (!std.ascii.eqlIgnoreCase(w2, second)) return "";
    }
    return kind;
}

/// The verb of the statement after a WITH clause: the first keyword of a
/// statement outside the parentheses that follows the `)` closing a
/// common table expression.
fn afterWith(s: *Scanner) Verb {
    var after_paren = false;
    while (s.next()) |tok| {
        switch (tok) {
            .close => after_paren = true,
            .word => |w| {
                if (after_paren) {
                    for ([_]Verb{ .select, .insert, .update, .delete, .merge, .values }) |v| {
                        if (std.ascii.eqlIgnoreCase(w, @tagName(v))) return v;
                    }
                }
                after_paren = false;
            },
            else => after_paren = false,
        }
    }
    return .select;
}

/// `w` in lower case in `buf`; "" if longer than any keyword.
fn lower(buf: *[16]u8, w: []const u8) []const u8 {
    if (w.len > buf.len) return "";
    return std.ascii.lowerString(buf, w);
}

/// The tokens that matter: words at the top level, and the parentheses
/// that nest the rest (strings, quoted names and comments are skipped).
const Scanner = struct {
    text: []const u8,
    pos: usize = 0,
    depth: u32 = 0,

    const Token = union(enum) { word: []const u8, open, close, other };

    /// The next word outside parentheses, or null at the end (or at a
    /// token that is not a word).
    fn word(s: *Scanner) ?[]const u8 {
        return switch (s.next() orelse return null) {
            .word => |w| w,
            else => null,
        };
    }

    /// The next token at depth 0 (what is inside parentheses is skipped,
    /// the closing one returned as `.close`).
    fn next(s: *Scanner) ?Token {
        while (s.raw()) |t| {
            switch (t) {
                .open => s.depth += 1,
                .close => {
                    if (s.depth > 0) s.depth -= 1;
                    if (s.depth == 0) return .close;
                },
                else => if (s.depth == 0) return t,
            }
        }
        return null;
    }

    fn raw(s: *Scanner) ?Token {
        const z = s.text;
        while (s.pos < z.len) {
            const c = z[s.pos];
            if (std.ascii.isWhitespace(c)) {
                s.pos += 1;
            } else if (std.mem.startsWith(u8, z[s.pos..], "--")) {
                s.pos = std.mem.indexOfScalarPos(u8, z, s.pos, '\n') orelse z.len;
            } else if (std.mem.startsWith(u8, z[s.pos..], "/*")) {
                s.pos = if (std.mem.indexOfPos(u8, z, s.pos + 2, "*/")) |e| e + 2 else z.len;
            } else if (c == '\'' or c == '"' or c == '`' or c == '[') {
                const close: u8 = if (c == '[') ']' else c;
                var i = s.pos + 1;
                while (i < z.len) : (i += 1) {
                    if (z[i] != close) continue;
                    // A doubled quote stands for itself.
                    if (close != ']' and i + 1 < z.len and z[i + 1] == close) {
                        i += 1;
                        continue;
                    }
                    break;
                }
                s.pos = @min(i + 1, z.len);
                return .other;
            } else if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = s.pos;
                while (s.pos < z.len and (std.ascii.isAlphanumeric(z[s.pos]) or z[s.pos] == '_' or z[s.pos] == '$')) s.pos += 1;
                return .{ .word = z[start..s.pos] };
            } else {
                s.pos += 1;
                return switch (c) {
                    '(' => .open,
                    ')' => .close,
                    else => .other,
                };
            }
        }
        return null;
    }
};

test "classify" {
    const T = struct {
        fn expect(sql: []const u8, verb: Verb, obj: []const u8) !void {
            const c = classify(sql);
            try std.testing.expectEqual(verb, c.verb);
            try std.testing.expectEqualStrings(obj, c.object);
        }
    };
    try T.expect("select 1", .select, "");
    try T.expect("  ;; -- c\n /* x */ INSERT INTO t VALUES(1)", .insert, "");
    try T.expect("WITH a AS (SELECT 1), \"delete\" AS (VALUES(2)) DELETE FROM t", .delete, "");
    try T.expect("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT * FROM c", .select, "");
    try T.expect("with x as materialized (select 'update') update t set a = 1", .update, "");
    try T.expect("CREATE UNIQUE INDEX i ON t(a)", .create, "INDEX");
    try T.expect("create or replace view v as select 1", .create, "VIEW");
    try T.expect("CREATE TEMP TABLE IF NOT EXISTS t(a)", .create, "TABLE");
    try T.expect("CREATE MATERIALIZED VIEW m AS SELECT 1", .create, "MATERIALIZED VIEW");
    try T.expect("CREATE FROBNICATOR x", .create, "");
    try T.expect("DROP TABLE IF EXISTS t", .drop, "TABLE");
    try T.expect("ALTER TABLE t ADD c INT", .alter, "TABLE");
    try T.expect("START TRANSACTION", .begin, "");
    try T.expect("BEGIN TRAN", .begin, "");
    try T.expect("end", .commit, "");
    try T.expect("REPLACE INTO t VALUES(1)", .insert, "");
    try T.expect("EXEC sp_who", .execute, "");
    try T.expect("VALUES (1), (2)", .values, "");
    try T.expect("MERGE INTO t USING s ON (1=1) WHEN MATCHED THEN DELETE", .merge, "");
    try T.expect("", .other, "");
    try T.expect("frobnicate", .other, "");

    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try classify("create unique index i on t(a)").format(&w);
    try std.testing.expectEqualStrings("CREATE INDEX", w.buffered());
}
