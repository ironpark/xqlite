//! The server over loopback TCP, with a line protocol of the test's own:
//! the client sends a script per line, the server answers each event
//! with a line and the end of the script with "end". "cancel ID" cancels
//! the statement of session ID.

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("root.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const Connection = server.Connection;
const Session = server.Session;

const Lines = struct {
    pub fn serve(_: *Lines, c: *Connection) !void {
        const session = try c.openSession(.{ .dialect = .sqlite });
        try c.out().print("hello {d}\n", .{c.ticket().id});
        try c.out().flush();
        while (try c.in().takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "cancel ")) {
                const id = try std.fmt.parseInt(u32, line["cancel ".len..], 10);
                try c.out().print("{s}\n", .{if (c.registry.cancel(id, null)) "canceled" else "unknown"});
            } else {
                var sink: Sink = .{ .w = c.out() };
                try session.run(line, &sink);
                try c.out().writeAll("end\n");
            }
            try c.out().flush();
        }
    }
};

const Sink = struct {
    w: *std.Io.Writer,

    pub fn columns(s: *Sink, cols: []const Session.Column) !void {
        try s.w.writeAll("cols");
        for (cols) |c| try s.w.print(" {s}", .{c.name});
        try s.w.writeByte('\n');
    }

    pub fn row(s: *Sink, r: *Session.Row) !void {
        try s.w.writeAll("row");
        for (0..r.len()) |i| switch (try r.value(i)) {
            .integer => |v| try s.w.print(" {d}", .{v}),
            .text => |v| try s.w.print(" {s}", .{v}),
            else => try s.w.writeAll(" ?"),
        };
        try s.w.writeByte('\n');
    }

    pub fn complete(s: *Sink, c: Session.Complete) !void {
        try s.w.print("done {f}\n", .{c.command});
    }

    pub fn failed(s: *Sink, f: Session.Failure) !void {
        try s.w.print("error {s}\n", .{f.class.sqlstate()});
    }
};

const Client = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    id: u32 = 0,

    fn connect(c: *Client, addr: std.Io.net.IpAddress) !void {
        c.stream = try addr.connect(io, .{ .mode = .stream });
        c.reader = c.stream.reader(io, &c.rbuf);
        c.writer = c.stream.writer(io, &c.wbuf);
        const hello = try c.line();
        c.id = try std.fmt.parseInt(u32, hello["hello ".len..], 10);
    }

    fn close(c: *Client) void {
        c.stream.close(io);
    }

    fn send(c: *Client, text: []const u8) !void {
        try c.writer.interface.writeAll(text);
        try c.writer.interface.writeByte('\n');
        try c.writer.interface.flush();
    }

    fn line(c: *Client) ![]const u8 {
        return (try c.reader.interface.takeDelimiter('\n')) orelse error.EndOfStream;
    }

    /// The lines of the answer to a script, up to "end", joined.
    fn answer(c: *Client, buf: *std.ArrayList(u8)) ![]const u8 {
        buf.clearRetainingCapacity();
        while (true) {
            const l = try c.line();
            if (std.mem.eql(u8, l, "end")) return buf.items;
            try buf.appendSlice(gpa, l);
            try buf.append(gpa, '\n');
        }
    }
};

fn canceler(addr: std.Io.net.IpAddress, victim: u32, stop: *std.atomic.Value(bool)) void {
    var c: Client = .{ .stream = undefined, .reader = undefined, .writer = undefined };
    c.connect(addr) catch return;
    defer c.close();
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cancel {d}", .{victim}) catch return;
    // The interrupt is cleared when a statement starts, so ask until the
    // victim reports the cancel.
    for (0..1000) |_| {
        if (stop.load(.acquire)) return;
        c.send(msg) catch return;
        _ = c.line() catch return;
        io.sleep(.fromMilliseconds(5), .awake) catch return;
    }
}

test "server: clients share the database, a cancel stops a query" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/server.db", .{tmp.sub_path});

    var lines: Lines = .{};
    var srv = try server.Server(Lines).init(io, gpa, &lines, .{
        .address = try .parse("127.0.0.1", 0),
        .path = path,
        .max_connections = 3,
    });
    defer srv.deinit();
    var running = try io.concurrent(server.Server(Lines).run, .{&srv});
    defer running.cancel(io) catch {};
    const addr = srv.address();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    var a: Client = .{ .stream = undefined, .reader = undefined, .writer = undefined };
    try a.connect(addr);
    defer a.close();
    var b: Client = .{ .stream = undefined, .reader = undefined, .writer = undefined };
    try b.connect(addr);
    defer b.close();
    try testing.expect(a.id != b.id);

    try a.send("CREATE TABLE t(x); INSERT INTO t VALUES(1), (2)");
    try testing.expectEqualStrings("done CREATE TABLE\ndone INSERT\n", try a.answer(&buf));
    // Another session sees the commit.
    try b.send("SELECT sum(x) AS s FROM t");
    try testing.expectEqualStrings("cols s\nrow 3\ndone SELECT\n", try b.answer(&buf));
    try b.send("SELECT * FROM nope");
    try testing.expectEqualStrings("error 42P01\n", try b.answer(&buf));

    // A query that would run for minutes, canceled from a third client.
    var stop: std.atomic.Value(bool) = .init(false);
    var cancel_task = try io.concurrent(canceler, .{ addr, a.id, &stop });
    try a.send("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT count(*) FROM c");
    const got = try a.answer(&buf);
    stop.store(true, .release);
    cancel_task.await(io);
    try testing.expectEqualStrings("error 57014\n", got);
    // The session goes on.
    try a.send("SELECT count(*) AS n FROM t");
    try testing.expectEqualStrings("cols n\nrow 2\ndone SELECT\n", try a.answer(&buf));
}
