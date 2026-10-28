//! The SQL parser: the LALR(1) engine of lemon's lempar.c driven by the
//! tables in grammar.zig, and the reduce actions of SQLite's parse.y.
//!
//! The actions are translated from the parse.c lemon generates, where the
//! stack slot of every symbol is already resolved: M(k) below is lemon's
//! yymsp[k].minor. Each action is keyed by its rule text (grammar.Rule),
//! so the switch must cover every rule of the grammar.

const std = @import("std");
const grammar = @import("grammar.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const expr = @import("../sql/expr.zig");
const build = @import("../sql/build.zig");
const sel = @import("../sql/select.zig");
const win = @import("../sql/window.zig");
const trig = @import("../sql/trigger.zig");
const upsert_mod = @import("../sql/upsert.zig");
const insert_mod = @import("../sql/insert.zig");
const delete_mod = @import("../sql/delete.zig");
const update_mod = @import("../sql/update.zig");
const pragma_mod = @import("../sql/pragma.zig");
const vacuum_mod = @import("../sql/vacuum.zig");
const attach_mod = @import("../sql/attach.zig");
const analyze_mod = @import("../sql/analyze.zig");
const alter = @import("../sql/alter.zig");
const vtab = @import("../sql/vtab.zig");
const prepare = @import("../sql/prepare.zig");
const ctype = @import("../util/ctype.zig");

const Parse = int.Parse;
const Token = int.Token;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const Select = int.Select;
const Window = int.Window;
const With = int.With;
const Cte = int.Cte;
const Upsert = int.Upsert;
const TriggerStep = int.TriggerStep;
const OnOrUsing = int.OnOrUsing;
const Oom = int.Oom;
const TK = int.TK;
const EP = int.EP;
const SF = int.SF;
const JT = int.JT;
const OE = int.OE;
const SO = int.SortOrder;
const g = grammar;

/// struct TrigEvent of parse.y: the event of a trigger, and its UPDATE OF
/// columns.
const TrigEvent = extern struct { a: i32 = 0, b: ?*IdList = null };

/// struct FrameBound of parse.y.
const FrameBound = extern struct { e_type: i32 = 0, expr: ?*Expr = null };

/// The refarg type of parse.y: bits to set in a REFERENCES action mask.
const RefArg = extern struct { value: i32 = 0, mask: i32 = 0 };

/// YYMINORTYPE: the semantic value of a symbol. Lemon reuses slots for
/// values of different types, so this must not be a checked union.
const Minor = extern union {
    tok: Token,
    elist: ?*ExprList,
    with: ?*With,
    cte: ?*Cte,
    upsert: ?*Upsert,
    idlist: ?*IdList,
    int: i32,
    str: ?[*]const u8,
    srclist: ?*SrcList,
    window: ?*Window,
    on_using: OnOrUsing,
    trig_event: TrigEvent,
    refarg: RefArg,
    u32: u32,
    /// Table options (TF_WithoutRowid etc.).
    tab_opts: int.TF,
    /// A join type (JT_*).
    jt: JT,
    /// SF_Distinct, SF_All or nothing, for DISTINCT/ALL.
    sf: SF,
    /// A conflict resolution (OE_*) of onconf, orconf, resolvetype,
    /// raisetype, insert_cmd and uniqueflag. The actions of refargs and
    /// refact stay in `int`, where refargs packs two of them as C does.
    oe: OE,
    trig_step: ?*TriggerStep,
    expr: ?*Expr,
    u8: u8,
    frame_bound: FrameBound,
    select: ?*Select,
};

const StackEntry = struct {
    stateno: u16,
    major: u16,
    minor: Minor,
};

/// The parser state (yyParser). Tokens are fed one at a time with `feed`.
pub const Parser = struct {
    p: *Parse,
    stack: []StackEntry,
    /// Index of the top of the stack (yytos).
    tos: usize = 0,

    pub fn init(p: *Parse) Oom!Parser {
        const stack = try p.arena.alloc(StackEntry, g.YYSTACKDEPTH);
        stack[0] = .{ .stateno = 0, .major = 0, .minor = .{ .int = 0 } };
        return .{ .p = p, .stack = stack };
    }

    /// yymsp[k].minor.
    fn m(s: *Parser, comptime k: i32) *Minor {
        return &s.stack[@intCast(@as(isize, @intCast(s.tos)) + k)].minor;
    }

    /// yymsp[k].major.
    fn major(s: *Parser, comptime k: i32) u8 {
        return @intCast(s.stack[@intCast(@as(isize, @intCast(s.tos)) + k)].major);
    }

    /// Port of yyGrowStack(): grow to twice the size plus 100 entries,
    /// up to SQLITE_LIMIT_PARSER_DEPTH. False if the limit is reached.
    fn growStack(s: *Parser) Oom!bool {
        const old = s.stack.len;
        var new = old * 2 + 100;
        const limit: usize = @intCast(s.p.db.limit(.parser_depth));
        if (new > limit) {
            new = limit;
            if (new <= old) return false;
        }
        const grown = try s.p.arena.alloc(StackEntry, new);
        @memcpy(grown[0..old], s.stack);
        s.stack = grown;
        return true;
    }

    /// Port of yyStackOverflow().
    fn stackOverflow(s: *Parser) void {
        s.tos = 0;
        if (s.p.n_err == 0) util.errorMsg(s.p, "Recursion limit", .{});
    }

    /// Port of yy_shift().
    fn shift(s: *Parser, new_state_arg: u16, maj: u16, minor: Token) Oom!void {
        s.tos += 1;
        if (s.tos >= s.stack.len) {
            if (!try s.growStack()) {
                s.tos -= 1;
                s.stackOverflow();
                return;
            }
        }
        var new_state = new_state_arg;
        if (new_state > g.YY_MAX_SHIFT) new_state += g.YY_MIN_REDUCE - g.YY_MIN_SHIFTREDUCE;
        s.stack[s.tos] = .{ .stateno = new_state, .major = maj, .minor = .{ .tok = minor } };
    }

    /// Port of sqlite3Parser(): process one token. Major 0 ends the input.
    pub fn feed(s: *Parser, maj: u8, minor: Token) Oom!void {
        var act: u16 = s.stack[s.tos].stateno;
        while (true) {
            act = findShiftAction(maj, act);
            if (act >= g.YY_MIN_REDUCE) {
                const ruleno = act - g.YY_MIN_REDUCE;
                // Room to push the LHS of an empty rule.
                if (g.yy_rule_info_nrhs[ruleno] == 0 and s.tos + 1 >= s.stack.len) {
                    if (!try s.growStack()) {
                        s.stackOverflow();
                        break;
                    }
                }
                act = try s.reduce(ruleno, maj, minor);
            } else if (act <= g.YY_MAX_SHIFTREDUCE) {
                try s.shift(act, maj, minor);
                break;
            } else if (act == g.YY_ACCEPT_ACTION) {
                s.tos -= 1;
                return;
            } else {
                std.debug.assert(act == g.YY_ERROR_ACTION);
                // YYNOERRORRECOVERY: report and stop.
                if (minor.z != null and minor.z.?[0] != 0) {
                    syntaxError(s.p, minor);
                } else {
                    util.errorMsg(s.p, "incomplete input", .{});
                }
                break;
            }
        }
    }

    /// Port of yy_reduce(): run the action of rule `ruleno`, then pop its
    /// right side and push its left side. Returns the new state.
    fn reduce(s: *Parser, ruleno: u16, lookahead: u8, lookahead_token: Token) Oom!u16 {
        try s.action(@enumFromInt(ruleno), lookahead, lookahead_token);
        const goto = g.yy_rule_info_lhs[ruleno];
        const size: isize = g.yy_rule_info_nrhs[ruleno];
        const base: usize = @intCast(@as(isize, @intCast(s.tos)) + size);
        const act = findReduceAction(s.stack[base].stateno, goto);
        std.debug.assert(!(act > g.YY_MAX_SHIFT and act <= g.YY_MAX_SHIFTREDUCE));
        std.debug.assert(act != g.YY_ERROR_ACTION);
        s.tos = base + 1;
        s.stack[s.tos].stateno = act;
        s.stack[s.tos].major = goto;
        return act;
    }

    fn action(s: *Parser, rule: g.Rule, lookahead: u8, la_token: Token) Oom!void {
        _ = lookahead;
        const p = s.p;
        const a = p.arena;
        var lhs: Minor = undefined;
        switch (rule) {
            .@"explain ::= EXPLAIN" => p.explain = 1,
            .@"explain ::= EXPLAIN QUERY PLAN" => p.explain = 2,
            .@"cmdx ::= cmd" => build.finishCoding(p),
            .@"cmd ::= BEGIN transtype trans_opt" => build.beginTransaction(p, s.m(-1).int),
            .@"transtype ::=" => s.m(1).int = TK.DEFERRED,
            .@"transtype ::= DEFERRED",
            .@"transtype ::= IMMEDIATE",
            .@"transtype ::= EXCLUSIVE",
            .@"range_or_rows ::= RANGE|ROWS|GROUPS",
            => s.m(0).int = s.major(0),
            .@"cmd ::= COMMIT|END trans_opt",
            .@"cmd ::= ROLLBACK trans_opt",
            => build.endTransaction(p, s.major(-1)),
            .@"cmd ::= SAVEPOINT nm" => build.savepoint(p, .BEGIN, s.m(0).tok),
            .@"cmd ::= RELEASE savepoint_opt nm" => build.savepoint(p, .RELEASE, s.m(0).tok),
            .@"cmd ::= ROLLBACK trans_opt TO savepoint_opt nm" => build.savepoint(p, .ROLLBACK, s.m(0).tok),
            .@"create_table ::= createkw temp TABLE ifnotexists nm dbnm" => {
                build.startTable(p, s.m(-1).tok, s.m(0).tok, s.m(-4).int != 0, false, false, s.m(-2).int != 0);
            },
            .@"createkw ::= CREATE" => disableLookaside(p),
            .@"ifnotexists ::=",
            .@"temp ::=",
            .@"autoinc ::=",
            .@"init_deferred_pred_opt ::=",
            .@"defer_subclause_opt ::=",
            .@"ifexists ::=",
            .@"collate ::=",
            => s.m(1).int = 0,
            .@"distinct ::=" => s.m(1).sf = .{},
            .@"ifnotexists ::= IF NOT EXISTS" => s.m(-2).int = 1,
            .@"temp ::= TEMP" => s.m(0).int = @intFromBool(!p.db.init.busy),
            .@"create_table_args ::= LP columnlist conslist_opt RP table_option_set" => {
                build.endTable(p, s.m(-2).tok, s.m(-1).tok, s.m(0).tab_opts, null);
            },
            .@"create_table_args ::= AS select" => build.endTable(p, null, null, .{}, s.m(0).select),
            .@"table_option_set ::=" => s.m(1).tab_opts = .{},
            .@"table_option_set ::= table_option_set COMMA table_option" => {
                lhs.tab_opts = s.m(-2).tab_opts.with(s.m(0).tab_opts);
                s.m(-2).tab_opts = lhs.tab_opts;
            },
            .@"table_option ::= WITHOUT nm" => {
                const x = s.m(0).tok;
                if (ctype.eqlNoCase(x.slice(), "rowid")) {
                    s.m(-1).tab_opts = .{ .WithoutRowid = true, .NoVisibleRowid = true };
                } else {
                    s.m(-1).tab_opts = .{};
                    util.errorMsg(p, "unknown table option: {s}", .{x.slice()});
                }
            },
            .@"table_option ::= nm" => {
                const x = s.m(0).tok;
                if (ctype.eqlNoCase(x.slice(), "strict")) {
                    lhs.tab_opts = .{ .Strict = true };
                } else {
                    lhs.tab_opts = .{};
                    util.errorMsg(p, "unknown table option: {s}", .{x.slice()});
                }
                s.m(0).tab_opts = lhs.tab_opts;
            },
            .@"columnname ::= nm typetoken" => build.addColumn(p, s.m(-1).tok, s.m(0).tok),
            .@"typetoken ::=",
            .@"conslist_opt ::=",
            .@"as ::=",
            => s.m(1).tok = .{},
            .@"typetoken ::= typename LP signed RP" => s.m(-3).tok.n = spanLen(s.m(-3).tok, s.m(0).tok),
            .@"typetoken ::= typename LP signed COMMA signed RP" => s.m(-5).tok.n = spanLen(s.m(-5).tok, s.m(0).tok),
            .@"typename ::= typename ID|STRING" => s.m(-1).tok.n = spanLen(s.m(-1).tok, s.m(0).tok),
            .@"scanpt ::=" => s.m(1).str = la_token.z,
            .@"scantok ::=" => s.m(1).tok = la_token,
            .@"ccons ::= CONSTRAINT nm",
            .@"tcons ::= CONSTRAINT nm",
            => p.u1.cr.constraint_name = s.m(0).tok,
            .@"ccons ::= DEFAULT scantok term" => {
                build.addDefaultValue(p, s.m(0).expr, s.m(-1).tok.z, tokEnd(s.m(-1).tok));
            },
            .@"ccons ::= DEFAULT LP expr RP" => {
                build.addDefaultValue(p, s.m(-1).expr, s.m(-2).tok.z.? + 1, s.m(0).tok.z);
            },
            .@"ccons ::= DEFAULT PLUS scantok term" => {
                build.addDefaultValue(p, s.m(0).expr, s.m(-2).tok.z, tokEnd(s.m(-1).tok));
            },
            .@"ccons ::= DEFAULT MINUS scantok term" => {
                const e = try expr.pExpr(p, TK.UMINUS, s.m(0).expr, null);
                build.addDefaultValue(p, e, s.m(-2).tok.z, tokEnd(s.m(-1).tok));
            },
            .@"ccons ::= DEFAULT scantok ID|INDEXED" => {
                const e = try tokenExpr(p, TK.STRING, s.m(0).tok);
                _ = expr.idToTrueFalse(e);
                build.addDefaultValue(p, e, s.m(0).tok.z, tokEnd(s.m(0).tok));
            },
            .@"ccons ::= NOT NULL onconf" => build.addNotNull(p, s.m(0).oe),
            .@"ccons ::= PRIMARY KEY sortorder onconf autoinc" => {
                build.addPrimaryKey(p, null, s.m(-1).oe, s.m(0).int != 0, s.m(-2).int);
            },
            .@"ccons ::= UNIQUE onconf" => {
                build.createIndex(p, null, null, null, null, s.m(0).oe, null, null, 0, false, .unique);
            },
            .@"ccons ::= CHECK LP expr RP" => build.addCheckConstraint(p, s.m(-1).expr, s.m(-2).tok.z, s.m(0).tok.z),
            .@"ccons ::= REFERENCES nm eidlist_opt refargs" => {
                build.createForeignKey(p, null, s.m(-2).tok, s.m(-1).elist, s.m(0).int);
            },
            .@"ccons ::= defer_subclause" => build.deferForeignKey(p, s.m(0).int != 0),
            .@"ccons ::= COLLATE ID|STRING" => build.addCollateType(p, s.m(0).tok),
            .@"generated ::= LP expr RP" => build.addGenerated(p, s.m(-1).expr, null),
            .@"generated ::= LP expr RP ID" => build.addGenerated(p, s.m(-2).expr, s.m(0).tok),
            .@"autoinc ::= AUTOINCR" => s.m(0).int = 1,
            .@"refargs ::=" => s.m(1).int = @as(i32, OE.None.int()) * 0x0101,
            .@"refargs ::= refargs refarg" => {
                s.m(-1).int = (s.m(-1).int & ~s.m(0).refarg.mask) | s.m(0).refarg.value;
            },
            .@"refarg ::= MATCH nm" => s.m(-1).refarg = .{ .value = 0, .mask = 0 },
            .@"refarg ::= ON INSERT refact" => s.m(-2).refarg = .{ .value = 0, .mask = 0 },
            .@"refarg ::= ON DELETE refact" => s.m(-2).refarg = .{ .value = s.m(0).int, .mask = 0x0000ff },
            .@"refarg ::= ON UPDATE refact" => s.m(-2).refarg = .{ .value = s.m(0).int << 8, .mask = 0x00ff00 },
            .@"refact ::= SET NULL" => s.m(-1).int = OE.SetNull.int(),
            .@"refact ::= SET DEFAULT" => s.m(-1).int = OE.SetDflt.int(),
            .@"refact ::= CASCADE" => s.m(0).int = OE.Cascade.int(),
            .@"refact ::= RESTRICT" => s.m(0).int = OE.Restrict.int(),
            .@"refact ::= NO ACTION" => s.m(-1).int = OE.None.int(),
            .@"defer_subclause ::= NOT DEFERRABLE init_deferred_pred_opt" => s.m(-2).int = 0,
            .@"defer_subclause ::= DEFERRABLE init_deferred_pred_opt" => s.m(-1).int = s.m(0).int,
            .@"orconf ::= OR resolvetype",
            .@"insert_cmd ::= INSERT orconf",
            => s.m(-1).oe = s.m(0).oe,
            .@"init_deferred_pred_opt ::= INITIALLY DEFERRED",
            .@"ifexists ::= IF EXISTS",
            .@"between_op ::= NOT BETWEEN",
            .@"in_op ::= NOT IN",
            .@"collate ::= COLLATE ID|STRING",
            => s.m(-1).int = 1,
            .@"init_deferred_pred_opt ::= INITIALLY IMMEDIATE" => s.m(-1).int = 0,
            .@"tconscomma ::= COMMA" => p.u1.cr.constraint_name.n = 0,
            .@"tcons ::= PRIMARY KEY LP sortlist autoinc RP onconf" => {
                build.addPrimaryKey(p, s.m(-3).elist, s.m(0).oe, s.m(-2).int != 0, 0);
            },
            .@"tcons ::= UNIQUE LP sortlist RP onconf" => {
                build.createIndex(p, null, null, null, s.m(-2).elist, s.m(0).oe, null, null, 0, false, .unique);
            },
            .@"tcons ::= CHECK LP expr RP onconf" => {
                build.addCheckConstraint(p, s.m(-2).expr, s.m(-3).tok.z, s.m(-1).tok.z);
            },
            .@"tcons ::= FOREIGN KEY LP eidlist RP REFERENCES nm eidlist_opt refargs defer_subclause_opt" => {
                build.createForeignKey(p, s.m(-6).elist, s.m(-3).tok, s.m(-2).elist, s.m(-1).int);
                build.deferForeignKey(p, s.m(0).int != 0);
            },
            .@"onconf ::=",
            .@"orconf ::=",
            => s.m(1).oe = .Default,
            .@"onconf ::= ON CONFLICT resolvetype" => s.m(-2).oe = s.m(0).oe,
            .@"resolvetype ::= IGNORE" => s.m(0).oe = .Ignore,
            .@"resolvetype ::= REPLACE",
            .@"insert_cmd ::= REPLACE",
            => s.m(0).oe = .Replace,
            .@"cmd ::= DROP TABLE ifexists fullname" => build.dropTable(p, s.m(0).srclist, false, s.m(-1).int != 0),
            .@"cmd ::= createkw temp VIEW ifnotexists nm dbnm eidlist_opt AS select" => {
                build.createView(p, s.m(-8).tok, s.m(-4).tok, s.m(-3).tok, s.m(-2).elist, s.m(0).select, s.m(-7).int != 0, s.m(-5).int != 0);
            },
            .@"cmd ::= DROP VIEW ifexists fullname" => build.dropTable(p, s.m(0).srclist, true, s.m(-1).int != 0),
            .@"cmd ::= select" => cmd: {
                var dest: sel.SelectDest = .{ .e_dest = sel.SRT.Output };
                if (!p.db.m_db_flags.EncodingFixed) prepare.readSchema(p) catch break :cmd;
                if (s.m(0).select) |x| sel.select(p, x, &dest) catch {};
            },
            .@"select ::= WITH wqlist selectnowith" => s.m(-2).select = attachWithToSelect(p, s.m(0).select, s.m(-1).with),
            .@"select ::= WITH RECURSIVE wqlist selectnowith" => s.m(-3).select = attachWithToSelect(p, s.m(0).select, s.m(-1).with),
            .@"select ::= selectnowith" => if (s.m(0).select) |x| doubleLinkSelect(p, x),
            .@"selectnowith ::= selectnowith multiselect_op oneselect" => {
                var rhs = s.m(0).select;
                const lhs_sel = s.m(-2).select;
                if (rhs) |r| if (r.prior != null) {
                    doubleLinkSelect(p, r);
                    const from = try build.srcListAppendFromTerm(p, null, null, null, .{}, r, null);
                    rhs = try sel.selectNew(p, null, from, null, null, null, null, .{}, null);
                };
                if (rhs) |r| {
                    r.op = @intCast(s.m(-1).int);
                    r.prior = lhs_sel;
                    if (lhs_sel) |l| l.sel_flags.MultiValue = false;
                    r.sel_flags.MultiValue = false;
                    if (s.m(-1).int != TK.ALL) p.has_compound = true;
                }
                s.m(-2).select = rhs;
            },
            .@"multiselect_op ::= UNION",
            .@"multiselect_op ::= EXCEPT|INTERSECT",
            => s.m(0).int = s.major(0),
            .@"multiselect_op ::= UNION ALL" => s.m(-1).int = TK.ALL,
            .@"oneselect ::= SELECT distinct selcollist from where_opt groupby_opt having_opt orderby_opt limit_opt" => {
                s.m(-8).select = try sel.selectNew(p, s.m(-6).elist, s.m(-5).srclist, s.m(-4).expr, s.m(-3).elist, s.m(-2).expr, s.m(-1).elist, s.m(-7).sf, s.m(0).expr);
            },
            .@"oneselect ::= SELECT distinct selcollist from where_opt groupby_opt having_opt window_clause orderby_opt limit_opt" => {
                const x = try sel.selectNew(p, s.m(-7).elist, s.m(-6).srclist, s.m(-5).expr, s.m(-4).elist, s.m(-3).expr, s.m(-1).elist, s.m(-8).sf, s.m(0).expr);
                x.win_defn = s.m(-2).window;
                s.m(-9).select = x;
            },
            .@"values ::= VALUES LP nexprlist RP" => {
                s.m(-3).select = try sel.selectNew(p, s.m(-1).elist, null, null, null, null, null, .{ .Values = true }, null);
            },
            .@"oneselect ::= mvalues" => insert_mod.multiValuesEnd(p, s.m(0).select),
            .@"mvalues ::= values COMMA LP nexprlist RP",
            .@"mvalues ::= mvalues COMMA LP nexprlist RP",
            => s.m(-4).select = try insert_mod.multiValues(p, s.m(-4).select.?, s.m(-1).elist),
            .@"distinct ::= DISTINCT" => s.m(0).sf = .{ .Distinct = true },
            .@"distinct ::= ALL" => s.m(0).sf = .{ .All = true },
            .@"sclp ::=",
            .@"orderby_opt ::=",
            .@"groupby_opt ::=",
            .@"exprlist ::=",
            .@"paren_exprlist ::=",
            .@"eidlist_opt ::=",
            => s.m(1).elist = null,
            .@"selcollist ::= sclp scanpt expr scanpt as" => {
                const l = try expr.listAppend(p, s.m(-4).elist, s.m(-2).expr);
                if (s.m(0).tok.n > 0) try expr.listSetName(p, l, s.m(0).tok, true);
                try expr.listSetSpan(p, l, s.m(-3).str, s.m(-1).str);
                s.m(-4).elist = l;
            },
            .@"selcollist ::= sclp scanpt STAR" => {
                const e = try expr.expr(a, TK.ASTERISK, null);
                expr.setErrorOffset(e, expr.tokenOffset(p, s.m(0).tok));
                s.m(-2).elist = try expr.listAppend(p, s.m(-2).elist, e);
            },
            .@"selcollist ::= sclp scanpt nm DOT STAR" => {
                const right = try expr.pExpr(p, TK.ASTERISK, null, null);
                expr.setErrorOffset(right, expr.tokenOffset(p, s.m(0).tok));
                const left = try tokenExpr(p, TK.ID, s.m(-2).tok);
                const dot = try expr.pExpr(p, TK.DOT, left, right);
                s.m(-4).elist = try expr.listAppend(p, s.m(-4).elist, dot);
            },
            .@"as ::= AS nm",
            .@"dbnm ::= DOT nm",
            .@"plus_num ::= PLUS INTEGER|FLOAT",
            .@"minus_num ::= MINUS INTEGER|FLOAT",
            => s.m(-1).tok = s.m(0).tok,
            .@"from ::=",
            .@"stl_prefix ::=",
            => s.m(1).srclist = null,
            .@"from ::= FROM seltablist" => {
                s.m(-1).srclist = s.m(0).srclist;
                build.srcListShiftJoinType(s.m(-1).srclist);
            },
            .@"stl_prefix ::= seltablist joinop" => {
                if (s.m(-1).srclist) |l| if (l.len() > 0) {
                    l.at(l.len() - 1).fg.jointype = s.m(0).jt;
                };
            },
            .@"seltablist ::= stl_prefix nm dbnm as on_using" => {
                s.m(-4).srclist = try build.srcListAppendFromTerm(p, s.m(-4).srclist, s.m(-3).tok, s.m(-2).tok, s.m(-1).tok, null, &s.m(0).on_using);
            },
            .@"seltablist ::= stl_prefix nm dbnm as indexed_by on_using" => {
                s.m(-5).srclist = try build.srcListAppendFromTerm(p, s.m(-5).srclist, s.m(-4).tok, s.m(-3).tok, s.m(-2).tok, null, &s.m(0).on_using);
                try build.srcListIndexedBy(p, s.m(-5).srclist, s.m(-1).tok);
            },
            .@"seltablist ::= stl_prefix nm dbnm LP exprlist RP as on_using" => {
                s.m(-7).srclist = try build.srcListAppendFromTerm(p, s.m(-7).srclist, s.m(-6).tok, s.m(-5).tok, s.m(-1).tok, null, &s.m(0).on_using);
                build.srcListFuncArgs(s.m(-7).srclist, s.m(-3).elist);
            },
            .@"seltablist ::= stl_prefix LP select RP as on_using" => {
                s.m(-5).srclist = try build.srcListAppendFromTerm(p, s.m(-5).srclist, null, null, s.m(-1).tok, s.m(-3).select, &s.m(0).on_using);
            },
            .@"seltablist ::= stl_prefix LP seltablist RP as on_using" => try nestedFrom(s, p),
            .@"dbnm ::=",
            .@"indexed_opt ::=",
            => s.m(1).tok = .{},
            .@"fullname ::= nm",
            .@"xfullname ::= nm",
            => {
                lhs.srclist = try build.srcListAppend(p, null, s.m(0).tok, null);
                if (p.inRenameObject()) if (lhs.srclist) |l| alter.renameTokenMap(p, l.at(0).name, s.m(0).tok);
                s.m(0).srclist = lhs.srclist;
            },
            .@"fullname ::= nm DOT nm",
            .@"xfullname ::= nm DOT nm",
            => {
                lhs.srclist = try build.srcListAppend(p, null, s.m(-2).tok, s.m(0).tok);
                if (p.inRenameObject()) if (lhs.srclist) |l| alter.renameTokenMap(p, l.at(0).name, s.m(0).tok);
                s.m(-2).srclist = lhs.srclist;
            },
            .@"xfullname ::= nm AS nm" => {
                lhs.srclist = try build.srcListAppend(p, null, s.m(-2).tok, null);
                if (lhs.srclist) |l| {
                    if (p.inRenameObject()) {
                        alter.renameTokenMap(p, l.at(0).name, s.m(-2).tok);
                    } else {
                        l.at(0).alias = try build.nameFromToken(a, s.m(0).tok);
                    }
                }
                s.m(-2).srclist = lhs.srclist;
            },
            .@"xfullname ::= nm DOT nm AS nm" => {
                lhs.srclist = try build.srcListAppend(p, null, s.m(-4).tok, s.m(-2).tok);
                if (lhs.srclist) |l| {
                    if (p.inRenameObject()) {
                        alter.renameTokenMap(p, l.at(0).name, s.m(-2).tok);
                    } else {
                        l.at(0).alias = try build.nameFromToken(a, s.m(0).tok);
                    }
                }
                s.m(-4).srclist = lhs.srclist;
            },
            .@"joinop ::= COMMA|JOIN" => s.m(0).jt = .{ .INNER = true },
            .@"joinop ::= JOIN_KW JOIN" => s.m(-1).jt = sel.joinType(p, s.m(-1).tok, null, null),
            .@"joinop ::= JOIN_KW nm JOIN" => s.m(-2).jt = sel.joinType(p, s.m(-2).tok, s.m(-1).tok, null),
            .@"joinop ::= JOIN_KW nm nm JOIN" => s.m(-3).jt = sel.joinType(p, s.m(-3).tok, s.m(-2).tok, s.m(-1).tok),
            .@"on_using ::= ON expr" => s.m(-1).on_using = .{ .on = s.m(0).expr, .using = null },
            .@"on_using ::= USING LP idlist RP" => s.m(-3).on_using = .{ .on = null, .using = s.m(-1).idlist },
            .@"on_using ::=" => s.m(1).on_using = .{},
            .@"indexed_by ::= INDEXED BY nm" => s.m(-2).tok = s.m(0).tok,
            // NOT INDEXED: a token with no text and length 1.
            .@"indexed_by ::= NOT INDEXED" => s.m(-1).tok = .{ .z = null, .n = 1 },
            .@"orderby_opt ::= ORDER BY sortlist",
            .@"groupby_opt ::= GROUP BY nexprlist",
            => s.m(-2).elist = s.m(0).elist,
            .@"sortlist ::= sortlist COMMA expr sortorder nulls" => {
                s.m(-4).elist = try expr.listAppend(p, s.m(-4).elist, s.m(-2).expr);
                expr.listSetSortOrder(s.m(-4).elist, s.m(-1).int, s.m(0).int);
            },
            .@"sortlist ::= expr sortorder nulls" => {
                s.m(-2).elist = try expr.listAppend(p, null, s.m(-2).expr);
                expr.listSetSortOrder(s.m(-2).elist, s.m(-1).int, s.m(0).int);
            },
            .@"sortorder ::= ASC" => s.m(0).int = SO.asc,
            .@"sortorder ::= DESC" => s.m(0).int = SO.desc,
            .@"sortorder ::=",
            .@"nulls ::=",
            => s.m(1).int = SO.undef,
            .@"nulls ::= NULLS FIRST" => s.m(-1).int = SO.asc,
            .@"nulls ::= NULLS LAST" => s.m(-1).int = SO.desc,
            .@"having_opt ::=",
            .@"limit_opt ::=",
            .@"where_opt ::=",
            .@"where_opt_ret ::=",
            .@"case_else ::=",
            .@"case_operand ::=",
            .@"vinto ::=",
            => s.m(1).expr = null,
            .@"having_opt ::= HAVING expr",
            .@"where_opt ::= WHERE expr",
            .@"where_opt_ret ::= WHERE expr",
            .@"case_else ::= ELSE expr",
            .@"vinto ::= INTO expr",
            => s.m(-1).expr = s.m(0).expr,
            .@"limit_opt ::= LIMIT expr" => s.m(-1).expr = try expr.pExpr(p, TK.LIMIT, s.m(0).expr, null),
            .@"limit_opt ::= LIMIT expr OFFSET expr" => s.m(-3).expr = try expr.pExpr(p, TK.LIMIT, s.m(-2).expr, s.m(0).expr),
            .@"limit_opt ::= LIMIT expr COMMA expr" => s.m(-3).expr = try expr.pExpr(p, TK.LIMIT, s.m(0).expr, s.m(-2).expr),
            .@"cmd ::= with DELETE FROM xfullname indexed_opt where_opt_ret" => {
                try build.srcListIndexedBy(p, s.m(-2).srclist, s.m(-1).tok);
                delete_mod.deleteFrom(p, s.m(-2).srclist, s.m(0).expr, null, null);
            },
            .@"where_opt_ret ::= RETURNING selcollist" => {
                build.addReturning(p, s.m(0).elist);
                s.m(-1).expr = null;
            },
            .@"where_opt_ret ::= WHERE expr RETURNING selcollist" => {
                build.addReturning(p, s.m(0).elist);
                s.m(-3).expr = s.m(-2).expr;
            },
            .@"cmd ::= with UPDATE orconf xfullname indexed_opt SET setlist from where_opt_ret" => {
                try build.srcListIndexedBy(p, s.m(-5).srclist, s.m(-4).tok);
                expr.listCheckLength(p, s.m(-2).elist, "set list");
                if (s.m(-1).srclist) |from| {
                    var from_clause: ?*SrcList = from;
                    if (from.len() > 1) {
                        const sub = try sel.selectNew(p, null, from, null, null, null, null, .{ .NestedFrom = true }, null);
                        from_clause = try build.srcListAppendFromTerm(p, null, null, null, .{}, sub, null);
                    }
                    if (s.m(-5).srclist) |target| s.m(-5).srclist = try build.srcListAppendList(p, target, from_clause);
                }
                update_mod.update(p, s.m(-5).srclist, s.m(-2).elist, s.m(0).expr, s.m(-6).oe, null, null, null);
            },
            .@"setlist ::= setlist COMMA nm EQ expr" => {
                s.m(-4).elist = try expr.listAppend(p, s.m(-4).elist, s.m(0).expr);
                try expr.listSetName(p, s.m(-4).elist, s.m(-2).tok, true);
            },
            .@"setlist ::= setlist COMMA LP idlist RP EQ expr" => {
                s.m(-6).elist = try expr.listAppendVector(p, s.m(-6).elist, s.m(-3).idlist, s.m(0).expr);
            },
            .@"setlist ::= nm EQ expr" => {
                lhs.elist = try expr.listAppend(p, null, s.m(0).expr);
                try expr.listSetName(p, lhs.elist, s.m(-2).tok, true);
                s.m(-2).elist = lhs.elist;
            },
            .@"setlist ::= LP idlist RP EQ expr" => {
                s.m(-4).elist = try expr.listAppendVector(p, null, s.m(-3).idlist, s.m(0).expr);
            },
            .@"cmd ::= with insert_cmd INTO xfullname idlist_opt select upsert" => {
                insert_mod.insert(p, s.m(-3).srclist, s.m(-1).select, s.m(-2).idlist, s.m(-5).oe, s.m(0).upsert);
            },
            .@"cmd ::= with insert_cmd INTO xfullname idlist_opt DEFAULT VALUES returning" => {
                insert_mod.insert(p, s.m(-4).srclist, null, s.m(-3).idlist, s.m(-6).oe, null);
            },
            .@"upsert ::=" => s.m(1).upsert = null,
            .@"upsert ::= RETURNING selcollist" => {
                s.m(-1).upsert = null;
                build.addReturning(p, s.m(0).elist);
            },
            .@"upsert ::= ON CONFLICT LP sortlist RP where_opt DO UPDATE SET setlist where_opt upsert" => {
                s.m(-11).upsert = try upsert_mod.upsertNew(p, s.m(-8).elist, s.m(-6).expr, s.m(-2).elist, s.m(-1).expr, s.m(0).upsert);
            },
            .@"upsert ::= ON CONFLICT LP sortlist RP where_opt DO NOTHING upsert" => {
                s.m(-8).upsert = try upsert_mod.upsertNew(p, s.m(-5).elist, s.m(-3).expr, null, null, s.m(0).upsert);
            },
            .@"upsert ::= ON CONFLICT DO NOTHING returning" => {
                s.m(-4).upsert = try upsert_mod.upsertNew(p, null, null, null, null, null);
            },
            .@"upsert ::= ON CONFLICT DO UPDATE SET setlist where_opt returning" => {
                s.m(-7).upsert = try upsert_mod.upsertNew(p, null, null, s.m(-2).elist, s.m(-1).expr, null);
            },
            .@"returning ::= RETURNING selcollist" => build.addReturning(p, s.m(0).elist),
            .@"idlist_opt ::=" => s.m(1).idlist = null,
            .@"idlist_opt ::= LP idlist RP" => s.m(-2).idlist = s.m(-1).idlist,
            .@"idlist ::= idlist COMMA nm" => s.m(-2).idlist = try build.idListAppend(p, s.m(-2).idlist, s.m(0).tok),
            .@"idlist ::= nm" => s.m(0).idlist = try build.idListAppend(p, null, s.m(0).tok),
            .@"expr ::= LP expr RP" => s.m(-2).expr = s.m(-1).expr,
            .@"expr ::= ID|INDEXED|JOIN_KW" => s.m(0).expr = try tokenExpr(p, TK.ID, s.m(0).tok),
            .@"expr ::= nm DOT nm" => {
                const t1 = try tokenExpr(p, TK.ID, s.m(-2).tok);
                const t2 = try tokenExpr(p, TK.ID, s.m(0).tok);
                lhs.expr = try expr.pExpr(p, TK.DOT, t1, t2);
                s.m(-2).expr = lhs.expr;
            },
            .@"expr ::= nm DOT nm DOT nm" => {
                const t1 = try tokenExpr(p, TK.ID, s.m(-4).tok);
                const t2 = try tokenExpr(p, TK.ID, s.m(-2).tok);
                const t3 = try tokenExpr(p, TK.ID, s.m(0).tok);
                const t4 = try expr.pExpr(p, TK.DOT, t2, t3);
                if (p.inRenameObject()) alter.renameTokenRemap(p, null, t1);
                lhs.expr = try expr.pExpr(p, TK.DOT, t1, t4);
                s.m(-4).expr = lhs.expr;
            },
            .@"term ::= NULL|FLOAT|BLOB",
            .@"term ::= STRING",
            => s.m(0).expr = try tokenExpr(p, s.major(0), s.m(0).tok),
            .@"term ::= INTEGER" => {
                const t = s.m(0).tok;
                const e = if (util.getInt32(t.slice())) |v|
                    try expr.exprInt32(a, v)
                else
                    try expr.exprAlloc(a, TK.INTEGER, t, false);
                e.w = .{ .ofst = expr.tokenOffset(p, t) };
                s.m(0).expr = e;
            },
            .@"expr ::= VARIABLE" => {
                const t = s.m(0).tok;
                const z = t.z.?;
                if (!(z[0] == '#' and ctype.isDigit(z[1]))) {
                    const e = try tokenExpr(p, TK.VARIABLE, t);
                    try expr.assignVarNumber(p, e, t.n);
                    s.m(0).expr = e;
                } else if (p.nested == 0) {
                    // "#N" names register N, only in nested parses.
                    syntaxError(p, t);
                    s.m(0).expr = null;
                } else {
                    const e = try expr.pExpr(p, TK.REGISTER, null, null);
                    e.i_table = util.getInt32(t.slice()[1..]) orelse 0;
                    s.m(0).expr = e;
                }
            },
            .@"expr ::= expr COLLATE ID|STRING" => {
                s.m(-2).expr = try expr.addCollateToken(p, s.m(-2).expr.?, s.m(0).tok, true);
            },
            .@"expr ::= CAST LP expr AS typetoken RP" => {
                const e = try expr.exprAlloc(a, TK.CAST, s.m(-1).tok, true);
                expr.attachSubtrees(e, s.m(-3).expr, null);
                s.m(-5).expr = e;
            },
            .@"expr ::= ID|INDEXED|JOIN_KW LP distinct exprlist RP" => {
                lhs.expr = try expr.exprFunction(p, s.m(-1).elist, s.m(-4).tok, s.m(-2).sf);
                s.m(-4).expr = lhs.expr;
            },
            .@"expr ::= ID|INDEXED|JOIN_KW LP distinct exprlist ORDER BY sortlist RP" => {
                const e = try expr.exprFunction(p, s.m(-4).elist, s.m(-7).tok, s.m(-5).sf);
                if (s.m(-1).elist) |ob| try expr.addFunctionOrderBy(p, e, ob);
                s.m(-7).expr = e;
            },
            .@"expr ::= ID|INDEXED|JOIN_KW LP STAR RP" => {
                lhs.expr = try expr.exprFunction(p, null, s.m(-3).tok, .{});
                s.m(-3).expr = lhs.expr;
            },
            .@"expr ::= ID|INDEXED|JOIN_KW LP distinct exprlist RP filter_over" => {
                const e = try expr.exprFunction(p, s.m(-2).elist, s.m(-5).tok, s.m(-3).sf);
                if (s.m(0).window) |w| win.windowAttach(p, e, w);
                s.m(-5).expr = e;
            },
            .@"expr ::= ID|INDEXED|JOIN_KW LP distinct exprlist ORDER BY sortlist RP filter_over" => {
                const e = try expr.exprFunction(p, s.m(-5).elist, s.m(-8).tok, s.m(-6).sf);
                if (s.m(0).window) |w| win.windowAttach(p, e, w);
                if (s.m(-2).elist) |ob| try expr.addFunctionOrderBy(p, e, ob);
                s.m(-8).expr = e;
            },
            .@"expr ::= ID|INDEXED|JOIN_KW LP STAR RP filter_over" => {
                const e = try expr.exprFunction(p, null, s.m(-4).tok, .{});
                if (s.m(0).window) |w| win.windowAttach(p, e, w);
                s.m(-4).expr = e;
            },
            .@"term ::= CTIME_KW" => {
                lhs.expr = try expr.exprFunction(p, null, s.m(0).tok, .{});
                s.m(0).expr = lhs.expr;
            },
            .@"expr ::= LP nexprlist COMMA expr RP" => {
                const list = try expr.listAppend(p, s.m(-3).elist, s.m(-1).expr);
                const e = try expr.pExpr(p, TK.VECTOR, null, null);
                e.x = .{ .list = list };
                for (list.slice()) |item| e.flags.set(item.expr.?.flags.only(EP.Propagate));
                s.m(-4).expr = e;
            },
            .@"expr ::= expr AND expr" => s.m(-2).expr = try expr.exprAnd(p, s.m(-2).expr, s.m(0).expr),
            .@"expr ::= expr OR expr",
            .@"expr ::= expr LT|GT|GE|LE expr",
            .@"expr ::= expr EQ|NE expr",
            .@"expr ::= expr BITAND|BITOR|LSHIFT|RSHIFT expr",
            .@"expr ::= expr PLUS|MINUS expr",
            .@"expr ::= expr STAR|SLASH|REM expr",
            .@"expr ::= expr CONCAT expr",
            => s.m(-2).expr = try expr.pExpr(p, s.major(-1), s.m(-2).expr, s.m(0).expr),
            .@"likeop ::= NOT LIKE_KW|MATCH" => {
                s.m(-1).tok = s.m(0).tok;
                s.m(-1).tok.n |= 0x80000000;
            },
            .@"expr ::= expr likeop expr" => {
                const not = s.m(-1).tok.n & 0x80000000 != 0;
                s.m(-1).tok.n &= 0x7fffffff;
                var list = try expr.listAppend(p, null, s.m(0).expr);
                list = try expr.listAppend(p, list, s.m(-2).expr);
                var e = try expr.exprFunction(p, list, s.m(-1).tok, .{});
                if (not) e = try expr.pExpr(p, TK.NOT, e, null);
                e.flags.InfixFunc = true;
                s.m(-2).expr = e;
            },
            .@"expr ::= expr likeop expr ESCAPE expr" => {
                const not = s.m(-3).tok.n & 0x80000000 != 0;
                s.m(-3).tok.n &= 0x7fffffff;
                var list = try expr.listAppend(p, null, s.m(-2).expr);
                list = try expr.listAppend(p, list, s.m(-4).expr);
                list = try expr.listAppend(p, list, s.m(0).expr);
                var e = try expr.exprFunction(p, list, s.m(-3).tok, .{});
                if (not) e = try expr.pExpr(p, TK.NOT, e, null);
                e.flags.InfixFunc = true;
                s.m(-4).expr = e;
            },
            .@"expr ::= expr ISNULL|NOTNULL" => s.m(-1).expr = try pExprIsNull(p, s.major(0), s.m(-1).expr.?),
            .@"expr ::= expr NOT NULL" => s.m(-2).expr = try pExprIsNull(p, TK.NOTNULL, s.m(-2).expr.?),
            .@"expr ::= expr IS expr" => s.m(-2).expr = try pExprIs(p, TK.IS, s.m(-2).expr.?, s.m(0).expr),
            .@"expr ::= expr IS NOT expr" => s.m(-3).expr = try pExprIs(p, TK.ISNOT, s.m(-3).expr.?, s.m(0).expr),
            .@"expr ::= expr IS NOT DISTINCT FROM expr" => s.m(-5).expr = try pExprIs(p, TK.IS, s.m(-5).expr.?, s.m(0).expr),
            .@"expr ::= expr IS DISTINCT FROM expr" => s.m(-4).expr = try pExprIs(p, TK.ISNOT, s.m(-4).expr.?, s.m(0).expr),
            .@"expr ::= NOT expr",
            .@"expr ::= BITNOT expr",
            => s.m(-1).expr = try expr.pExpr(p, s.major(-1), s.m(0).expr, null),
            .@"expr ::= PLUS|MINUS expr" => {
                const e = s.m(0).expr;
                const op: u8 = s.major(-1) + (TK.UPLUS - TK.PLUS);
                if (e != null and e.?.op == TK.UPLUS) {
                    e.?.op = op;
                    s.m(-1).expr = e;
                } else {
                    s.m(-1).expr = try expr.pExpr(p, op, e, null);
                }
            },
            .@"expr ::= expr PTR expr" => {
                var list = try expr.listAppend(p, null, s.m(-2).expr);
                list = try expr.listAppend(p, list, s.m(0).expr);
                lhs.expr = try expr.exprFunction(p, list, s.m(-1).tok, .{});
                s.m(-2).expr = lhs.expr;
            },
            .@"between_op ::= BETWEEN",
            .@"in_op ::= IN",
            => s.m(0).int = 0,
            .@"expr ::= expr between_op expr AND expr" => {
                var list = try expr.listAppend(p, null, s.m(-2).expr);
                list = try expr.listAppend(p, list, s.m(0).expr);
                var e = try expr.pExpr(p, TK.BETWEEN, s.m(-4).expr, null);
                e.x = .{ .list = list };
                expr.setHeightAndFlags(p, e);
                if (s.m(-3).int != 0) e = try expr.pExpr(p, TK.NOT, e, null);
                s.m(-4).expr = e;
            },
            .@"expr ::= expr in_op LP exprlist RP" => try inList(s, p),
            .@"expr ::= LP select RP" => {
                const e = try expr.pExpr(p, TK.SELECT, null, null);
                expr.pExprAddSelect(p, e, s.m(-1).select);
                s.m(-2).expr = e;
            },
            .@"expr ::= expr in_op LP select RP" => {
                var e = try expr.pExpr(p, TK.IN, s.m(-4).expr, null);
                expr.pExprAddSelect(p, e, s.m(-1).select);
                if (s.m(-3).int != 0) e = try expr.pExpr(p, TK.NOT, e, null);
                s.m(-4).expr = e;
            },
            .@"expr ::= expr in_op nm dbnm paren_exprlist" => {
                const src = try build.srcListAppend(p, null, s.m(-2).tok, s.m(-1).tok);
                const sub = try sel.selectNew(p, null, src, null, null, null, null, .{}, null);
                if (s.m(0).elist) |args| build.srcListFuncArgs(src, args);
                var e = try expr.pExpr(p, TK.IN, s.m(-4).expr, null);
                expr.pExprAddSelect(p, e, sub);
                if (s.m(-3).int != 0) e = try expr.pExpr(p, TK.NOT, e, null);
                s.m(-4).expr = e;
            },
            .@"expr ::= EXISTS LP select RP" => {
                const e = try expr.pExpr(p, TK.EXISTS, null, null);
                s.m(-3).expr = e;
                expr.pExprAddSelect(p, e, s.m(-1).select);
            },
            .@"expr ::= CASE case_operand case_exprlist case_else END" => {
                const e = try expr.pExpr(p, TK.CASE, s.m(-3).expr, null);
                e.x = .{ .list = if (s.m(-1).expr != null)
                    try expr.listAppend(p, s.m(-2).elist, s.m(-1).expr)
                else
                    s.m(-2).elist };
                expr.setHeightAndFlags(p, e);
                s.m(-4).expr = e;
            },
            .@"case_exprlist ::= case_exprlist WHEN expr THEN expr" => {
                s.m(-4).elist = try expr.listAppend(p, s.m(-4).elist, s.m(-2).expr);
                s.m(-4).elist = try expr.listAppend(p, s.m(-4).elist, s.m(0).expr);
            },
            .@"case_exprlist ::= WHEN expr THEN expr" => {
                s.m(-3).elist = try expr.listAppend(p, null, s.m(-2).expr);
                s.m(-3).elist = try expr.listAppend(p, s.m(-3).elist, s.m(0).expr);
            },
            .@"nexprlist ::= nexprlist COMMA expr" => s.m(-2).elist = try expr.listAppend(p, s.m(-2).elist, s.m(0).expr),
            .@"nexprlist ::= expr" => s.m(0).elist = try expr.listAppend(p, null, s.m(0).expr),
            .@"paren_exprlist ::= LP exprlist RP",
            .@"eidlist_opt ::= LP eidlist RP",
            => s.m(-2).elist = s.m(-1).elist,
            .@"cmd ::= createkw uniqueflag INDEX ifnotexists nm dbnm ON nm LP sortlist RP where_opt" => {
                const tbl = try build.srcListAppend(p, null, s.m(-4).tok, null);
                build.createIndex(p, s.m(-7).tok, s.m(-6).tok, tbl, s.m(-2).elist, s.m(-10).oe, s.m(-11).tok, s.m(0).expr, SO.asc, s.m(-8).int != 0, .appdef);
                if (p.inRenameObject()) if (p.new_index) |idx| alter.renameTokenMap(p, idx.name.ptr, s.m(-4).tok);
            },
            .@"uniqueflag ::= UNIQUE",
            .@"raisetype ::= ABORT",
            => s.m(0).oe = .Abort,
            .@"uniqueflag ::=" => s.m(1).oe = .None,
            .@"eidlist ::= eidlist COMMA nm collate sortorder" => {
                s.m(-4).elist = try addExprIdListTerm(p, s.m(-4).elist, s.m(-2).tok, s.m(-1).int != 0, s.m(0).int);
            },
            .@"eidlist ::= nm collate sortorder" => {
                s.m(-2).elist = try addExprIdListTerm(p, null, s.m(-2).tok, s.m(-1).int != 0, s.m(0).int);
            },
            .@"cmd ::= DROP INDEX ifexists fullname" => build.dropIndex(p, s.m(0).srclist, s.m(-1).int != 0),
            .@"cmd ::= VACUUM vinto" => vacuum_mod.vacuum(p, null, s.m(0).expr),
            .@"cmd ::= VACUUM nm vinto" => vacuum_mod.vacuum(p, s.m(-1).tok, s.m(0).expr),
            .@"cmd ::= PRAGMA nm dbnm" => pragma_mod.pragma(p, s.m(-1).tok, s.m(0).tok, null, false),
            .@"cmd ::= PRAGMA nm dbnm EQ nmnum" => pragma_mod.pragma(p, s.m(-3).tok, s.m(-2).tok, s.m(0).tok, false),
            .@"cmd ::= PRAGMA nm dbnm LP nmnum RP" => pragma_mod.pragma(p, s.m(-4).tok, s.m(-3).tok, s.m(-1).tok, false),
            .@"cmd ::= PRAGMA nm dbnm EQ minus_num" => pragma_mod.pragma(p, s.m(-3).tok, s.m(-2).tok, s.m(0).tok, true),
            .@"cmd ::= PRAGMA nm dbnm LP minus_num RP" => pragma_mod.pragma(p, s.m(-4).tok, s.m(-3).tok, s.m(-1).tok, true),
            .@"cmd ::= createkw trigger_decl BEGIN trigger_cmd_list END" => {
                const all: Token = .{ .z = s.m(-3).tok.z, .n = spanLen(s.m(-3).tok, s.m(0).tok) };
                trig.finishTrigger(p, s.m(-1).trig_step, all);
            },
            .@"trigger_decl ::= temp TRIGGER ifnotexists nm dbnm trigger_time trigger_event ON fullname foreach_clause when_clause" => {
                trig.beginTrigger(p, s.m(-7).tok, s.m(-6).tok, s.m(-5).int, s.m(-4).trig_event.a, s.m(-4).trig_event.b, s.m(-2).srclist, s.m(0).expr, s.m(-10).int != 0, s.m(-8).int != 0);
                s.m(-10).tok = if (s.m(-6).tok.n == 0) s.m(-7).tok else s.m(-6).tok;
                p.is_create = false;
            },
            .@"trigger_time ::= BEFORE|AFTER" => s.m(0).int = s.major(0),
            .@"trigger_time ::= INSTEAD OF" => s.m(-1).int = TK.INSTEAD,
            .@"trigger_time ::=" => s.m(1).int = TK.BEFORE,
            .@"trigger_event ::= DELETE|INSERT",
            .@"trigger_event ::= UPDATE",
            => s.m(0).trig_event = .{ .a = s.major(0), .b = null },
            .@"trigger_event ::= UPDATE OF idlist" => s.m(-2).trig_event = .{ .a = TK.UPDATE, .b = s.m(0).idlist },
            .@"when_clause ::=",
            .@"key_opt ::=",
            => s.m(1).expr = null,
            .@"when_clause ::= WHEN expr",
            .@"key_opt ::= KEY expr",
            => s.m(-1).expr = s.m(0).expr,
            .@"trigger_cmd_list ::= trigger_cmd_list trigger_cmd SEMI" => {
                if (s.m(-2).trig_step) |first| {
                    first.last.?.next = s.m(-1).trig_step;
                    first.last = s.m(-1).trig_step;
                }
            },
            .@"trigger_cmd_list ::= trigger_cmd SEMI" => if (s.m(-1).trig_step) |t| {
                t.last = t;
            },
            .@"tridxby ::= INDEXED BY nm" => {
                util.errorMsg(p, "the INDEXED BY clause is not allowed on UPDATE or DELETE statements within triggers", .{});
            },
            .@"tridxby ::= NOT INDEXED" => {
                util.errorMsg(p, "the NOT INDEXED clause is not allowed on UPDATE or DELETE statements within triggers", .{});
            },
            .@"trigger_cmd ::= UPDATE orconf xfullname tridxby SET setlist from where_opt scanpt" => {
                lhs.trig_step = if (s.m(-6).srclist) |t|
                    try trig.updateStep(p, t, s.m(-2).srclist, s.m(-3).elist, s.m(-1).expr, s.m(-7).oe, s.m(-8).tok.z.?, s.m(0).str.?)
                else
                    null;
                s.m(-8).trig_step = lhs.trig_step;
            },
            .@"trigger_cmd ::= scanpt insert_cmd INTO xfullname idlist_opt select upsert scanpt" => {
                lhs.trig_step = if (s.m(-4).srclist) |t|
                    try trig.insertStep(p, t, s.m(-3).idlist, s.m(-2).select, s.m(-6).oe, s.m(-1).upsert, s.m(-7).str.?, s.m(0).str.?)
                else
                    null;
                s.m(-7).trig_step = lhs.trig_step;
            },
            .@"trigger_cmd ::= DELETE FROM xfullname tridxby where_opt scanpt" => {
                lhs.trig_step = if (s.m(-3).srclist) |t|
                    try trig.deleteStep(p, t, s.m(-1).expr, s.m(-5).tok.z.?, s.m(0).str.?)
                else
                    null;
                s.m(-5).trig_step = lhs.trig_step;
            },
            .@"trigger_cmd ::= scanpt select scanpt" => {
                lhs.trig_step = try trig.selectStep(p, s.m(-1).select, s.m(-2).str.?, s.m(0).str.?);
                s.m(-2).trig_step = lhs.trig_step;
            },
            .@"expr ::= RAISE LP IGNORE RP" => {
                const e = try expr.pExpr(p, TK.RAISE, null, null);
                e.aff_expr = OE.Ignore.int();
                s.m(-3).expr = e;
            },
            .@"expr ::= RAISE LP raisetype COMMA expr RP" => {
                const e = try expr.pExpr(p, TK.RAISE, s.m(-1).expr, null);
                e.aff_expr = s.m(-3).oe.int();
                s.m(-5).expr = e;
            },
            .@"raisetype ::= ROLLBACK" => s.m(0).oe = .Rollback,
            .@"raisetype ::= FAIL" => s.m(0).oe = .Fail,
            .@"cmd ::= DROP TRIGGER ifexists fullname" => trig.dropTrigger(p, s.m(0).srclist, s.m(-1).int != 0),
            .@"cmd ::= ATTACH database_kw_opt expr AS expr key_opt" => attach_mod.attach(p, s.m(-3).expr, s.m(-1).expr, s.m(0).expr),
            .@"cmd ::= DETACH database_kw_opt expr" => attach_mod.detach(p, s.m(0).expr),
            .@"cmd ::= REINDEX" => build.reindex(p, null, null),
            .@"cmd ::= REINDEX nm dbnm" => build.reindex(p, s.m(-1).tok, s.m(0).tok),
            .@"cmd ::= ANALYZE" => analyze_mod.analyze(p, null, null),
            .@"cmd ::= ANALYZE nm dbnm" => analyze_mod.analyze(p, s.m(-1).tok, s.m(0).tok),
            .@"cmd ::= ALTER TABLE fullname RENAME TO nm" => alter.renameTable(p, s.m(-3).srclist, s.m(0).tok),
            .@"cmd ::= alter_add carglist" => {
                s.m(-1).tok.n = spanLen(s.m(-1).tok, p.last_token);
                alter.finishAddColumn(p, s.m(-1).tok);
            },
            .@"alter_add ::= ALTER TABLE fullname ADD kwcolumn_opt nm typetoken" => {
                disableLookaside(p);
                alter.beginAddColumn(p, s.m(-4).srclist);
                build.addColumn(p, s.m(-1).tok, s.m(0).tok);
                s.m(-6).tok = s.m(-1).tok;
            },
            .@"cmd ::= ALTER TABLE fullname DROP kwcolumn_opt nm" => alter.dropColumn(p, s.m(-3).srclist, s.m(0).tok),
            .@"cmd ::= ALTER TABLE fullname RENAME kwcolumn_opt nm TO nm" => alter.renameColumn(p, s.m(-5).srclist, s.m(-2).tok, s.m(0).tok),
            .@"cmd ::= ALTER TABLE fullname DROP CONSTRAINT nm" => alter.dropConstraint(p, s.m(-3).srclist, s.m(0).tok, null),
            .@"cmd ::= ALTER TABLE fullname ALTER kwcolumn_opt nm DROP NOT NULL" => alter.dropConstraint(p, s.m(-6).srclist, null, s.m(-3).tok),
            .@"cmd ::= ALTER TABLE fullname ALTER kwcolumn_opt nm SET NOT NULL onconf" => alter.setNotNull(p, s.m(-7).srclist, s.m(-4).tok, s.m(-2).tok),
            .@"cmd ::= ALTER TABLE fullname ADD CONSTRAINT nm CHECK LP expr RP onconf" => {
                const lp = s.m(-3).tok.z.?;
                alter.addConstraint(p, s.m(-8).srclist, s.m(-6).tok, s.m(-5).tok, lp + 1, @intFromPtr(s.m(-1).tok.z.?) - @intFromPtr(lp) - 1, s.m(-2).expr);
            },
            .@"cmd ::= ALTER TABLE fullname ADD CHECK LP expr RP onconf" => {
                const lp = s.m(-3).tok.z.?;
                alter.addConstraint(p, s.m(-6).srclist, s.m(-4).tok, null, lp + 1, @intFromPtr(s.m(-1).tok.z.?) - @intFromPtr(lp) - 1, s.m(-2).expr);
            },
            .@"cmd ::= create_vtab" => vtab.finishParse(p, null),
            .@"cmd ::= create_vtab LP vtabarglist RP" => vtab.finishParse(p, s.m(0).tok),
            .@"create_vtab ::= createkw VIRTUAL TABLE ifnotexists nm dbnm USING nm" => {
                vtab.beginParse(p, s.m(-3).tok, s.m(-2).tok, s.m(0).tok, s.m(-4).int != 0);
            },
            .@"vtabarg ::=" => vtab.argInit(p),
            .@"vtabargtoken ::= ANY",
            .@"vtabargtoken ::= lp anylist RP",
            .@"lp ::= LP",
            => vtab.argExtend(p, s.m(0).tok),
            .@"with ::= WITH wqlist",
            .@"with ::= WITH RECURSIVE wqlist",
            => _ = sel.withPush(p, s.m(0).with),
            .@"wqas ::= AS" => s.m(0).u8 = @intFromEnum(int.M10d.any),
            .@"wqas ::= AS MATERIALIZED" => s.m(-1).u8 = @intFromEnum(int.M10d.yes),
            .@"wqas ::= AS NOT MATERIALIZED" => s.m(-2).u8 = @intFromEnum(int.M10d.no),
            .@"wqitem ::= withnm eidlist_opt wqas LP select RP" => {
                s.m(-5).cte = try build.cteNew(p, s.m(-5).tok, s.m(-4).elist, s.m(-1).select, @enumFromInt(s.m(-3).u8));
            },
            .@"withnm ::= nm" => p.has_with = true,
            .@"wqlist ::= wqitem" => s.m(0).with = try build.withAdd(p, null, s.m(0).cte.?),
            .@"wqlist ::= wqlist COMMA wqitem" => s.m(-2).with = try build.withAdd(p, s.m(-2).with, s.m(0).cte.?),
            .@"windowdefn_list ::= windowdefn_list COMMA windowdefn" => {
                const w = s.m(0).window.?;
                try win.windowChain(p, w, s.m(-2).window);
                w.next_win = s.m(-2).window;
                s.m(-2).window = w;
            },
            .@"windowdefn ::= nm AS LP window RP" => {
                if (s.m(-1).window) |w| w.name = try a.dupeSentinel(u8, s.m(-4).tok.slice(), 0);
                lhs.window = s.m(-1).window;
                s.m(-4).window = lhs.window;
            },
            .@"window ::= PARTITION BY nexprlist orderby_opt frame_opt" => {
                s.m(-4).window = try win.windowAssemble(p, s.m(0).window, s.m(-2).elist, s.m(-1).elist, null);
            },
            .@"window ::= nm PARTITION BY nexprlist orderby_opt frame_opt" => {
                lhs.window = try win.windowAssemble(p, s.m(0).window, s.m(-2).elist, s.m(-1).elist, s.m(-5).tok);
                s.m(-5).window = lhs.window;
            },
            .@"window ::= ORDER BY sortlist frame_opt" => {
                s.m(-3).window = try win.windowAssemble(p, s.m(0).window, null, s.m(-1).elist, null);
            },
            .@"window ::= nm ORDER BY sortlist frame_opt" => {
                lhs.window = try win.windowAssemble(p, s.m(0).window, null, s.m(-1).elist, s.m(-4).tok);
                s.m(-4).window = lhs.window;
            },
            .@"window ::= nm frame_opt" => {
                lhs.window = try win.windowAssemble(p, s.m(0).window, null, null, s.m(-1).tok);
                s.m(-1).window = lhs.window;
            },
            .@"frame_opt ::=" => {
                s.m(1).window = try win.windowAlloc(p, 0, TK.UNBOUNDED, null, TK.CURRENT, null, 0);
            },
            .@"frame_opt ::= range_or_rows frame_bound_s frame_exclude_opt" => {
                const fb = s.m(-1).frame_bound;
                lhs.window = try win.windowAlloc(p, s.m(-2).int, fb.e_type, fb.expr, TK.CURRENT, null, s.m(0).u8);
                s.m(-2).window = lhs.window;
            },
            .@"frame_opt ::= range_or_rows BETWEEN frame_bound_s AND frame_bound_e frame_exclude_opt" => {
                const s0 = s.m(-3).frame_bound;
                const e0 = s.m(-1).frame_bound;
                lhs.window = try win.windowAlloc(p, s.m(-5).int, s0.e_type, s0.expr, e0.e_type, e0.expr, s.m(0).u8);
                s.m(-5).window = lhs.window;
            },
            .@"frame_bound_s ::= frame_bound",
            .@"frame_bound_e ::= frame_bound",
            => {},
            .@"frame_bound_s ::= UNBOUNDED PRECEDING",
            .@"frame_bound_e ::= UNBOUNDED FOLLOWING",
            .@"frame_bound ::= CURRENT ROW",
            => s.m(-1).frame_bound = .{ .e_type = s.major(-1), .expr = null },
            .@"frame_bound ::= expr PRECEDING|FOLLOWING" => {
                // Through a temporary: the result shares the slot of the expr.
                lhs.frame_bound = .{ .e_type = s.major(0), .expr = s.m(-1).expr };
                s.m(-1).frame_bound = lhs.frame_bound;
            },
            .@"frame_exclude_opt ::=" => s.m(1).u8 = 0,
            .@"frame_exclude_opt ::= EXCLUDE frame_exclude" => s.m(-1).u8 = s.m(0).u8,
            .@"frame_exclude ::= NO OTHERS",
            .@"frame_exclude ::= CURRENT ROW",
            => s.m(-1).u8 = s.major(-1),
            .@"frame_exclude ::= GROUP|TIES" => s.m(0).u8 = s.major(0),
            .@"window_clause ::= WINDOW windowdefn_list" => s.m(-1).window = s.m(0).window,
            .@"filter_over ::= filter_clause over_clause" => {
                if (s.m(0).window) |w| w.filter = s.m(-1).expr;
                lhs.window = s.m(0).window;
                s.m(-1).window = lhs.window;
            },
            .@"filter_over ::= over_clause" => {},
            .@"filter_over ::= filter_clause" => {
                const w = try a.create(Window);
                w.* = .{ .e_frm_type = TK.FILTER, .filter = s.m(0).expr };
                s.m(0).window = w;
            },
            .@"over_clause ::= OVER LP window RP" => s.m(-3).window = s.m(-1).window,
            .@"over_clause ::= OVER nm" => {
                const w = try a.create(Window);
                w.* = .{ .name = try a.dupeSentinel(u8, s.m(0).tok.slice(), 0) };
                s.m(-1).window = w;
            },
            .@"filter_clause ::= FILTER LP WHERE expr RP" => s.m(-4).expr = s.m(-1).expr,
            .@"term ::= QNUMBER" => {
                const e = try tokenExpr(p, s.major(0), s.m(0).tok);
                util.dequoteNumber(p, e);
                s.m(0).expr = e;
            },

            // Rules without actions, including those lemon optimized out.
            .@"input ::= cmdlist",
            .@"cmdlist ::= cmdlist ecmd",
            .@"cmdlist ::= ecmd",
            .@"ecmd ::= SEMI",
            .@"ecmd ::= cmdx SEMI",
            .@"ecmd ::= explain cmdx SEMI",
            .@"trans_opt ::=",
            .@"trans_opt ::= TRANSACTION",
            .@"trans_opt ::= TRANSACTION nm",
            .@"savepoint_opt ::= SAVEPOINT",
            .@"savepoint_opt ::=",
            .@"cmd ::= create_table create_table_args",
            .@"table_option_set ::= table_option",
            .@"columnlist ::= columnlist COMMA columnname carglist",
            .@"columnlist ::= columnname carglist",
            .@"nm ::= ID|INDEXED|JOIN_KW",
            .@"nm ::= STRING",
            .@"typetoken ::= typename",
            .@"typename ::= ID|STRING",
            .@"signed ::= plus_num",
            .@"signed ::= minus_num",
            .@"carglist ::= carglist ccons",
            .@"carglist ::=",
            .@"ccons ::= NULL onconf",
            .@"ccons ::= GENERATED ALWAYS AS generated",
            .@"ccons ::= AS generated",
            .@"conslist_opt ::= COMMA conslist",
            .@"conslist ::= conslist tconscomma tcons",
            .@"conslist ::= tcons",
            .@"tconscomma ::=",
            .@"defer_subclause_opt ::= defer_subclause",
            .@"resolvetype ::= raisetype",
            .@"selectnowith ::= oneselect",
            .@"oneselect ::= values",
            .@"sclp ::= selcollist COMMA",
            .@"as ::= ID|STRING",
            .@"indexed_opt ::= indexed_by",
            .@"returning ::=",
            .@"expr ::= term",
            .@"likeop ::= LIKE_KW|MATCH",
            .@"case_operand ::= expr",
            .@"exprlist ::= nexprlist",
            .@"nmnum ::= plus_num",
            .@"nmnum ::= nm",
            .@"nmnum ::= ON",
            .@"nmnum ::= DELETE",
            .@"nmnum ::= DEFAULT",
            .@"plus_num ::= INTEGER|FLOAT",
            .@"foreach_clause ::=",
            .@"foreach_clause ::= FOR EACH ROW",
            .@"tridxby ::=",
            .@"database_kw_opt ::= DATABASE",
            .@"database_kw_opt ::=",
            .@"kwcolumn_opt ::=",
            .@"kwcolumn_opt ::= COLUMNKW",
            .@"vtabarglist ::= vtabarg",
            .@"vtabarglist ::= vtabarglist COMMA vtabarg",
            .@"vtabarg ::= vtabarg vtabargtoken",
            .@"anylist ::=",
            .@"anylist ::= anylist LP anylist RP",
            .@"anylist ::= anylist ANY",
            .@"with ::=",
            .@"windowdefn_list ::= windowdefn",
            .@"window ::= frame_opt",
            => {},
        }
    }
};

/// Port of yy_find_shift_action().
fn findShiftAction(lookahead_arg: u8, stateno: u16) u16 {
    if (stateno > g.YY_MAX_SHIFT) return stateno;
    var lookahead: u16 = lookahead_arg;
    while (true) {
        const i: usize = g.yy_shift_ofst[stateno] + @as(usize, lookahead);
        if (g.yy_lookahead[i] == lookahead) return g.yy_action[i];
        const fallback = g.yy_fallback[lookahead];
        if (fallback != 0) {
            lookahead = fallback;
            continue;
        }
        const j = i - lookahead + g.YYWILDCARD;
        if (g.yy_lookahead[j] == g.YYWILDCARD and lookahead > 0) return g.yy_action[j];
        return g.yy_default[stateno];
    }
}

/// Port of yy_find_reduce_action().
fn findReduceAction(stateno: u16, lookahead: u16) u16 {
    std.debug.assert(stateno <= g.YY_REDUCE_COUNT);
    const i: usize = @intCast(@as(i32, g.yy_reduce_ofst[stateno]) + lookahead);
    std.debug.assert(g.yy_lookahead[i] == lookahead);
    return g.yy_action[i];
}

// ============================================== helpers from parse.y

/// Port of parserSyntaxError().
pub fn syntaxError(p: *Parse, t: Token) void {
    util.errorMsgAt(p, t.z, "near \"{s}\": syntax error", .{t.slice()});
}

/// Port of disableLookaside(): starting a CREATE statement, whose objects
/// may outlive the statement, so not in lookaside.
fn disableLookaside(p: *Parse) void {
    p.disable_lookaside += 1;
    @import("../sql/malloc.zig").disableLookaside(p.db);
    p.is_create = true;
    p.u1 = .{ .cr = .{} };
}

/// The length of the text from the start of `from` to the end of `to`.
fn spanLen(from: Token, to: Token) u32 {
    return @intCast(@intFromPtr(to.z.? + to.n) - @intFromPtr(from.z.?));
}

/// One past the end of a token.
fn tokEnd(t: Token) ?[*]const u8 {
    return if (t.z) |z| z + t.n else null;
}

/// Port of tokenExpr(): a leaf node for one token, dequoted if quoted.
fn tokenExpr(p: *Parse, op: u8, t: Token) Oom!*Expr {
    const e = try p.arena.create(Expr);
    e.* = .{
        .op = op,
        .flags = .{ .Leaf = true },
        .u = .{ .token = try p.arena.dupeSentinel(u8, t.slice(), 0) },
        .w = .{ .ofst = expr.tokenOffset(p, t) },
        .n_height = 1,
    };
    if (t.n > 0 and ctype.isQuote(e.u.token.?[0])) util.dequoteExpr(e);
    if (p.inRenameObject()) alter.renameTokenMap(p, e, t);
    return e;
}

/// Port of parserDoubleLinkSelect(): set the `next` links of a compound
/// and check its ORDER BY/LIMIT placement and size.
fn doubleLinkSelect(p: *Parse, s: *Select) void {
    if (s.prior == null) return;
    var next: ?*Select = null;
    var loop: *Select = s;
    var cnt: i32 = 1;
    while (true) {
        loop.next = next;
        loop.sel_flags.Compound = true;
        next = loop;
        loop = loop.prior orelse break;
        cnt += 1;
        if (loop.order_by != null or loop.limit != null) {
            util.errorMsg(p, "{s} clause should come after {s} not before", .{
                if (loop.order_by != null) "ORDER BY" else "LIMIT",
                sel.selectOpName(next.?.op),
            });
            break;
        }
    }
    const mx = p.db.limit(.compound_select);
    if (!s.sel_flags.intersects(.{ .MultiValue = true, .Values = true }) and mx > 0 and cnt > mx) {
        util.errorMsg(p, "too many terms in compound SELECT", .{});
    }
}

/// Port of attachWithToSelect().
fn attachWithToSelect(p: *Parse, s_arg: ?*Select, with: ?*With) ?*Select {
    const s = s_arg orelse return null;
    s.with = with;
    doubleLinkSelect(p, s);
    return s;
}

/// Port of parserAddExprIdListTerm(): a name in a column list where
/// COLLATE and ASC/DESC are only accepted in an existing schema.
fn addExprIdListTerm(p: *Parse, prior: ?*ExprList, id: Token, has_collate: bool, sort_order: i32) Oom!*ExprList {
    const l = try expr.listAppend(p, prior, null);
    if ((has_collate or sort_order != SO.undef) and !p.db.init.busy) {
        util.errorMsg(p, "syntax error after column name \"{s}\"", .{id.slice()});
    }
    try expr.listSetName(p, l, id, true);
    return l;
}

/// Port of sqlite3PExprIsNull(): ISNULL/NOTNULL, folded to a constant for
/// literal operands.
fn pExprIsNull(p: *Parse, op: u8, left: *Expr) Oom!*Expr {
    std.debug.assert(op == TK.ISNULL or op == TK.NOTNULL);
    var e = left;
    while (e.op == TK.UPLUS or e.op == TK.UMINUS) e = e.left.?;
    switch (e.op) {
        TK.INTEGER, TK.STRING, TK.FLOAT, TK.BLOB => return expr.exprInt32(p.arena, @intFromBool(op == TK.NOTNULL)),
        else => return expr.pExpr(p, op, left, null),
    }
}

/// Port of sqlite3PExprIs(): IS/IS NOT, turned into ISNULL/NOTNULL when
/// comparing with NULL.
fn pExprIs(p: *Parse, op: u8, left: *Expr, right: ?*Expr) Oom!*Expr {
    if (right) |r| if (r.op == TK.NULL) {
        return pExprIsNull(p, if (op == TK.IS) TK.ISNULL else TK.NOTNULL, left);
    };
    return expr.pExpr(p, op, left, right);
}

/// The action of "seltablist ::= stl_prefix LP seltablist RP as on_using":
/// a parenthesized FROM clause. A single term is merged into the outer
/// list; several become a nested subquery.
fn nestedFrom(s: *Parser, p: *Parse) Oom!void {
    const inner = s.m(-3).srclist;
    const alias = s.m(-1).tok;
    const on_using = &s.m(0).on_using;
    if (s.m(-5).srclist == null and alias.n == 0 and on_using.on == null and on_using.using == null) {
        s.m(-5).srclist = inner;
    } else if (inner != null and inner.?.len() == 1) {
        s.m(-5).srclist = try build.srcListAppendFromTerm(p, s.m(-5).srclist, null, null, alias, null, on_using);
        if (s.m(-5).srclist) |l| {
            const new = l.at(l.len() - 1);
            const old = inner.?.at(0);
            std.debug.assert(!old.fg.fixed_schema);
            new.name = old.name;
            old.name = null;
            if (old.fg.is_subquery) {
                new.fg.is_subquery = true;
                new.u4 = .{ .subq = old.u4.subq };
                old.u4 = .{ .subq = null };
                old.fg.is_subquery = false;
                if (new.u4.subq.?.select.sel_flags.NestedFrom) new.fg.is_nested_from = true;
            } else {
                new.u4 = .{ .database = old.u4.database };
                old.u4 = .{ .database = null };
            }
            if (old.fg.is_tab_func) {
                new.u1 = .{ .func_arg = old.u1.func_arg };
                old.u1 = .{ .func_arg = null };
                old.fg.is_tab_func = false;
                new.fg.is_tab_func = true;
            } else if (old.fg.is_indexed_by) {
                new.u1 = .{ .indexed_by = old.u1.indexed_by };
                old.u1 = .{ .indexed_by = null };
                old.fg.is_indexed_by = false;
                new.fg.is_indexed_by = true;
            }
            new.fg.not_indexed = old.fg.not_indexed;
        }
    } else {
        build.srcListShiftJoinType(inner);
        const sub = try sel.selectNew(p, null, inner, null, null, null, null, .{ .NestedFrom = true }, null);
        s.m(-5).srclist = try build.srcListAppendFromTerm(p, s.m(-5).srclist, null, null, alias, sub, on_using);
    }
}

/// The action of "expr ::= expr in_op LP exprlist RP".
fn inList(s: *Parser, p: *Parse) Oom!void {
    const not = s.m(-3).int != 0;
    const list_opt = s.m(-1).elist;
    var lhs_e = s.m(-4).expr.?;
    const list = list_opt orelse {
        // "x IN ()" is false and "x NOT IN ()" true; but if x contains a
        // function (maybe an aggregate) keep evaluating it.
        const b = try expr.expr(p.arena, TK.STRING, if (not) "true" else "false");
        _ = expr.idToTrueFalse(b);
        if (!lhs_e.flags.HasFunc) {
            expr.unmapAndDelete(p, lhs_e);
            s.m(-4).expr = b;
        } else {
            s.m(-4).expr = try expr.pExpr(p, if (not) TK.OR else TK.AND, b, lhs_e);
        }
        return;
    };
    var rhs = list.at(0).expr.?;
    if (list.len() == 1 and expr.isConstant(p, rhs) and rhs.op != TK.COLLATE and lhs_e.op != TK.VECTOR) {
        // "x IN (y)" is "x = +y".
        list.at(0).expr = null;
        rhs = try expr.pExpr(p, TK.UPLUS, rhs, null);
        lhs_e = try expr.pExpr(p, TK.EQ, lhs_e, rhs);
    } else if (list.len() == 1 and rhs.op == TK.SELECT) {
        lhs_e = try expr.pExpr(p, TK.IN, lhs_e, null);
        expr.pExprAddSelect(p, lhs_e, rhs.x.select);
        rhs.x = .{ .select = null };
    } else {
        lhs_e = try expr.pExpr(p, TK.IN, lhs_e, null);
        if (lhs_e.left.?.op == TK.VECTOR) {
            const n = lhs_e.left.?.x.list.?.len();
            if (try expr.listToValues(p, n, list)) |values| {
                doubleLinkSelect(p, values);
                expr.pExprAddSelect(p, lhs_e, values);
            }
        } else {
            lhs_e.x = .{ .list = list };
            expr.setHeightAndFlags(p, lhs_e);
        }
    }
    if (not) lhs_e = try expr.pExpr(p, TK.NOT, lhs_e, null);
    s.m(-4).expr = lhs_e;
}
