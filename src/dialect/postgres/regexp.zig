//! PostgreSQL's regular expression functions and SIMILAR TO, on the
//! engine of are.zig.
//!
//! Engine functions (the schema holds them: operators, rows of
//! set-returning calls):
//!
//!   xq_pg_re(s, pattern, flags)     s ~ pattern (flags ''), ~* ('i');
//!                                   `!~`, `!~*` are its NOT. (The
//!                                   older xq_pg_regex() is regex.zig's)
//!   xq_pg_similar_escape(p [, e])   similar_to_escape(): SIMILAR TO's
//!                                   pattern as a regular expression;
//!                                   `s SIMILAR TO p ESCAPE e` is
//!                                   xq_pg_re(s, xq_pg_similar_escape(p, e), '')
//!   xq_pg_rows_regexp_matches(s, p, flags)  the rows of regexp_matches()
//!   xq_pg_rows_regexp_split(s, p, flags)    of regexp_split_to_table()
//!                                   (JSON arrays, as json_each() reads
//!                                   them: parser.zig)
//!
//! The dialect's functions: regexp_match, regexp_replace, regexp_count,
//! regexp_instr, regexp_substr, regexp_like, regexp_split_to_array,
//! similar_to_escape and textregexsubstr (substring(s FROM pattern),
//! substring(s SIMILAR p ESCAPE e)). Their flags, errors, NULLs and
//! positions (in characters, from 1) are PostgreSQL's.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const are = @import("are.zig");
const array = @import("array.zig");
const json = @import("json.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Allocator = std.mem.Allocator;
const FuncDef = int.FuncDef;

const det: dfunc.Options = .{ .deterministic = true };

fn inArena(comptime f: fn (*Call, []*Mem) void) dfunc.StepFn {
    return dfunc.withArena(Call, f);
}

pub const engine_functions = [_]FuncDef{
    dfunc.scalar("xq_pg_re", 3, det, inArena(reFunc)),
    dfunc.scalar("xq_pg_similar_escape", 1, det, inArena(similarEscapeFunc)),
    dfunc.scalar("xq_pg_similar_escape", 2, det, inArena(similarEscapeFunc)),
    dfunc.scalar("xq_pg_rows_regexp_matches", 3, det, inArena(rowsMatchesFunc)),
    dfunc.scalar("xq_pg_rows_regexp_split", 3, det, inArena(rowsSplitFunc)),
};

pub const functions = dfunc.overloads("regexp_match", &.{ 2, 3 }, det, inArena(matchFunc)) ++
    dfunc.overloads("regexp_replace", &.{ 3, 4, 5, 6 }, det, inArena(replaceFunc)) ++
    dfunc.overloads("regexp_count", &.{ 2, 3, 4 }, det, inArena(countFunc)) ++
    dfunc.overloads("regexp_instr", &.{ 2, 3, 4, 5, 6, 7 }, det, inArena(instrFunc)) ++
    dfunc.overloads("regexp_substr", &.{ 2, 3, 4, 5, 6 }, det, inArena(substrFunc)) ++
    dfunc.overloads("regexp_like", &.{ 2, 3 }, det, inArena(likeFunc)) ++
    dfunc.overloads("regexp_split_to_array", &.{ 2, 3 }, det, inArena(splitArrayFunc)) ++
    dfunc.overloads("similar_to_escape", &.{ 1, 2 }, det, inArena(similarEscapeFunc)) ++
    dfunc.overloads("textregexsubstr", &.{ 2, 3 }, det, inArena(textSubstrFunc));

// ================================================================ calls

const Call = struct {
    arena: std.heap.ArenaAllocator,
    ctx: *Context,

    pub fn init(ctx: *Context) Call {
        return .{ .arena = .init(dfunc.gpa(ctx)), .ctx = ctx };
    }

    pub fn deinit(c: *Call) void {
        c.arena.deinit();
    }

    fn a(c: *Call) Allocator {
        return c.arena.allocator();
    }

    fn text(c: *Call, m: *Mem) ?[]const u8 {
        return dfunc.text(c.ctx, m);
    }

    fn oom(c: *Call) void {
        api.resultErrorNomem(c.ctx);
    }

    fn fail(c: *Call, comptime state: *const [5]u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(c.a(), fmt, args) catch return c.oom();
        api.resultErrorState(c.ctx, .of(state), msg);
    }

    fn failFields(c: *Call, comptime state: *const [5]u8, f: @import("../../sql/util.zig").ErrorFields) void {
        api.resultErrorFields(c.ctx, .of(state), f);
    }

    /// Integer argument `m` (not NULL).
    fn intArg(_: *Call, m: *Mem) i64 {
        return api.valueInt64(m);
    }
};

/// A pattern with its flags, compiled: held by the connection's cache
/// and by the statements that keep it as auxiliary data (`refs` of
/// them), freed when the last lets go.
const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    pattern: []const u8,
    opt: are.Options,
    re: are.Regex,
    refs: u32 = 1,

    fn release(x: *Compiled) void {
        x.refs -= 1;
        if (x.refs > 0) return;
        const gpa = x.arena.child_allocator;
        x.arena.deinit();
        gpa.destroy(x);
    }

    fn is(x: *const Compiled, pattern: []const u8, opt: are.Options) bool {
        return std.meta.eql(x.opt, opt) and std.mem.eql(u8, x.pattern, pattern);
    }
};

/// The patterns a connection compiled last, the latest first, as
/// PostgreSQL's RE_compile_and_cache() keeps 32 of them: for a pattern
/// that is no constant, whose auxiliary data lasts one row.
const Cache = struct {
    items: [32]*Compiled = undefined,
    len: usize = 0,

    /// The connection's (made on first use); null if out of memory.
    fn of(ctx: *Context) ?*Cache {
        const st = &api.contextDbHandle(ctx).xq.postgres;
        if (st.regex_cache) |p| return @ptrCast(@alignCast(p));
        const k = dfunc.gpa(ctx).create(Cache) catch return null;
        k.* = .{};
        st.regex_cache = k;
        st.regex_cache_free = &free;
        return k;
    }

    fn free(gpa: Allocator, p: *anyopaque) void {
        const k: *Cache = @ptrCast(@alignCast(p));
        for (k.items[0..k.len]) |x| x.release();
        gpa.destroy(k);
    }

    /// The entry of `pattern` with `opt`, made the latest; null if none.
    fn get(k: *Cache, pattern: []const u8, opt: are.Options) ?*Compiled {
        for (k.items[0..k.len], 0..) |x, i| if (x.is(pattern, opt)) {
            std.mem.copyBackwards(*Compiled, k.items[1 .. i + 1], k.items[0..i]);
            k.items[0] = x;
            return x;
        };
        return null;
    }

    /// Add `x` (the cache takes its reference) as the latest, dropping
    /// the oldest if full.
    fn put(k: *Cache, x: *Compiled) void {
        if (k.len == k.items.len) {
            k.len -= 1;
            k.items[k.len].release();
        }
        std.mem.copyBackwards(*Compiled, k.items[1 .. k.len + 1], k.items[0..k.len]);
        k.items[0] = x;
        k.len += 1;
    }
};

const Flags = struct { opt: are.Options, global: bool };

/// Flags text `f` (PostgreSQL's parse_re_flags()); `fname` is the
/// function that does not take 'g' (null: it does). Null after making
/// the error the result.
fn parseFlags(c: *Call, f: []const u8, fname: ?[]const u8) ?Flags {
    var r: Flags = .{ .opt = .{}, .global = false };
    for (f, 0..) |ch, i| {
        if (ch == 'g') {
            r.global = true;
        } else if (ch >= 128 or !r.opt.apply(ch)) {
            c.fail("22023", "invalid regular expression option: \"{s}\"", .{f[i .. i + json.charLen(f, i)]});
            return null;
        }
    }
    if (r.global) if (fname) |n| {
        const msg = std.fmt.allocPrint(c.a(), "{s}() does not support the \"global\" option", .{n}) catch {
            c.oom();
            return null;
        };
        const hint: ?[]const u8 = if (std.mem.eql(u8, n, "regexp_match")) "Use the regexp_matches function instead." else null;
        c.failFields("22023", .{ .message = msg, .hint = hint });
        return null;
    };
    return r;
}

/// `pattern` compiled with `opt`: the auxiliary data of argument `arg`
/// of the call if it is that (a constant pattern, after the first row),
/// else from the connection's cache, or compiled (and kept in both);
/// null after making the error the result.
fn compileArg(c: *Call, pattern: []const u8, opt: are.Options, arg: i32) ?*const are.Regex {
    if (api.getAuxdataTyped(c.ctx, arg, Compiled.release)) |x| {
        if (x.is(pattern, opt)) return &x.re;
    }
    const k = Cache.of(c.ctx) orelse {
        c.oom();
        return null;
    };
    const x = k.get(pattern, opt) orelse blk: {
        const x = compileNew(c, pattern, opt) orelse return null;
        k.put(x);
        break :blk x;
    };
    // The cache's reference keeps it for this call (no other call
    // compiles until it returns); the statement takes one more (which
    // setAuxdata() lets go at once outside a statement, or on OOM).
    x.refs += 1;
    api.setAuxdataTyped(c.ctx, arg, Compiled.release, x);
    return &x.re;
}

/// `pattern` compiled with `opt` (one reference); null after making the
/// error the result.
fn compileNew(c: *Call, pattern: []const u8, opt: are.Options) ?*Compiled {
    const gpa = dfunc.gpa(c.ctx);
    const x = gpa.create(Compiled) catch {
        c.oom();
        return null;
    };
    x.* = .{ .arena = .init(gpa), .pattern = &.{}, .opt = opt, .re = undefined };
    x.pattern = x.arena.allocator().dupe(u8, pattern) catch {
        x.release();
        c.oom();
        return null;
    };
    var why: are.Fail = .badrpt;
    x.re = are.compile(x.arena.allocator(), x.pattern, opt, &why) catch |err| {
        x.release();
        switch (err) {
            error.OutOfMemory => c.oom(),
            error.BadPattern => c.fail("2201B", "invalid regular expression: {s}", .{why.message()}),
        }
        return null;
    };
    return x;
}

const Pattern = struct { re: *const are.Regex, global: bool };

/// The pattern argument `argv[1]` with flags text `flags`, compiled.
fn regexOf(c: *Call, argv: []*Mem, flags: []const u8, fname: ?[]const u8) ?Pattern {
    const pat = c.text(argv[1]) orelse return null;
    const f = parseFlags(c, flags, fname) orelse return null;
    const re = compileArg(c, pat, f.opt, 1) orelse return null;
    return .{ .re = re, .global = f.global };
}

fn flagsArg(c: *Call, argv: []*Mem, i: usize) ?[]const u8 {
    if (i >= argv.len) return "";
    return c.text(argv[i]);
}

/// Integer parameter `name` at least `min` (PostgreSQL's message when
/// not).
fn atLeast(c: *Call, m: *Mem, name: []const u8, min: i64) ?i64 {
    const v = c.intArg(m);
    if (v < min) {
        c.fail("22023", "invalid value for parameter \"{s}\": {d}", .{ name, v });
        return null;
    }
    return v;
}

/// The byte offset of character position `pos` (from 1) of `s`, or
/// null past its end.
fn byteAt(s: []const u8, pos: i64) ?usize {
    var i: usize = 0;
    var n: i64 = 1;
    while (n < pos) : (n += 1) {
        if (i >= s.len) return null;
        i = dfunc.nextChar(s, i);
    }
    return i;
}

fn charPos(s: []const u8, byte: usize) i64 {
    return @intCast(dfunc.charCount(s[0..byte]) + 1);
}

/// A match and its groups.
const Match = struct { span: are.Span, caps: []?are.Span };

/// The matches of `re` in `s` from byte `from`, at most `limit`: all of
/// them if `global` (PostgreSQL's setup_regexp_matches(): after an empty
/// match the next search starts a character later; `split` drops the
/// empty matches at the end and right after the previous match); their
/// groups only if `groups` (else none: `caps` is empty).
fn matches(c: *Call, re: *const are.Regex, s: []const u8, from: usize, global: bool, split: bool, limit: usize, groups: bool) are.Error![]Match {
    var out: std.ArrayList(Match) = .empty;
    var m = try are.Matcher.init(c.a(), re, s);
    var start = from;
    var prev_end: usize = 0;
    while (start <= s.len) {
        const sp = try m.exec(start, groups) orelse break;
        if (!split or (sp.so < s.len and sp.eo > prev_end)) {
            const caps: []?are.Span = if (groups) try c.a().dupe(?are.Span, m.caps) else &.{};
            try out.append(c.a(), .{ .span = sp, .caps = caps });
            if (out.items.len >= limit) break;
        }
        prev_end = sp.eo;
        if (!global) break;
        start = sp.eo;
        if (sp.so == sp.eo) {
            if (start >= s.len) break;
            start = dfunc.nextChar(s, start);
        }
    }
    return out.items;
}

fn engineError(c: *Call, err: are.Error) void {
    switch (err) {
        error.OutOfMemory => c.oom(),
        error.BadPattern => c.fail("2201B", "invalid regular expression: {s}", .{are.Fail.toobig.message()}),
    }
}

/// The text[] of a match's groups (of the whole match if it has none).
fn groupsArray(c: *Call, s: []const u8, mt: Match) error{OutOfMemory}![]const u8 {
    var elems: std.ArrayList(?[]const u8) = .empty;
    if (mt.caps.len == 0) {
        try elems.append(c.a(), s[mt.span.so..mt.span.eo]);
    } else for (mt.caps) |g| {
        try elems.append(c.a(), if (g) |x| s[x.so..x.eo] else null);
    }
    return array.write(c.a(), &array.Array.list(elems.items));
}

/// A JSON array of strings, as json_each() reads the rows.
fn jsonRows(c: *Call, rows: []const []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    out.append(c.a(), '[') catch return c.oom();
    for (rows, 0..) |z, i| {
        if (i > 0) out.append(c.a(), ',') catch return c.oom();
        json.writeString(c.a(), &out, z) catch return c.oom();
    }
    out.append(c.a(), ']') catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

// ============================================================ functions

/// xq_pg_re(s, pattern, flags): whether `s` has a match.
fn reFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    const flags = c.text(argv[2]) orelse return;
    const r = regexOf(c, argv, flags, null) orelse return;
    const found = are.search(c.a(), r.re, s) catch |err| return engineError(c, err);
    api.resultInt64(c.ctx, @intFromBool(found));
}

/// regexp_like(s, pattern [, flags]).
fn likeFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    const r = regexOf(c, argv, flagsArg(c, argv, 2) orelse return, "regexp_like") orelse return;
    const found = are.search(c.a(), r.re, s) catch |err| return engineError(c, err);
    api.resultInt64(c.ctx, @intFromBool(found));
}

/// regexp_match(s, pattern [, flags]): the first match's groups.
fn matchFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    const r = regexOf(c, argv, flagsArg(c, argv, 2) orelse return, "regexp_match") orelse return;
    const ms = matches(c, r.re, s, 0, false, false, 1, true) catch |err| return engineError(c, err);
    if (ms.len == 0) return api.resultNull(c.ctx);
    const z = groupsArray(c, s, ms[0]) catch return c.oom();
    api.resultText(c.ctx, z, .transient);
}

/// xq_pg_rows_regexp_matches(s, pattern, flags): regexp_matches()'s
/// rows, each a text[].
fn rowsMatchesFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultText(c.ctx, "[]", .static);
    const s = c.text(argv[0]) orelse return;
    const r = regexOf(c, argv, c.text(argv[2]) orelse return, null) orelse return;
    const ms = matches(c, r.re, s, 0, r.global, false, std.math.maxInt(usize), true) catch |err| return engineError(c, err);
    var rows: std.ArrayList([]const u8) = .empty;
    for (ms) |mt| rows.append(c.a(), groupsArray(c, s, mt) catch return c.oom()) catch return c.oom();
    jsonRows(c, rows.items);
}

/// The pieces of `s` between the matches (regexp_split_to_*()).
fn splitPieces(c: *Call, argv: []*Mem, fname: []const u8) ?[]?[]const u8 {
    const s = c.text(argv[0]) orelse return null;
    const r = regexOf(c, argv, flagsArg(c, argv, 2) orelse return null, fname) orelse return null;
    const ms = matches(c, r.re, s, 0, true, true, std.math.maxInt(usize), false) catch |err| {
        engineError(c, err);
        return null;
    };
    var out: std.ArrayList(?[]const u8) = .empty;
    var at: usize = 0;
    for (ms) |mt| {
        out.append(c.a(), s[at..mt.span.so]) catch {
            c.oom();
            return null;
        };
        at = mt.span.eo;
    }
    out.append(c.a(), s[at..]) catch {
        c.oom();
        return null;
    };
    return out.items;
}

/// regexp_split_to_array(s, pattern [, flags]).
fn splitArrayFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const pieces = splitPieces(c, argv, "regexp_split_to_array") orelse return;
    const z = array.write(c.a(), &array.Array.list(pieces)) catch return c.oom();
    api.resultText(c.ctx, z, .transient);
}

/// xq_pg_rows_regexp_split(s, pattern, flags): regexp_split_to_table()'s
/// rows.
fn rowsSplitFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultText(c.ctx, "[]", .static);
    const pieces = splitPieces(c, argv, "regexp_split_to_table") orelse return;
    var rows: std.ArrayList([]const u8) = .empty;
    for (pieces) |p| rows.append(c.a(), p.?) catch return c.oom();
    jsonRows(c, rows.items);
}

/// regexp_replace(s, pattern, replacement [, start [, N]] [, flags]):
/// `\1`..`\9` in the replacement are the groups, `\&` the match, `\\`
/// a backslash. The fourth argument is the start if it is a number, the
/// flags if text (PostgreSQL's two functions of four arguments).
fn replaceFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    const rep = c.text(argv[2]) orelse return;
    var start: i64 = 1;
    var n: i64 = 1;
    var flags: []const u8 = "";
    var n_given = false;
    if (argv.len == 4) {
        const t = api.valueType(argv[3]);
        if (t == vi.SQLITE_INTEGER or t == vi.SQLITE_FLOAT) {
            start = atLeast(c, argv[3], "start", 1) orelse return;
        } else {
            flags = c.text(argv[3]) orelse return;
            if (flags.len > 0 and std.ascii.isDigit(flags[0])) {
                const msg = std.fmt.allocPrint(c.a(), "invalid regular expression option: \"{s}\"", .{flags[0..1]}) catch return c.oom();
                return c.failFields("22023", .{ .message = msg, .hint = "If you meant to use regexp_replace() with a start parameter, cast the fourth argument to integer explicitly." });
            }
        }
    } else if (argv.len > 4) {
        start = atLeast(c, argv[3], "start", 1) orelse return;
        n = atLeast(c, argv[4], "n", 0) orelse return;
        n_given = true;
        if (argv.len > 5) flags = c.text(argv[5]) orelse return;
    }
    const r = regexOf(c, argv, flags, null) orelse return;
    // All matches: 'g' (unless N picks one), or N = 0.
    const all = (r.global and !n_given) or (n_given and n == 0);
    const from = byteAt(s, start) orelse return api.resultText(c.ctx, s, .transient);
    const want: usize = if (all) std.math.maxInt(usize) else @intCast(n);
    const ms = matches(c, r.re, s, from, true, false, want, refersToGroup(rep)) catch |err| return engineError(c, err);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (ms, 1..) |mt, k| {
        if (!all and k != want) continue;
        out.appendSlice(c.a(), s[at..mt.span.so]) catch return c.oom();
        substitute(c.a(), &out, rep, s, mt) catch return c.oom();
        at = mt.span.eo;
    }
    out.appendSlice(c.a(), s[at..]) catch return c.oom();
    api.resultText(c.ctx, out.items, .transient);
}

/// Whether replacement `rep` may name a group (`\1`..`\9`).
fn refersToGroup(rep: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rep, i, '\\')) |k| : (i = k + 1) {
        if (k + 1 < rep.len and rep[k + 1] >= '1' and rep[k + 1] <= '9') return true;
    }
    return false;
}

fn substitute(a: Allocator, out: *std.ArrayList(u8), rep: []const u8, s: []const u8, mt: Match) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < rep.len) {
        const ch = rep[i];
        if (ch != '\\' or i + 1 >= rep.len) {
            try out.append(a, ch);
            i += 1;
            continue;
        }
        const e = rep[i + 1];
        if (e >= '1' and e <= '9') {
            const g = e - '1';
            if (g < mt.caps.len) if (mt.caps[g]) |x| try out.appendSlice(a, s[x.so..x.eo]);
            i += 2;
        } else if (e == '&') {
            try out.appendSlice(a, s[mt.span.so..mt.span.eo]);
            i += 2;
        } else if (e == '\\') {
            try out.append(a, '\\');
            i += 2;
        } else {
            try out.append(a, '\\');
            i += 1;
        }
    }
}

/// regexp_count(s, pattern [, start [, flags]]).
fn countFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    const start: i64 = if (argv.len > 2) atLeast(c, argv[2], "start", 1) orelse return else 1;
    const r = regexOf(c, argv, flagsArg(c, argv, 3) orelse return, "regexp_count") orelse return;
    const from = byteAt(s, start) orelse return api.resultInt64(c.ctx, 0);
    const ms = matches(c, r.re, s, from, true, false, std.math.maxInt(usize), false) catch |err| return engineError(c, err);
    api.resultInt64(c.ctx, @intCast(ms.len));
}

const Nth = union(enum) { err, none, span: are.Span };

/// The N'th match from character `start`, or the part of it that group
/// `subexpr` (0: the whole) matched (regexp_instr(), regexp_substr():
/// the indexes of their arguments).
fn nth(c: *Call, argv: []*Mem, s: []const u8, fname: []const u8, n_arg: usize, flags_arg: usize, sub_arg: usize) Nth {
    const start: i64 = if (argv.len > 2) atLeast(c, argv[2], "start", 1) orelse return .err else 1;
    const n: i64 = if (argv.len > n_arg) atLeast(c, argv[n_arg], "n", 1) orelse return .err else 1;
    if (std.mem.eql(u8, fname, "regexp_instr") and argv.len > 4) {
        const e = c.intArg(argv[4]);
        if (e != 0 and e != 1) {
            c.fail("22023", "invalid value for parameter \"endoption\": {d}", .{e});
            return .err;
        }
    }
    const sub: i64 = if (argv.len > sub_arg) atLeast(c, argv[sub_arg], "subexpr", 0) orelse return .err else 0;
    const r = regexOf(c, argv, flagsArg(c, argv, flags_arg) orelse return .err, fname) orelse return .err;
    const from = byteAt(s, start) orelse return .none;
    const ms = matches(c, r.re, s, from, true, false, @intCast(n), sub != 0) catch |err| {
        engineError(c, err);
        return .err;
    };
    if (ms.len < n) return .none;
    const mt = ms[@intCast(n - 1)];
    if (sub == 0) return .{ .span = mt.span };
    if (sub > mt.caps.len) return .none;
    return .{ .span = mt.caps[@intCast(sub - 1)] orelse return .none };
}

/// regexp_instr(s, pattern [, start [, N [, endoption [, flags [,
/// subexpr]]]]]): the character position of the match (after it if
/// endoption is 1), 0 if none.
fn instrFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    switch (nth(c, argv, s, "regexp_instr", 3, 5, 6)) {
        .err => {},
        .none => api.resultInt64(c.ctx, 0),
        .span => |sp| {
            const end = argv.len > 4 and c.intArg(argv[4]) == 1;
            api.resultInt64(c.ctx, charPos(s, if (end) sp.eo else sp.so));
        },
    }
}

/// regexp_substr(s, pattern [, start [, N [, flags [, subexpr]]]]).
fn substrFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    switch (nth(c, argv, s, "regexp_substr", 3, 4, 5)) {
        .err => {},
        .none => api.resultNull(c.ctx),
        .span => |sp| api.resultText(c.ctx, s[sp.so..sp.eo], .transient),
    }
}

/// textregexsubstr(s, pattern): substring(s FROM pattern): the part the
/// first group matched (the whole match if there is no group);
/// textregexsubstr(s, pattern, escape): substring(s SIMILAR pattern
/// ESCAPE escape), PostgreSQL's SQL function substring(text, text,
/// text) of similar_to_escape() (its errors say so).
fn textSubstrFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const s = c.text(argv[0]) orelse return;
    const re = if (argv.len > 2) blk: {
        const pat = similarOf(c, argv[1], argv[2], "SQL function \"substring\" statement 1") orelse return;
        break :blk compileArg(c, pat, .{}, 1) orelse return;
    } else (regexOf(c, argv, "", null) orelse return).re;
    const ms = matches(c, re, s, 0, false, false, 1, true) catch |err| return engineError(c, err);
    if (ms.len == 0) return api.resultNull(c.ctx);
    const sp = if (ms[0].caps.len > 0) ms[0].caps[0] orelse return api.resultNull(c.ctx) else ms[0].span;
    api.resultText(c.ctx, s[sp.so..sp.eo], .transient);
}

// ============================================================ SIMILAR TO

/// similar_to_escape(pattern [, escape]).
fn similarEscapeFunc(c: *Call, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(c.ctx);
    const z = similarOf(c, argv[0], if (argv.len > 1) argv[1] else null, null) orelse return;
    api.resultText(c.ctx, z, .transient);
}

/// The regular expression of SIMILAR pattern `pm` with escape `em`
/// (none: backslash); null after making the error the result, with
/// `context` its CONTEXT.
fn similarOf(c: *Call, pm: *Mem, em: ?*Mem, context: ?[]const u8) ?[]const u8 {
    const p = c.text(pm) orelse return null;
    var esc: ?[]const u8 = "\\";
    if (em) |m| {
        const e = c.text(m) orelse return null;
        if (e.len == 0) {
            esc = null;
        } else if (dfunc.charCount(e) > 1) {
            c.failFields("22025", .{ .message = "invalid escape string", .hint = "Escape string must be empty or one character.", .context = context });
            return null;
        } else esc = e;
    }
    var out: std.ArrayList(u8) = .empty;
    similarEscape(c.a(), p, esc, &out) catch |err| {
        switch (err) {
            error.OutOfMemory => c.oom(),
            error.TooManyQuotes => c.failFields("2200B", .{ .message = "SQL regular expression may not contain more than two escape-double-quote separators", .context = context }),
        }
        return null;
    };
    return out.items;
}

/// The regular expression of a SIMILAR TO pattern (PostgreSQL's
/// similar_escape_internal()): `%` is `.*`, `_` `.`, `(` a group that
/// does not capture, the escape (none if null) makes the next character
/// literal, and the two escape-double-quotes of substring(... SIMILAR
/// ...) mark the part it returns; the whole is anchored.
pub fn similarEscape(a: Allocator, p: []const u8, esc: ?[]const u8, out: *std.ArrayList(u8)) error{ OutOfMemory, TooManyQuotes }!void {
    try out.appendSlice(a, "^(?:");
    var after_escape = false;
    var in_class = false;
    var class_pos: u8 = 0;
    var nquotes: u8 = 0;
    var i: usize = 0;
    while (i < p.len) {
        const len = json.charLen(p, i);
        const ch = p[i .. i + len];
        i += len;
        if (len > 1) {
            // A character of several bytes: no special meaning.
            if (after_escape) {
                try out.append(a, '\\');
                try out.appendSlice(a, ch);
                after_escape = false;
            } else if (esc != null and std.mem.eql(u8, esc.?, ch)) {
                after_escape = true;
            } else try out.appendSlice(a, ch);
            continue;
        }
        const pc = ch[0];
        if (after_escape) {
            if (pc == '"' and !in_class) {
                switch (nquotes) {
                    0 => try out.appendSlice(a, "){1,1}?("),
                    1 => try out.appendSlice(a, "){1,1}(?:"),
                    else => return error.TooManyQuotes,
                }
                nquotes += 1;
            } else {
                try out.append(a, '\\');
                try out.append(a, pc);
                class_pos = 3;
            }
            after_escape = false;
        } else if (esc != null and esc.?.len == 1 and pc == esc.?[0]) {
            after_escape = true;
        } else if (in_class) {
            if (pc == '\\') try out.append(a, '\\');
            try out.append(a, pc);
            if (pc == ']' and class_pos > 2) {
                in_class = false;
            } else if (pc == '^' and class_pos == 1) {
                class_pos = 2;
            } else class_pos = 3;
        } else if (pc == '[') {
            try out.append(a, pc);
            in_class = true;
            class_pos = 1;
        } else if (pc == '%') {
            try out.appendSlice(a, ".*");
        } else if (pc == '_') {
            try out.append(a, '.');
        } else if (pc == '(') {
            try out.appendSlice(a, "(?:");
        } else if (pc == '\\' or pc == '.' or pc == '^' or pc == '$') {
            try out.append(a, '\\');
            try out.append(a, pc);
        } else try out.append(a, pc);
    }
    try out.appendSlice(a, ")$");
}

// ================================================================ tests

test "similar_to_escape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?[]const u8, []const u8 }{
        .{ "a%b_c[x]#\"y#\"", "#", "^(?:a.*b.c[x]){1,1}?(y){1,1}(?:)$" },
        .{ "(a|b)\\.$^", "\\", "^(?:(?:a|b)\\.\\$\\^)$" },
        .{ "[]a]#\"%", "#", "^(?:[]a]){1,1}?(.*)$" },
        .{ "[^]x]%", "\\", "^(?:[^]x].*)$" },
        .{ "a\\", null, "^(?:a\\\\)$" },
        .{ "é_ü", "ü", "^(?:é.)$" },
    };
    for (cases) |cs| {
        var out: std.ArrayList(u8) = .empty;
        try similarEscape(a, cs[0], cs[1], &out);
        try std.testing.expectEqualStrings(cs[2], out.items);
    }
}
