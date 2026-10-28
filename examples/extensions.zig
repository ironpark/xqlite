//! Extending SQL from Zig: scalar functions, aggregates, a collation and
//! a table-valued function, with signatures taken from the Zig code.
//!
//!     zig build example-extensions

const std = @import("std");
const xqlite = @import("xqlite");

/// A scalar function: arity 2, INTEGER arguments, INTEGER result.
fn gcd(a: i64, b: i64) i64 {
    var x = @abs(a);
    var y = @abs(b);
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return @intCast(x);
}

/// Text in, text out. The allocator parameter is an arena freed after
/// the call; an error becomes the SQL error message.
fn shout(arena: std.mem.Allocator, s: ?[]const u8) ![]const u8 {
    const text = s orelse return error.NothingToShout;
    const out = try arena.alloc(u8, text.len + 1);
    for (text, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    out[text.len] = '!';
    return out;
}

/// A context pointer: state shared with the application.
const Stats = struct {
    calls: u32 = 0,

    fn tick(self: *Stats) u32 {
        self.calls += 1;
        return self.calls;
    }
};

/// An aggregate (and window function): the geometric mean.
const GeoMean = struct {
    log_sum: f64 = 0,
    n: u32 = 0,

    pub fn step(self: *GeoMean, x: f64) !void {
        if (x <= 0) return error.NonPositiveValue;
        self.log_sum += @log(x);
        self.n += 1;
    }
    pub fn inverse(self: *GeoMean, x: f64) !void {
        self.log_sum -= @log(x);
        self.n -= 1;
    }
    pub fn value(self: *GeoMean) ?f64 {
        if (self.n == 0) return null;
        return @exp(self.log_sum / @as(f64, @floatFromInt(self.n)));
    }
    pub fn final(self: *GeoMean) ?f64 {
        return self.value();
    }
};

/// A collation: compare by length, then bytes.
fn byLength(a: []const u8, b: []const u8) std.math.Order {
    return switch (std.math.order(a.len, b.len)) {
        .eq => std.mem.order(u8, a, b),
        else => |o| o,
    };
}

/// fib(n): the first n Fibonacci numbers, as a table-valued function.
const Fib = struct {
    pub const schema = "CREATE TABLE x(i INTEGER, value INTEGER, n HIDDEN)";
    pub const arg_columns = [_]usize{2};

    pub fn connect(_: std.mem.Allocator, _: []const []const u8) Fib {
        return .{};
    }

    pub const Cursor = struct {
        i: i64 = 0,
        n: i64 = 0,
        a: i64 = 0,
        b: i64 = 1,

        pub fn open(_: *Fib) Cursor {
            return .{};
        }
        pub fn filter(c: *Cursor, args: xqlite.FilterArgs) !void {
            c.* = .{ .n = (try args.get(i64, 0)) orelse 10 };
            if (c.n > 92) return error.WouldOverflow;
        }
        pub fn next(c: *Cursor) void {
            const t = c.a + c.b;
            c.a = c.b;
            c.b = t;
            c.i += 1;
        }
        pub fn eof(c: *const Cursor) bool {
            return c.i >= c.n;
        }
        pub fn column(c: *Cursor, i: usize) i64 {
            return switch (i) {
                0 => c.i,
                1 => c.a,
                else => c.n,
            };
        }
        pub fn rowid(c: *Cursor) i64 {
            return c.i;
        }
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var db = try xqlite.Db.open(gpa, init.io, ":memory:", .{});
    defer db.close();

    var stats: Stats = .{};
    try db.createFunction("gcd", {}, gcd, .{ .deterministic = true });
    try db.createFunction("shout", {}, shout, .{});
    try db.createFunction("tick", &stats, Stats.tick, .{});
    try db.createAggregate("geomean", GeoMean, .{ .deterministic = true });
    try db.createCollation("bylength", {}, byLength);
    try db.createModule("fib", Fib, {});

    std.debug.print("gcd(84, 36) = {d}\n", .{(try db.one(i64, "SELECT gcd(84, 36)", .{})).?});

    const loud = (try db.oneAlloc([]const u8, gpa, "SELECT shout(?)", .{"hello"})).?;
    defer gpa.free(loud);
    std.debug.print("shout('hello') = {s}\n", .{loud});

    db.exec("SELECT shout(NULL)") catch |err| {
        std.debug.print("shout(NULL) -> {s}: {s}\n", .{ @errorName(err), db.lastError().?.message });
    };

    try db.exec(
        \\CREATE TABLE prices(day INTEGER, price REAL);
        \\INSERT INTO prices VALUES(1, 10), (2, 12), (3, 9), (4, 15), (5, 14);
    );
    std.debug.print("geomean(price) = {d:.3}\n", .{(try db.one(f64, "SELECT geomean(price) FROM prices", .{})).?});

    var s = try db.prepare(
        \\SELECT day, geomean(price) OVER (ORDER BY day ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS g, tick() AS t
        \\FROM prices
    );
    defer s.finalize();
    var it = s.iterator(struct { day: i64, g: f64, t: u32 });
    while (try it.next()) |r| std.debug.print("  day {d}: 3-day geomean {d:.3} (call {d})\n", .{ r.day, r.g, r.t });
    std.debug.print("tick() was called {d} times\n", .{stats.calls});

    try db.exec("CREATE TABLE words(w TEXT); INSERT INTO words VALUES('pear'), ('fig'), ('banana'), ('kiwi')");
    const words = try db.all([]const u8, gpa, "SELECT w FROM words ORDER BY w COLLATE bylength", .{});
    defer {
        for (words) |w| gpa.free(w);
        gpa.free(words);
    }
    std.debug.print("by length:", .{});
    for (words) |w| std.debug.print(" {s}", .{w});
    std.debug.print("\n", .{});

    var f = try db.prepare("SELECT i, value FROM fib(?)");
    defer f.finalize();
    try f.bind(.{12});
    std.debug.print("fib:", .{});
    var fit = f.iterator(struct { i64, i64 });
    while (try fit.next()) |r| std.debug.print(" {d}", .{r[1]});
    std.debug.print("\n", .{});
    std.debug.print("sum of the first 50: {d}\n", .{(try db.one(i64, "SELECT sum(value) FROM fib(50)", .{})).?});
}
