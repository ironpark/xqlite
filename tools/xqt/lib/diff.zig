//! A unified diff of two texts, cut short, for failure reports.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Unchanged lines around each change.
    context: usize = 3,
    /// Stop after this many lines of hunks ("..." follows).
    max_lines: usize = 40,
};

/// Splits at '\n'; a final newline does not start another line.
pub fn lines(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try list.append(gpa, l);
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) _ = list.pop();
    return list.toOwnedSlice(gpa);
}

/// Writes the diff from `a` to `b` (texts) in the format of `diff -u`:
/// "--- a_name", "+++ b_name", then "@@ -l,n +l,n @@" hunks. Writes
/// nothing if they are equal.
pub fn write(w: *Io.Writer, gpa: Allocator, a_name: []const u8, b_name: []const u8, a: []const u8, b: []const u8, opts: Options) !void {
    const al = try lines(gpa, a);
    defer gpa.free(al);
    const bl = try lines(gpa, b);
    defer gpa.free(bl);
    try writeLines(w, gpa, a_name, b_name, al, bl, opts);
}

const Op = enum { same, del, ins };

/// `write` on texts already split into lines.
pub fn writeLines(w: *Io.Writer, gpa: Allocator, a_name: []const u8, b_name: []const u8, a: []const []const u8, b: []const []const u8, opts: Options) !void {
    const ops = try script(gpa, a, b);
    defer gpa.free(ops);
    if (std.mem.indexOfNone(Op, ops, &.{.same}) == null) return;
    try w.print("--- {s}\n+++ {s}\n", .{ a_name, b_name });

    var written: usize = 0;
    var i: usize = 0; // index into ops
    var ai: usize = 0;
    var bi: usize = 0;
    while (i < ops.len) {
        // The next change, and the hunk around it: changes closer than
        // 2 * context lines join one hunk.
        const first = std.mem.indexOfNonePos(Op, ops, i, &.{.same}) orelse break;
        for (ops[i..first]) |op| {
            ai += @intFromBool(op != .ins);
            bi += @intFromBool(op != .del);
        }
        const start = first -| opts.context;
        var end = first;
        while (end < ops.len) {
            const next_same = std.mem.indexOfScalarPos(Op, ops, end, .same) orelse ops.len;
            const next_change = std.mem.indexOfNonePos(Op, ops, next_same, &.{.same}) orelse ops.len;
            end = next_same;
            if (next_change == ops.len or next_change - next_same > 2 * opts.context) break;
            end = next_change;
        }
        const stop = @min(ops.len, end + opts.context);
        // Line numbers at `start`.
        const back = first - start;
        const a0 = ai - back;
        const b0 = bi - back;
        var na: usize = 0;
        var nb: usize = 0;
        for (ops[start..stop]) |op| {
            na += @intFromBool(op != .ins);
            nb += @intFromBool(op != .del);
        }
        try w.writeAll("@@ -");
        try range(w, a0, na);
        try w.writeAll(" +");
        try range(w, b0, nb);
        try w.writeAll(" @@\n");
        var x = a0;
        var y = b0;
        for (ops[start..stop]) |op| {
            if (written == opts.max_lines) {
                try w.writeAll("...\n");
                return;
            }
            written += 1;
            switch (op) {
                .same => {
                    try w.print(" {s}\n", .{a[x]});
                    x += 1;
                    y += 1;
                },
                .del => {
                    try w.print("-{s}\n", .{a[x]});
                    x += 1;
                },
                .ins => {
                    try w.print("+{s}\n", .{b[y]});
                    y += 1;
                },
            }
        }
        ai = x;
        bi = y;
        i = stop;
    }
}

/// "l,n" as diff -u and Python's difflib print it.
fn range(w: *Io.Writer, start: usize, n: usize) !void {
    if (n == 1) return w.print("{d}", .{start + 1});
    try w.print("{d},{d}", .{ if (n == 0) start else start + 1, n });
}

/// The edit script from `a` to `b`: a longest common subsequence of the
/// lines between the common prefix and suffix. Past a size where that
/// costs too much, the middle is all deleted and inserted.
fn script(gpa: Allocator, a: []const []const u8, b: []const []const u8) ![]Op {
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and std.mem.eql(u8, a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and
        std.mem.eql(u8, a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    const ma = a[pre .. a.len - suf];
    const mb = b[pre .. b.len - suf];

    var ops: std.ArrayList(Op) = .empty;
    errdefer ops.deinit(gpa);
    try ops.appendNTimes(gpa, .same, pre);
    const n = ma.len;
    const m = mb.len;
    if (n * m > 4 << 20) {
        try ops.appendNTimes(gpa, .del, n);
        try ops.appendNTimes(gpa, .ins, m);
    } else {
        // lcs[i][j]: the LCS length of ma[i..] and mb[j..].
        const lcs = try gpa.alloc(u32, (n + 1) * (m + 1));
        defer gpa.free(lcs);
        const at = struct {
            fn f(cols: usize, i: usize, j: usize) usize {
                return i * (cols + 1) + j;
            }
        }.f;
        var i = n + 1;
        while (i > 0) {
            i -= 1;
            var j = m + 1;
            while (j > 0) {
                j -= 1;
                lcs[at(m, i, j)] = if (i == n or j == m)
                    0
                else if (std.mem.eql(u8, ma[i], mb[j]))
                    lcs[at(m, i + 1, j + 1)] + 1
                else
                    @max(lcs[at(m, i + 1, j)], lcs[at(m, i, j + 1)]);
            }
        }
        var x: usize = 0;
        var y: usize = 0;
        while (x < n or y < m) {
            if (x < n and y < m and std.mem.eql(u8, ma[x], mb[y])) {
                try ops.append(gpa, .same);
                x += 1;
                y += 1;
            } else if (y == m or (x < n and lcs[at(m, x + 1, y)] >= lcs[at(m, x, y + 1)])) {
                try ops.append(gpa, .del);
                x += 1;
            } else {
                try ops.append(gpa, .ins);
                y += 1;
            }
        }
    }
    try ops.appendNTimes(gpa, .same, suf);
    return ops.toOwnedSlice(gpa);
}

fn expectDiff(want: []const u8, a: []const u8, b: []const u8, opts: Options) !void {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, std.testing.allocator, "a", "b", a, b, opts);
    try std.testing.expectEqualStrings(want, out.written());
}

test "unified diff" {
    try expectDiff("", "x\ny\n", "x\ny\n", .{});
    try expectDiff(
        \\--- a
        \\+++ b
        \\@@ -1,3 +1,3 @@
        \\ 1
        \\-2
        \\+two
        \\ 3
        \\
    , "1\n2\n3\n", "1\ntwo\n3\n", .{ .context = 1 });
    // Changes far apart make two hunks; an empty side counts from 0.
    try expectDiff(
        \\--- a
        \\+++ b
        \\@@ -1,2 +1 @@
        \\-0
        \\ 1
        \\@@ -6 +5,2 @@
        \\ 6
        \\+7
        \\
    , "0\n1\n2\n3\n4\n5\n6\n", "1\n2\n3\n4\n5\n6\n7\n", .{ .context = 1 });
    try expectDiff(
        \\--- a
        \\+++ b
        \\@@ -0,0 +1 @@
        \\+x
        \\
    , "", "x\n", .{});
    try expectDiff(
        \\--- a
        \\+++ b
        \\@@ -1,3 +1,3 @@
        \\-1
        \\-2
        \\...
        \\
    , "1\n2\n3\n", "4\n5\n6\n", .{ .max_lines = 2 });
}
