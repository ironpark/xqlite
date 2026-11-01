//! The driver of the frontends whose parser tokenizes a whole statement
//! before parsing it (PostgreSQL, Oracle): the lexer's error, an empty
//! statement, compiling it, and the dialect's wording of SQLite's errors.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const ir = @import("../ir/ir.zig");
const lower = @import("../ir/lower.zig");

const RC = int.RC;

/// Frontend.run for the parser module `parser` (`Parser.init`, `LexError`),
/// which compiles a statement with `compile(p, sql, &ps)` and rewords its
/// errors with `translateError(p)`.
pub fn run(comptime parser: type, comptime compile: anytype, comptime translateError: fn (*int.Parse) int.Oom!void) fn (*int.Parse, [:0]const u8) (int.Oom || int.ParseError)!void {
    return struct {
        fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
            var lex_error: parser.LexError = .{};
            var ps = parser.Parser.init(p.arena, sql, 0, &lex_error) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.ParseFailed => {
                    // A lexical error is a syntax error.
                    ir.stmt.errorMsgState(p, sql.ptr + lex_error.pos, .of("42601"), "{s}", .{lex_error.msg});
                    p.tail = sql[sql.len..];
                    try translateError(p);
                    return error.ParseFailed;
                },
            };
            const rest = sql[ps.end..];
            if (ps.isEmpty()) {
                p.tail = rest;
                return;
            }
            compile(p, sql, &ps) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Failed => {},
            };
            if (p.n_err == 0 and p.rc == RC.OK) ir.stmt.finishCoding(p);
            p.tail = rest;
            // dialect.runParser() fails the statement.
            try translateError(p);
        }
    }.run;
}

/// The lower.Error of a parser's error `err`: its message at its place in
/// `sql`, unless the parser could not read the schema (then the error is
/// in `p` already).
pub fn parseFailed(p: *int.Parse, sql: [:0]const u8, ps: anytype, err: anytype) lower.Error {
    switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => {
            if (ps.err_in_parse) return error.Failed;
            const z: ?[*]const u8 = if (ps.err_pos < sql.len) sql.ptr + ps.err_pos else null;
            ir.stmt.errorMsgState(p, z, ps.err_state, "{s}", .{ps.err_msg});
            return error.Failed;
        },
    }
}
