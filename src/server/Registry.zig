//! The sessions of a server, for the requests that come from outside a
//! session: PostgreSQL's CancelRequest (a new connection that names a
//! session by its process id and secret key), MySQL's KILL QUERY (a
//! statement of another session, by connection id), and the connection
//! limit. Thread-safe: each session runs on a task of its own.

const std = @import("std");
const Session = @import("Session.zig");

const Registry = @This();

io: std.Io,
gpa: std.mem.Allocator,
/// The most sessions at a time.
max: u32,
mutex: std.Io.Mutex = .init,
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
/// The id of the last session added (ids start at 1 and are not reused
/// before they wrap).
last_id: u32 = 0,

const Entry = struct { session: *Session, ticket: Ticket };

/// What a session is known by. The protocols send it to their client
/// (PostgreSQL's BackendKeyData, MySQL's connection id, TDS's SPID).
pub const Ticket = struct {
    id: u32,
    /// A secret the client must give back to cancel (PostgreSQL), so that
    /// another client cannot cancel by guessing ids.
    key: u32,
};

pub fn init(io: std.Io, gpa: std.mem.Allocator, max: u32) Registry {
    return .{ .io = io, .gpa = gpa, .max = max };
}

pub fn deinit(r: *Registry) void {
    r.entries.deinit(r.gpa);
    r.* = undefined;
}

/// Add `session`, unless there are `max` already (error.TooManySessions).
/// Remove it with remove() before closing it.
pub fn add(r: *Registry, session: *Session) error{ OutOfMemory, TooManySessions }!Ticket {
    var key_bytes: [4]u8 = undefined;
    r.io.random(&key_bytes);
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (r.entries.count() >= r.max) return error.TooManySessions;
    var id = r.last_id;
    while (true) {
        id +%= 1;
        if (id != 0 and !r.entries.contains(id)) break;
    }
    const t: Ticket = .{ .id = id, .key = std.mem.readInt(u32, &key_bytes, .little) };
    try r.entries.put(r.gpa, id, .{ .session = session, .ticket = t });
    r.last_id = id;
    return t;
}

pub fn remove(r: *Registry, id: u32) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    _ = r.entries.remove(id);
}

/// Cancel the statement running in session `id` (Session.cancel()), if
/// there is that session and `key` is its key or null (a request that
/// needs none, such as KILL QUERY from an authenticated session). Returns
/// whether it did.
pub fn cancel(r: *Registry, id: u32, key: ?u32) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const e = r.entries.get(id) orelse return false;
    if (key) |k| if (k != e.ticket.key) return false;
    // Under the lock, so that the session is not closed meanwhile.
    e.session.cancel();
    return true;
}

test "add, cancel by key, the limit" {
    var r: Registry = .init(std.testing.io, std.testing.allocator, 2);
    defer r.deinit();
    var a = try Session.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer a.close();
    var b = try Session.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer b.close();
    const ta = try r.add(&a);
    const tb = try r.add(&b);
    try std.testing.expect(ta.id != tb.id);
    try std.testing.expectError(error.TooManySessions, r.add(&b));
    try std.testing.expect(!r.cancel(ta.id, ta.key +% 1));
    try std.testing.expect(r.cancel(ta.id, ta.key));
    try std.testing.expect(r.cancel(tb.id, null));
    r.remove(ta.id);
    try std.testing.expect(!r.cancel(ta.id, ta.key));
    try std.testing.expectEqual(@as(usize, 1), r.entries.count());
}
