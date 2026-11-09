//! SQLite's parser (sqlite3RunParser() and the grammar of parse.y, SQLite
//! 3.54.1): recursive descent over the tokens of
//! src/dialect/sqlite/lexer.zig, lowered through the builders of
//! src/ir/ir.zig with the same arguments in the same order as the reduce
//! actions of the parser lemon generates from parse.y. That is what makes
//! the bytecode, the schema text and the error messages the same as
//! SQLite's (docs/sqlparse.md 5.3). It replaced a port of lemon's parser
//! after a comparison of the two on SQLite's tests, sqllogictest, the fuzz
//! corpora and generated statements (docs/sqlparse.md 6).
//!
//! # Following lemon
//!
//! Lemon's LALR(1) parser runs a rule's action (a reduction) when the
//! token after the rule's last token arrives, before that token is
//! shifted; an empty rule (`ifnotexists ::=`, `scanpt ::=`) reduces when
//! the token after it arrives. Every builder call here follows the same
//! discipline: it is made after the last token of its rule is consumed
//! and before anything else is. `advance()` feeds the next token the
//! moment one is consumed (`feed()`: the checks of runParser() on it, and
//! `p.last_token`), so a builder sees the same lookahead token as lemon's
//! action, and the same `p.last_token`.
//!
//! Lemon stops after the token whose reductions set an error (rc not
//! OK): `advance()` stops at the consumption of the token being fed when
//! rc is no longer OK. Later errors overwrite the message (sqlite3ErrorMsg
//! does), so a syntax error at that same token is the one reported, as in
//! lemon.
//!
//! A syntax error is reported at the first token that cannot continue a
//! valid prefix, which is where lemon reports it: the functions here take
//! the alternatives lemon's state has at that point, and otherwise return
//! to their caller (lemon's default reduction), whose expected token then
//! fails (`fail()`, `expect()`).
//!
//! Keywords: parse.y's `%fallback ID` lets many keywords be identifiers.
//! In lemon a keyword is itself where the state has an action for it, and
//! an identifier where it has none but has one for ID. So at each place
//! below the keywords the grammar allows there are tested first, and then
//! `isNm()`, `isIds()`... accept the other fallback keywords as names.
//! WINDOW, OVER and FILTER are keywords or identifiers by the tokens
//! around them, as tokenize.c decides (`lexOne()`).
//!
//! Expressions use precedence climbing with parse.y's precedence table
//! (`level()`), the way lemon resolves its conflicts (`binds()`). The
//! generic engine of pkg/sql/parse (pratt) is not used: which token is an
//! operator depends on the fallback rules above, the BETWEEN's middle
//! operand is not an expression of one binding power (`exprBetween()`),
//! and NOT before NULL/LIKE/BETWEEN/IN binds by the precedence of NOT.
//!
//! Tokens are not read through the Cursor of pkg/sql/parse either: lemon
//! is fed one token at a time, after runParser()'s checks on the text up
//! to it (SQLITE_LIMIT_SQL_LENGTH counting space and comments, interrupts,
//! comments, illegal tokens), and the actions see the token fed
//! (`p.last_token`, `scanpt`). The source here keeps the token fed
//! (`peek()`) apart from those read ahead to decide (`at()`), which are
//! not checked yet.
//!
//! Lemon's stack is on the heap; this parser recurses. `push()` counts
//! lemon's stack depth for "Recursion limit", and bounds the native stack
//! a parse takes.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const util = @import("../../sql/util.zig");
const ctype = @import("xqlite_base").ctype;
const ir = @import("../../ir/ir.zig");
const lexer = @import("lexer.zig");
const fallsBack = lexer.fallsBack;

const Parse = int.Parse;
const Token = int.Token;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const Select = int.Select;
const Window = int.Window;
const With = int.With;
const Upsert = int.Upsert;
const TriggerStep = int.TriggerStep;
const OnOrUsing = int.OnOrUsing;
const Oom = int.Oom;
const RC = int.RC;
const TK = lexer.TK;
const SF = int.SF;
const JT = int.JT;
const OE = int.OE;
const TF = int.TF;
const SO = int.SortOrder;

/// `Stop`: the parse ends here (an error, or the end of a statement
/// that finished coding), as runParser()'s loop breaks.
pub const Error = Oom || error{Stop};

/// Port of sqlite3RunParser(): parse `sql` and generate code as
/// statements complete. Errors are left in `p`, and fail the run (C:
/// returns the number of errors, 0 or 1). Afterwards `p.tail` is the text
/// after the last token parsed.
pub fn runParser(p: *Parse, sql: [:0]const u8) (Oom || int.ParseError)!void {
    const db = p.db;
    if (db.n_vdbe_active == 0) db.is_interrupted.store(false, .monotonic);
    p.rc = RC.OK;
    p.tail = sql;
    const parent = db.parse;
    db.parse = p;
    defer db.parse = parent;

    const pos = try run(p, sql);

    var failed = false;
    if (p.err_msg != null or (p.rc != RC.OK and p.rc != RC.DONE)) {
        if (p.err_msg == null) p.err_msg = try p.arena.dupeSentinel(u8, util.errStr(p.rc), 0);
        failed = true;
    }
    p.tail = std.mem.sliceTo(sql[pos..], 0);
    if (p.new_table) |t| if (!p.inSpecialParse()) {
        @import("../../sql/build.zig").deleteTable(db, t);
        p.new_table = null;
    };
    if (failed) return error.ParseFailed;
}

/// The statements of `sql` (sqlite3RunParser()'s loop). Returns where the
/// text not consumed starts.
fn run(p: *Parse, sql: [:0]const u8) Oom!usize {
    var s: Parser = .{
        .p = p,
        .sql = sql,
        .stack_base = stackPosition(),
        .mx = p.db.limit(.sql_length),
        // Lemon's stack starts with room for 50 (YYSTACKDEPTH) and grows
        // up to the limit.
        .max_depth = @intCast(@max(50, p.db.limit(.parser_depth))),
    };
    s.begin() catch |err| switch (err) {
        error.Stop => return s.stop_pos,
        error.OutOfMemory => |e| return e,
    };
    s.input() catch |err| switch (err) {
        error.Stop => return s.stop_pos,
        error.OutOfMemory => |e| return e,
    };
    return s.stop_pos;
}

// ============================================================== tokens

/// A token: its code as lemon would get it (WINDOW, OVER and FILTER
/// decided; SEMI then 0 at the end of the text) and its place in the
/// text.
const Tok = struct {
    tk: u8,
    /// getToken()'s code, before WINDOW, OVER, FILTER and the end are
    /// decided.
    raw: u8,
    /// Whether a comment is in the text between it and the token before.
    comment: bool,
    start: u32,
    len: u32,

    fn end(t: Tok) u32 {
        return t.start + t.len;
    }
};

/// `nm`: ID|INDEXED|JOIN_KW or STRING, or a keyword falling back to ID.
fn isNm(tk: u8) bool {
    return tk == TK.ID or tk == TK.INDEXED or tk == TK.JOIN_KW or tk == TK.STRING or fallsBack(tk);
}

/// `ids`: ID|STRING, or a keyword falling back to ID.
fn isIds(tk: u8) bool {
    return tk == TK.ID or tk == TK.STRING or fallsBack(tk);
}

/// `id`: ID|INDEXED, or a keyword falling back to ID.
fn isId(tk: u8) bool {
    return tk == TK.ID or tk == TK.INDEXED or fallsBack(tk);
}

/// ID, or a keyword falling back to it.
fn isPlainId(tk: u8) bool {
    return tk == TK.ID or fallsBack(tk);
}

/// A name where an expression starts (`nm` of `nm DOT nm`): the keywords
/// that start an expression of their own are not names there.
fn isExprNm(tk: u8) bool {
    return isNm(tk) and tk != TK.CAST and tk != TK.RAISE and tk != TK.CTIME_KW;
}

/// The first token of a `select`.
fn startsSelect(tk: u8) bool {
    return tk == TK.SELECT or tk == TK.VALUES or tk == TK.WITH;
}

/// The token analyzeWindowKeyword() and the others read: the next one
/// that is not space or a comment, anything that can be an identifier
/// as ID.
fn nextSignificant(sql: [:0]const u8, pos: *usize) u8 {
    var t: lexer.Scanned = undefined;
    while (true) {
        t = lexer.getToken(sql, pos.*);
        pos.* += t.len;
        if (t.tk != TK.SPACE and t.tk != TK.COMMENT) break;
    }
    if (t.tk == TK.ID or t.tk == TK.STRING or t.tk == TK.JOIN_KW or t.tk == TK.WINDOW or
        t.tk == TK.OVER or fallsBack(t.tk)) return TK.ID;
    return t.tk;
}

/// WINDOW (ending at `pos`) is a keyword only before an identifier and
/// AS (analyzeWindowKeyword()).
fn windowCode(sql: [:0]const u8, pos_arg: usize) u8 {
    var pos = pos_arg;
    if (nextSignificant(sql, &pos) != TK.ID) return TK.ID;
    if (nextSignificant(sql, &pos) != TK.AS) return TK.ID;
    return TK.WINDOW;
}

/// OVER is a keyword only after ")" and before "(" or an identifier
/// (analyzeOverKeyword()).
fn overCode(sql: [:0]const u8, pos_arg: usize, last: i32) u8 {
    var pos = pos_arg;
    if (last == TK.RP) {
        const t = nextSignificant(sql, &pos);
        if (t == TK.LP or t == TK.ID) return TK.OVER;
    }
    return TK.ID;
}

/// FILTER is a keyword only after ")" and before "("
/// (analyzeFilterKeyword()).
fn filterCode(sql: [:0]const u8, pos_arg: usize, last: i32) u8 {
    var pos = pos_arg;
    if (last == TK.RP and nextSignificant(sql, &pos) == TK.LP) return TK.FILTER;
    return TK.ID;
}

// ============================================================== parser

/// The binding level of an operator after an expression (parse.y's
/// %left/%right lines, 1 the loosest), 0 if the token is none.
fn level(tk: u8) u8 {
    return switch (tk) {
        TK.OR => 1,
        TK.AND => 2,
        TK.NOT => 3,
        TK.IS, TK.MATCH, TK.LIKE_KW, TK.BETWEEN, TK.IN, TK.ISNULL, TK.NOTNULL, TK.NE, TK.EQ => 4,
        TK.GT, TK.LE, TK.LT, TK.GE => 5,
        TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT => 7,
        TK.PLUS, TK.MINUS => 8,
        TK.STAR, TK.SLASH, TK.REM => 9,
        TK.CONCAT, TK.PTR => 10,
        TK.COLLATE => 11,
        else => 0,
    };
}

/// Whether an operator of level `l` continues the operand of a rule of
/// precedence `min`: lemon shifts when the token's precedence is higher,
/// or equal and right-associative (NOT; BITNOT and ESCAPE are no
/// operator after an operand, ESCAPE is read by like()).
fn binds(l: u8, min: u8) bool {
    return l > min or (l == min and l == prec_not);
}

/// Precedences of rules that are no operator token's level.
const prec_not = 3;
const prec_is = 4;
const prec_unary = 12;

/// The native stack a parse may take (see Parser.push()): nesting at
/// SQLITE_LIMIT_PARSER_DEPTH takes about 600 KiB in ReleaseSafe, 2.3 MiB
/// in Debug. WebAssembly has a stack of 1 MiB.
const stack_budget: usize = if (@import("builtin").cpu.arch.isWasm()) 512 * 1024 else 1024 * 1024;

/// Where the native stack is (it grows down).
inline fn stackPosition() usize {
    var probe: u8 = 0;
    return @intFromPtr(&probe);
}

/// struct FrameBound of parse.y.
const FrameBound = struct { e_type: i32, expr: ?*Expr = null };

const Parser = struct {
    p: *Parse,
    sql: [:0]const u8,
    /// The tokens read ahead. la[0] is the token being fed to the
    /// parser (lemon's lookahead), already checked by feed().
    la: [4]Tok = undefined,
    n_la: u8 = 0,
    /// Where reading ahead goes on, and the code of the token read last
    /// (for OVER and FILTER, and the end of the text).
    lex_pos: usize = 0,
    lex_last: i32 = -1,
    /// runParser()'s `pos`: the start of the text not fed yet.
    pos: usize = 0,
    /// runParser()'s mxSqlLen: what is left of SQLITE_LIMIT_SQL_LENGTH.
    mx: i64,
    /// Where the text after the parse starts (p.tail), once stopped.
    stop_pos: usize = 0,
    /// Where the native stack was when the parse began.
    stack_base: usize,
    /// Lemon's stack depth, approximately: the symbols the open rules
    /// have taken (push()), against SQLITE_LIMIT_PARSER_DEPTH. Lemon's
    /// stack starts with an entry and the statement's first symbol.
    depth: u32 = 2,
    max_depth: u32,

    // ---------------------------------------------------------- tokens

    /// The next token of the text after the one read ahead last: space
    /// and comments skipped (feed() checks them), WINDOW, OVER and FILTER
    /// decided, SEMI then 0 at the end (as runParser() feeds them).
    fn lexOne(s: *Parser) Tok {
        var i = s.lex_pos;
        var comment = false;
        while (true) {
            const r = lexer.getToken(s.sql, i);
            if (r.tk == TK.SPACE or r.tk == TK.COMMENT) {
                comment = comment or r.tk == TK.COMMENT;
                i += r.len;
                continue;
            }
            var code = r.tk;
            if (s.sql[i] == 0) {
                code = if (s.lex_last == TK.SEMI or s.lex_last == 0) 0 else TK.SEMI;
            } else if (code == TK.WINDOW) {
                code = windowCode(s.sql, i + r.len);
            } else if (code == TK.OVER) {
                code = overCode(s.sql, i + r.len, s.lex_last);
            } else if (code == TK.FILTER) {
                code = filterCode(s.sql, i + r.len, s.lex_last);
            }
            s.lex_pos = i + r.len;
            s.lex_last = code;
            return .{ .tk = code, .raw = r.tk, .comment = comment, .start = @intCast(i), .len = @intCast(r.len) };
        }
    }

    /// Read ahead to la[k].
    fn fill(s: *Parser, k: usize) void {
        while (s.n_la <= k) : (s.n_la += 1) s.la[s.n_la] = s.lexOne();
    }

    /// Feed la[0]: what runParser() does with the text up to it before
    /// it hands the token to the parser. Space and comments count against
    /// SQLITE_LIMIT_SQL_LENGTH; at the special tokens it checks for an
    /// interrupt; a comment is an error unless reading the schema or
    /// SQLITE_DBCONFIG_ENABLE_COMMENTS; an illegal token is an error.
    fn feed(s: *Parser) Error!void {
        // Most tokens: an ordinary one after space (and comments where
        // allowed), in the limit. The loop below would charge the same
        // and stop nowhere.
        const t = s.la[0];
        const db = s.p.db;
        const n: i64 = @intCast(t.end() - s.pos);
        if (t.raw < TK.WINDOW and n <= s.mx and
            (!t.comment or db.init.busy or db.flags.Comments) and
            (t.start == s.pos or !db.is_interrupted.load(.monotonic)))
        {
            s.mx -= n;
            s.pos = t.start;
            s.p.last_token = s.token(t);
            return;
        }
        return s.feedSlow();
    }

    /// feed() token by token, as runParser() does.
    noinline fn feedSlow(s: *Parser) Error!void {
        const p = s.p;
        const db = p.db;
        while (true) {
            const r = lexer.getToken(s.sql, s.pos);
            s.mx -= @intCast(r.len);
            if (s.mx < 0) {
                p.rc = RC.TOOBIG;
                p.n_err += 1;
                return s.stopAt(s.pos);
            }
            if (r.tk < TK.WINDOW) break;
            if (db.is_interrupted.load(.monotonic)) {
                p.rc = RC.INTERRUPT;
                p.n_err += 1;
                return s.stopAt(s.pos);
            }
            if (r.tk == TK.SPACE) {
                s.pos += r.len;
                continue;
            }
            if (s.sql[s.pos] == 0) break;
            if (r.tk == TK.COMMENT and (db.init.busy or db.flags.Comments)) {
                s.pos += r.len;
                continue;
            }
            if (r.tk == TK.WINDOW or r.tk == TK.OVER or r.tk == TK.FILTER or r.tk == TK.QNUMBER) break;
            util.errorMsgState(p, s.sql.ptr + s.pos, .of("42601"), "unrecognized token: \"{s}\"", .{s.sql[s.pos..][0..r.len]});
            return s.stopAt(s.pos);
        }
        std.debug.assert(s.pos == s.la[0].start);
        p.last_token = s.token(s.la[0]);
    }

    fn stopAt(s: *Parser, pos: usize) error{Stop} {
        s.stop_pos = pos;
        return error.Stop;
    }

    /// Read and feed the first token.
    fn begin(s: *Parser) Error!void {
        s.fill(0);
        try s.feed();
    }

    /// The token being fed.
    inline fn peek(s: *Parser) Tok {
        return s.la[0];
    }

    /// The code of the token being fed.
    inline fn tk(s: *Parser) u8 {
        return s.la[0].tk;
    }

    /// The token `k` after the one being fed (not fed yet).
    fn at(s: *Parser, k: usize) Tok {
        s.fill(k);
        return s.la[k];
    }

    fn token(s: *const Parser, t: Tok) Token {
        return .{ .z = s.sql.ptr + t.start, .n = t.len };
    }

    /// Where the token being fed starts (parse.y's `scanpt`).
    fn scanpt(s: *const Parser) [*]const u8 {
        return s.sql.ptr + s.la[0].start;
    }

    /// Consume the token being fed (lemon shifts it) and feed the next.
    fn advance(s: *Parser) Error!Tok {
        return s.advanceDeep(0);
    }

    /// advance() for the token that opens a nested rule: `n` symbols
    /// more on lemon's stack (push()), checked at the shift of the token.
    fn advanceDeep(s: *Parser, n: u32) Error!Tok {
        const t = s.la[0];
        s.pos = t.end();
        if (n > 0) try s.push(n);
        // runParser() stops after the token whose reductions set an
        // error, or after the statement that finished coding (DONE).
        if (s.p.rc != RC.OK) return s.stopAt(s.pos);
        s.n_la -= 1;
        std.mem.copyForwards(Tok, s.la[0..s.n_la], s.la[1 .. s.n_la + 1]);
        s.fill(0);
        try s.feed();
        return t;
    }

    /// `n` more symbols on lemon's stack: "Recursion limit" past
    /// SQLITE_LIMIT_PARSER_DEPTH (yyStackOverflow()). The nesting at which
    /// it fails is close to lemon's, not the same. Lemon's stack is on the
    /// heap; this parser's is the native stack, so it fails the same way
    /// when the parse has taken `stack_budget` of it, which an optimized
    /// build reaches only past lemon's limit (a Debug one sooner).
    fn push(s: *Parser, n: u32) error{Stop}!void {
        s.depth += n;
        if (s.depth >= s.max_depth or s.stack_base -| stackPosition() > stack_budget) {
            if (s.p.n_err == 0) util.errorMsg(s.p, "Recursion limit", .{});
            return s.stopAt(s.pos);
        }
    }

    fn pop(s: *Parser, n: u32) void {
        s.depth -= n;
    }

    /// A syntax error at the token being fed (yy_syntax_error).
    noinline fn fail(s: *Parser) error{Stop} {
        const t = s.la[0];
        if (s.sql[t.start] != 0) {
            ir.stmt.syntaxError(s.p, s.token(t));
        } else {
            util.errorMsgState(s.p, null, .of("42601"), "incomplete input", .{});
        }
        return s.stopAt(t.end());
    }

    /// Consume a token of code `code`, else a syntax error.
    fn expect(s: *Parser, code: u8) Error!Tok {
        if (s.tk() != code) return s.fail();
        return s.advance();
    }

    /// expect() for the token that opens a nested rule (advanceDeep()).
    fn expectDeep(s: *Parser, code: u8, n: u32) Error!Tok {
        if (s.tk() != code) return s.fail();
        return s.advanceDeep(n);
    }

    /// Consume the token if it is `code`.
    fn eat(s: *Parser, code: u8) Error!?Tok {
        if (s.tk() != code) return null;
        return try s.advance();
    }

    /// `nm`, else a syntax error.
    fn nm(s: *Parser) Error!Token {
        if (!isNm(s.tk())) return s.fail();
        return s.token(try s.advance());
    }

    /// `dbnm`: DOT nm, or nothing.
    fn dbnm(s: *Parser) Error!Token {
        if (s.tk() != TK.DOT) return .{};
        _ = try s.advance();
        return s.nm();
    }

    // ------------------------------------------------------ statements

    /// input ::= cmdlist. cmdlist ::= (SEMI | explain? cmdx SEMI)*,
    /// ended by token 0.
    fn input(s: *Parser) Error!void {
        const p = s.p;
        while (true) {
            switch (s.tk()) {
                0 => {
                    // Accepted. runParser() reads the end once more: a
                    // last check for an interrupt.
                    s.pos = s.peek().end();
                    if (p.db.is_interrupted.load(.monotonic)) {
                        p.rc = RC.INTERRUPT;
                        p.n_err += 1;
                    }
                    s.stop_pos = s.pos;
                    return;
                },
                TK.SEMI => _ = try s.advance(),
                TK.EXPLAIN => {
                    _ = try s.advance();
                    if (s.tk() == TK.QUERY) {
                        _ = try s.advance();
                        _ = try s.expect(TK.PLAN);
                        ir.stmt.setExplain(p, 2);
                    } else {
                        ir.stmt.setExplain(p, 1);
                    }
                    try s.cmdx();
                },
                else => try s.cmdx(),
            }
        }
    }

    /// cmdx ::= cmd, then SEMI.
    fn cmdx(s: *Parser) Error!void {
        try s.cmd();
        if (!s.p.xq_hold_finish) ir.stmt.finishCoding(s.p);
        _ = try s.expect(TK.SEMI);
    }

    fn cmd(s: *Parser) Error!void {
        const p = s.p;
        switch (s.tk()) {
            TK.BEGIN => {
                _ = try s.advance();
                const kind: i32 = switch (s.tk()) {
                    TK.DEFERRED, TK.IMMEDIATE, TK.EXCLUSIVE => (try s.advance()).tk,
                    else => TK.DEFERRED,
                };
                try s.transOpt();
                ir.txn.begin(p, kind);
            },
            TK.COMMIT, TK.END => {
                const op = (try s.advance()).tk;
                try s.transOpt();
                ir.txn.end(p, op);
            },
            TK.ROLLBACK => {
                _ = try s.advance();
                try s.transOpt();
                if (s.tk() == TK.TO) {
                    _ = try s.advance();
                    _ = try s.eat(TK.SAVEPOINT);
                    const name = try s.nm();
                    ir.txn.savepoint(p, .ROLLBACK, name);
                } else {
                    ir.txn.end(p, TK.ROLLBACK);
                }
            },
            TK.SAVEPOINT => {
                _ = try s.advance();
                const name = try s.nm();
                ir.txn.savepoint(p, .BEGIN, name);
            },
            TK.RELEASE => {
                _ = try s.advance();
                _ = try s.eat(TK.SAVEPOINT);
                const name = try s.nm();
                ir.txn.savepoint(p, .RELEASE, name);
            },
            TK.CREATE => try s.create(),
            TK.DROP => try s.drop(),
            TK.SELECT, TK.VALUES => {
                const sel = try s.select();
                ir.stmt.select(p, sel);
            },
            TK.WITH => try s.withStatement(),
            TK.DELETE => try s.delete(),
            TK.UPDATE => try s.update(),
            TK.INSERT, TK.REPLACE => try s.insert(),
            TK.VACUUM => try s.vacuum(),
            TK.PRAGMA => try s.pragma(),
            TK.ATTACH => {
                _ = try s.advance();
                _ = try s.eat(TK.DATABASE);
                const file = try s.expr();
                _ = try s.expect(TK.AS);
                const name = try s.expr();
                var key: ?*Expr = null;
                if (s.tk() == TK.KEY) {
                    _ = try s.advance();
                    key = try s.expr();
                }
                ir.admin.attach(p, file, name, key);
            },
            TK.DETACH => {
                _ = try s.advance();
                _ = try s.eat(TK.DATABASE);
                const name = try s.expr();
                ir.admin.detach(p, name);
            },
            TK.REINDEX, TK.ANALYZE => {
                const op = (try s.advance()).tk;
                var name1: ?Token = null;
                var name2: Token = .{};
                if (isNm(s.tk())) {
                    name1 = s.token(try s.advance());
                    name2 = try s.dbnm();
                }
                if (op == TK.REINDEX) {
                    if (name1) |n| ir.admin.reindex(p, n, name2) else ir.admin.reindex(p, null, null);
                } else {
                    if (name1) |n| ir.admin.analyze(p, n, name2) else ir.admin.analyze(p, null, null);
                }
            },
            TK.ALTER => try s.alter(),
            else => return s.fail(),
        }
    }

    /// trans_opt ::= TRANSACTION nm? | .
    fn transOpt(s: *Parser) Error!void {
        if (s.tk() != TK.TRANSACTION) return;
        _ = try s.advance();
        if (isNm(s.tk())) _ = try s.advance();
    }

    /// WITH at the start of a statement: a SELECT's, or the `with` of a
    /// DELETE, UPDATE or INSERT.
    fn withStatement(s: *Parser) Error!void {
        const p = s.p;
        const w = try s.withClause();
        switch (s.tk()) {
            TK.DELETE, TK.UPDATE, TK.INSERT, TK.REPLACE => {
                // with ::= WITH wqlist, reduced by the DML keyword.
                _ = ir.with.push(p, w);
                switch (s.tk()) {
                    TK.DELETE => try s.delete(),
                    TK.UPDATE => try s.update(),
                    else => try s.insert(),
                }
            },
            else => {
                const body = try s.selectNoWith();
                const sel = ir.select.attachWith(p, body, w);
                ir.stmt.select(p, sel);
            },
        }
    }

    fn vacuum(s: *Parser) Error!void {
        _ = try s.advance();
        var name: ?Token = null;
        if (s.tk() != TK.INTO and isNm(s.tk())) name = s.token(try s.advance());
        var into: ?*Expr = null;
        if (s.tk() == TK.INTO) {
            _ = try s.advance();
            into = try s.expr();
        }
        ir.admin.vacuum(s.p, name, into);
    }

    /// PRAGMA nm dbnm [EQ value | LP value RP].
    fn pragma(s: *Parser) Error!void {
        _ = try s.advance();
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        const close = switch (s.tk()) {
            TK.EQ => false,
            TK.LP => true,
            else => {
                ir.admin.pragma(s.p, name1, name2, null, false);
                return;
            },
        };
        _ = try s.advance();
        var minus = false;
        const value: Token = switch (s.tk()) {
            TK.MINUS, TK.PLUS => blk: {
                minus = (try s.advance()).tk == TK.MINUS;
                if (s.tk() != TK.INTEGER and s.tk() != TK.FLOAT) return s.fail();
                break :blk s.token(try s.advance());
            },
            TK.INTEGER, TK.FLOAT, TK.ON, TK.DELETE, TK.DEFAULT => s.token(try s.advance()),
            else => try s.nm(),
        };
        if (close) _ = try s.expect(TK.RP);
        ir.admin.pragma(s.p, name1, name2, value, minus);
    }

    fn drop(s: *Parser) Error!void {
        const p = s.p;
        _ = try s.advance();
        const what = s.tk();
        switch (what) {
            TK.TABLE, TK.VIEW, TK.INDEX, TK.TRIGGER => _ = try s.advance(),
            else => return s.fail(),
        }
        const if_exists = try s.ifExists();
        const name = try s.fullname();
        switch (what) {
            TK.TABLE => ir.ddl.dropTable(p, name, false, if_exists),
            TK.VIEW => ir.ddl.dropTable(p, name, true, if_exists),
            TK.INDEX => ir.ddl.dropIndex(p, name, if_exists),
            else => ir.ddl.dropTrigger(p, name, if_exists),
        }
    }

    /// ifexists ::= IF EXISTS | .
    fn ifExists(s: *Parser) Error!bool {
        if (s.tk() != TK.IF) return false;
        _ = try s.advance();
        _ = try s.expect(TK.EXISTS);
        return true;
    }

    /// ifnotexists ::= IF NOT EXISTS | .
    fn ifNotExists(s: *Parser) Error!bool {
        if (s.tk() != TK.IF) return false;
        _ = try s.advance();
        _ = try s.expect(TK.NOT);
        _ = try s.expect(TK.EXISTS);
        return true;
    }

    /// fullname ::= nm | nm DOT nm.
    fn fullname(s: *Parser) Error!?*SrcList {
        const name1 = try s.nm();
        var name2: Token = .{};
        if (s.tk() == TK.DOT) {
            _ = try s.advance();
            name2 = try s.nm();
        }
        return ir.from.fullName(s.p, name1, name2, .{});
    }

    /// xfullname ::= nm [DOT nm] [AS nm].
    fn xfullname(s: *Parser) Error!?*SrcList {
        const name1 = try s.nm();
        var name2: Token = .{};
        var alias: Token = .{};
        if (s.tk() == TK.DOT) {
            _ = try s.advance();
            name2 = try s.nm();
        }
        if (s.tk() == TK.AS) {
            _ = try s.advance();
            alias = try s.nm();
        }
        return ir.from.fullName(s.p, name1, name2, alias);
    }

    /// kwcolumn_opt ::= COLUMNKW | .
    fn kwColumn(s: *Parser) Error!void {
        _ = try s.eat(TK.COLUMNKW);
    }

    fn alter(s: *Parser) Error!void {
        const p = s.p;
        _ = try s.advance();
        _ = try s.expect(TK.TABLE);
        const table = try s.fullname();
        switch (s.tk()) {
            TK.RENAME => {
                _ = try s.advance();
                if (s.tk() == TK.TO) {
                    _ = try s.advance();
                    const to = try s.nm();
                    ir.ddl.renameTable(p, table, to);
                } else {
                    try s.kwColumn();
                    const old = try s.nm();
                    _ = try s.expect(TK.TO);
                    const new = try s.nm();
                    ir.ddl.renameColumn(p, table, old, new);
                }
            },
            TK.ADD => {
                _ = try s.advance();
                switch (s.tk()) {
                    TK.CONSTRAINT => {
                        const kw = s.token(try s.advance());
                        const name = try s.nm();
                        _ = try s.expect(TK.CHECK);
                        try s.alterAddCheck(table, kw, name);
                    },
                    TK.CHECK => {
                        const kw = s.token(try s.advance());
                        try s.alterAddCheck(table, kw, null);
                    },
                    else => {
                        try s.kwColumn();
                        var col = try s.nm();
                        const ty = try s.typetoken();
                        // alter_add ::= ALTER TABLE fullname ADD
                        // kwcolumn_opt nm typetoken.
                        ir.ddl.beginCreate(p);
                        ir.ddl.beginAddColumn(p, table);
                        ir.ddl.addColumn(p, col, ty);
                        try s.carglist();
                        col.n = spanLen(col, p.last_token);
                        ir.ddl.finishAddColumn(p, col);
                    },
                }
            },
            TK.DROP => {
                _ = try s.advance();
                if (s.tk() == TK.CONSTRAINT) {
                    _ = try s.advance();
                    const name = try s.nm();
                    ir.ddl.dropConstraint(p, table, name, null);
                } else {
                    try s.kwColumn();
                    const col = try s.nm();
                    ir.ddl.dropColumn(p, table, col);
                }
            },
            TK.ALTER => {
                _ = try s.advance();
                try s.kwColumn();
                const col = try s.nm();
                switch (s.tk()) {
                    TK.DROP => {
                        _ = try s.advance();
                        _ = try s.expect(TK.NOT);
                        _ = try s.expect(TK.NULL);
                        ir.ddl.dropConstraint(p, table, null, col);
                    },
                    TK.SET => {
                        _ = try s.advance();
                        const not = s.token(try s.expect(TK.NOT));
                        _ = try s.expect(TK.NULL);
                        _ = try s.onconf();
                        ir.ddl.setNotNull(p, table, col, not);
                    },
                    else => return s.fail(),
                }
            },
            else => return s.fail(),
        }
    }

    /// The rest of ALTER TABLE ... ADD [CONSTRAINT nm] CHECK: LP expr RP
    /// onconf.
    fn alterAddCheck(s: *Parser, table: ?*SrcList, kw: Token, name: ?Token) Error!void {
        const lp = s.token(try s.expect(TK.LP));
        const e = try s.expr();
        const rp = s.token(try s.expect(TK.RP));
        _ = try s.onconf();
        ir.ddl.addConstraint(s.p, table, kw, name, textBetween(lp, rp), e);
    }

    // ------------------------------------------------------------- DDL

    /// CREATE ...: createkw, then a table, view, index, trigger or
    /// virtual table.
    fn create(s: *Parser) Error!void {
        const p = s.p;
        const create_tok = s.token(try s.advance());
        // createkw ::= CREATE.
        ir.ddl.beginCreate(p);
        switch (s.tk()) {
            TK.TEMP, TK.TABLE, TK.VIEW, TK.TRIGGER => {
                var temp = false;
                if (s.tk() == TK.TEMP) {
                    _ = try s.advance();
                    // temp ::= TEMP.
                    temp = !p.db.init.busy;
                }
                switch (s.tk()) {
                    TK.TABLE => try s.createTable(temp),
                    TK.VIEW => try s.createView(create_tok, temp),
                    TK.TRIGGER => try s.createTrigger(temp),
                    else => return s.fail(),
                }
            },
            TK.UNIQUE, TK.INDEX => try s.createIndex(create_tok),
            TK.VIRTUAL => try s.createVtab(),
            else => return s.fail(),
        }
    }

    fn createTable(s: *Parser, temp: bool) Error!void {
        const p = s.p;
        _ = try s.advance();
        const if_not_exists = try s.ifNotExists();
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        ir.ddl.startTable(p, name1, name2, temp, false, false, if_not_exists);
        switch (s.tk()) {
            TK.LP => {
                _ = try s.advance();
                var cons: Token = .{};
                while (true) {
                    try s.columnDef();
                    if (s.tk() != TK.COMMA) break;
                    if (startsTableConstraint(s.at(1).tk)) {
                        cons = s.token(try s.advance());
                        try s.tableConstraints();
                        break;
                    }
                    _ = try s.advance();
                }
                const rp = s.token(try s.expect(TK.RP));
                const opts = try s.tableOptions();
                ir.ddl.endTable(p, cons, rp, opts, null);
            },
            TK.AS => {
                _ = try s.advance();
                const sel = try s.select();
                ir.ddl.endTable(p, null, null, .{}, sel);
            },
            else => return s.fail(),
        }
    }

    /// table_option_set: the options after the column list, comma
    /// separated, the first may be missing.
    fn tableOptions(s: *Parser) Error!TF {
        var opts: TF = .{};
        if (s.tk() == TK.WITHOUT or isNm(s.tk())) opts = try s.tableOption();
        while (s.tk() == TK.COMMA) {
            _ = try s.advance();
            opts = opts.with(try s.tableOption());
        }
        return opts;
    }

    /// table_option ::= WITHOUT nm | nm.
    fn tableOption(s: *Parser) Error!TF {
        const p = s.p;
        if (s.tk() == TK.WITHOUT) {
            _ = try s.advance();
            const x = try s.nm();
            if (ctype.eqlNoCase(x.slice(), "rowid")) return .{ .WithoutRowid = true, .NoVisibleRowid = true };
            ir.stmt.errorMsg(p, "unknown table option: {s}", .{x.slice()});
            return .{};
        }
        const x = try s.nm();
        if (ctype.eqlNoCase(x.slice(), "strict")) return .{ .Strict = true };
        ir.stmt.errorMsg(p, "unknown table option: {s}", .{x.slice()});
        return .{};
    }

    /// columnname carglist.
    fn columnDef(s: *Parser) Error!void {
        const name = try s.nm();
        const ty = try s.typetoken();
        ir.ddl.addColumn(s.p, name, ty);
        try s.carglist();
    }

    /// typetoken ::= typename [LP signed RP | LP signed COMMA signed RP]
    /// | . (an absent type is an empty token).
    fn typetoken(s: *Parser) Error!Token {
        if (!isIds(s.tk())) return .{};
        var t = s.token(try s.advance());
        // typename ::= typename ids.
        while (isIds(s.tk())) t.n = spanLen(t, s.token(try s.advance()));
        if (s.tk() == TK.LP) {
            _ = try s.advance();
            try s.signed();
            if (s.tk() == TK.COMMA) {
                _ = try s.advance();
                try s.signed();
            }
            t.n = spanLen(t, s.token(try s.expect(TK.RP)));
        }
        return t;
    }

    /// signed ::= [PLUS|MINUS] INTEGER|FLOAT.
    fn signed(s: *Parser) Error!void {
        if (s.tk() == TK.PLUS or s.tk() == TK.MINUS) _ = try s.advance();
        if (s.tk() != TK.INTEGER and s.tk() != TK.FLOAT) return s.fail();
        _ = try s.advance();
    }

    /// carglist ::= ccons*.
    fn carglist(s: *Parser) Error!void {
        const p = s.p;
        while (true) {
            switch (s.tk()) {
                TK.CONSTRAINT => {
                    _ = try s.advance();
                    p.u1.cr.constraint_name = try s.nm();
                },
                TK.DEFAULT => try s.defaultValue(),
                TK.NULL => {
                    _ = try s.advance();
                    _ = try s.onconf();
                },
                TK.NOT => {
                    _ = try s.advance();
                    switch (s.tk()) {
                        TK.NULL => {
                            _ = try s.advance();
                            ir.ddl.addNotNull(p, try s.onconf());
                        },
                        TK.DEFERRABLE => {
                            _ = try s.advance();
                            _ = try s.initDeferred();
                            ir.ddl.deferForeignKey(p, false);
                        },
                        else => return s.fail(),
                    }
                },
                TK.PRIMARY => {
                    _ = try s.advance();
                    _ = try s.expect(TK.KEY);
                    const order = try s.sortorder();
                    const on_error = try s.onconf();
                    const autoinc = try s.eat(TK.AUTOINCR) != null;
                    ir.ddl.addPrimaryKey(p, null, on_error, autoinc, order);
                },
                TK.UNIQUE => {
                    _ = try s.advance();
                    const on_error = try s.onconf();
                    ir.ddl.createIndex(p, null, null, null, null, on_error, null, null, 0, false, .unique);
                },
                TK.CHECK => {
                    _ = try s.advance();
                    const lp = s.token(try s.expect(TK.LP));
                    const e = try s.expr();
                    const rp = s.token(try s.expect(TK.RP));
                    ir.ddl.addCheckConstraint(p, e, lp.z, rp.z);
                },
                TK.REFERENCES => {
                    _ = try s.advance();
                    const table = try s.nm();
                    const cols = try s.eidlistOpt();
                    const actions = try s.refargs();
                    ir.ddl.createForeignKey(p, null, table, cols, actions);
                },
                TK.DEFERRABLE => {
                    _ = try s.advance();
                    const deferred = try s.initDeferred();
                    ir.ddl.deferrableForeignKey(p, deferred);
                },
                TK.COLLATE => {
                    _ = try s.advance();
                    if (!isIds(s.tk())) return s.fail();
                    ir.ddl.addCollateType(p, s.token(try s.advance()));
                },
                TK.GENERATED => {
                    _ = try s.advance();
                    _ = try s.expect(TK.ALWAYS);
                    _ = try s.expect(TK.AS);
                    try s.generated();
                },
                TK.AS => {
                    _ = try s.advance();
                    try s.generated();
                },
                else => return,
            }
        }
    }

    /// generated ::= LP expr RP [ID].
    fn generated(s: *Parser) Error!void {
        _ = try s.expect(TK.LP);
        const e = try s.expr();
        _ = try s.expect(TK.RP);
        if (isPlainId(s.tk())) {
            ir.ddl.addGenerated(s.p, e, s.token(try s.advance()));
        } else {
            ir.ddl.addGenerated(s.p, e, null);
        }
    }

    /// DEFAULT and the default value of a column. The text stored is from
    /// the value's first token (scantok) or the sign.
    fn defaultValue(s: *Parser) Error!void {
        const p = s.p;
        _ = try s.advance();
        switch (s.tk()) {
            TK.LP => {
                const lp = s.token(try s.advance());
                const e = try s.expr();
                const rp = s.token(try s.expect(TK.RP));
                ir.ddl.addDefaultValue(p, e, lp.z.? + 1, rp.z);
            },
            TK.PLUS, TK.MINUS => {
                const sign = try s.advance();
                if (!isTerm(s.tk())) return s.fail();
                const first = s.token(s.peek());
                const e = try s.term();
                const z = s.token(sign).z;
                if (sign.tk == TK.MINUS) {
                    const neg = try ir.expr.binary(p, TK.UMINUS, e, null);
                    ir.ddl.addDefaultValue(p, neg, z, tokEnd(first));
                } else {
                    ir.ddl.addDefaultValue(p, e, z, tokEnd(first));
                }
            },
            else => {
                if (isTerm(s.tk())) {
                    const first = s.token(s.peek());
                    const e = try s.term();
                    ir.ddl.addDefaultValue(p, e, first.z, tokEnd(first));
                } else if (isId(s.tk())) {
                    const t = s.token(try s.advance());
                    const e = try ir.expr.token(p, TK.STRING, t);
                    _ = ir.expr.idToTrueFalse(e);
                    ir.ddl.addDefaultValue(p, e, t.z, tokEnd(t));
                } else {
                    return s.fail();
                }
            },
        }
    }

    /// onconf ::= ON CONFLICT resolvetype | .
    fn onconf(s: *Parser) Error!OE {
        if (s.tk() != TK.ON) return .Default;
        _ = try s.advance();
        _ = try s.expect(TK.CONFLICT);
        return s.resolvetype();
    }

    /// orconf ::= OR resolvetype | .
    fn orconf(s: *Parser) Error!OE {
        if (s.tk() != TK.OR) return .Default;
        _ = try s.advance();
        return s.resolvetype();
    }

    /// resolvetype ::= ROLLBACK | ABORT | FAIL | IGNORE | REPLACE.
    fn resolvetype(s: *Parser) Error!OE {
        const oe: OE = switch (s.tk()) {
            TK.ROLLBACK => .Rollback,
            TK.ABORT => .Abort,
            TK.FAIL => .Fail,
            TK.IGNORE => .Ignore,
            TK.REPLACE => .Replace,
            else => return s.fail(),
        };
        _ = try s.advance();
        return oe;
    }

    /// sortorder ::= ASC | DESC | .
    fn sortorder(s: *Parser) Error!i32 {
        return switch (s.tk()) {
            TK.ASC => blk: {
                _ = try s.advance();
                break :blk SO.asc;
            },
            TK.DESC => blk: {
                _ = try s.advance();
                break :blk SO.desc;
            },
            else => SO.undef,
        };
    }

    /// init_deferred_pred_opt ::= INITIALLY DEFERRED | INITIALLY
    /// IMMEDIATE | .
    fn initDeferred(s: *Parser) Error!bool {
        if (s.tk() != TK.INITIALLY) return false;
        _ = try s.advance();
        switch (s.tk()) {
            TK.DEFERRED => {
                _ = try s.advance();
                return true;
            },
            TK.IMMEDIATE => {
                _ = try s.advance();
                return false;
            },
            else => return s.fail(),
        }
    }

    /// refargs ::= refarg*: the ON DELETE and ON UPDATE actions, packed
    /// as parse.y does.
    fn refargs(s: *Parser) Error!i32 {
        var actions: i32 = @as(i32, OE.None.int()) * 0x0101;
        while (true) {
            var value: i32 = 0;
            var mask: i32 = 0;
            switch (s.tk()) {
                TK.MATCH => {
                    _ = try s.advance();
                    _ = try s.nm();
                },
                TK.ON => {
                    _ = try s.advance();
                    switch (s.tk()) {
                        TK.INSERT => {
                            _ = try s.advance();
                            _ = try s.refact();
                        },
                        TK.DELETE => {
                            _ = try s.advance();
                            value = try s.refact();
                            mask = 0x0000ff;
                        },
                        TK.UPDATE => {
                            _ = try s.advance();
                            value = (try s.refact()) << 8;
                            mask = 0x00ff00;
                        },
                        else => return s.fail(),
                    }
                },
                else => return actions,
            }
            actions = (actions & ~mask) | value;
        }
    }

    /// refact ::= SET NULL | SET DEFAULT | CASCADE | RESTRICT | NO ACTION.
    fn refact(s: *Parser) Error!i32 {
        switch (s.tk()) {
            TK.SET => {
                _ = try s.advance();
                switch (s.tk()) {
                    TK.NULL => {
                        _ = try s.advance();
                        return OE.SetNull.int();
                    },
                    TK.DEFAULT => {
                        _ = try s.advance();
                        return OE.SetDflt.int();
                    },
                    else => return s.fail(),
                }
            },
            TK.CASCADE => {
                _ = try s.advance();
                return OE.Cascade.int();
            },
            TK.RESTRICT => {
                _ = try s.advance();
                return OE.Restrict.int();
            },
            TK.NO => {
                _ = try s.advance();
                _ = try s.expect(TK.ACTION);
                return OE.None.int();
            },
            else => return s.fail(),
        }
    }

    /// eidlist_opt ::= LP eidlist RP | .
    fn eidlistOpt(s: *Parser) Error!?*ExprList {
        if (s.tk() != TK.LP) return null;
        _ = try s.advance();
        const list = try s.eidlist();
        _ = try s.expect(TK.RP);
        return list;
    }

    /// eidlist ::= nm collate sortorder (COMMA nm collate sortorder)*.
    fn eidlist(s: *Parser) Error!?*ExprList {
        var list: ?*ExprList = null;
        while (true) {
            const name = try s.nm();
            var has_collate = false;
            if (s.tk() == TK.COLLATE) {
                _ = try s.advance();
                if (!isIds(s.tk())) return s.fail();
                _ = try s.advance();
                has_collate = true;
            }
            const order = try s.sortorder();
            list = try ir.list.addIdTerm(s.p, list, name, has_collate, order);
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }

    /// conslist ::= tcons (COMMA? tcons)*, after the COMMA that ends the
    /// columns.
    fn tableConstraints(s: *Parser) Error!void {
        const p = s.p;
        while (true) {
            try s.tableConstraint();
            if (s.tk() == TK.COMMA) {
                _ = try s.advance();
                // tconscomma ::= COMMA.
                p.u1.cr.constraint_name.n = 0;
                if (!startsTableConstraint(s.tk())) return s.fail();
            } else if (!startsTableConstraint(s.tk())) {
                return;
            }
        }
    }

    fn tableConstraint(s: *Parser) Error!void {
        const p = s.p;
        switch (s.tk()) {
            TK.CONSTRAINT => {
                _ = try s.advance();
                p.u1.cr.constraint_name = try s.nm();
            },
            TK.PRIMARY => {
                _ = try s.advance();
                _ = try s.expect(TK.KEY);
                _ = try s.expect(TK.LP);
                const cols = try s.sortlist();
                const autoinc = try s.eat(TK.AUTOINCR) != null;
                _ = try s.expect(TK.RP);
                const on_error = try s.onconf();
                ir.ddl.addPrimaryKey(p, cols, on_error, autoinc, 0);
            },
            TK.UNIQUE => {
                _ = try s.advance();
                _ = try s.expect(TK.LP);
                const cols = try s.sortlist();
                _ = try s.expect(TK.RP);
                const on_error = try s.onconf();
                ir.ddl.createIndex(p, null, null, null, cols, on_error, null, null, 0, false, .unique);
            },
            TK.CHECK => {
                _ = try s.advance();
                const lp = s.token(try s.expect(TK.LP));
                const e = try s.expr();
                const rp = s.token(try s.expect(TK.RP));
                _ = try s.onconf();
                ir.ddl.addCheckConstraint(p, e, lp.z, rp.z);
            },
            TK.FOREIGN => {
                _ = try s.advance();
                _ = try s.expect(TK.KEY);
                _ = try s.expect(TK.LP);
                const from = try s.eidlist();
                _ = try s.expect(TK.RP);
                _ = try s.expect(TK.REFERENCES);
                const table = try s.nm();
                const to = try s.eidlistOpt();
                const actions = try s.refargs();
                var deferrable = false;
                const deferred = switch (s.tk()) {
                    TK.NOT => blk: {
                        _ = try s.advance();
                        _ = try s.expect(TK.DEFERRABLE);
                        _ = try s.initDeferred();
                        break :blk false;
                    },
                    TK.DEFERRABLE => blk: {
                        _ = try s.advance();
                        deferrable = true;
                        break :blk try s.initDeferred();
                    },
                    else => false,
                };
                ir.ddl.createForeignKey(p, from, table, to, actions);
                if (deferrable) ir.ddl.deferrableForeignKey(p, deferred) else ir.ddl.deferForeignKey(p, deferred);
            },
            else => return s.fail(),
        }
    }

    fn createView(s: *Parser, create_tok: Token, temp: bool) Error!void {
        _ = try s.advance();
        const if_not_exists = try s.ifNotExists();
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        const cols = try s.eidlistOpt();
        _ = try s.expect(TK.AS);
        const sel = try s.select();
        ir.ddl.createView(s.p, create_tok, name1, name2, cols, sel, temp, if_not_exists);
    }

    fn createIndex(s: *Parser, create_tok: Token) Error!void {
        const p = s.p;
        var on_error: OE = .None;
        if (s.tk() == TK.UNIQUE) {
            _ = try s.advance();
            on_error = .Abort;
        }
        _ = try s.expect(TK.INDEX);
        const if_not_exists = try s.ifNotExists();
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        _ = try s.expect(TK.ON);
        const table = try s.nm();
        _ = try s.expect(TK.LP);
        const cols = try s.sortlist();
        _ = try s.expect(TK.RP);
        const where = try s.whereOpt();
        const tbl = try ir.from.append(p, null, table, null);
        ir.ddl.createIndex(p, name1, name2, tbl, cols, on_error, create_tok, where, SO.asc, if_not_exists, .appdef);
        if (p.inRenameObject()) if (p.new_index) |idx| ir.ddl.renameTokenMap(p, idx.name.ptr, table);
    }

    fn createVtab(s: *Parser) Error!void {
        const p = s.p;
        _ = try s.advance();
        _ = try s.expect(TK.TABLE);
        const if_not_exists = try s.ifNotExists();
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        _ = try s.expect(TK.USING);
        const module = try s.nm();
        ir.ddl.beginVtab(p, name1, name2, module, if_not_exists);
        if (s.tk() != TK.LP) {
            ir.ddl.finishVtab(p, null);
            return;
        }
        // The arguments: any tokens (lemon's %wildcard ANY, the end of
        // the text but token 0 included), parentheses balanced, split
        // at the commas outside them.
        _ = try s.advance();
        while (true) {
            // vtabarg ::= .
            ir.ddl.vtabArgInit(p);
            while (s.tk() != TK.COMMA and s.tk() != TK.RP) {
                if (s.tk() == 0) return s.fail();
                const t = try s.advance();
                // vtabargtoken ::= ANY, lp ::= LP.
                ir.ddl.vtabArgExtend(p, s.token(t));
                if (t.tk == TK.LP) {
                    try s.anylist();
                    // vtabargtoken ::= lp anylist RP.
                    ir.ddl.vtabArgExtend(p, s.token(try s.expect(TK.RP)));
                }
            }
            if (s.tk() == TK.RP) break;
            _ = try s.advance();
        }
        const rp = try s.advance();
        ir.ddl.finishVtab(p, s.token(rp));
    }

    /// anylist ::= (LP anylist RP | ANY)*: what is inside the parentheses
    /// of a virtual table argument.
    fn anylist(s: *Parser) Error!void {
        while (true) {
            switch (s.tk()) {
                TK.RP => return,
                0 => return s.fail(),
                TK.LP => {
                    _ = try s.advanceDeep(2);
                    try s.anylist();
                    _ = try s.expect(TK.RP);
                    s.pop(2);
                },
                else => _ = try s.advance(),
            }
        }
    }

    // -------------------------------------------------------- triggers

    fn createTrigger(s: *Parser, temp: bool) Error!void {
        const p = s.p;
        _ = try s.advance();
        const if_not_exists = try s.ifNotExists();
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        const time: i32 = switch (s.tk()) {
            TK.BEFORE, TK.AFTER => (try s.advance()).tk,
            TK.INSTEAD => blk: {
                _ = try s.advance();
                _ = try s.expect(TK.OF);
                break :blk TK.INSTEAD;
            },
            else => TK.BEFORE,
        };
        var event: i32 = undefined;
        var columns: ?*IdList = null;
        switch (s.tk()) {
            TK.DELETE, TK.INSERT => event = (try s.advance()).tk,
            TK.UPDATE => {
                event = (try s.advance()).tk;
                if (s.tk() == TK.OF) {
                    _ = try s.advance();
                    columns = try s.idlist();
                }
            },
            else => return s.fail(),
        }
        _ = try s.expect(TK.ON);
        const table = try s.fullname();
        if (s.tk() == TK.FOR) {
            _ = try s.advance();
            _ = try s.expect(TK.EACH);
            _ = try s.expect(TK.ROW);
        }
        var when: ?*Expr = null;
        if (s.tk() == TK.WHEN) {
            _ = try s.advance();
            when = try s.expr();
        }
        ir.ddl.beginTrigger(p, name1, name2, time, event, columns, table, when, temp, if_not_exists);
        // trigger_decl's value: the name the text of the trigger starts at.
        const first = if (name2.n == 0) name1 else name2;
        p.is_create = false;
        _ = try s.expect(TK.BEGIN);
        var steps: ?*TriggerStep = null;
        var first_step = true;
        while (true) {
            const step = try s.triggerCmd();
            _ = try s.expect(TK.SEMI);
            if (first_step) {
                // trigger_cmd_list ::= trigger_cmd SEMI.
                if (step) |t| t.last = t;
                steps = step;
                first_step = false;
            } else if (steps) |list| {
                // trigger_cmd_list ::= trigger_cmd_list trigger_cmd SEMI.
                list.last.?.next = step;
                list.last = step;
            }
            if (s.tk() == TK.END) break;
        }
        const end = s.token(try s.advance());
        const all: Token = .{ .z = first.z, .n = spanLen(first, end) };
        ir.ddl.finishTrigger(p, steps, all);
    }

    /// trigger_cmd: an UPDATE, INSERT, DELETE or SELECT of a trigger's
    /// body, with the text it spans.
    fn triggerCmd(s: *Parser) Error!?*TriggerStep {
        const p = s.p;
        switch (s.tk()) {
            TK.UPDATE => {
                const text_start = s.scanpt();
                _ = try s.advance();
                const on_error = try s.orconf();
                const table = try s.xfullname();
                try s.tridxby();
                _ = try s.expect(TK.SET);
                const set = try s.setlist();
                const from = try s.fromClause();
                const where = try s.whereOpt();
                const end = s.scanpt();
                const t = table orelse return null;
                return ir.ddl.triggerUpdateStep(p, t, from, set, where, on_error, text_start, end);
            },
            TK.INSERT, TK.REPLACE => {
                const text_start = s.scanpt();
                const on_error = try s.insertCmd();
                _ = try s.expect(TK.INTO);
                const table = try s.xfullname();
                const cols = try s.idlistOpt();
                const sel = try s.select();
                const up = try s.upsert();
                const end = s.scanpt();
                const t = table orelse return null;
                return ir.ddl.triggerInsertStep(p, t, cols, sel, on_error, up, text_start, end);
            },
            TK.DELETE => {
                const text_start = s.scanpt();
                _ = try s.advance();
                _ = try s.expect(TK.FROM);
                const table = try s.xfullname();
                try s.tridxby();
                const where = try s.whereOpt();
                const end = s.scanpt();
                const t = table orelse return null;
                return ir.ddl.triggerDeleteStep(p, t, where, text_start, end);
            },
            TK.SELECT, TK.VALUES, TK.WITH => {
                const text_start = s.scanpt();
                const sel = try s.select();
                const end = s.scanpt();
                return ir.ddl.triggerSelectStep(p, sel, text_start, end);
            },
            else => return s.fail(),
        }
    }

    /// tridxby ::= INDEXED BY nm | NOT INDEXED | . (an error in a
    /// trigger).
    fn tridxby(s: *Parser) Error!void {
        switch (s.tk()) {
            TK.INDEXED => {
                _ = try s.advance();
                _ = try s.expect(TK.BY);
                _ = try s.nm();
                ir.stmt.errorMsg(s.p, "the INDEXED BY clause is not allowed on UPDATE or DELETE statements within triggers", .{});
            },
            TK.NOT => {
                _ = try s.advance();
                _ = try s.expect(TK.INDEXED);
                ir.stmt.errorMsg(s.p, "the NOT INDEXED clause is not allowed on UPDATE or DELETE statements within triggers", .{});
            },
            else => {},
        }
    }

    // ------------------------------------------------------------- DML

    /// insert_cmd ::= INSERT orconf | REPLACE.
    fn insertCmd(s: *Parser) Error!OE {
        if ((try s.advance()).tk == TK.REPLACE) return .Replace;
        return s.orconf();
    }

    /// [with] DELETE FROM xfullname indexed_opt where_opt_ret.
    fn delete(s: *Parser) Error!void {
        _ = try s.advance();
        _ = try s.expect(TK.FROM);
        const table = try s.xfullname();
        const indexed = try s.indexedOpt();
        const where = try s.whereOptRet();
        try ir.from.indexedBy(s.p, table, indexed);
        ir.dml.delete(s.p, table, where, null, null);
    }

    /// [with] UPDATE orconf xfullname indexed_opt SET setlist from
    /// where_opt_ret.
    fn update(s: *Parser) Error!void {
        _ = try s.advance();
        const on_error = try s.orconf();
        const table = try s.xfullname();
        const indexed = try s.indexedOpt();
        _ = try s.expect(TK.SET);
        const set = try s.setlist();
        const from = try s.fromClause();
        const where = try s.whereOptRet();
        try ir.from.indexedBy(s.p, table, indexed);
        try ir.dml.updateFrom(s.p, table, set, from, where, on_error);
    }

    /// [with] insert_cmd INTO xfullname idlist_opt (select upsert |
    /// DEFAULT VALUES returning).
    fn insert(s: *Parser) Error!void {
        const p = s.p;
        const on_error = try s.insertCmd();
        _ = try s.expect(TK.INTO);
        const table = try s.xfullname();
        const cols = try s.idlistOpt();
        if (s.tk() == TK.DEFAULT) {
            _ = try s.advance();
            _ = try s.expect(TK.VALUES);
            try s.returning();
            ir.dml.insert(p, table, null, cols, on_error, null);
            return;
        }
        if (!startsSelect(s.tk())) return s.fail();
        const sel = try s.select();
        const up = try s.upsert();
        ir.dml.insert(p, table, sel, cols, on_error, up);
    }

    /// upsert: ON CONFLICT clauses, or RETURNING, or nothing. The clauses
    /// nest to the right, so the last is built first.
    fn upsert(s: *Parser) Error!?*Upsert {
        const p = s.p;
        switch (s.tk()) {
            TK.RETURNING => {
                _ = try s.advance();
                const list = try s.selcollist();
                ir.dml.addReturning(p, list);
                return null;
            },
            TK.ON => {},
            else => return null,
        }
        _ = try s.advanceDeep(10);
        defer s.pop(10);
        _ = try s.expect(TK.CONFLICT);
        if (s.tk() == TK.LP) {
            _ = try s.advance();
            const target = try s.sortlist();
            _ = try s.expect(TK.RP);
            const target_where = try s.whereOpt();
            _ = try s.expect(TK.DO);
            switch (s.tk()) {
                TK.UPDATE => {
                    _ = try s.advance();
                    _ = try s.expect(TK.SET);
                    const set = try s.setlist();
                    const where = try s.whereOpt();
                    const next = try s.upsert();
                    return try ir.dml.upsertNew(p, target, target_where, set, where, next);
                },
                TK.NOTHING => {
                    _ = try s.advance();
                    const next = try s.upsert();
                    return try ir.dml.upsertNew(p, target, target_where, null, null, next);
                },
                else => return s.fail(),
            }
        }
        _ = try s.expect(TK.DO);
        switch (s.tk()) {
            TK.NOTHING => {
                _ = try s.advance();
                try s.returning();
                return try ir.dml.upsertNew(p, null, null, null, null, null);
            },
            TK.UPDATE => {
                _ = try s.advance();
                _ = try s.expect(TK.SET);
                const set = try s.setlist();
                const where = try s.whereOpt();
                try s.returning();
                return try ir.dml.upsertNew(p, null, null, set, where, null);
            },
            else => return s.fail(),
        }
    }

    /// returning ::= RETURNING selcollist | .
    fn returning(s: *Parser) Error!void {
        if (s.tk() != TK.RETURNING) return;
        _ = try s.advance();
        const list = try s.selcollist();
        ir.dml.addReturning(s.p, list);
    }

    /// where_opt_ret ::= [WHERE expr] [RETURNING selcollist].
    fn whereOptRet(s: *Parser) Error!?*Expr {
        var where: ?*Expr = null;
        if (s.tk() == TK.WHERE) {
            _ = try s.advance();
            where = try s.expr();
        }
        try s.returning();
        return where;
    }

    /// where_opt ::= WHERE expr | .
    fn whereOpt(s: *Parser) Error!?*Expr {
        if (s.tk() != TK.WHERE) return null;
        _ = try s.advance();
        return s.expr();
    }

    /// indexed_opt ::= INDEXED BY nm | NOT INDEXED | . (NOT INDEXED is a
    /// token with no text and length 1).
    fn indexedOpt(s: *Parser) Error!Token {
        switch (s.tk()) {
            TK.INDEXED => {
                _ = try s.advance();
                _ = try s.expect(TK.BY);
                return s.nm();
            },
            TK.NOT => {
                _ = try s.advance();
                _ = try s.expect(TK.INDEXED);
                return .{ .z = null, .n = 1 };
            },
            else => return .{},
        }
    }

    /// setlist: (nm | LP idlist RP) EQ expr, comma separated.
    fn setlist(s: *Parser) Error!?*ExprList {
        const p = s.p;
        var list: ?*ExprList = null;
        while (true) {
            if (s.tk() == TK.LP) {
                _ = try s.advance();
                const cols = try s.idlist();
                _ = try s.expect(TK.RP);
                _ = try s.expect(TK.EQ);
                const e = try s.expr();
                list = try ir.list.appendVector(p, list, cols, e);
            } else {
                const name = try s.nm();
                _ = try s.expect(TK.EQ);
                const e = try s.expr();
                list = try ir.list.append(p, list, e);
                try ir.list.setName(p, list, name, true);
            }
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }

    /// idlist_opt ::= LP idlist RP | .
    fn idlistOpt(s: *Parser) Error!?*IdList {
        if (s.tk() != TK.LP) return null;
        _ = try s.advance();
        const list = try s.idlist();
        _ = try s.expect(TK.RP);
        return list;
    }

    /// idlist ::= nm (COMMA nm)*.
    fn idlist(s: *Parser) Error!?*IdList {
        var list: ?*IdList = null;
        while (true) {
            const name = try s.nm();
            list = try ir.list.idAppend(s.p, list, name);
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }

    // ---------------------------------------------------------- SELECT

    /// with ::= WITH [RECURSIVE] wqlist: the common table expressions.
    fn withClause(s: *Parser) Error!?*With {
        const p = s.p;
        _ = try s.advance();
        _ = try s.eat(TK.RECURSIVE);
        var w: ?*With = null;
        while (true) {
            const name = try s.nm();
            // withnm ::= nm.
            p.has_with = true;
            const cols = try s.eidlistOpt();
            _ = try s.expect(TK.AS);
            var m: int.M10d = .any;
            switch (s.tk()) {
                TK.MATERIALIZED => {
                    _ = try s.advance();
                    m = .yes;
                },
                TK.NOT => {
                    _ = try s.advance();
                    _ = try s.expect(TK.MATERIALIZED);
                    m = .no;
                },
                else => {},
            }
            _ = try s.expectDeep(TK.LP, 1);
            const sel = try s.select();
            _ = try s.expect(TK.RP);
            s.pop(1);
            const cte = try ir.with.cte(p, name, cols, sel, m);
            w = try ir.with.add(p, w, cte);
            if (s.tk() != TK.COMMA) return w;
            _ = try s.advance();
        }
    }

    /// select ::= [WITH [RECURSIVE] wqlist] selectnowith.
    fn select(s: *Parser) Error!?*Select {
        const p = s.p;
        if (s.tk() == TK.WITH) {
            const w = try s.withClause();
            const body = try s.selectNoWith();
            return ir.select.attachWith(p, body, w);
        }
        const sel = try s.selectNoWith();
        if (sel) |x| ir.select.doubleLink(p, x);
        return sel;
    }

    /// selectnowith ::= oneselect (multiselect_op oneselect)*.
    fn selectNoWith(s: *Parser) Error!?*Select {
        var lhs = try s.oneSelect();
        while (true) {
            const op: i32 = switch (s.tk()) {
                TK.UNION => blk: {
                    _ = try s.advance();
                    if (s.tk() == TK.ALL) {
                        _ = try s.advance();
                        break :blk TK.ALL;
                    }
                    break :blk TK.UNION;
                },
                TK.EXCEPT, TK.INTERSECT => (try s.advance()).tk,
                else => return lhs,
            };
            const rhs = try s.oneSelect();
            lhs = try ir.select.compound(s.p, lhs, op, rhs);
        }
    }

    /// oneselect: SELECT ... or VALUES rows.
    fn oneSelect(s: *Parser) Error!?*Select {
        const p = s.p;
        switch (s.tk()) {
            TK.SELECT => {},
            TK.VALUES => return s.values(),
            else => return s.fail(),
        }
        // SELECT distinct sclp scanpt.
        _ = try s.advanceDeep(4);
        defer s.pop(4);
        const flags = try s.distinct();
        const cols = try s.selcollist();
        const from = try s.fromClause();
        const where = try s.whereOpt();
        var group: ?*ExprList = null;
        if (s.tk() == TK.GROUP) {
            _ = try s.advance();
            _ = try s.expect(TK.BY);
            group = try s.nexprlist();
        }
        var having: ?*Expr = null;
        if (s.tk() == TK.HAVING) {
            _ = try s.advance();
            having = try s.expr();
        }
        var windows: ?*Window = null;
        const has_window = s.tk() == TK.WINDOW;
        if (has_window) windows = try s.windowClause();
        const order = try s.orderbyOpt();
        const limit = try s.limitOpt();
        const sel = try ir.select.new(p, cols, from, where, group, having, order, flags, limit);
        if (has_window) sel.win_defn = windows;
        return sel;
    }

    /// values ::= VALUES LP nexprlist RP, then mvalues: COMMA LP
    /// nexprlist RP rows.
    fn values(s: *Parser) Error!?*Select {
        const p = s.p;
        _ = try s.advance();
        _ = try s.expect(TK.LP);
        var row = try s.nexprlist();
        _ = try s.expect(TK.RP);
        var sel = try ir.select.values(p, row);
        if (s.tk() != TK.COMMA) return sel;
        while (s.tk() == TK.COMMA) {
            _ = try s.advance();
            _ = try s.expect(TK.LP);
            row = try s.nexprlist();
            _ = try s.expect(TK.RP);
            sel = try ir.select.multiValues(p, sel, row);
        }
        // oneselect ::= mvalues.
        ir.select.multiValuesEnd(p, sel);
        return sel;
    }

    /// distinct ::= DISTINCT | ALL | .
    fn distinct(s: *Parser) Error!SF {
        switch (s.tk()) {
            TK.DISTINCT => {
                _ = try s.advance();
                return .{ .Distinct = true };
            },
            TK.ALL => {
                _ = try s.advance();
                return .{ .All = true };
            },
            else => return .{},
        }
    }

    /// selcollist: result columns, comma separated: expr [as], STAR,
    /// nm DOT STAR.
    fn selcollist(s: *Parser) Error!?*ExprList {
        const p = s.p;
        var list: ?*ExprList = null;
        while (true) {
            const text_start = s.scanpt();
            if (s.tk() == TK.STAR) {
                list = try ir.list.star(p, list, s.token(try s.advance()));
            } else if (isExprNm(s.tk()) and s.at(1).tk == TK.DOT and s.at(2).tk == TK.STAR) {
                const table = s.token(try s.advance());
                _ = try s.advance();
                list = try ir.list.tableStar(p, list, table, s.token(try s.advance()));
            } else {
                const e = try s.expr();
                const end = s.scanpt();
                var alias: Token = .{};
                if (s.tk() == TK.AS) {
                    _ = try s.advance();
                    alias = try s.nm();
                } else if (isIds(s.tk())) {
                    alias = s.token(try s.advance());
                }
                list = try ir.list.resultColumn(p, list, e, alias, text_start, end);
            }
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }

    /// from ::= FROM seltablist | .
    fn fromClause(s: *Parser) Error!?*SrcList {
        if (s.tk() != TK.FROM) return null;
        _ = try s.advance();
        const list = try s.seltablist();
        ir.from.shiftJoinType(list);
        return list;
    }

    /// seltablist: FROM terms joined by joinop.
    fn seltablist(s: *Parser) Error!?*SrcList {
        const p = s.p;
        var list: ?*SrcList = null;
        while (true) {
            list = try s.fromTerm(list);
            const jt: JT = switch (s.tk()) {
                TK.COMMA, TK.JOIN => blk: {
                    _ = try s.advance();
                    break :blk .{ .INNER = true };
                },
                TK.JOIN_KW => blk: {
                    const a = s.token(try s.advance());
                    if (s.tk() == TK.JOIN) {
                        _ = try s.advance();
                        break :blk ir.from.joinType(p, a, null, null);
                    }
                    const b = try s.nm();
                    if (s.tk() == TK.JOIN) {
                        _ = try s.advance();
                        break :blk ir.from.joinType(p, a, b, null);
                    }
                    const c = try s.nm();
                    _ = try s.expect(TK.JOIN);
                    break :blk ir.from.joinType(p, a, b, c);
                },
                else => return list,
            };
            // stl_prefix ::= seltablist joinop.
            if (list) |l| if (l.len() > 0) {
                l.at(l.len() - 1).fg.jointype = jt;
            };
        }
    }

    /// One term of a FROM clause, appended to `prefix` (stl_prefix).
    fn fromTerm(s: *Parser, prefix: ?*SrcList) Error!?*SrcList {
        const p = s.p;
        if (s.tk() == TK.LP) {
            _ = try s.advanceDeep(2);
            defer s.pop(2);
            if (startsSelect(s.tk())) {
                const sel = try s.select();
                _ = try s.expect(TK.RP);
                const alias = try s.asOpt();
                var on_using = try s.onUsing();
                return ir.from.appendTerm(p, prefix, null, null, alias, sel, &on_using);
            }
            const inner = try s.seltablist();
            _ = try s.expect(TK.RP);
            const alias = try s.asOpt();
            var on_using = try s.onUsing();
            return ir.from.nested(p, prefix, inner, alias, &on_using);
        }
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        if (s.tk() == TK.LP) {
            _ = try s.advanceDeep(1);
            const args = try s.exprlist();
            _ = try s.expect(TK.RP);
            s.pop(1);
            const alias = try s.asOpt();
            var on_using = try s.onUsing();
            const list = try ir.from.appendTerm(p, prefix, name1, name2, alias, null, &on_using);
            ir.from.funcArgs(list, args);
            return list;
        }
        const alias = try s.asOpt();
        const indexed: ?Token = switch (s.tk()) {
            TK.INDEXED, TK.NOT => try s.indexedOpt(),
            else => null,
        };
        var on_using = try s.onUsing();
        const list = try ir.from.appendTerm(p, prefix, name1, name2, alias, null, &on_using);
        if (indexed) |i| try ir.from.indexedBy(p, list, i);
        return list;
    }

    /// as ::= AS nm | ids | .
    fn asOpt(s: *Parser) Error!Token {
        if (s.tk() == TK.AS) {
            _ = try s.advance();
            return s.nm();
        }
        if (isIds(s.tk())) return s.token(try s.advance());
        return .{};
    }

    /// on_using ::= ON expr | USING LP idlist RP | .
    fn onUsing(s: *Parser) Error!OnOrUsing {
        switch (s.tk()) {
            TK.ON => {
                _ = try s.advance();
                return .{ .on = try s.expr(), .using = null };
            },
            TK.USING => {
                _ = try s.advance();
                _ = try s.expect(TK.LP);
                const list = try s.idlist();
                _ = try s.expect(TK.RP);
                return .{ .on = null, .using = list };
            },
            else => return .{},
        }
    }

    /// orderby_opt ::= ORDER BY sortlist | .
    fn orderbyOpt(s: *Parser) Error!?*ExprList {
        if (s.tk() != TK.ORDER) return null;
        _ = try s.advance();
        _ = try s.expect(TK.BY);
        return s.sortlist();
    }

    /// sortlist ::= expr sortorder nulls (COMMA expr sortorder nulls)*.
    fn sortlist(s: *Parser) Error!?*ExprList {
        var list: ?*ExprList = null;
        while (true) {
            const e = try s.expr();
            const order = try s.sortorder();
            var nulls: i32 = SO.undef;
            if (s.tk() == TK.NULLS) {
                _ = try s.advance();
                switch (s.tk()) {
                    TK.FIRST => nulls = SO.asc,
                    TK.LAST => nulls = SO.desc,
                    else => return s.fail(),
                }
                _ = try s.advance();
            }
            list = try ir.list.append(s.p, list, e);
            ir.list.setSortOrder(list, order, nulls);
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }

    /// limit_opt ::= LIMIT expr [OFFSET expr | COMMA expr] | .
    fn limitOpt(s: *Parser) Error!?*Expr {
        if (s.tk() != TK.LIMIT) return null;
        _ = try s.advance();
        const a = try s.expr();
        switch (s.tk()) {
            TK.OFFSET => {
                _ = try s.advance();
                const b = try s.expr();
                return try ir.expr.binary(s.p, TK.LIMIT, a, b);
            },
            TK.COMMA => {
                _ = try s.advance();
                const b = try s.expr();
                return try ir.expr.binary(s.p, TK.LIMIT, b, a);
            },
            else => return try ir.expr.binary(s.p, TK.LIMIT, a, null),
        }
    }

    // ---------------------------------------------------------- windows

    /// window_clause ::= WINDOW windowdefn (COMMA windowdefn)*.
    fn windowClause(s: *Parser) Error!?*Window {
        _ = try s.advance();
        var list: ?*Window = null;
        while (true) {
            const name = try s.nm();
            _ = try s.expect(TK.AS);
            _ = try s.expectDeep(TK.LP, 2);
            const w = try s.window();
            _ = try s.expect(TK.RP);
            s.pop(2);
            // windowdefn ::= nm AS LP window RP.
            if (w) |x| x.name = try s.p.arena.dupeSentinel(u8, name.slice(), 0);
            if (list) |prev| {
                // windowdefn_list ::= windowdefn_list COMMA windowdefn.
                const x = w.?;
                try ir.window.chain(s.p, x, prev);
                x.next_win = prev;
            }
            list = w;
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }

    /// window: [nm] [PARTITION BY nexprlist] [ORDER BY sortlist]
    /// frame_opt, inside the parentheses.
    fn window(s: *Parser) Error!?*Window {
        const p = s.p;
        var base: ?Token = null;
        switch (s.tk()) {
            TK.PARTITION, TK.ORDER, TK.RANGE, TK.ROWS, TK.GROUPS => {},
            else => if (isNm(s.tk())) {
                base = s.token(try s.advance());
            },
        }
        switch (s.tk()) {
            TK.PARTITION => {
                _ = try s.advance();
                _ = try s.expect(TK.BY);
                const part = try s.nexprlist();
                const order = try s.orderbyOpt();
                const frame = try s.frameOpt();
                return ir.window.assemble(p, frame, part, order, base);
            },
            TK.ORDER => {
                _ = try s.advance();
                _ = try s.expect(TK.BY);
                const order = try s.sortlist();
                const frame = try s.frameOpt();
                return ir.window.assemble(p, frame, null, order, base);
            },
            else => {
                const frame = try s.frameOpt();
                if (base == null) return frame;
                return ir.window.assemble(p, frame, null, null, base);
            },
        }
    }

    /// frame_opt ::= range_or_rows frame_bound_s frame_exclude_opt |
    /// range_or_rows BETWEEN frame_bound_s AND frame_bound_e
    /// frame_exclude_opt | .
    fn frameOpt(s: *Parser) Error!?*Window {
        const p = s.p;
        switch (s.tk()) {
            TK.RANGE, TK.ROWS, TK.GROUPS => {},
            else => return ir.window.alloc(p, 0, TK.UNBOUNDED, null, TK.CURRENT, null, 0),
        }
        const kind: i32 = (try s.advance()).tk;
        if (s.tk() == TK.BETWEEN) {
            _ = try s.advance();
            const lo = try s.frameBound(true);
            _ = try s.expect(TK.AND);
            const hi = try s.frameBound(false);
            const exclude = try s.frameExclude();
            return ir.window.alloc(p, kind, lo.e_type, lo.expr, hi.e_type, hi.expr, exclude);
        }
        const lo = try s.frameBound(true);
        const exclude = try s.frameExclude();
        return ir.window.alloc(p, kind, lo.e_type, lo.expr, TK.CURRENT, null, exclude);
    }

    /// frame_bound_s (`starting`: UNBOUNDED PRECEDING) or frame_bound_e
    /// (UNBOUNDED FOLLOWING), or frame_bound: expr PRECEDING|FOLLOWING,
    /// CURRENT ROW.
    fn frameBound(s: *Parser, starting: bool) Error!FrameBound {
        switch (s.tk()) {
            TK.UNBOUNDED => {
                _ = try s.advance();
                _ = try s.expect(if (starting) TK.PRECEDING else TK.FOLLOWING);
                return .{ .e_type = TK.UNBOUNDED };
            },
            TK.CURRENT => {
                _ = try s.advance();
                _ = try s.expect(TK.ROW);
                return .{ .e_type = TK.CURRENT };
            },
            else => {
                const e = try s.expr();
                switch (s.tk()) {
                    TK.PRECEDING, TK.FOLLOWING => return .{ .e_type = (try s.advance()).tk, .expr = e },
                    else => return s.fail(),
                }
            },
        }
    }

    /// frame_exclude_opt ::= EXCLUDE (NO OTHERS | CURRENT ROW | GROUP |
    /// TIES) | .
    fn frameExclude(s: *Parser) Error!u8 {
        if (s.tk() != TK.EXCLUDE) return 0;
        _ = try s.advance();
        switch (s.tk()) {
            TK.NO => {
                _ = try s.advance();
                _ = try s.expect(TK.OTHERS);
                return TK.NO;
            },
            TK.CURRENT => {
                _ = try s.advance();
                _ = try s.expect(TK.ROW);
                return TK.CURRENT;
            },
            TK.GROUP, TK.TIES => return (try s.advance()).tk,
            else => return s.fail(),
        }
    }

    /// filter_over: [FILTER LP WHERE expr RP] [OVER (LP window RP | nm)],
    /// at least one, after a function's arguments.
    fn filterOver(s: *Parser) Error!?*Window {
        const p = s.p;
        var filter: ?*Expr = null;
        const has_filter = s.tk() == TK.FILTER;
        if (has_filter) {
            _ = try s.advance();
            _ = try s.expect(TK.LP);
            _ = try s.expect(TK.WHERE);
            filter = try s.expr();
            _ = try s.expect(TK.RP);
        }
        if (s.tk() != TK.OVER) {
            // filter_over ::= filter_clause.
            const w = try p.arena.create(Window);
            w.* = .{ .e_frm_type = TK.FILTER, .filter = filter };
            return w;
        }
        _ = try s.advance();
        var w: ?*Window = undefined;
        if (s.tk() == TK.LP) {
            _ = try s.advanceDeep(2);
            w = try s.window();
            _ = try s.expect(TK.RP);
            s.pop(2);
        } else {
            const name = try s.nm();
            const x = try p.arena.create(Window);
            x.* = .{ .name = try p.arena.dupeSentinel(u8, name.slice(), 0) };
            w = x;
        }
        // filter_over ::= filter_clause over_clause.
        if (has_filter) if (w) |x| {
            x.filter = filter;
        };
        return w;
    }

    // ------------------------------------------------------ expressions

    /// expr: an expression, any operator.
    fn expr(s: *Parser) Error!?*Expr {
        return s.exprAbove(0);
    }

    /// An expression of the operators that bind the operand of a rule of
    /// precedence `min` (binds()).
    fn exprAbove(s: *Parser, min: u8) Error!?*Expr {
        var lhs = try s.operand();
        while (true) {
            const l = level(s.tk());
            if (l == 0 or !binds(l, min)) return lhs;
            lhs = try s.infix(lhs);
        }
    }

    /// The middle operand of BETWEEN: an expression of any operator, but
    /// an AND that is not inside one of its operands ends it (lemon shifts
    /// that AND for the BETWEEN, and an AND inside the right side of an OR
    /// for the AND: `x BETWEEN a OR b AND c AND d`).
    fn exprBetween(s: *Parser) Error!?*Expr {
        var lhs = try s.operand();
        while (true) {
            const code = s.tk();
            if (code == TK.AND or level(code) == 0) return lhs;
            lhs = try s.infix(lhs);
        }
    }

    // The functions on the way of nested expressions (exprAbove(),
    // operand(), infix(), prefix(), parenthesized()) keep small frames,
    // what else they do is out of line: the nesting lemon allows
    // (SQLITE_LIMIT_PARSER_DEPTH) takes that many frames of them.

    /// The operator being fed applied to `lhs`.
    fn infix(s: *Parser, lhs: ?*Expr) Error!?*Expr {
        const op = s.tk();
        switch (op) {
            TK.AND, TK.OR, TK.LT, TK.GT, TK.GE, TK.LE, TK.EQ, TK.NE, TK.BITAND, TK.BITOR, TK.LSHIFT, TK.RSHIFT, TK.PLUS, TK.MINUS, TK.STAR, TK.SLASH, TK.REM, TK.CONCAT => {
                _ = try s.advanceDeep(2);
                const rhs = try s.exprAbove(level(op));
                s.pop(2);
                return s.binaryNode(op, lhs, rhs);
            },
            TK.LIKE_KW, TK.MATCH => return s.like(lhs, false),
            TK.BETWEEN => return s.between(lhs, false),
            TK.IN => return s.in(lhs, false),
            else => return s.infixOther(lhs),
        }
    }

    noinline fn binaryNode(s: *Parser, op: u8, lhs: ?*Expr, rhs: ?*Expr) Error!?*Expr {
        if (op == TK.AND) return try ir.expr.@"and"(s.p, lhs, rhs);
        return try ir.expr.binary(s.p, op, lhs, rhs);
    }

    /// The operators but the binary ones of infix().
    noinline fn infixOther(s: *Parser, lhs: ?*Expr) Error!?*Expr {
        const p = s.p;
        const op = s.peek();
        switch (op.tk) {
            TK.PTR => {
                _ = try s.advanceDeep(2);
                defer s.pop(2);
                const rhs = try s.exprAbove(level(TK.PTR));
                var list = try ir.list.append(p, null, lhs);
                list = try ir.list.append(p, list, rhs);
                return try ir.expr.function(p, list, s.token(op), .{});
            },
            TK.COLLATE => {
                _ = try s.advance();
                if (!isIds(s.tk())) return s.fail();
                const name = s.token(try s.advance());
                return try ir.expr.collate(p, lhs.?, name, true);
            },
            TK.ISNULL, TK.NOTNULL => {
                _ = try s.advance();
                return try ir.expr.isNull(p, op.tk, lhs.?);
            },
            TK.IS => {
                _ = try s.advanceDeep(2);
                defer s.pop(2);
                var code: u8 = TK.IS;
                if (s.tk() == TK.NOT) {
                    _ = try s.advance();
                    code = TK.ISNOT;
                }
                if (s.tk() == TK.DISTINCT) {
                    // IS [NOT] DISTINCT FROM: the opposite of IS [NOT].
                    _ = try s.advance();
                    _ = try s.expect(TK.FROM);
                    code = if (code == TK.IS) TK.ISNOT else TK.IS;
                }
                const rhs = try s.exprAbove(prec_is);
                return try ir.expr.is(p, code, lhs.?, rhs);
            },
            TK.NOT => {
                // NOT NULL, NOT LIKE, NOT BETWEEN, NOT IN.
                _ = try s.advance();
                switch (s.tk()) {
                    TK.NULL => {
                        _ = try s.advance();
                        return try ir.expr.isNull(p, TK.NOTNULL, lhs.?);
                    },
                    TK.LIKE_KW, TK.MATCH => return s.like(lhs, true),
                    TK.BETWEEN => return s.between(lhs, true),
                    TK.IN => return s.in(lhs, true),
                    else => return s.fail(),
                }
            },
            else => unreachable,
        }
    }

    /// expr likeop expr [ESCAPE expr], at LIKE_KW|MATCH.
    noinline fn like(s: *Parser, lhs: ?*Expr, not: bool) Error!?*Expr {
        const op = s.token(try s.advanceDeep(2));
        defer s.pop(2);
        const rhs = try s.exprAbove(level(TK.LIKE_KW));
        var escape: ?*Expr = null;
        if (s.tk() == TK.ESCAPE) {
            _ = try s.advanceDeep(2);
            escape = try s.exprAbove(level(TK.LIKE_KW));
            s.pop(2);
        }
        return try ir.expr.like(s.p, op, not, lhs, rhs, escape);
    }

    /// expr between_op expr AND expr, at BETWEEN.
    noinline fn between(s: *Parser, lhs: ?*Expr, not: bool) Error!?*Expr {
        _ = try s.advanceDeep(2);
        defer s.pop(2);
        const lo = try s.exprBetween();
        _ = try s.expectDeep(TK.AND, 2);
        const hi = try s.exprAbove(level(TK.BETWEEN));
        s.pop(2);
        return try ir.expr.between(s.p, lhs, not, lo, hi);
    }

    /// expr in_op (LP exprlist RP | LP select RP | nm dbnm
    /// paren_exprlist), at IN.
    noinline fn in(s: *Parser, lhs: ?*Expr, not: bool) Error!?*Expr {
        const p = s.p;
        _ = try s.advanceDeep(2);
        defer s.pop(2);
        if (s.tk() == TK.LP) {
            _ = try s.advanceDeep(1);
            defer s.pop(1);
            if (startsSelect(s.tk())) {
                const sel = try s.select();
                _ = try s.expect(TK.RP);
                return try ir.expr.inSelect(p, lhs, not, sel);
            }
            const list = try s.exprlist();
            _ = try s.expect(TK.RP);
            return try ir.expr.inList(p, lhs.?, not, list);
        }
        const name1 = try s.nm();
        const name2 = try s.dbnm();
        var args: ?*ExprList = null;
        if (s.tk() == TK.LP) {
            _ = try s.advanceDeep(1);
            args = try s.exprlist();
            _ = try s.expect(TK.RP);
            s.pop(1);
        }
        return try ir.expr.inTable(p, lhs, not, name1, name2, args);
    }

    /// An operand: a prefix operator and its operand, a parenthesized
    /// expression, or a primary expression.
    fn operand(s: *Parser) Error!?*Expr {
        switch (s.tk()) {
            TK.NOT, TK.BITNOT, TK.PLUS, TK.MINUS => {
                const op = s.tk();
                _ = try s.advanceDeep(1);
                const e = try s.exprAbove(if (op == TK.NOT) prec_not else prec_unary);
                s.pop(1);
                return s.prefixNode(op, e);
            },
            TK.LP => return s.parenthesized(),
            TK.CASE => return s.caseExpr(),
            else => {
                if (isIdj(s.tk()) and s.at(1).tk == TK.LP) return s.call();
                return s.primary();
            },
        }
    }

    noinline fn prefixNode(s: *Parser, op: u8, e: ?*Expr) Error!?*Expr {
        if (op == TK.NOT or op == TK.BITNOT) return try ir.expr.binary(s.p, op, e, null);
        const code: u8 = op + (TK.UPLUS - TK.PLUS);
        if (e) |x| if (x.op == TK.UPLUS) {
            x.op = code;
            return x;
        };
        return try ir.expr.binary(s.p, code, e, null);
    }

    /// A term, a name, a function call, CAST, CASE, EXISTS, RAISE.
    noinline fn primary(s: *Parser) Error!?*Expr {
        const p = s.p;
        const t = s.peek();
        switch (t.tk) {
            TK.STRING => if (s.at(1).tk == TK.DOT) return s.dotted() else return s.term(),
            TK.NULL, TK.FLOAT, TK.BLOB, TK.INTEGER, TK.QNUMBER, TK.CTIME_KW => return s.term(),
            TK.VARIABLE => {
                _ = try s.advance();
                const tok = s.token(t);
                const z = tok.z.?;
                if (!(z[0] == '#' and ctype.isDigit(z[1]))) {
                    const e = try ir.expr.token(p, TK.VARIABLE, tok);
                    try ir.expr.assignVarNumber(p, e, tok.n);
                    return e;
                }
                if (p.nested == 0) {
                    // "#N" names register N, only in nested parses.
                    ir.stmt.syntaxError(p, tok);
                    return null;
                }
                const e = try ir.expr.binary(p, TK.REGISTER, null, null);
                e.i_table = util.getInt32(tok.slice()[1..]) orelse 0;
                return e;
            },
            TK.CAST => {
                _ = try s.advanceDeep(2);
                defer s.pop(2);
                _ = try s.expect(TK.LP);
                const e = try s.expr();
                _ = try s.expect(TK.AS);
                const ty = try s.typetoken();
                _ = try s.expect(TK.RP);
                return try ir.expr.cast(p, e, ty);
            },
            TK.EXISTS => {
                _ = try s.advanceDeep(2);
                defer s.pop(2);
                _ = try s.expect(TK.LP);
                const sel = try s.select();
                _ = try s.expect(TK.RP);
                return try ir.expr.subquery(p, TK.EXISTS, sel);
            },
            TK.RAISE => {
                _ = try s.advanceDeep(2);
                defer s.pop(2);
                _ = try s.expect(TK.LP);
                if (s.tk() == TK.IGNORE) {
                    _ = try s.advance();
                    _ = try s.expect(TK.RP);
                    const e = try ir.expr.binary(p, TK.RAISE, null, null);
                    e.aff_expr = OE.Ignore.int();
                    return e;
                }
                const oe: OE = switch (s.tk()) {
                    TK.ROLLBACK => .Rollback,
                    TK.ABORT => .Abort,
                    TK.FAIL => .Fail,
                    else => return s.fail(),
                };
                _ = try s.advance();
                _ = try s.expect(TK.COMMA);
                const msg = try s.expr();
                _ = try s.expect(TK.RP);
                const e = try ir.expr.binary(p, TK.RAISE, msg, null);
                e.aff_expr = oe.int();
                return e;
            },
            else => {
                if (!isIdj(t.tk)) return s.fail();
                switch (s.at(1).tk) {
                    TK.DOT => return s.dotted(),
                    else => {
                        _ = try s.advance();
                        return try ir.expr.token(p, TK.ID, s.token(t));
                    },
                }
            },
        }
    }

    /// term: NULL, FLOAT, BLOB, STRING, INTEGER, QNUMBER, CTIME_KW.
    noinline fn term(s: *Parser) Error!?*Expr {
        const p = s.p;
        const t = try s.advance();
        const tok = s.token(t);
        return switch (t.tk) {
            TK.NULL, TK.FLOAT, TK.BLOB, TK.STRING => try ir.expr.token(p, t.tk, tok),
            TK.INTEGER => try ir.expr.integer(p, tok),
            TK.QNUMBER => blk: {
                const e = try ir.expr.token(p, t.tk, tok);
                ir.expr.dequoteNumber(p, e);
                break :blk e;
            },
            TK.CTIME_KW => try ir.expr.function(p, null, tok, .{}),
            else => unreachable,
        };
    }

    /// nm DOT nm [DOT nm]: a column of a table (of a schema).
    noinline fn dotted(s: *Parser) Error!?*Expr {
        const p = s.p;
        const n1 = s.token(try s.advance());
        _ = try s.advance();
        const n2 = try s.nm();
        if (s.tk() != TK.DOT) {
            const t1 = try ir.expr.token(p, TK.ID, n1);
            const t2 = try ir.expr.token(p, TK.ID, n2);
            return try ir.expr.binary(p, TK.DOT, t1, t2);
        }
        _ = try s.advance();
        const n3 = try s.nm();
        const t1 = try ir.expr.token(p, TK.ID, n1);
        const t2 = try ir.expr.token(p, TK.ID, n2);
        const t3 = try ir.expr.token(p, TK.ID, n3);
        const t4 = try ir.expr.binary(p, TK.DOT, t2, t3);
        if (p.inRenameObject()) ir.ddl.renameTokenRemap(p, null, t1);
        return try ir.expr.binary(p, TK.DOT, t1, t4);
    }

    /// A function call: idj LP (STAR | distinct exprlist [ORDER BY
    /// sortlist]) RP [filter_over]. The window is built before the call.
    noinline fn call(s: *Parser) Error!?*Expr {
        const p = s.p;
        const name = s.token(try s.advance());
        _ = try s.advanceDeep(3);
        defer s.pop(3);
        var star = false;
        var flags: SF = .{};
        var args: ?*ExprList = null;
        var order: ?*ExprList = null;
        if (s.tk() == TK.STAR) {
            _ = try s.advance();
            star = true;
        } else {
            flags = try s.distinct();
            if (s.tk() != TK.RP and s.tk() != TK.ORDER) args = try s.nexprlist();
            if (s.tk() == TK.ORDER) {
                _ = try s.advance();
                _ = try s.expect(TK.BY);
                order = try s.sortlist();
            }
        }
        _ = try s.expect(TK.RP);
        var w: ?*Window = null;
        const windowed = s.tk() == TK.FILTER or s.tk() == TK.OVER;
        if (windowed) w = try s.filterOver();
        const e = try ir.expr.function(p, args, name, flags);
        if (windowed) if (w) |x| ir.window.attach(p, e, x);
        if (order) |ob| try ir.expr.addFunctionOrderBy(p, e, ob);
        return e;
    }

    /// LP expr RP, LP select RP, LP nexprlist COMMA expr RP (a vector).
    fn parenthesized(s: *Parser) Error!?*Expr {
        _ = try s.advanceDeep(1);
        defer s.pop(1);
        if (startsSelect(s.tk())) return s.subquery();
        const first = try s.exprAbove(0);
        if (s.tk() != TK.COMMA) {
            _ = try s.expect(TK.RP);
            return first;
        }
        return s.vector(first);
    }

    /// The rest of LP select RP.
    noinline fn subquery(s: *Parser) Error!?*Expr {
        const sel = try s.select();
        _ = try s.expect(TK.RP);
        return try ir.expr.subquery(s.p, TK.SELECT, sel);
    }

    /// The rest of LP nexprlist COMMA expr RP, after the first
    /// expression.
    noinline fn vector(s: *Parser, first: ?*Expr) Error!?*Expr {
        const p = s.p;
        // nexprlist ::= expr: reduced at the first COMMA; the last
        // expression joins the list when the vector is reduced.
        var list = try ir.list.append(p, null, first);
        var n: u32 = 2;
        defer s.pop(2);
        while (true) {
            _ = try s.advanceDeep(n);
            n = 0;
            const e = try s.expr();
            if (s.tk() == TK.COMMA) {
                list = try ir.list.append(p, list, e);
                continue;
            }
            _ = try s.expect(TK.RP);
            list = try ir.list.append(p, list, e);
            return try ir.expr.vector(p, list);
        }
    }

    /// CASE [expr] (WHEN expr THEN expr)+ [ELSE expr] END.
    noinline fn caseExpr(s: *Parser) Error!?*Expr {
        const p = s.p;
        // CASE case_operand WHEN.
        _ = try s.advanceDeep(3);
        defer s.pop(3);
        var base: ?*Expr = null;
        if (s.tk() != TK.WHEN) base = try s.expr();
        var list: ?*ExprList = null;
        _ = try s.expect(TK.WHEN);
        while (true) {
            const when = try s.expr();
            _ = try s.expect(TK.THEN);
            const then = try s.expr();
            list = try ir.list.append(p, list, when);
            list = try ir.list.append(p, list, then);
            if (s.tk() != TK.WHEN) break;
            _ = try s.advance();
        }
        var @"else": ?*Expr = null;
        if (s.tk() == TK.ELSE) {
            _ = try s.advance();
            @"else" = try s.expr();
        }
        _ = try s.expect(TK.END);
        return try ir.expr.case(p, base, list, @"else");
    }

    /// exprlist ::= nexprlist | . (empty before RP).
    fn exprlist(s: *Parser) Error!?*ExprList {
        if (s.tk() == TK.RP) return null;
        return s.nexprlist();
    }

    /// nexprlist ::= expr (COMMA expr)*.
    fn nexprlist(s: *Parser) Error!?*ExprList {
        var list: ?*ExprList = null;
        while (true) {
            const e = try s.expr();
            list = try ir.list.append(s.p, list, e);
            if (s.tk() != TK.COMMA) return list;
            _ = try s.advance();
        }
    }
};

/// `idj` where an expression starts: ID|INDEXED|JOIN_KW, or a keyword
/// that falls back to ID and does not start an expression of its own.
fn isIdj(tk: u8) bool {
    return tk == TK.ID or tk == TK.INDEXED or tk == TK.JOIN_KW or
        (fallsBack(tk) and tk != TK.CAST and tk != TK.RAISE and tk != TK.CTIME_KW);
}

/// The first token of a `term`.
fn isTerm(tk: u8) bool {
    return switch (tk) {
        TK.NULL, TK.FLOAT, TK.BLOB, TK.STRING, TK.INTEGER, TK.QNUMBER, TK.CTIME_KW => true,
        else => false,
    };
}

/// The first token of a table constraint (tcons).
fn startsTableConstraint(tk: u8) bool {
    return switch (tk) {
        TK.CONSTRAINT, TK.PRIMARY, TK.UNIQUE, TK.CHECK, TK.FOREIGN => true,
        else => false,
    };
}

/// The length of the text from the start of `from` to the end of `to`.
fn spanLen(from: Token, to: Token) u32 {
    return @intCast(@intFromPtr(to.z.? + to.n) - @intFromPtr(from.z.?));
}

/// The text between two tokens (exclusive of both).
fn textBetween(open: Token, close: Token) []const u8 {
    const z = tokEnd(open).?;
    return z[0 .. @intFromPtr(close.z.?) - @intFromPtr(z)];
}

/// One past the end of a token.
fn tokEnd(t: Token) ?[*]const u8 {
    return if (t.z) |z| z + t.n else null;
}

// ================================================================= tests

/// What runParser() left in `p` for `sql`: the error, its offset, the
/// result code and the tail.
fn parseOutcome(a: std.mem.Allocator, db: *int.Sqlite3, sql: [:0]const u8) ![]const u8 {
    var p: Parse = .{ .db = db, .arena = a, .syntax_only = true };
    const failed = if (runParser(&p, sql)) |_| false else |err| switch (err) {
        error.ParseFailed => true,
        error.OutOfMemory => |e| return e,
    };
    return std.fmt.allocPrint(a, "failed={} msg={s} offset={d} rc={d} tail={d}", .{
        failed, p.err_msg orelse "", db.err_byte_offset, p.rc, sql.len - p.tail.len,
    });
}

test "sqlite parser: at the limits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var schema: int.Schema = .{};
    var db: int.Sqlite3 = .{ .gpa = undefined };
    db.gpa = @import("../../sql/malloc.zig").dbAllocator(&db);
    try db.dbs.append(a, .{ .name = "main", .schema = &schema });
    try db.dbs.append(a, .{ .name = "temp", .schema = &schema });

    const inputs = [_][:0]const u8{
        "SELECT 1",
        "SELECT 1;  SELECT 2;",
        "SELECT a, b FROM t WHERE x BETWEEN 1 AND 2 /* c */ ORDER BY 1 -- c\n;",
        "  /* c */ SELECT 1 -- c",
        "SELECT 1 /* c",
        "SELECT sum(x) OVER (ORDER BY y) FROM t WINDOW w AS ()",
        "SELECT 1_000, 'abc",
        "SELECT ((((((((((1))))))))))",
        "SELECT -(-(-(-(-(-(-(-1)))))))",
        "SELECT f(f(f(f(f(f(f(1)))))))",
        "SELECT (SELECT (SELECT (SELECT 1)))",
        "SELECT * FROM ((((t))))",
        "SELECT 1+(1+(1+(1+(1+(1+(1+(1+1)))))))",
        "SELECT CASE WHEN CASE WHEN 1 THEN 2 END THEN 3 END",
        "INSERT INTO t VALUES(1) ON CONFLICT DO NOTHING",
        "CREATE TABLE t(a INT CHECK(a > (1 + (2))))",
        "",
        ";;",
    };
    const Config = struct { sql_length: i32 = 1_000_000_000, depth: i32 = 2500, comments: bool = true, interrupt: bool = false };
    const configs = [_]Config{
        .{},
        .{ .sql_length = 0 },
        .{ .sql_length = 7 },
        .{ .sql_length = 9 },
        .{ .sql_length = 15 },
        .{ .sql_length = 30 },
        .{ .comments = false },
        .{ .interrupt = true },
        .{ .depth = 1 },
    };
    // What lemon did (recorded when both parsers were built).
    const expected = [_][]const u8{
        "failed=false msg= offset=-1 rc=0 tail=8",
        "failed=false msg= offset=-1 rc=0 tail=20",
        "failed=false msg= offset=-1 rc=0 tail=68",
        "failed=false msg= offset=-1 rc=0 tail=23",
        "failed=false msg= offset=-1 rc=0 tail=13",
        "failed=false msg= offset=-1 rc=0 tail=53",
        "failed=true msg=unrecognized token: \"'abc\" offset=14 rc=1 tail=14",
        "failed=false msg= offset=14 rc=0 tail=28",
        "failed=false msg= offset=14 rc=0 tail=30",
        "failed=false msg= offset=14 rc=0 tail=29",
        "failed=false msg= offset=14 rc=0 tail=35",
        "failed=false msg= offset=14 rc=0 tail=23",
        "failed=false msg= offset=14 rc=0 tail=38",
        "failed=false msg= offset=14 rc=0 tail=50",
        "failed=false msg= offset=14 rc=0 tail=46",
        "failed=false msg= offset=14 rc=0 tail=42",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=0",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=2",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
        "failed=false msg= offset=14 rc=0 tail=8",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=8",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=9",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=7",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
        "failed=false msg= offset=14 rc=0 tail=8",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=11",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=12",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=10",
        "failed=false msg= offset=14 rc=0 tail=13",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=14",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=14",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=12",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=14",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=15",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
        "failed=false msg= offset=14 rc=0 tail=8",
        "failed=false msg= offset=14 rc=0 tail=20",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=27",
        "failed=false msg= offset=14 rc=0 tail=23",
        "failed=false msg= offset=14 rc=0 tail=13",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=30",
        "failed=true msg=unrecognized token: \"'abc\" offset=14 rc=1 tail=14",
        "failed=false msg= offset=14 rc=0 tail=28",
        "failed=false msg= offset=14 rc=0 tail=30",
        "failed=false msg= offset=14 rc=0 tail=29",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=30",
        "failed=false msg= offset=14 rc=0 tail=23",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=30",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=29",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=27",
        "failed=true msg=string or blob too big offset=14 rc=18 tail=30",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
        "failed=false msg= offset=14 rc=0 tail=8",
        "failed=false msg= offset=14 rc=0 tail=20",
        "failed=true msg=unrecognized token: \"/* c */\" offset=43 rc=1 tail=43",
        "failed=true msg=unrecognized token: \"/* c */\" offset=2 rc=1 tail=2",
        "failed=true msg=unrecognized token: \"/* c\" offset=9 rc=1 tail=9",
        "failed=false msg= offset=9 rc=0 tail=53",
        "failed=true msg=unrecognized token: \"'abc\" offset=14 rc=1 tail=14",
        "failed=false msg= offset=14 rc=0 tail=28",
        "failed=false msg= offset=14 rc=0 tail=30",
        "failed=false msg= offset=14 rc=0 tail=29",
        "failed=false msg= offset=14 rc=0 tail=35",
        "failed=false msg= offset=14 rc=0 tail=23",
        "failed=false msg= offset=14 rc=0 tail=38",
        "failed=false msg= offset=14 rc=0 tail=50",
        "failed=false msg= offset=14 rc=0 tail=46",
        "failed=false msg= offset=14 rc=0 tail=42",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=0",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=6",
        "failed=true msg=interrupted offset=14 rc=9 tail=0",
        "failed=true msg=interrupted offset=14 rc=9 tail=2",
        "failed=false msg= offset=14 rc=0 tail=8",
        "failed=false msg= offset=14 rc=0 tail=20",
        "failed=false msg= offset=14 rc=0 tail=68",
        "failed=false msg= offset=14 rc=0 tail=23",
        "failed=false msg= offset=14 rc=0 tail=13",
        "failed=false msg= offset=14 rc=0 tail=53",
        "failed=true msg=unrecognized token: \"'abc\" offset=14 rc=1 tail=14",
        "failed=false msg= offset=14 rc=0 tail=28",
        "failed=false msg= offset=14 rc=0 tail=30",
        "failed=false msg= offset=14 rc=0 tail=29",
        "failed=false msg= offset=14 rc=0 tail=35",
        "failed=false msg= offset=14 rc=0 tail=23",
        "failed=false msg= offset=14 rc=0 tail=38",
        "failed=false msg= offset=14 rc=0 tail=50",
        "failed=false msg= offset=14 rc=0 tail=46",
        "failed=false msg= offset=14 rc=0 tail=42",
        "failed=false msg= offset=14 rc=0 tail=0",
        "failed=false msg= offset=14 rc=0 tail=2",
    };
    var k: usize = 0;
    for (configs) |c| {
        db.limits.set(.sql_length, c.sql_length);
        db.limits.set(.parser_depth, c.depth);
        db.flags.Comments = c.comments;
        db.n_vdbe_active = @intFromBool(c.interrupt);
        for (inputs) |sql| {
            db.is_interrupted.store(c.interrupt, .monotonic);
            const got = try parseOutcome(a, &db, sql);
            std.testing.expectEqualStrings(expected[k], got) catch |err| {
                std.debug.print("for {s} with {}\n", .{ sql, c });
                return err;
            };
            k += 1;
        }
    }
    db.n_vdbe_active = 0;

    // Nesting past SQLITE_LIMIT_PARSER_DEPTH: "Recursion limit", and the
    // native stack holds.
    db.limits.set(.sql_length, 1_000_000_000);
    db.limits.set(.parser_depth, 2500);
    db.flags.Comments = true;
    for ([_][2][]const u8{ .{ "(", ")" }, .{ "- ", "" }, .{ "f(", ")" }, .{ "(1+", ")" }, .{ "(SELECT ", ")" }, .{ "NOT ", "" }, .{ "CASE WHEN ", " THEN 1 END" } }) |shape| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "SELECT ");
        for (0..5000) |_| try text.appendSlice(a, shape[0]);
        try text.append(a, '1');
        for (0..5000) |_| try text.appendSlice(a, shape[1]);
        const sql = try a.dupeSentinel(u8, text.items, 0);
        const got = try parseOutcome(a, &db, sql);
        errdefer std.debug.print("{s}...: {s}\n", .{ sql[0..40], got });
        try std.testing.expect(std.mem.indexOf(u8, got, "msg=Recursion limit") != null);
    }
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
    db.gpa = @import("../../sql/malloc.zig").dbAllocator(&db);
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
