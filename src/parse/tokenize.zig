//! The SQL tokenizer (port of tokenize.c and the keyword lookup generated
//! by mkkeywordhash). Input is NUL-terminated, as in C: the scanner may
//! look one byte past a token.

const std = @import("std");
const grammar = @import("grammar.zig");
const ctype = @import("xqlite_base").ctype;

const TK = grammar.TK;

/// Character classes (CC_*), the first switch of getToken().
const CC = enum(u8) {
    x = 0,
    kywd0 = 1,
    kywd = 2,
    digit = 3,
    dollar = 4,
    varalpha = 5,
    varnum = 6,
    space = 7,
    quote = 8,
    quote2 = 9,
    pipe = 10,
    minus = 11,
    lt = 12,
    gt = 13,
    eq = 14,
    bang = 15,
    slash = 16,
    lp = 17,
    rp = 18,
    semi = 19,
    plus = 20,
    star = 21,
    percent = 22,
    comma = 23,
    @"and" = 24,
    tilda = 25,
    dot = 26,
    id = 27,
    illegal = 28,
    nul = 29,
    bom = 30,
};

const ai_class: [256]u8 = .{
    29, 28, 28, 28, 28, 28, 28, 28, 28, 7,  7,  28, 7,  7,  28, 28,
    28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    7,  15, 8,  5,  4,  22, 24, 8,  17, 18, 21, 20, 23, 11, 26, 16,
    3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  5,  19, 12, 14, 13, 6,
    5,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
    1,  1,  1,  1,  1,  1,  1,  1,  0,  2,  2,  9,  28, 28, 28, 2,
    8,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
    1,  1,  1,  1,  1,  1,  1,  1,  0,  2,  2,  28, 10, 28, 25, 28,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 30,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
};

fn class(c: u8) CC {
    return @fromBackingInt(@intCast(ai_class[c]));
}

/// SQLITE_DIGIT_SEPARATOR.
const digit_separator = '_';

/// The longest keyword (CURRENT_TIMESTAMP).
const max_keyword_len = 17;

const keyword_map = blk: {
    var kvs: [grammar.keywords.len]struct { []const u8, u8 } = undefined;
    for (grammar.keywords, 0..) |k, i| kvs[i] = .{ k.name, k.code };
    break :blk std.StaticStringMap(u8).initComptime(kvs);
};

/// Port of keywordCode(): the token code of keyword `z`, or TK_ID.
/// Keywords are matched ignoring the case of letters.
pub fn keywordCode(z: []const u8) u8 {
    if (z.len < 2 or z.len > max_keyword_len) return TK.ID;
    var buf: [max_keyword_len]u8 = undefined;
    // The C code compares (c & ~0x20) with the upper-case keyword.
    for (z, 0..) |c, i| buf[i] = c & ~@as(u8, 0x20);
    return keyword_map.get(buf[0..z.len]) orelse TK.ID;
}

/// A token: its code and length in bytes.
pub const Scanned = struct { tk: u8, len: usize };

/// Port of sqlite3GetToken(): the token starting at `z`.
pub fn getToken(z: [*:0]const u8) Scanned {
    var i: usize = undefined;
    switch (class(z[0])) {
        .space => {
            i = 1;
            while (ctype.isSpace(z[i])) i += 1;
            return .{ .tk = TK.SPACE, .len = i };
        },
        .minus => {
            if (z[1] == '-') {
                i = 2;
                while (z[i] != 0 and z[i] != '\n') i += 1;
                return .{ .tk = TK.COMMENT, .len = i };
            } else if (z[1] == '>') {
                return .{ .tk = TK.PTR, .len = 2 + @as(usize, @intFromBool(z[2] == '>')) };
            }
            return .{ .tk = TK.MINUS, .len = 1 };
        },
        .lp => return .{ .tk = TK.LP, .len = 1 },
        .rp => return .{ .tk = TK.RP, .len = 1 },
        .semi => return .{ .tk = TK.SEMI, .len = 1 },
        .plus => return .{ .tk = TK.PLUS, .len = 1 },
        .star => return .{ .tk = TK.STAR, .len = 1 },
        .slash => {
            if (z[1] != '*' or z[2] == 0) return .{ .tk = TK.SLASH, .len = 1 };
            i = 3;
            var c = z[2];
            while ((c != '*' or z[i] != '/')) : (i += 1) {
                c = z[i];
                if (c == 0) break;
            }
            if (c != 0) i += 1;
            return .{ .tk = TK.COMMENT, .len = i };
        },
        .percent => return .{ .tk = TK.REM, .len = 1 },
        .eq => return .{ .tk = TK.EQ, .len = 1 + @as(usize, @intFromBool(z[1] == '=')) },
        .lt => return switch (z[1]) {
            '=' => .{ .tk = TK.LE, .len = 2 },
            '>' => .{ .tk = TK.NE, .len = 2 },
            '<' => .{ .tk = TK.LSHIFT, .len = 2 },
            else => .{ .tk = TK.LT, .len = 1 },
        },
        .gt => return switch (z[1]) {
            '=' => .{ .tk = TK.GE, .len = 2 },
            '>' => .{ .tk = TK.RSHIFT, .len = 2 },
            else => .{ .tk = TK.GT, .len = 1 },
        },
        .bang => {
            if (z[1] != '=') return .{ .tk = TK.ILLEGAL, .len = 1 };
            return .{ .tk = TK.NE, .len = 2 };
        },
        .pipe => {
            if (z[1] != '|') return .{ .tk = TK.BITOR, .len = 1 };
            return .{ .tk = TK.CONCAT, .len = 2 };
        },
        .comma => return .{ .tk = TK.COMMA, .len = 1 },
        .@"and" => return .{ .tk = TK.BITAND, .len = 1 },
        .tilda => return .{ .tk = TK.BITNOT, .len = 1 },
        .quote => {
            const delim = z[0];
            i = 1;
            var c: u8 = 0;
            while (true) : (i += 1) {
                c = z[i];
                if (c == 0) break;
                if (c == delim) {
                    if (z[i + 1] == delim) {
                        i += 1;
                    } else {
                        break;
                    }
                }
            }
            if (c == '\'') return .{ .tk = TK.STRING, .len = i + 1 };
            if (c != 0) return .{ .tk = TK.ID, .len = i + 1 };
            return .{ .tk = TK.ILLEGAL, .len = i };
        },
        .dot, .digit => |cc| {
            if (cc == .dot and !ctype.isDigit(z[1])) return .{ .tk = TK.DOT, .len = 1 };
            return scanNumber(z);
        },
        .quote2 => {
            i = 1;
            var c = z[0];
            while (c != ']') : (i += 1) {
                c = z[i];
                if (c == 0) break;
            }
            return .{ .tk = if (c == ']') TK.ID else TK.ILLEGAL, .len = i };
        },
        .varnum => {
            i = 1;
            while (ctype.isDigit(z[i])) i += 1;
            return .{ .tk = TK.VARIABLE, .len = i };
        },
        .dollar, .varalpha => {
            var tk: u8 = TK.VARIABLE;
            var n: usize = 0;
            i = 1;
            while (true) : (i += 1) {
                const c = z[i];
                if (c == 0) break;
                if (ctype.isIdChar(c)) {
                    n += 1;
                } else if (c == '(' and n > 0) {
                    // Tcl array element: $name(index).
                    while (true) {
                        i += 1;
                        const d = z[i];
                        if (d == 0 or ctype.isSpace(d) or d == ')') break;
                    }
                    if (z[i] == ')') {
                        i += 1;
                    } else {
                        tk = TK.ILLEGAL;
                    }
                    break;
                } else if (c == ':' and z[i + 1] == ':') {
                    i += 1;
                } else {
                    break;
                }
            }
            if (n == 0) tk = TK.ILLEGAL;
            return .{ .tk = tk, .len = i };
        },
        .kywd0 => {
            if (ai_class[z[1]] > @backingInt(CC.kywd)) {
                i = 1;
            } else {
                i = 2;
                while (ai_class[z[i]] <= @backingInt(CC.kywd)) i += 1;
                if (ctype.isIdChar(z[i])) {
                    // Started like a keyword but continues with a character
                    // keywords never contain: an identifier.
                    i += 1;
                } else {
                    return .{ .tk = keywordCode(z[0..i]), .len = i };
                }
            }
        },
        .x => {
            if (z[1] == '\'') {
                var tk: u8 = TK.BLOB;
                i = 2;
                while (ctype.isXdigit(z[i])) i += 1;
                if (z[i] != '\'' or i % 2 != 0) {
                    tk = TK.ILLEGAL;
                    while (z[i] != 0 and z[i] != '\'') i += 1;
                }
                if (z[i] != 0) i += 1;
                return .{ .tk = tk, .len = i };
            }
            // No keyword starts with 'x': an identifier.
            i = 1;
        },
        .kywd, .id => i = 1,
        .bom => {
            if (z[1] == 0xbb and z[2] == 0xbf) return .{ .tk = TK.SPACE, .len = 3 };
            i = 1;
        },
        .nul => return .{ .tk = TK.ILLEGAL, .len = 0 },
        .illegal => return .{ .tk = TK.ILLEGAL, .len = 1 },
    }
    while (ctype.isIdChar(z[i])) i += 1;
    return .{ .tk = TK.ID, .len = i };
}

/// The CC_DIGIT case of sqlite3GetToken().
fn scanNumber(z: [*:0]const u8) Scanned {
    var tk: u8 = TK.INTEGER;
    var i: usize = 0;
    if (z[0] == '0' and (z[1] == 'x' or z[1] == 'X') and ctype.isXdigit(z[2])) {
        i = 3;
        while (true) : (i += 1) {
            if (!ctype.isXdigit(z[i])) {
                if (z[i] != digit_separator) break;
                tk = TK.QNUMBER;
            }
        }
    } else {
        i = scanDigits(z, 0, &tk);
        if (z[i] == '.') {
            if (tk == TK.INTEGER) tk = TK.FLOAT;
            i = scanDigits(z, i + 1, &tk);
        }
        if ((z[i] == 'e' or z[i] == 'E') and
            (ctype.isDigit(z[i + 1]) or ((z[i + 1] == '+' or z[i + 1] == '-') and ctype.isDigit(z[i + 2]))))
        {
            if (tk == TK.INTEGER) tk = TK.FLOAT;
            i = scanDigits(z, i + 2, &tk);
        }
    }
    while (ctype.isIdChar(z[i])) {
        tk = TK.ILLEGAL;
        i += 1;
    }
    return .{ .tk = tk, .len = i };
}

/// Skips digits and digit separators from `start`; a separator makes the
/// token a QNUMBER.
fn scanDigits(z: [*:0]const u8, start: usize, tk: *u8) usize {
    var i = start;
    while (true) : (i += 1) {
        if (!ctype.isDigit(z[i])) {
            if (z[i] != digit_separator) return i;
            tk.* = TK.QNUMBER;
        }
    }
}

/// The next token that is not space or a comment, folding everything that
/// can be an identifier into TK_ID (getToken() of tokenize.c).
fn nextSignificant(z: *[*:0]const u8) u8 {
    var t: Scanned = undefined;
    while (true) {
        t = getToken(z.*);
        z.* += t.len;
        if (t.tk != TK.SPACE and t.tk != TK.COMMENT) break;
    }
    if (t.tk == TK.ID or t.tk == TK.STRING or t.tk == TK.JOIN_KW or t.tk == TK.WINDOW or
        t.tk == TK.OVER or grammar.yy_fallback[t.tk] == TK.ID)
    {
        return TK.ID;
    }
    return t.tk;
}

/// Port of analyzeWindowKeyword(): WINDOW is a keyword only if followed
/// by an identifier and AS.
pub fn analyzeWindowKeyword(z_arg: [*:0]const u8) u8 {
    var z = z_arg;
    if (nextSignificant(&z) != TK.ID) return TK.ID;
    if (nextSignificant(&z) != TK.AS) return TK.ID;
    return TK.WINDOW;
}

/// Port of analyzeOverKeyword(): OVER is a keyword only after ")" and
/// before "(" or an identifier.
pub fn analyzeOverKeyword(z_arg: [*:0]const u8, last_token: i32) u8 {
    var z = z_arg;
    if (last_token == TK.RP) {
        const t = nextSignificant(&z);
        if (t == TK.LP or t == TK.ID) return TK.OVER;
    }
    return TK.ID;
}

/// Port of analyzeFilterKeyword(): FILTER is a keyword only after ")" and
/// before "(".
pub fn analyzeFilterKeyword(z_arg: [*:0]const u8, last_token: i32) u8 {
    var z = z_arg;
    if (last_token == TK.RP and nextSignificant(&z) == TK.LP) return TK.FILTER;
    return TK.ID;
}

test "tokenize: token kinds and lengths" {
    const cases = [_]struct { []const u8, u8, usize }{
        .{ "select", TK.SELECT, 6 },
        .{ "SeLeCt x", TK.SELECT, 6 },
        .{ "selectx", TK.ID, 7 },
        .{ "current_timestamp", TK.CTIME_KW, 17 },
        .{ "xyz", TK.ID, 3 },
        .{ "x'0aFF'", TK.BLOB, 7 },
        .{ "x'0aF'", TK.ILLEGAL, 6 },
        .{ "123", TK.INTEGER, 3 },
        .{ "1_000", TK.QNUMBER, 5 },
        .{ "0x1F", TK.INTEGER, 4 },
        .{ "1.5e10", TK.FLOAT, 6 },
        .{ ".5", TK.FLOAT, 2 },
        .{ "1e", TK.ILLEGAL, 2 },
        .{ "12abc", TK.ILLEGAL, 5 },
        .{ "'it''s'", TK.STRING, 7 },
        .{ "'open", TK.ILLEGAL, 5 },
        .{ "\"id\"", TK.ID, 4 },
        .{ "[a b]", TK.ID, 5 },
        .{ "`q`", TK.ID, 3 },
        .{ "?12", TK.VARIABLE, 3 },
        .{ ":name", TK.VARIABLE, 5 },
        .{ "$a(b c)", TK.ILLEGAL, 4 },
        .{ "$a::b(x)", TK.VARIABLE, 8 },
        .{ "@", TK.ILLEGAL, 1 },
        .{ "-- c\nx", TK.COMMENT, 4 },
        .{ "/* c */x", TK.COMMENT, 7 },
        .{ "/* c", TK.COMMENT, 4 },
        .{ "->>", TK.PTR, 3 },
        .{ "<>", TK.NE, 2 },
        .{ "!=", TK.NE, 2 },
        .{ "==", TK.EQ, 2 },
        .{ "||", TK.CONCAT, 2 },
        .{ "\xef\xbb\xbfx", TK.SPACE, 3 },
        .{ "\xc3\xa9t\xc3\xa9", TK.ID, 5 },
        .{ "", TK.ILLEGAL, 0 },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        @memcpy(buf[0..c[0].len], c[0]);
        buf[c[0].len] = 0;
        const t = getToken(buf[0..c[0].len :0].ptr);
        errdefer std.debug.print("input {s}\n", .{c[0]});
        try std.testing.expectEqual(c[1], t.tk);
        try std.testing.expectEqual(c[2], t.len);
    }
}

// ================================================================ driver

const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const Parser = @import("parser.zig").Parser;

/// Port of sqlite3RunParser(): tokenize `sql` and run the parser over it,
/// which generates code as statements complete. Errors are left in `p`,
/// and fail the run (C: returns the number of errors, 0 or 1). Afterwards
/// `p.tail` is the text after the last token parsed.
pub fn runParser(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    const db = p.db;
    var failed = false;
    var mx_sql_len: i64 = db.limit(.sql_length);
    if (db.n_vdbe_active == 0) db.is_interrupted.store(false, .monotonic);
    p.rc = int.RC.OK;
    p.tail = sql;
    var parser = try Parser.init(p);
    const parent = db.parse;
    db.parse = p;
    defer db.parse = parent;

    var z: [*:0]const u8 = sql.ptr;
    var last_token_parsed: i32 = -1;
    while (true) {
        var t = getToken(z);
        mx_sql_len -= @intCast(t.len);
        if (mx_sql_len < 0) {
            p.rc = int.RC.TOOBIG;
            p.n_err += 1;
            break;
        }
        if (t.tk >= TK.WINDOW) {
            std.debug.assert(t.tk == TK.SPACE or t.tk == TK.OVER or t.tk == TK.FILTER or
                t.tk == TK.ILLEGAL or t.tk == TK.WINDOW or t.tk == TK.QNUMBER or t.tk == TK.COMMENT);
            if (db.is_interrupted.load(.monotonic)) {
                p.rc = int.RC.INTERRUPT;
                p.n_err += 1;
                break;
            }
            if (t.tk == TK.SPACE) {
                z += t.len;
                continue;
            }
            if (z[0] == 0) {
                // End of input: feed a SEMI, then 0.
                if (last_token_parsed == TK.SEMI) {
                    t.tk = 0;
                } else if (last_token_parsed == 0) {
                    break;
                } else {
                    t.tk = TK.SEMI;
                }
                t.len = 0;
            } else if (t.tk == TK.WINDOW) {
                t.tk = analyzeWindowKeyword(z + 6);
            } else if (t.tk == TK.OVER) {
                t.tk = analyzeOverKeyword(z + 4, last_token_parsed);
            } else if (t.tk == TK.FILTER) {
                t.tk = analyzeFilterKeyword(z + 6, last_token_parsed);
            } else if (t.tk == TK.COMMENT and (db.init.busy or db.flags.Comments)) {
                z += t.len;
                continue;
            } else if (t.tk != TK.QNUMBER) {
                util.errorMsgState(p, z, .of("42601"), "unrecognized token: \"{s}\"", .{z[0..t.len]});
                break;
            }
        }
        p.last_token = .{ .z = z, .n = @intCast(t.len) };
        try parser.feed(t.tk, p.last_token);
        last_token_parsed = t.tk;
        z += t.len;
        if (p.rc != int.RC.OK) break;
    }
    if (p.err_msg != null or (p.rc != int.RC.OK and p.rc != int.RC.DONE)) {
        if (p.err_msg == null) p.err_msg = try p.arena.dupeSentinel(u8, util.errStr(p.rc), 0);
        failed = true;
    }
    p.tail = std.mem.span(z);
    if (p.new_table) |t| if (!p.inSpecialParse()) {
        @import("../sql/build.zig").deleteTable(db, t);
        p.new_table = null;
    };
    if (failed) return error.ParseFailed;
}

/// runParser() for the tests: whether the statements have an error.
fn testParse(p: *int.Parse, sql: [:0]const u8) int.Oom!bool {
    runParser(p, sql) catch |err| switch (err) {
        error.ParseFailed => return true,
        error.OutOfMemory => |e| return e,
    };
    return false;
}

test "parser: syntax of a range of statements" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schema: int.Schema = .{};
    var db: int.Sqlite3 = .{ .gpa = undefined };
    db.gpa = @import("../sql/malloc.zig").dbAllocator(&db);
    try db.dbs.append(arena, .{ .name = "main", .schema = &schema });
    try db.dbs.append(arena, .{ .name = "temp", .schema = &schema });

    const ok = [_][:0]const u8{
        "SELECT 1",
        "select a, b as c, t.* from t where x > 1 and y like 'a%' escape '!' order by 1 desc nulls last limit 5 offset 2;",
        "SELECT count(*), sum(x) FILTER (WHERE x>0) OVER (PARTITION BY g ORDER BY t ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t GROUP BY g HAVING count(*)>1 WINDOW w AS (ORDER BY x)",
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<10) SELECT x FROM c",
        "SELECT * FROM a LEFT OUTER JOIN b USING (id) NATURAL JOIN c, (SELECT 1) AS d JOIN (e, f) ON 1",
        "SELECT x IN (1,2,3), x NOT IN (SELECT y FROM t), (a,b) IN ((1,2),(3,4)), x IN (), x IN t, EXISTS (SELECT 1)",
        "SELECT CASE WHEN a THEN 1 WHEN b THEN 2 ELSE 3 END, CASE x WHEN 1 THEN 'a' END, CAST(x AS VARCHAR(10)), -x, +x, ~x, NOT x",
        "SELECT x IS NULL, x NOTNULL, x NOT NULL, x IS NOT DISTINCT FROM y, x BETWEEN 1 AND 2, x ->> '$.a', x COLLATE nocase",
        "SELECT ?, ?7, :name, @v, $tcl::var(x), 1_000, 0x1F, 1.5e3, x'00ff', current_timestamp",
        "VALUES (1,2),(3,4)",
        "INSERT INTO t(a,b) VALUES (1,2),(3,4) ON CONFLICT(a) DO UPDATE SET b=excluded.b WHERE b<0 RETURNING *",
        "INSERT OR REPLACE INTO main.t DEFAULT VALUES",
        "REPLACE INTO t SELECT * FROM u",
        "UPDATE OR IGNORE t SET a=1, (b,c)=(2,3) FROM u, v WHERE t.id=u.id RETURNING a",
        "DELETE FROM t INDEXED BY i WHERE a=1",
        "CREATE TABLE IF NOT EXISTS t(a INTEGER PRIMARY KEY DESC AUTOINCREMENT, b TEXT NOT NULL DEFAULT 'x' COLLATE nocase, c REAL CHECK(c>0) UNIQUE ON CONFLICT REPLACE, d REFERENCES u(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, e AS (a+1) STORED, f GENERATED ALWAYS AS (b) VIRTUAL, CONSTRAINT pk UNIQUE(b,c), FOREIGN KEY(d) REFERENCES u, CHECK(a<>b)) WITHOUT ROWID, STRICT",
        "CREATE TEMP TABLE t AS SELECT 1",
        "CREATE UNIQUE INDEX IF NOT EXISTS i ON t(a COLLATE nocase DESC, b) WHERE a>0",
        "CREATE VIEW v(x,y) AS SELECT 1, 2",
        "CREATE TRIGGER tr AFTER UPDATE OF a ON t FOR EACH ROW WHEN new.a>0 BEGIN INSERT INTO log VALUES(new.a); UPDATE u SET x=1; DELETE FROM w WHERE x=old.a; SELECT RAISE(ABORT, 'no'); END",
        "CREATE VIRTUAL TABLE f USING fts5(a, b, tokenize = 'porter ascii')",
        "DROP TABLE IF EXISTS t; DROP VIEW v; DROP INDEX i; DROP TRIGGER tr",
        "BEGIN IMMEDIATE TRANSACTION; SAVEPOINT s; RELEASE s; ROLLBACK TO s; COMMIT; END; ROLLBACK",
        "PRAGMA main.cache_size = -2000; PRAGMA table_info(t); PRAGMA foreign_keys",
        "ATTACH DATABASE 'x.db' AS x; DETACH x; VACUUM; VACUUM INTO 'y.db'; ANALYZE; REINDEX t",
        "ALTER TABLE t RENAME TO u; ALTER TABLE t ADD COLUMN z INT DEFAULT 0; ALTER TABLE t DROP COLUMN z; ALTER TABLE t RENAME a TO b",
        "EXPLAIN QUERY PLAN SELECT 1",
        "SELECT 1 -- comment\n /* block */ ;",
        "SELECT window, over, filter FROM t WINDOW window AS (ORDER BY 1)",
        "SELECT a FROM t UNION SELECT b FROM u EXCEPT SELECT c FROM v ORDER BY 1",
    };
    for (ok) |sql| {
        var p: int.Parse = .{ .db = &db, .arena = arena, .syntax_only = true };
        const failed = try testParse(&p, sql);
        if (failed) std.debug.print("{s}\n  -> {s}\n", .{ sql, p.err_msg.? });
        try std.testing.expect(!failed);
    }

    const bad = [_]struct { [:0]const u8, []const u8 }{
        .{ "SELECT FROM", "near \"FROM\": syntax error" },
        .{ "SELECT * FROM", "incomplete input" },
        .{ "SELEC 1", "near \"SELEC\": syntax error" },
        .{ "SELECT 1 2", "near \"2\": syntax error" },
        .{ "SELECT 'abc", "unrecognized token: \"'abc\"" },
        .{ "SELECT 1e", "unrecognized token: \"1e\"" },
        .{ "SELECT 1 FROM t LEFT CROSS JOIN u", "unknown join type: LEFT CROSS" },
        .{ "SELECT 1 ORDER BY 1 UNION SELECT 2", "ORDER BY clause should come after UNION not before" },
        .{ "CREATE TABLE t(a) WITHOUT x", "unknown table option: x" },
        .{ "SELECT ?0", "variable number must be between ?1 and ?32766" },
        .{ "SELECT 1_", "unrecognized token: \"1_\"" },
        .{ "SELECT 1__0", "unrecognized token: \"1__0\"" },
        .{ "WITH a AS (SELECT 1), a AS (SELECT 2) SELECT 1", "duplicate WITH table name: a" },
        .{ "SELECT sum(x) OVER (ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM t", "unsupported frame specification" },
        .{ "SELECT * FROM t ON 1", "a JOIN clause is required before ON" },
        .{ "CREATE INDEX i ON t(a NULLS FIRST)", "" },
    };
    for (bad) |c| {
        var p: int.Parse = .{ .db = &db, .arena = arena, .syntax_only = true };
        const failed = try testParse(&p, c[0]);
        if (c[1].len == 0) continue;
        if (!failed) std.debug.print("{s}: no error\n", .{c[0]});
        try std.testing.expect(failed);
        std.testing.expectEqualStrings(c[1], p.err_msg.?) catch |err| {
            std.debug.print("for {s}\n", .{c[0]});
            return err;
        };
    }
}
