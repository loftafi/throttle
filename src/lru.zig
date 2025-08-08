/// Thread safe LRU cache.
pub fn LRU(comptime K: type, comptime V: type) type {
    return struct {
        const Entry = struct {
            value: V,
            node: *DoublyLinkedList(K).Node,
        };

        /// Maximum number of items to hold in this cache.
        limit: usize,

        /// Current number of items held in this cache.
        len: usize,

        /// List of keys with most recently used key first.
        keys: DoublyLinkedList(K),

        /// HashMap of each key/value pair for fast lookup.
        entries: std.AutoHashMapUnmanaged(K, Entry),

        mutex: Mutex,

        // If the value is a pointer to an object, and if the object must be
        // freed, provide a function to dealloc the value in the entity.
        entry_dealloc: ?*const fn (entry: V, allocator: Allocator) void,

        const Self = @This();

        pub fn init(limit: usize) Self {
            return Self{
                .keys = DoublyLinkedList(K){},
                .entries = .empty,
                .mutex = .{},
                .limit = limit,
                .len = 0,
                .entry_dealloc = null,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.entry_dealloc != null) {
                var vi = self.entries.valueIterator();
                while (vi.next()) |value| {
                    self.entry_dealloc.?(value.value, allocator);
                }
            }
            self.entries.deinit(allocator);

            while (self.keys.pop()) |entry| {
                allocator.destroy(entry);
            }
            self.* = undefined;
        }

        /// Add a value to the cache. If adding a value would exceed the
        /// maximum cache size, the oldest entry is removed.
        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = try self.entries.getOrPut(allocator, key);

            if (entry.found_existing) {
                // Move this key to start of key list, it is most recent
                self.keys.remove(entry.value_ptr.*.node);
                self.keys.prepend(entry.value_ptr.*.node);

                // Replace the hashmap value
                if (self.entry_dealloc != null) {
                    self.entry_dealloc.?(entry.value_ptr.*.value, allocator);
                }
                entry.value_ptr.*.value = value;
                return;
            }

            // Create new cache entry
            var node = try allocator.create(DoublyLinkedList(K).Node);
            node.data = key;
            self.keys.prepend(node);
            entry.value_ptr.* = Entry{ .value = value, .node = node };

            // If cache overflows, remove oldest item.
            if (self.len >= self.limit) {
                const result = self.keys.pop().?;
                defer allocator.destroy(result);
                const removed_key = result.*.data;
                if (self.entries.fetchRemove(removed_key)) |rmkv| {
                    if (self.entry_dealloc != null) {
                        self.entry_dealloc.?(rmkv.value.value, allocator);
                    }
                    return;
                }
                return;
            }

            self.len = self.len + 1;
            return;
        }

        /// Return the value assocaited with a key if it exists in the cache:
        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.entries.get(key)) |hash_value| {
                self.keys.remove(hash_value.node);
                self.keys.prepend(hash_value.node);
                return hash_value.value;
            } else {
                return null;
            }
        }

        /// Return the number of items in the cache.
        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        /// Return the list of keys. Not thread safe.
        pub fn getKeys(self: *const Self) DoublyLinkedList(K) {
            return self.keys;
        }
    };
}

test "init_deinit" {
    const allocator = std.testing.allocator;

    var lru = LRU(i64, i64).init(10);
    defer lru.deinit(allocator);

    var lru2 = LRU(i64, i64).init(10);
    try lru2.put(allocator, 50, 60);
    try lru2.put(allocator, 50, 61);
    try lru2.put(allocator, 53, 63);
    defer lru2.deinit(allocator);
}

test "destry_helper" {
    const allocator = std.testing.allocator;

    const Sample = struct {
        age: u8 = 10,
        pub const Self = @This();
        pub fn destroy(self: *Self, gpa: Allocator) void {
            gpa.destroy(self);
        }
    };

    // Overflow the LRU cache with 3 items, to check
    // dealloc when the cache overflows.
    var lru = LRU(u32, *Sample).init(2);
    defer lru.deinit(allocator);
    lru.entry_dealloc = Sample.destroy;

    const sample = try allocator.create(Sample);
    sample.*.age = 20;

    const sample2 = try allocator.create(Sample);
    sample2.*.age = 30;

    const sample3 = try allocator.create(Sample);
    sample3.*.age = 40;

    try lru.put(allocator, 20, sample);
    try lru.put(allocator, 30, sample2);
    try lru.put(allocator, 40, sample3);

    try expect(lru.get(30).?.age == 30);
    try expect(lru.get(40).?.age == 40);
    try expect(lru.get(20) == null);

    // Test when put causes entry replacement needing dealloc
    const sample4 = try allocator.create(Sample);
    sample4.*.age = 40;
    try lru.put(allocator, 40, sample4);
}

test "put_get" {
    const allocator = std.testing.allocator;

    var lru = LRU(u16, u16).init(256);
    defer lru.deinit(allocator);

    try lru.put(allocator, 10, 20);
    try expect(lru.get(10).? == 20);

    try lru.put(allocator, 20, 30);
    try expect(lru.get(20).? == 30);

    try lru.put(allocator, 20, 40);
    try expect(lru.get(20).? == 40);

    try expect(lru.get(30) == null);
}

test "length_check" {
    const allocator = std.testing.allocator;

    var lru = LRU(u16, usize).init(50);
    defer lru.deinit(allocator);

    try expect(lru.count() == 0);

    try lru.put(allocator, 1, 10);
    try expect(lru.count() == 1);

    try lru.put(allocator, 2, 20);
    try expect(lru.count() == 2);

    try lru.put(allocator, 2, 30);
    try expect(lru.count() == 2);
}

test "oldest_removal" {
    const allocator = std.testing.allocator;

    var lru = LRU(usize, usize).init(2);
    defer lru.deinit(allocator);

    try lru.put(allocator, 1, 10);
    try lru.put(allocator, 2, 20);
    try expect(lru.count() == 2);

    // Check adding one too many items evicts the oldest item.
    try lru.put(allocator, 3, 30);

    try expect(lru.count() == 2);
    try expect(lru.getKeys().len == 2);

    try expect(lru.get(1) == null);
    try expect(lru.get(2).? == 20);
    try expect(lru.get(3).? == 30);

    // Check oldest (not used) entry is removed.
    try lru.put(allocator, 4, 40);
    try expect(lru.get(2) == null);
}

test "read_can_evict" {
    const allocator = std.testing.allocator;

    var lru = LRU(u64, usize).init(6);
    defer lru.deinit(allocator);

    try lru.put(allocator, 1, 1);
    try lru.put(allocator, 2, 2);
    try lru.put(allocator, 3, 3);
    try lru.put(allocator, 4, 4);
    try lru.put(allocator, 5, 5);
    try lru.put(allocator, 6, 6);

    // Use some of the entries so they become recent.
    try expect(lru.get(1).? == 1);
    try expect(lru.get(2).? == 2);
}

// Threaded use avoids thred leaks and panics
test "threadsafe_concurrency" {
    const allocator = std.testing.allocator;
    var threads: [5]std.Thread = undefined;

    var lru = LRU(usize, usize).init(200);
    defer lru.deinit(allocator);

    for (&threads, 0..) |*thread, i|
        thread.* = try std.Thread.spawn(.{}, lru_thread, .{ allocator, &lru, i });

    for (&threads) |*thread|
        thread.*.join();
}

fn lru_thread(
    allocator: Allocator,
    lru: *LRU(usize, usize),
    value: usize,
) error{OutOfMemory}!void {
    const x: usize = 100 * value;

    for (0..1000) |i| {
        try lru.put(allocator, i + x, value);
        _ = lru.get(i + x);
    }
}

const std = @import("std");
const expect = std.testing.expect;

const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const Mutex = std.Thread.Mutex;
