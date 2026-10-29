//! `xqt planner gen basic|hard SEED NBLOCKS NQUERIES`: random planner
//! cases in the format of `xqt planner`, on standard output. (Was
//! tools/planner/gen-basic.py and gen-hard.py.)
//!
//! - basic: one to three tables, plain and partial indexes, joins of every
//!   kind, simple terms, GROUP BY, DISTINCT, ORDER BY, LIMIT, and DML.
//! - hard: the harder parts of the planner: skip-scan and ANALYZE
//!   statistics, collations, expression and partial indexes, row values,
//!   correlated subqueries, nested joins, automatic indexes, ORDER BY,
//!   GROUP BY and DISTINCT through indexes, DESC indexes, and DML through
//!   triggers and foreign keys.
//!
//! The same arguments give the same bytes as the Python scripts did:
//! `Random` is CPython's random.Random (MT19937 seeded by init_by_array
//! from the integer seed, random(), and randrange, choice and sample
//! through _randbelow), and the generators draw in the order the Python
//! expressions evaluated.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");

pub const usage =
    \\usage: xqt planner gen basic|hard SEED NBLOCKS NQUERIES
    \\
    \\Writes NBLOCKS blocks of random planner cases, each with a random
    \\schema, NQUERIES queries and some DML, to standard output; the same
    \\arguments give the same cases (those of gen-basic.py and gen-hard.py).
    \\
    \\  basic   tables, indexes, joins, simple terms, GROUP BY, ORDER BY, LIMIT
    \\  hard    ANALYZE and skip-scan, collations, expression and partial
    \\          indexes, row values, correlated subqueries, nested joins,
    \\          triggers and foreign keys
    \\
;

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    _ = io;
    _ = cfg;
    if (args.len != 4) return usageError(out);
    const hard = if (std.mem.eql(u8, args[0], "basic")) false else if (std.mem.eql(u8, args[0], "hard")) true else return usageError(out);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const seed = parseInt(arena, args[1]) catch return usageError(out);
    const nblocks = std.fmt.parseInt(i64, std.mem.trim(u8, args[2], " \t\n"), 10) catch return usageError(out);
    const nq = std.fmt.parseInt(i64, std.mem.trim(u8, args[3], " \t\n"), 10) catch return usageError(out);
    var r: Random = .init(seed);
    var g: Gen = .{ .a = arena, .r = &r };
    const text = if (hard) try g.hardCases(nblocks, nq) else try g.basicCases(nblocks, nq);
    try out.writeAll(text);
    try out.writeByte('\n');
    return 0;
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

/// A decimal integer of any size, as int() reads it: the 32-bit words of
/// its absolute value, least significant first (CPython's random_seed).
fn parseInt(arena: Allocator, text: []const u8) ![]u32 {
    var s = std.mem.trim(u8, text, " \t\n");
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s = s[1..];
    if (s.len == 0) return error.InvalidCharacter;
    var words: std.ArrayList(u32) = .empty;
    try words.append(arena, 0);
    var last_underscore = true;
    for (s) |ch| {
        if (ch == '_' and !last_underscore) {
            last_underscore = true;
            continue;
        }
        if (!std.ascii.isDigit(ch)) return error.InvalidCharacter;
        last_underscore = false;
        var carry: u64 = ch - '0';
        for (words.items) |*w| {
            const v = @as(u64, w.*) * 10 + carry;
            w.* = @truncate(v);
            carry = v >> 32;
        }
        if (carry != 0) try words.append(arena, @intCast(carry));
    }
    if (last_underscore) return error.InvalidCharacter;
    while (words.items.len > 1 and words.items[words.items.len - 1] == 0) _ = words.pop();
    return words.items;
}

/// CPython's random.Random: MT19937 and the algorithms of random.py.
pub const Random = struct {
    mt: [n]u32,
    index: usize,

    const n = 624;
    const m = 397;

    /// random.Random(seed) for an integer seed given as the 32-bit words
    /// of its absolute value (init_by_array).
    pub fn init(key: []const u32) Random {
        var r: Random = undefined;
        r.initGenrand(19650218);
        var i: usize = 1;
        var j: usize = 0;
        var k: usize = @max(n, key.len);
        while (k > 0) : (k -= 1) {
            r.mt[i] = (r.mt[i] ^ ((r.mt[i - 1] ^ (r.mt[i - 1] >> 30)) *% 1664525)) +% key[j] +% @as(u32, @truncate(j));
            i += 1;
            j += 1;
            if (i >= n) {
                r.mt[0] = r.mt[n - 1];
                i = 1;
            }
            if (j >= key.len) j = 0;
        }
        k = n - 1;
        while (k > 0) : (k -= 1) {
            r.mt[i] = (r.mt[i] ^ ((r.mt[i - 1] ^ (r.mt[i - 1] >> 30)) *% 1566083941)) -% @as(u32, @truncate(i));
            i += 1;
            if (i >= n) {
                r.mt[0] = r.mt[n - 1];
                i = 1;
            }
        }
        r.mt[0] = 0x80000000;
        return r;
    }

    fn initGenrand(r: *Random, s: u32) void {
        r.mt[0] = s;
        for (1..n) |i| r.mt[i] = 1812433253 *% (r.mt[i - 1] ^ (r.mt[i - 1] >> 30)) +% @as(u32, @intCast(i));
        r.index = n;
    }

    fn next(r: *Random) u32 {
        if (r.index >= n) {
            for (0..n) |kk| {
                const y = (r.mt[kk] & 0x80000000) | (r.mt[(kk + 1) % n] & 0x7fffffff);
                r.mt[kk] = r.mt[(kk + m) % n] ^ (y >> 1) ^ (if (y & 1 != 0) @as(u32, 0x9908b0df) else 0);
            }
            r.index = 0;
        }
        var y = r.mt[r.index];
        r.index += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c5680;
        y ^= (y << 15) & 0xefc60000;
        y ^= y >> 18;
        return y;
    }

    /// random(): a double in [0, 1) from 53 bits.
    pub fn random(r: *Random) f64 {
        const a: f64 = @floatFromInt(r.next() >> 5);
        const b: f64 = @floatFromInt(r.next() >> 6);
        return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0);
    }

    /// getrandbits(k) for 0 < k <= 32.
    fn getrandbits(r: *Random, k: u6) u32 {
        return r.next() >> @intCast(32 - @as(u32, k));
    }

    /// _randbelow_with_getrandbits(n) for 0 < n < 2^32.
    pub fn below(r: *Random, bound: usize) usize {
        std.debug.assert(bound > 0 and bound <= std.math.maxInt(u32));
        const k: u6 = @intCast(64 - @clz(@as(u64, bound)));
        var v = r.getrandbits(k);
        while (v >= bound) v = r.getrandbits(k);
        return v;
    }

    /// randint(a, b).
    pub fn int(r: *Random, a: i64, b: i64) i64 {
        std.debug.assert(b >= a);
        return a + @as(i64, @intCast(r.below(@intCast(b - a + 1))));
    }

    /// choice(seq).
    pub fn choice(r: *Random, comptime T: type, seq: []const T) T {
        return seq[r.below(seq.len)];
    }

    /// sample(population, k).
    pub fn sample(r: *Random, comptime T: type, a: Allocator, population: []const T, k: usize) ![]T {
        const len = population.len;
        std.debug.assert(k <= len);
        const result = try a.alloc(T, k);
        var setsize: usize = 21;
        if (k > 5) {
            // 4 ** ceil(log(k * 3, 4)), as floats.
            const e = @ceil(@log(@as(f64, @floatFromInt(k * 3))) / @log(4.0));
            setsize += std.math.pow(usize, 4, @intFromFloat(e));
        }
        if (len <= setsize) {
            const pool = try a.dupe(T, population);
            for (0..k) |i| {
                const j = r.below(len - i);
                result[i] = pool[j];
                pool[j] = pool[len - i - 1];
            }
        } else {
            var selected: std.AutoHashMapUnmanaged(usize, void) = .empty;
            defer selected.deinit(a);
            for (0..k) |i| {
                var j = r.below(len);
                while (selected.contains(j)) j = r.below(len);
                try selected.put(a, j, {});
                result[i] = population[j];
            }
        }
        return result;
    }
};

const Table = struct {
    name: []const u8,
    cols: []const []const u8,
};

const Gen = struct {
    a: Allocator,
    r: *Random,

    fn fmt(g: *Gen, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(g.a, f, args);
    }

    fn join(g: *Gen, parts: []const []const u8, sep: []const u8) ![]const u8 {
        return std.mem.join(g.a, sep, parts);
    }

    fn str(g: *Gen, comptime T: type, v: T) ![]const u8 {
        return g.fmt("{d}", .{v});
    }

    /// The columns of `tabs` as "t.c".
    fn allColumns(g: *Gen, tabs: []const Table) ![]const []const u8 {
        var allc: std.ArrayList([]const u8) = .empty;
        for (tabs) |t| for (t.cols) |c| try allc.append(g.a, try g.fmt("{s}.{s}", .{ t.name, c }));
        return allc.items;
    }

    // ------------------------------------------------------------ basic

    fn basicCases(g: *Gen, nblocks: i64, nq: i64) ![]const u8 {
        var blocks: std.ArrayList([]const u8) = .empty;
        var bi: i64 = 0;
        while (bi < nblocks) : (bi += 1) {
            var setup: std.ArrayList([]const u8) = .empty;
            const tabs = try g.basicSchema(&setup);
            var qs: std.ArrayList([]const u8) = .empty;
            var i: i64 = 0;
            while (i < nq) : (i += 1) try qs.append(g.a, try g.basicQuery(tabs));
            i = 0;
            while (i < @max(1, @divFloor(nq, 6))) : (i += 1) try qs.append(g.a, try g.basicDml(tabs));
            try blocks.append(g.a, try g.fmt("{s}\n==\n{s}", .{ try g.join(setup.items, "\n"), try g.join(qs.items, "\n") }));
        }
        return g.join(blocks.items, "\n----\n");
    }

    const basic_cols = [_][]const u8{ "a", "b", "c", "d", "e" };

    fn basicSchema(g: *Gen, out: *std.ArrayList([]const u8)) ![]const Table {
        const r = g.r;
        var tabs: std.ArrayList(Table) = .empty;
        const ntab = r.int(1, 3);
        var ti: i64 = 0;
        while (ti < ntab) : (ti += 1) {
            const name = try g.fmt("t{d}", .{ti});
            const ncol: usize = @intCast(r.int(2, 5));
            const cols = basic_cols[0..ncol];
            const kind = r.choice([]const u8, &.{ "rowid", "ipk", "ipk", "wr", "plain" });
            var defs: std.ArrayList([]const u8) = .empty;
            for (cols, 0..) |c, i| {
                const ty = r.choice([]const u8, &.{ "INT", "INTEGER", "TEXT", "", "REAL" });
                if (eql(kind, "ipk") and i == 0) {
                    try defs.append(g.a, try g.fmt("{s} INTEGER PRIMARY KEY", .{c}));
                } else {
                    try defs.append(g.a, try g.typed(c, ty));
                }
            }
            var tail: []const u8 = "";
            if (eql(kind, "wr")) {
                const second = if (r.random() < 0.3) try g.fmt(", {s}", .{cols[1]}) else "";
                try defs.append(g.a, try g.fmt("PRIMARY KEY({s}{s})", .{ cols[0], second }));
                tail = " WITHOUT ROWID";
            }
            try out.append(g.a, try g.fmt("CREATE TABLE {s}({s}){s};", .{ name, try g.join(defs.items, ", "), tail }));
            const nidx = r.int(0, 3);
            var ii: i64 = 0;
            while (ii < nidx) : (ii += 1) {
                const kn: usize = @intCast(r.int(1, @min(3, @as(i64, @intCast(ncol)))));
                const k = try r.sample([]const u8, g.a, cols, kn);
                var parts = try g.a.alloc([]const u8, k.len);
                for (k, 0..) |c, i| parts[i] = if (r.random() < 0.15) try g.fmt("{s} DESC", .{c}) else c;
                const uniq = if (r.random() < 0.2) "UNIQUE " else "";
                var where: []const u8 = "";
                const x = r.random();
                if (x < 0.1) {
                    where = try g.fmt(" WHERE {s} IS NOT NULL", .{r.choice([]const u8, cols)});
                } else if (x < 0.15) {
                    where = try g.fmt(" WHERE {s}>10", .{r.choice([]const u8, cols)});
                }
                if (r.random() < 0.08) {
                    parts = try std.mem.concat(g.a, []const u8, &.{ &.{try g.fmt("{s}+1", .{k[0]})}, parts[1..] });
                }
                try out.append(g.a, try g.fmt("CREATE {s}INDEX {s}i{d} ON {s}({s}){s};", .{ uniq, name, ii, name, try g.join(parts, ", "), where }));
            }
            const nrows = r.choice(i64, &.{ 0, 5, 30, 200 });
            var vals: std.ArrayList([]const u8) = .empty;
            for (cols) |_| {
                const m = r.choice(i64, &.{ 3, 7, 20, 1000 });
                const opts = [_][]const u8{
                    try g.fmt("i%{d}", .{m}),
                    try g.fmt("'s'||(i%{d})", .{m}),
                    try g.fmt("CASE WHEN i%{d}=0 THEN NULL ELSE i%{d} END", .{ r.int(2, 6), m }),
                    "i",
                    try g.fmt("(i*7)%{d}", .{m}),
                };
                try vals.append(g.a, r.choice([]const u8, &opts));
            }
            if (eql(kind, "ipk") or eql(kind, "wr")) vals.items[0] = "i";
            if (nrows != 0) {
                try out.append(g.a, try g.fmt("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{d}) INSERT OR IGNORE INTO {s} SELECT {s} FROM n;", .{ nrows, name, try g.join(vals.items, ", ") }));
            }
            try tabs.append(g.a, .{ .name = name, .cols = cols });
        }
        if (r.random() < 0.3) try out.append(g.a, "ANALYZE;");
        return tabs.items;
    }

    /// f'{c} {ty}'.strip()
    fn typed(g: *Gen, c: []const u8, ty: []const u8) ![]const u8 {
        return if (ty.len == 0) c else g.fmt("{s} {s}", .{ c, ty });
    }

    fn basicLit(g: *Gen) ![]const u8 {
        const r = g.r;
        const opts = [_][]const u8{
            try g.str(i64, r.int(0, 25)),
            try g.fmt("'s{d}'", .{r.int(0, 25)}),
            "NULL",
            try g.fmt("{d}.5", .{r.int(0, 9)}),
        };
        return r.choice([]const u8, &opts);
    }

    fn basicTerm(g: *Gen, tabs: []const Table) anyerror![]const u8 {
        const r = g.r;
        const t = r.choice(Table, tabs);
        const c = try g.fmt("{s}.{s}", .{ t.name, r.choice([]const u8, t.cols) });
        const x = r.random();
        if (x < 0.25) return g.fmt("{s}={s}", .{ c, try g.basicLit() });
        if (x < 0.4) {
            const op = r.choice([]const u8, &.{ "<", ">", "<=", ">=" });
            return g.fmt("{s}{s}{s}", .{ c, op, try g.basicLit() });
        }
        if (x < 0.48) {
            const lo = r.int(0, 10);
            return g.fmt("{s} BETWEEN {d} AND {d}", .{ c, lo, r.int(5, 20) });
        }
        if (x < 0.56) {
            const count = r.int(1, 4);
            var lits: std.ArrayList([]const u8) = .empty;
            var i: i64 = 0;
            while (i < count) : (i += 1) try lits.append(g.a, try g.basicLit());
            return g.fmt("{s} IN ({s})", .{ c, try g.join(lits.items, ", ") });
        }
        if (x < 0.6) return g.fmt("{s} IS NULL", .{c});
        if (x < 0.63) return g.fmt("{s} IS NOT NULL", .{c});
        if (x < 0.67) return g.fmt("{s} LIKE 's{d}%'", .{ c, r.int(0, 3) });
        if (x < 0.75 and tabs.len > 1) {
            const t2 = r.choice(Table, tabs);
            return g.fmt("{s}={s}.{s}", .{ c, t2.name, r.choice([]const u8, t2.cols) });
        }
        if (x < 0.82) {
            const a = try g.basicTerm(tabs);
            return g.fmt("({s} OR {s})", .{ a, try g.basicTerm(tabs) });
        }
        if (x < 0.86) {
            const t2 = r.choice(Table, tabs);
            return g.fmt("{s} IN (SELECT {s} FROM {s})", .{ c, r.choice([]const u8, t2.cols), t2.name });
        }
        if (x < 0.88) return g.fmt("NOT ({s})", .{try g.basicTerm(tabs)});
        if (x < 0.9) return g.fmt("{s} IS {s}", .{ c, try g.basicLit() });
        return g.fmt("{s}<>{s}", .{ c, try g.basicLit() });
    }

    fn basicQuery(g: *Gen, tabs: []const Table) ![]const u8 {
        const r = g.r;
        const k: usize = @intCast(r.int(1, @intCast(tabs.len)));
        const use = try r.sample(Table, g.a, tabs, k);
        var frm: std.ArrayList([]const u8) = .empty;
        for (use, 0..) |t, i| {
            if (i == 0) {
                try frm.append(g.a, t.name);
                continue;
            }
            const j = r.choice([]const u8, &.{ "JOIN", "JOIN", ",", "LEFT JOIN", "CROSS JOIN", "RIGHT JOIN", "FULL JOIN" });
            if (eql(j, ",")) {
                try frm.append(g.a, try g.fmt(", {s}", .{t.name}));
            } else {
                const p = r.choice(Table, use[0..i]);
                const tc = r.choice([]const u8, t.cols);
                const on = try g.fmt(" ON {s}.{s}={s}.{s}", .{ t.name, tc, p.name, r.choice([]const u8, p.cols) });
                try frm.append(g.a, try g.fmt(" {s} {s}{s}", .{ j, t.name, on }));
            }
        }
        var where: []const u8 = "";
        const nt = r.choice(i64, &.{ 0, 1, 1, 2, 2, 3 });
        if (nt != 0) {
            var terms: std.ArrayList([]const u8) = .empty;
            var i: i64 = 0;
            while (i < nt) : (i += 1) try terms.append(g.a, try g.basicTerm(use));
            where = try g.fmt(" WHERE {s}", .{try g.join(terms.items, " AND ")});
        }
        const allc = try g.allColumns(use);
        const x = r.random();
        var group: []const u8 = "";
        var sel: []const u8 = undefined;
        if (x < 0.15) {
            sel = "count(*)";
        } else if (x < 0.25) {
            const gc = r.choice([]const u8, allc);
            sel = try g.fmt("{s}, count(*), max({s})", .{ gc, r.choice([]const u8, allc) });
            group = try g.fmt(" GROUP BY {s}", .{gc});
        } else if (x < 0.3) {
            const f = r.choice([]const u8, &.{ "min", "max" });
            sel = try g.fmt("{s}({s})", .{ f, r.choice([]const u8, allc) });
        } else if (x < 0.38) {
            const kn: usize = @intCast(r.int(1, @intCast(@min(2, allc.len))));
            sel = try g.fmt("DISTINCT {s}", .{try g.join(try r.sample([]const u8, g.a, allc, kn), ", ")});
        } else {
            const kn: usize = @intCast(r.int(1, @intCast(@min(4, allc.len))));
            sel = try g.join(try r.sample([]const u8, g.a, allc, kn), ", ");
        }
        var order: []const u8 = "";
        if (r.random() < 0.45) {
            const kn: usize = @intCast(r.int(1, @intCast(@min(2, allc.len))));
            const obs = try r.sample([]const u8, g.a, allc, kn);
            for (obs) |*o| o.* = try g.fmt("{s}{s}", .{ o.*, r.choice([]const u8, &.{ "", " DESC", " ASC" }) });
            order = try g.fmt(" ORDER BY {s}", .{try g.join(obs, ", ")});
        }
        if (group.len > 0 or eql(sel, "count(*)") or std.mem.startsWith(u8, sel, "min(") or std.mem.startsWith(u8, sel, "max(")) {
            if (group.len == 0) order = "";
        }
        var limit: []const u8 = "";
        if (r.random() < 0.25) {
            limit = try g.fmt(" LIMIT {d}", .{r.int(1, 5)});
            if (r.random() < 0.3) limit = try g.fmt("{s} OFFSET {d}", .{ limit, r.int(1, 3) });
        }
        // Without ORDER BY the row order is plan-defined; with the same plan
        // it must match exactly, so such queries stay.
        return g.fmt("SELECT {s} FROM {s}{s}{s}{s}{s}", .{ sel, try g.join(frm.items, ""), where, group, order, limit });
    }

    fn basicDml(g: *Gen, tabs: []const Table) ![]const u8 {
        const r = g.r;
        const t = r.choice(Table, tabs);
        const w = if (r.random() < 0.9) try g.fmt(" WHERE {s}", .{try g.basicTerm(&.{t})}) else "";
        if (r.random() < 0.5) {
            const c = r.choice([]const u8, t.cols);
            const opts = [_][]const u8{ try g.basicLit(), try g.fmt("{s}+1", .{c}) };
            return g.fmt("UPDATE {s} SET {s}={s}{s}", .{ t.name, c, r.choice([]const u8, &opts), w });
        }
        return g.fmt("DELETE FROM {s}{s}", .{ t.name, w });
    }

    // ------------------------------------------------------------ hard

    fn hardCases(g: *Gen, nblocks: i64, nq: i64) ![]const u8 {
        var blocks: std.ArrayList([]const u8) = .empty;
        var bi: i64 = 0;
        while (bi < nblocks) : (bi += 1) {
            var setup: std.ArrayList([]const u8) = .empty;
            const tabs = try g.hardSchema(&setup);
            var qs: std.ArrayList([]const u8) = .empty;
            var i: i64 = 0;
            while (i < nq) : (i += 1) try qs.append(g.a, try g.hardQuery(tabs));
            i = 0;
            while (i < @max(1, @divFloor(nq, 5))) : (i += 1) try qs.append(g.a, try g.hardDmlFk(tabs));
            try blocks.append(g.a, try g.fmt("{s}\n==\n{s}", .{ try g.join(setup.items, "\n"), try g.join(qs.items, "\n") }));
        }
        return g.join(blocks.items, "\n----\n");
    }

    const hard_cols = [_][]const u8{ "a", "b", "c", "d" };

    fn hardSchema(g: *Gen, out: *std.ArrayList([]const u8)) ![]const Table {
        const r = g.r;
        var tabs: std.ArrayList(Table) = .empty;
        const ntab = r.int(2, 4);
        var ti: i64 = 0;
        while (ti < ntab) : (ti += 1) {
            const name = try g.fmt("t{d}", .{ti});
            const cols = hard_cols[0..@intCast(r.int(3, 4))];
            const kind = r.choice([]const u8, &.{ "rowid", "ipk", "wr" });
            var defs: std.ArrayList([]const u8) = .empty;
            for (cols, 0..) |c, i| {
                const ty = r.choice([]const u8, &.{ "INT", "TEXT", "", "TEXT COLLATE NOCASE", "REAL", "INTEGER" });
                if (eql(kind, "ipk") and i == 0) {
                    try defs.append(g.a, try g.fmt("{s} INTEGER PRIMARY KEY", .{c}));
                } else {
                    try defs.append(g.a, try g.typed(c, ty));
                }
            }
            var tail: []const u8 = "";
            if (eql(kind, "wr")) {
                try defs.append(g.a, try g.fmt("PRIMARY KEY({s}, {s})", .{ cols[0], cols[1] }));
                tail = " WITHOUT ROWID";
            }
            if (ti > 0 and r.random() < 0.3) try defs.append(g.a, try g.fmt("FOREIGN KEY({s}) REFERENCES t0", .{cols[cols.len - 1]}));
            try out.append(g.a, try g.fmt("CREATE TABLE {s}({s}){s};", .{ name, try g.join(defs.items, ", "), tail }));
            const nidx = r.int(1, 3);
            var ii: i64 = 0;
            while (ii < nidx) : (ii += 1) {
                const x = r.random();
                var body: []const u8 = undefined;
                if (x < 0.15) {
                    body = try g.fmt("{s}+{s}", .{ cols[1], cols[2] });
                } else if (x < 0.25) {
                    body = try g.fmt("lower({s}), {s}", .{ cols[1], cols[2] });
                } else if (x < 0.35) {
                    body = try g.fmt("{s} COLLATE NOCASE", .{cols[1]});
                } else {
                    const k = try r.sample([]const u8, g.a, cols, @intCast(r.int(1, 3)));
                    for (k) |*c| c.* = if (r.random() < 0.2) try g.fmt("{s} DESC", .{c.*}) else c.*;
                    body = try g.join(k, ", ");
                }
                const uniq = if (r.random() < 0.15) "UNIQUE " else "";
                const where = if (r.random() < 0.12) try g.fmt(" WHERE {s} IS NOT NULL", .{r.choice([]const u8, cols)}) else "";
                try out.append(g.a, try g.fmt("CREATE {s}INDEX {s}i{d} ON {s}({s}){s};", .{ uniq, name, ii, name, body, where }));
            }
            const nrows = r.choice(i64, &.{ 10, 100, 1000, 3000 });
            var vals: std.ArrayList([]const u8) = .empty;
            for (cols) |_| {
                const m = r.choice(i64, &.{ 2, 4, 10, 50, 100000 });
                const opts = [_][]const u8{
                    try g.fmt("i%{d}", .{m}),
                    try g.fmt("'k'||(i%{d})", .{m}),
                    try g.fmt("CASE WHEN i%{d}=0 THEN NULL ELSE i%{d} END", .{ r.int(3, 9), m }),
                    try g.fmt("char(65+i%{d})||(i%{d})", .{ @min(m, 26), m }),
                };
                try vals.append(g.a, r.choice([]const u8, &opts));
            }
            if (!eql(kind, "rowid")) {
                vals.items[0] = "i";
                if (eql(kind, "wr")) vals.items[1] = "i%7";
            }
            try out.append(g.a, try g.fmt("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{d}) INSERT OR IGNORE INTO {s} SELECT {s} FROM n;", .{ nrows, name, try g.join(vals.items, ", ") }));
            try tabs.append(g.a, .{ .name = name, .cols = cols });
        }
        if (r.random() < 0.6) try out.append(g.a, "ANALYZE;");
        if (r.random() < 0.3) {
            const t = r.choice(Table, tabs.items[1..]);
            const t0 = tabs.items[0].cols;
            try out.append(g.a, try g.fmt("CREATE TRIGGER tr AFTER UPDATE ON {s} BEGIN UPDATE t0 SET {s}={s} WHERE {s}=new.{s}; END;", .{ t.name, t0[1], t0[1], t0[0], t.cols[0] }));
        }
        return tabs.items;
    }

    fn hardLit(g: *Gen) ![]const u8 {
        const r = g.r;
        const opts = [_][]const u8{
            try g.str(i64, r.int(0, 60)),
            try g.fmt("'k{d}'", .{r.int(0, 50)}),
            try g.fmt("'K{d}'", .{r.int(0, 9)}),
            "'A1'",
            "NULL",
            try g.fmt("?{d}", .{r.int(1, 3)}),
        };
        return r.choice([]const u8, &opts);
    }

    const Col = struct { c: []const u8, t: Table };

    fn hardCol(g: *Gen, tabs: []const Table) !Col {
        const t = g.r.choice(Table, tabs);
        return .{ .c = try g.fmt("{s}.{s}", .{ t.name, g.r.choice([]const u8, t.cols) }), .t = t };
    }

    fn hardTerm(g: *Gen, tabs: []const Table, depth: u32) anyerror![]const u8 {
        const r = g.r;
        const col = try g.hardCol(tabs);
        const c = col.c;
        const t = col.t;
        const x = r.random();
        if (x < 0.18) return g.fmt("{s}={s}", .{ c, try g.hardLit() });
        if (x < 0.28) {
            const op = r.choice([]const u8, &.{ "<", ">", "<=", ">=" });
            return g.fmt("{s}{s}{s}", .{ c, op, try g.hardLit() });
        }
        if (x < 0.33) {
            const lo = try g.hardLit();
            return g.fmt("{s} BETWEEN {s} AND {s}", .{ c, lo, try g.hardLit() });
        }
        if (x < 0.4) {
            const count = r.int(1, 5);
            var lits: std.ArrayList([]const u8) = .empty;
            var i: i64 = 0;
            while (i < count) : (i += 1) try lits.append(g.a, try g.hardLit());
            return g.fmt("{s} IN ({s})", .{ c, try g.join(lits.items, ", ") });
        }
        if (x < 0.43) return g.fmt("{s} IS NULL", .{c});
        if (x < 0.47) return g.fmt("{s} LIKE '{s}%'", .{ c, r.choice([]const u8, &.{ "k1", "K", "a", "k" }) });
        if (x < 0.5) return g.fmt("{s} GLOB 'k1*'", .{c});
        if (x < 0.55) {
            const op = r.choice([]const u8, &.{ "=", ">", "<", ">=", "<=" });
            const l1 = try g.hardLit();
            const l2 = try g.hardLit();
            return g.fmt("({s}.{s}, {s}.{s}) {s} ({s}, {s})", .{ t.name, t.cols[0], t.name, t.cols[1], op, l1, l2 });
        }
        if (x < 0.6) return g.fmt("{s}.{s}+{s}.{s}={d}", .{ t.name, t.cols[1], t.name, t.cols[2], r.int(0, 40) });
        if (x < 0.63) return g.fmt("lower({s}.{s})='{s}'", .{ t.name, t.cols[1], r.choice([]const u8, &.{ "k1", "a1", "k2" }) });
        if (x < 0.66) return g.fmt("{s}='k1' COLLATE NOCASE", .{c});
        if (x < 0.74 and tabs.len > 1) {
            const c2 = try g.hardCol(tabs);
            return g.fmt("{s}={s}", .{ c, c2.c });
        }
        if (x < 0.8 and depth < 2) {
            const a = try g.hardTerm(tabs, depth + 1);
            return g.fmt("({s} OR {s})", .{ a, try g.hardTerm(tabs, depth + 1) });
        }
        if (x < 0.84) {
            const t2 = r.choice(Table, tabs);
            const in = r.choice([]const u8, &.{ "IN", "NOT IN" });
            const sc = r.choice([]const u8, t2.cols);
            const wc = r.choice([]const u8, t2.cols);
            return g.fmt("{s} {s} (SELECT {s} FROM {s} WHERE {s}>{d})", .{ c, in, sc, t2.name, wc, r.int(0, 20) });
        }
        if (x < 0.88) {
            const t2 = r.choice(Table, tabs);
            const not = r.choice([]const u8, &.{ "", "NOT " });
            return g.fmt("{s}EXISTS (SELECT 1 FROM {s} AS x WHERE x.{s}={s})", .{ not, t2.name, r.choice([]const u8, t2.cols), c });
        }
        if (x < 0.91) {
            const t2 = r.choice(Table, tabs);
            return g.fmt("{s} = (SELECT max(y.{s}) FROM {s} AS y WHERE y.{s}={s})", .{ c, t2.cols[0], t2.name, t2.cols[1], c });
        }
        if (x < 0.94) return g.fmt("{s} IS NOT {s}", .{ c, try g.hardLit() });
        if (x < 0.97) return g.fmt("coalesce({s},0)>{d}", .{ c, r.int(0, 5) });
        const lo = r.int(0, 5);
        return g.fmt("{s} NOT BETWEEN {d} AND {d}", .{ c, lo, r.int(5, 30) });
    }

    const From = struct { use: []const Table, s: []const u8 };

    fn hardFrom(g: *Gen, tabs: []const Table) !From {
        const r = g.r;
        const k: usize = @intCast(r.int(1, @intCast(@min(3, tabs.len))));
        const use = try r.sample(Table, g.a, tabs, k);
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(g.a, use[0].name);
        for (1..k) |i| {
            const t = use[i];
            const p = r.choice(Table, use[0..i]);
            const j = r.choice([]const u8, &.{ "JOIN", ",", "LEFT JOIN", "CROSS JOIN", "RIGHT JOIN", "FULL JOIN", "NATURAL JOIN", "JOIN USING" });
            if (eql(j, ",")) {
                try parts.append(g.a, try g.fmt(", {s}", .{t.name}));
            } else if (eql(j, "NATURAL JOIN")) {
                try parts.append(g.a, try g.fmt(" NATURAL JOIN {s}", .{t.name}));
            } else if (eql(j, "JOIN USING")) {
                try parts.append(g.a, try g.fmt(" JOIN {s} USING({s})", .{ t.name, t.cols[0] }));
            } else {
                const tc = r.choice([]const u8, t.cols);
                try parts.append(g.a, try g.fmt(" {s} {s} ON {s}.{s}={s}.{s}", .{ j, t.name, t.name, tc, p.name, r.choice([]const u8, p.cols) }));
            }
        }
        var s = try g.join(parts.items, "");
        if (k >= 3 and r.random() < 0.3 and !contains(s, ",") and !contains(s, "NATURAL") and !contains(s, "USING")) {
            // A parenthesized (nested) join.
            const a = use[0];
            const b = use[1];
            const c = use[2];
            s = try g.fmt("{s} LEFT JOIN ({s} JOIN {s} ON {s}.{s}={s}.{s}) ON {s}.{s}={s}.{s}", .{ a.name, b.name, c.name, c.name, c.cols[0], b.name, b.cols[1], b.name, b.cols[0], a.name, a.cols[0] });
        }
        if (r.random() < 0.1) {
            const t = use[0];
            s = try g.fmt("(SELECT * FROM {s} WHERE {s} IS NOT NULL LIMIT 50) AS {s}{s}", .{ t.name, t.cols[1], t.name, s[t.name.len..] });
        }
        return .{ .use = use, .s = s };
    }

    fn hardQuery(g: *Gen, tabs: []const Table) ![]const u8 {
        const r = g.r;
        const f = try g.hardFrom(tabs);
        const use = f.use;
        const nt = r.choice(i64, &.{ 0, 1, 1, 2, 2, 3 });
        var where: []const u8 = "";
        if (nt != 0) {
            var terms: std.ArrayList([]const u8) = .empty;
            var i: i64 = 0;
            while (i < nt) : (i += 1) try terms.append(g.a, try g.hardTerm(use, 0));
            where = try g.fmt(" WHERE {s}", .{try g.join(terms.items, " AND ")});
        }
        const allc = try g.allColumns(use);
        var group: []const u8 = "";
        var order: []const u8 = "";
        var limit: []const u8 = "";
        var sel: []const u8 = undefined;
        const x = r.random();
        if (x < 0.12) {
            sel = "count(*)";
        } else if (x < 0.25) {
            const gs = try r.sample([]const u8, g.a, allc, @intCast(r.int(1, 2)));
            const gl = try g.join(gs, ", ");
            sel = try g.fmt("{s}, count(*), sum({s})", .{ gl, r.choice([]const u8, allc) });
            group = try g.fmt(" GROUP BY {s}", .{gl});
            if (r.random() < 0.3) group = try g.fmt("{s} HAVING count(*)>{d}", .{ group, r.int(1, 3) });
        } else if (x < 0.32) {
            const fun = r.choice([]const u8, &.{ "min", "max" });
            sel = try g.fmt("{s}({s})", .{ fun, r.choice([]const u8, allc) });
        } else if (x < 0.42) {
            sel = try g.fmt("DISTINCT {s}", .{try g.join(try r.sample([]const u8, g.a, allc, @intCast(r.int(1, 2))), ", ")});
        } else {
            const kn: usize = @intCast(r.int(1, @intCast(@min(4, allc.len))));
            sel = try g.join(try r.sample([]const u8, g.a, allc, kn), ", ");
        }
        if (r.random() < 0.55 and !(std.mem.startsWith(u8, sel, "count(*)") or std.mem.startsWith(u8, sel, "min(") or std.mem.startsWith(u8, sel, "max("))) {
            const kn: usize = @intCast(r.int(1, @intCast(@min(3, allc.len))));
            const obs = try r.sample([]const u8, g.a, allc, kn);
            for (obs) |*o| o.* = try g.fmt("{s}{s}", .{ o.*, r.choice([]const u8, &.{ "", " DESC", " ASC", " NULLS FIRST", " DESC NULLS LAST" }) });
            order = try g.fmt(" ORDER BY {s}", .{try g.join(obs, ", ")});
        }
        if (r.random() < 0.3) {
            limit = try g.fmt(" LIMIT {d}", .{r.int(1, 8)});
            if (r.random() < 0.3) limit = try g.fmt("{s} OFFSET {d}", .{ limit, r.int(1, 4) });
        }
        return g.fmt("SELECT {s} FROM {s}{s}{s}{s}{s}", .{ sel, f.s, where, group, order, limit });
    }

    fn hardDml(g: *Gen, tabs: []const Table) ![]const u8 {
        const r = g.r;
        const t = r.choice(Table, tabs);
        const w = try g.fmt(" WHERE {s}", .{try g.hardTerm(&.{t}, 0)});
        const x = r.random();
        if (x < 0.45) {
            const c = r.choice([]const u8, t.cols[1..]);
            const opts = [_][]const u8{ try g.hardLit(), c, "NULL" };
            return g.fmt("UPDATE {s} SET {s}={s}{s}", .{ t.name, c, r.choice([]const u8, &opts), w });
        }
        if (x < 0.85) return g.fmt("DELETE FROM {s}{s}", .{ t.name, w });
        const t2 = r.choice(Table, tabs);
        var sel: std.ArrayList([]const u8) = .empty;
        for (0..t.cols.len) |i| try sel.append(g.a, t2.cols[i % t2.cols.len]);
        return g.fmt("INSERT OR IGNORE INTO {s} SELECT {s} FROM {s} WHERE {s}", .{ t.name, try g.join(sel.items, ", "), t2.name, try g.hardTerm(&.{t2}, 0) });
    }

    fn hardDmlFk(g: *Gen, tabs: []const Table) ![]const u8 {
        const q = try g.hardDml(tabs);
        return if (g.r.random() < 0.4) g.fmt("PRAGMA foreign_keys=ON; {s}", .{q}) else q;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn contains(s: []const u8, sub: []const u8) bool {
    return std.mem.indexOf(u8, s, sub) != null;
}

test Random {
    // random.Random(1): random(), randint(0, 100), choice of 7, sample(range(10), 3).
    var r: Random = .init(&.{1});
    try std.testing.expectEqual(@as(f64, 0.13436424411240122), r.random());
    var r2: Random = .init(&.{0});
    try std.testing.expectEqual(@as(f64, 0.8444218515250481), r2.random());
}

test parseInt {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualSlices(u32, &.{0}, try parseInt(arena.allocator(), "0"));
    try std.testing.expectEqualSlices(u32, &.{42}, try parseInt(arena.allocator(), "-42"));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, try parseInt(arena.allocator(), "4294967296"));
}
