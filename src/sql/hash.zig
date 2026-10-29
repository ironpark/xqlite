//! The element order of SQLite's Hash (port of hash.c).
//!
//! The schema maps are Zig hash maps, which iterate in another order than
//! SQLite's Hash. Where C's iteration order shows in the bytecode or the
//! data (ANALYZE and PRAGMA optimize go over Schema.tblHash), a HashOrder
//! next to the map keeps the elements in the order C's Hash would: it
//! makes the same buckets, chains and rehashes as hash.c. Lookups stay
//! with the Zig map.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Port of SQLITE_MALLOC_SOFT_LIMIT (the reference builds use 1024): the
/// bucket array is never made larger than this.
const malloc_soft_limit = 1024;

/// sizeof(struct _ht) on 64-bit platforms (an int and a pointer).
const sizeof_ht = 16;

/// Port of strHash(): the hash of `z`, ignoring the case of ASCII letters.
pub fn strHash(z: []const u8) u32 {
    var h: u32 = 0;
    for (z) |c| {
        if (c == 0) break;
        h +%= 0xdf & c;
        h *%= 0x9e3779b1;
    }
    return h;
}

/// Elements in the order of a C Hash keyed by name (case-insensitive),
/// with values of type V.
pub fn HashOrder(comptime V: type) type {
    return struct {
        const Self = @This();

        /// The first element of the list of all elements (Hash.first).
        first: ?*Elem = null,
        count: u32 = 0,
        /// The buckets (Hash.ht, Hash.htsize); empty until the first rehash.
        ht: []Bucket = &.{},

        pub const Elem = struct {
            next: ?*Elem = null,
            prev: ?*Elem = null,
            data: V,
            key: []const u8,
            h: u32,
        };

        /// struct _ht.
        const Bucket = struct {
            count: u32 = 0,
            chain: ?*Elem = null,
        };

        /// Port of sqlite3HashClear().
        pub fn clear(self: *Self, gpa: Allocator) void {
            var elem = self.first;
            self.first = null;
            gpa.free(self.ht);
            self.ht = &.{};
            while (elem) |e| {
                elem = e.next;
                gpa.destroy(e);
            }
            self.count = 0;
        }

        /// Port of insertElement(): link `new` into bucket `entry` (if
        /// any) and the list of all elements.
        fn insertElement(self: *Self, entry: ?*Bucket, new: *Elem) void {
            var head: ?*Elem = null;
            if (entry) |b| {
                head = if (b.count != 0) b.chain else null;
                b.count += 1;
                b.chain = new;
            }
            if (head) |h| {
                new.next = h;
                new.prev = h.prev;
                if (h.prev) |pv| pv.next = new else self.first = new;
                h.prev = new;
            } else {
                new.next = self.first;
                if (self.first) |f| f.prev = new;
                new.prev = null;
                self.first = new;
            }
        }

        /// Port of rehash(). A failed allocation leaves the buckets as
        /// they are, as in C.
        fn rehash(self: *Self, gpa: Allocator, new_size_arg: u32) void {
            var new_size = new_size_arg;
            if (@as(u64, new_size) * sizeof_ht > malloc_soft_limit) new_size = malloc_soft_limit / sizeof_ht;
            if (new_size == self.ht.len) return;
            // sqlite3MallocSize() of the array is what was asked for:
            // malloc rounds to 8 or 16 bytes, a multiple of sizeof_ht.
            const new_ht = gpa.alloc(Bucket, new_size) catch return;
            gpa.free(self.ht);
            self.ht = new_ht;
            @memset(new_ht, .{});
            var elem = self.first;
            self.first = null;
            while (elem) |e| {
                elem = e.next;
                self.insertElement(&new_ht[e.h % new_size], e);
            }
        }

        /// Port of findElementWithHash(): the element of `key`, or null.
        fn find(self: *const Self, key: []const u8, h: u32) ?*Elem {
            var elem: ?*Elem = undefined;
            var count: u32 = undefined;
            if (self.ht.len > 0) {
                const b = &self.ht[h % self.ht.len];
                elem = b.chain;
                count = b.count;
            } else {
                elem = self.first;
                count = self.count;
            }
            while (count > 0) : (count -= 1) {
                const e = elem.?;
                if (e.h == h and std.ascii.eqlIgnoreCase(e.key, key)) return e;
                elem = e.next;
            }
            return null;
        }

        /// Port of removeElement().
        fn removeElement(self: *Self, gpa: Allocator, elem: *Elem) void {
            if (elem.prev) |pv| pv.next = elem.next else self.first = elem.next;
            if (elem.next) |nx| nx.prev = elem.prev;
            if (self.ht.len > 0) {
                const b = &self.ht[elem.h % self.ht.len];
                if (b.chain == elem) b.chain = elem.next;
                b.count -= 1;
            }
            gpa.destroy(elem);
            self.count -= 1;
            if (self.count == 0) self.clear(gpa);
        }

        /// Port of sqlite3HashInsert() with data: add `key` (or replace
        /// its value). `key` must live as long as the element.
        pub fn insert(self: *Self, gpa: Allocator, key: []const u8, data: V) Allocator.Error!void {
            const h = strHash(key);
            if (self.find(key, h)) |e| {
                e.data = data;
                e.key = key;
                return;
            }
            const new = try gpa.create(Elem);
            new.* = .{ .key = key, .h = h, .data = data };
            self.count += 1;
            if (self.count >= 5 and self.count > 2 * self.ht.len) self.rehash(gpa, self.count * 3);
            self.insertElement(if (self.ht.len > 0) &self.ht[h % self.ht.len] else null, new);
        }

        /// Port of sqlite3HashInsert() without data: remove `key`.
        pub fn remove(self: *Self, gpa: Allocator, key: []const u8) void {
            if (self.find(key, strHash(key))) |e| self.removeElement(gpa, e);
        }

        pub const Iterator = struct {
            elem: ?*Elem,

            pub fn next(it: *Iterator) ?V {
                const e = it.elem orelse return null;
                it.elem = e.next;
                return e.data;
            }
        };

        /// The values in C's order (sqliteHashFirst(), sqliteHashNext()).
        pub fn iterator(self: *const Self) Iterator {
            return .{ .elem = self.first };
        }
    };
}

test "HashOrder iterates as SQLite's Hash" {
    const gpa = std.testing.allocator;
    var h: HashOrder(u32) = .{};
    defer h.clear(gpa);
    // Without buckets, a new element goes first.
    const names = [_][]const u8{ "a", "b", "c", "d" };
    for (names, 0..) |n, i| try h.insert(gpa, n, @intCast(i));
    var it = h.iterator();
    for ([_]u32{ 3, 2, 1, 0 }) |want| try std.testing.expectEqual(want, it.next().?);
    try std.testing.expectEqual(null, it.next());
    // The fifth makes 15 buckets; the order follows the chains.
    try h.insert(gpa, "e", 4);
    h.remove(gpa, "B");
    try std.testing.expectEqual(4, h.count);
    var n: u32 = 0;
    it = h.iterator();
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(4, n);
    for (names) |k| h.remove(gpa, k);
    h.remove(gpa, "e");
    try std.testing.expectEqual(null, h.first);
    try std.testing.expectEqual(0, h.ht.len);
}
