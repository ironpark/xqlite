//! A small regular expression engine for jsonpath's like_regex: the
//! common part of POSIX extended (and PostgreSQL's advanced) syntax,
//! matched by a Pike VM (no backtracking blow-up):
//!
//!   literals, `.`, `[...]` / `[^...]` with ranges, `\d \w \s` (and their
//!   negations), escaped characters, `^`, `$`, `( )`, `|`, `*`, `+`,
//!   `?`, `{n}`, `{n,}`, `{n,m}`;
//!
//! flags: `i` (ASCII case-insensitive), `s` (`.` matches newline; the
//! default here), `q` (the pattern is a literal string). A match may be
//! anywhere in the text (unanchored, as like_regex is).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, BadPattern };

const Range = struct { lo: u21, hi: u21 };

const Cls = struct { ranges: []const Range, neg: bool };

const Node = union(enum) {
    empty,
    lit: u21,
    any,
    cls: Cls,
    bol,
    eol,
    cat: []*Node,
    alt: []*Node,
    rep: struct { n: *Node, min: u32, max: ?u32 },
};

const Inst = union(enum) {
    lit: u21,
    any,
    cls: Cls,
    bol,
    eol,
    split: struct { a: u32, b: u32 },
    jmp: u32,
    match,
};

pub const Regex = struct {
    prog: []Inst,
    fold: bool,

    /// Whether `s` has a match.
    pub fn search(re: *const Regex, a: Allocator, s: []const u8) Error!bool {
        const n = re.prog.len;
        var cur = try std.DynamicBitSet.initEmpty(a, n);
        var next = try std.DynamicBitSet.initEmpty(a, n);
        var stack: std.ArrayList(u32) = .empty;
        var i: usize = 0;
        while (true) {
            // A thread starts at every position.
            if (try re.add(a, &cur, &stack, 0, s, i)) return true;
            if (i >= s.len) break;
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(s.len, i + len);
            const c: u21 = std.unicode.utf8Decode(s[i..end]) catch s[i];
            next.unsetAll();
            var it = cur.iterator(.{});
            while (it.next()) |pc| {
                const ok = switch (re.prog[pc]) {
                    .lit => |l| re.eq(l, c),
                    .any => true,
                    .cls => |k| re.inClass(k, c),
                    else => false,
                };
                if (ok and try re.add(a, &next, &stack, @intCast(pc + 1), s, end)) return true;
            }
            std.mem.swap(std.DynamicBitSet, &cur, &next);
            i = end;
        }
        return false;
    }

    /// Add the thread at `pc` (and what it reaches without reading) to
    /// `set`; true if it reaches the match.
    fn add(re: *const Regex, a: Allocator, set: *std.DynamicBitSet, stack: *std.ArrayList(u32), pc0: u32, s: []const u8, i: usize) Error!bool {
        stack.clearRetainingCapacity();
        try stack.append(a, pc0);
        while (stack.pop()) |pc| {
            if (set.isSet(pc)) continue;
            set.set(pc);
            switch (re.prog[pc]) {
                .match => return true,
                .jmp => |t| try stack.append(a, t),
                .split => |sp| {
                    try stack.append(a, sp.b);
                    try stack.append(a, sp.a);
                },
                .bol => if (i == 0) try stack.append(a, pc + 1),
                .eol => if (i == s.len) try stack.append(a, pc + 1),
                else => {},
            }
        }
        return false;
    }

    fn eq(re: *const Regex, x: u21, y: u21) bool {
        if (x == y) return true;
        return re.fold and x < 128 and y < 128 and std.ascii.toLower(@intCast(x)) == std.ascii.toLower(@intCast(y));
    }

    fn inClass(re: *const Regex, k: Cls, c: u21) bool {
        var in = false;
        for (k.ranges) |r| {
            if (c >= r.lo and c <= r.hi) in = true;
            if (re.fold and c < 128) {
                const lc = std.ascii.toLower(@intCast(c));
                const uc = std.ascii.toUpper(@intCast(c));
                if ((lc >= r.lo and lc <= r.hi) or (uc >= r.lo and uc <= r.hi)) in = true;
            }
        }
        return in != k.neg;
    }
};

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    depth: u32 = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn node(p: *Parser, n: Node) Error!*Node {
        const x = try p.a.create(Node);
        x.* = n;
        return x;
    }

    fn alt(p: *Parser) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        try items.append(p.a, try p.cat());
        while (p.peek() == '|') {
            p.i += 1;
            try items.append(p.a, try p.cat());
        }
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .alt = items.items });
    }

    fn cat(p: *Parser) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            var item = try p.atom();
            while (p.peek()) |q| {
                var min: u32 = 0;
                var max: ?u32 = null;
                switch (q) {
                    '*' => p.i += 1,
                    '+' => {
                        p.i += 1;
                        min = 1;
                    },
                    '?' => {
                        p.i += 1;
                        max = 1;
                    },
                    '{' => {
                        const save = p.i;
                        p.i += 1;
                        min = p.number() orelse {
                            p.i = save;
                            break;
                        };
                        max = min;
                        if (p.peek() == ',') {
                            p.i += 1;
                            max = p.number();
                        }
                        if (p.peek() != '}') return error.BadPattern;
                        p.i += 1;
                        if (max != null and max.? < min) return error.BadPattern;
                        if (min > 1000 or (max orelse 0) > 1000) return error.BadPattern;
                    },
                    else => break,
                }
                // A non-greedy marker changes nothing for a yes/no match.
                if (p.peek() == '?') p.i += 1;
                item = try p.node(.{ .rep = .{ .n = item, .min = min, .max = max } });
            }
            try items.append(p.a, item);
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .cat = items.items });
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.i += 1;
        }
        if (p.i == start) return null;
        return std.fmt.parseInt(u32, p.s[start..p.i], 10) catch null;
    }

    fn char(p: *Parser) u21 {
        const len = std.unicode.utf8ByteSequenceLength(p.s[p.i]) catch 1;
        const end = @min(p.s.len, p.i + len);
        const c: u21 = std.unicode.utf8Decode(p.s[p.i..end]) catch p.s[p.i];
        p.i = end;
        return c;
    }

    fn atom(p: *Parser) Error!*Node {
        const c = p.peek().?;
        switch (c) {
            '(' => {
                p.i += 1;
                if (std.mem.startsWith(u8, p.s[p.i..], "?:")) p.i += 2;
                p.depth += 1;
                if (p.depth > 100) return error.BadPattern;
                const inner = try p.alt();
                p.depth -= 1;
                if (p.peek() != ')') return error.BadPattern;
                p.i += 1;
                return inner;
            },
            '.' => {
                p.i += 1;
                return p.node(.any);
            },
            '^' => {
                p.i += 1;
                return p.node(.bol);
            },
            '$' => {
                p.i += 1;
                return p.node(.eol);
            },
            '[' => return p.class(),
            '\\' => {
                p.i += 1;
                if (p.i >= p.s.len) return error.BadPattern;
                if (shorthand(p.s[p.i])) |k| {
                    p.i += 1;
                    return p.node(.{ .cls = k });
                }
                return p.node(.{ .lit = p.char() });
            },
            '*', '+', '?', '{' => return error.BadPattern,
            else => return p.node(.{ .lit = p.char() }),
        }
    }

    fn class(p: *Parser) Error!*Node {
        p.i += 1;
        var neg = false;
        if (p.peek() == '^') {
            neg = true;
            p.i += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            const c = p.peek() orelse return error.BadPattern;
            if (c == ']' and !first) {
                p.i += 1;
                break;
            }
            first = false;
            var lo: u21 = undefined;
            if (c == '\\') {
                p.i += 1;
                if (p.i >= p.s.len) return error.BadPattern;
                if (shorthand(p.s[p.i])) |k| {
                    p.i += 1;
                    if (k.neg) return error.BadPattern;
                    try ranges.appendSlice(p.a, k.ranges);
                    continue;
                }
                lo = p.char();
            } else lo = p.char();
            var hi = lo;
            if (p.peek() == '-' and p.i + 1 < p.s.len and p.s[p.i + 1] != ']') {
                p.i += 1;
                if (p.peek() == '\\') p.i += 1;
                hi = p.char();
                if (hi < lo) return error.BadPattern;
            }
            try ranges.append(p.a, .{ .lo = lo, .hi = hi });
        }
        return p.node(.{ .cls = .{ .ranges = ranges.items, .neg = neg } });
    }
};

const digits = [_]Range{.{ .lo = '0', .hi = '9' }};
const words = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = '_', .hi = '_' } };
const spaces = [_]Range{ .{ .lo = 9, .hi = 13 }, .{ .lo = ' ', .hi = ' ' } };

fn shorthand(c: u8) ?Cls {
    return switch (c) {
        'd' => .{ .ranges = &digits, .neg = false },
        'D' => .{ .ranges = &digits, .neg = true },
        'w' => .{ .ranges = &words, .neg = false },
        'W' => .{ .ranges = &words, .neg = true },
        's' => .{ .ranges = &spaces, .neg = false },
        'S' => .{ .ranges = &spaces, .neg = true },
        else => null,
    };
}

const Emitter = struct {
    a: Allocator,
    prog: std.ArrayList(Inst) = .empty,

    fn pc(e: *Emitter) u32 {
        return @intCast(e.prog.items.len);
    }

    fn emit(e: *Emitter, i: Inst) Error!u32 {
        if (e.prog.items.len > 100_000) return error.BadPattern;
        try e.prog.append(e.a, i);
        return e.pc() - 1;
    }

    fn node(e: *Emitter, n: *const Node) Error!void {
        switch (n.*) {
            .empty => {},
            .lit => |c| _ = try e.emit(.{ .lit = c }),
            .any => _ = try e.emit(.any),
            .cls => |k| _ = try e.emit(.{ .cls = k }),
            .bol => _ = try e.emit(.bol),
            .eol => _ = try e.emit(.eol),
            .cat => |items| for (items) |x| try e.node(x),
            .alt => |items| {
                var jumps: std.ArrayList(u32) = .empty;
                for (items, 0..) |x, k| {
                    if (k + 1 < items.len) {
                        const sp = try e.emit(.{ .split = .{ .a = 0, .b = 0 } });
                        e.prog.items[sp].split.a = e.pc();
                        try e.node(x);
                        try jumps.append(e.a, try e.emit(.{ .jmp = 0 }));
                        e.prog.items[sp].split.b = e.pc();
                    } else try e.node(x);
                }
                for (jumps.items) |j| e.prog.items[j].jmp = e.pc();
            },
            .rep => |r| {
                for (0..r.min) |_| try e.node(r.n);
                if (r.max) |max| {
                    var outs: std.ArrayList(u32) = .empty;
                    for (r.min..max) |_| {
                        const sp = try e.emit(.{ .split = .{ .a = 0, .b = 0 } });
                        e.prog.items[sp].split.a = e.pc();
                        try outs.append(e.a, sp);
                        try e.node(r.n);
                    }
                    for (outs.items) |sp| e.prog.items[sp].split.b = e.pc();
                } else {
                    const sp = try e.emit(.{ .split = .{ .a = 0, .b = 0 } });
                    e.prog.items[sp].split.a = e.pc();
                    try e.node(r.n);
                    _ = try e.emit(.{ .jmp = sp });
                    e.prog.items[sp].split.b = e.pc();
                }
            },
        }
    }
};

/// Compile `pattern` with like_regex `flags`.
pub fn compile(a: Allocator, pattern: []const u8, flags: []const u8) Error!Regex {
    var fold = false;
    var quote = false;
    for (flags) |f| switch (f) {
        'i' => fold = true,
        'q' => quote = true,
        's', 'm', 'x' => {},
        else => return error.BadPattern,
    };
    var e: Emitter = .{ .a = a };
    if (quote) {
        var i: usize = 0;
        while (i < pattern.len) {
            const len = std.unicode.utf8ByteSequenceLength(pattern[i]) catch 1;
            const end = @min(pattern.len, i + len);
            _ = try e.emit(.{ .lit = std.unicode.utf8Decode(pattern[i..end]) catch pattern[i] });
            i = end;
        }
    } else {
        var p: Parser = .{ .a = a, .s = pattern };
        const n = try p.alt();
        if (p.i != pattern.len) return error.BadPattern;
        try e.node(n);
    }
    _ = try e.emit(.match);
    return .{ .prog = e.prog.items, .fold = fold };
}

test "regex" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8, []const u8, bool }{
        .{ "^a.c$", "", "abc", true },
        .{ "^a.c$", "", "abcd", false },
        .{ "b", "", "abc", true },
        .{ "^(ab|cd)+$", "", "abcdab", true },
        .{ "^(ab|cd)+$", "", "abce", false },
        .{ "^[a-c]{2,3}$", "", "cab", true },
        .{ "^[a-c]{2,3}$", "", "cabc", false },
        .{ "^[^0-9]*$", "", "abc", true },
        .{ "\\d+", "", "x12", true },
        .{ "^ABC$", "i", "abc", true },
        .{ "a.c", "q", "abc", false },
        .{ "a.c", "q", "xa.cx", true },
        .{ "colou?r", "", "color", true },
        .{ "^$", "", "", true },
        .{ "x*", "", "", true },
    };
    for (cases) |cs| {
        const re = try compile(a, cs[0], cs[1]);
        try std.testing.expectEqual(cs[3], try re.search(a, cs[2]));
    }
    try std.testing.expectError(error.BadPattern, compile(a, "(a", ""));
    try std.testing.expectError(error.BadPattern, compile(a, "*a", ""));
}
