//! The drivers of the dialects' frontends (dialect.Frontend.run): what
//! is around parsing a statement, the same in every dialect: blank text
//! and empty statements, the end of the statement and where the next one
//! starts (Parse.tail), the parser's error recorded in the Parse
//! (sqlparse.Diag), finishing the code, and the dialect's wording of
//! SQLite's errors.
//!
//!  - run(): parsers that tokenize a whole statement first (PostgreSQL,
//!    Oracle), with the lexer's error;
//!  - streaming(): parsers that read the tokens as they go (MariaDB, SQL
//!    Server), where only the parser knows where a statement ends.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const ir = @import("../ir/ir.zig");
const lower = @import("../ir/lower.zig");
const sqlparse = @import("sql/parse");

const RC = int.RC;

/// What the session changes in how a statement is lexed (Parser.init()'s
/// options; each default is the dialect's, what a statement the dialect
/// writes itself is lexed with). PostgreSQL's standard_conforming_strings:
/// off, '...' strings take backslash escapes, as E'...'. Oracle reads
/// none.
pub const Options = struct {
    standard_strings: bool = true,

    /// The options of `db`'s session.
    pub fn of(db: *const int.Sqlite3) Options {
        return .{ .standard_strings = db.xq.postgres.standard_strings };
    }
};

/// The error of a statement that does not lex (Parser.init()).
pub const LexError = struct {
    fields: @import("../sql/util.zig").ErrorFields = .{ .message = "" },
    pos: usize = 0,
    /// The SQLSTATE if not a syntax error's.
    state: ?int.ErrorState = null,
};

/// What compile() of run() fails with: lowering's errors (in the Parse
/// already), and the parser's (ParseFailed: in its Diag, which run()
/// records, unless the parser could not read the schema: then it is in
/// the Parse too).
pub const CompileError = lower.Error || sqlparse.Error;

/// Frontend.run for the parser module `parser` (`Parser.init(arena, sql,
/// pos, &lex_error, options)`), which compiles a statement with
/// `compile(p, sql, &ps)` (a CompileError) and rewords its errors with
/// `translateError(p)`.
pub fn run(comptime parser: type, comptime compile: anytype, comptime translateError: fn (*int.Parse) int.Oom!void) fn (*int.Parse, [:0]const u8) (int.Oom || int.ParseError)!void {
    return struct {
        fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
            var lex_error: LexError = .{};
            var ps = parser.Parser.init(p.arena, sql, 0, &lex_error, .of(p.db)) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.ParseFailed => {
                    // A lexical error is a syntax error (unless it says).
                    ir.stmt.errorFieldsAt(p, sql.ptr + lex_error.pos, lex_error.state orelse .of("42601"), lex_error.fields);
                    p.tail = sql[sql.len..];
                    try translateError(p);
                    return error.ParseFailed;
                },
            };
            const rest = sql[ps.end..];
            if (ps.c.atEof()) {
                p.tail = rest;
                return;
            }
            compile(p, sql, &ps) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Failed => {},
                error.ParseFailed => if (!ps.err_in_parse) report(p, sql, ps.c.diag),
            };
            if (p.n_err == 0 and p.rc == RC.OK) ir.stmt.finishCoding(p);
            p.tail = rest;
            // dialect.runParser() fails the statement.
            try translateError(p);
        }
    }.run;
}

/// Frontend.run for a parser that reads its tokens as it goes. `F` (the
/// dialect's frontend.zig) gives:
///  - `Parser`, with the cursor `c` and `atStmtEnd()`;
///  - `init(p, sql) Parser`;
///  - `separator(*Parser) bool`: whether the next token ends a statement
///    (`;`, SQL Server's GO), skipped before one and after it;
///  - `statement(*Parser) Error!void`: compile the statement;
///  - `translateError(p) Oom!void`: the dialect's wording of an error;
///  - optionally `begin(*Parser) Oom!void`, before the statement, and
///    `end(*Parser) Oom!void`, after it compiled.
pub fn streaming(comptime F: type) fn (*int.Parse, [:0]const u8) (int.Oom || int.ParseError)!void {
    return struct {
        fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
            var s: F.Parser = F.init(p, sql);
            while (F.separator(&s)) s.c.skip();
            if (s.c.atEof()) {
                p.tail = sql[sql.len..];
                return;
            }
            if (@hasDecl(F, "begin")) try F.begin(&s);
            const ok = blk: {
                F.statement(&s) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.ParseFailed => break :blk false,
                };
                if (!s.atStmtEnd()) {
                    _ = s.c.syntaxError() catch {};
                    break :blk false;
                }
                break :blk p.n_err == 0;
            };
            if (!ok) {
                recordDiag(p, sql, s.c.diag);
                p.tail = sql[sql.len..];
                try F.translateError(p);
                return error.ParseFailed;
            }
            if (@hasDecl(F, "end")) try F.end(&s);
            if (F.separator(&s)) {
                s.c.skip();
                p.tail = sql[s.c.lastEnd()..];
            } else if (s.c.atEof()) {
                // (Also before a NUL in the text: the rest is not SQL.)
                p.tail = sql[sql.len..];
            } else p.tail = sql[s.c.here()..];
            ir.stmt.finishCoding(p);
        }
    }.run;
}

/// Record in `p` the error a parser found (`diag`, a sqlparse.Diag of
/// int.ErrorState) at its place in `sql`, unless `p` has an error already
/// (lowering, or a builder, recorded it first).
pub fn recordDiag(p: *int.Parse, sql: [:0]const u8, diag: anytype) void {
    if (diag.failed and p.n_err == 0) report(p, sql, diag);
}

/// The error `diag` in `p`, at its place in `sql` (none if it has none).
fn report(p: *int.Parse, sql: [:0]const u8, diag: anytype) void {
    const pos = diag.pos orelse sql.len;
    const z: ?[*]const u8 = if (pos < sql.len) sql.ptr + pos else null;
    ir.stmt.errorMsgState(p, z, diag.state, "{s}", .{diag.msg});
}

/// A rewording of an engine message: the prefix of SQLite's message, then
/// the dialect's text before and after the name that follows the prefix.
pub const Reword = struct {
    prefix: []const u8,
    before: []const u8,
    after: []const u8 = "",
    /// Whether the message names the object (if not, it is `before`).
    named: bool = true,
    /// What a name in schema main is written with (SQL Server's `dbo.`).
    main_as: []const u8 = "",
};

/// `name` without schema `main.`, which the dialects' messages leave out.
pub fn withoutMain(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "main.")) name[5..] else name;
}

/// Message `m` reworded by the rule of `rules` whose prefix it has (in
/// `a`), with that rule; null if it has none.
pub fn reword(a: std.mem.Allocator, m: []const u8, rules: []const Reword) std.mem.Allocator.Error!?struct { rule: *const Reword, text: [:0]u8 } {
    for (rules) |*r| if (std.mem.startsWith(u8, m, r.prefix)) {
        if (!r.named) return .{ .rule = r, .text = try a.dupeSentinel(u8, r.before, 0) };
        const name = m[r.prefix.len..];
        const bare = withoutMain(name);
        const schema = if (bare.len < name.len) r.main_as else "";
        return .{ .rule = r, .text = try std.fmt.allocPrintSentinel(a, "{s}{s}{s}{s}", .{ r.before, schema, bare, r.after }, 0) };
    };
    return null;
}
