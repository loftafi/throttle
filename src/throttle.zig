//! Throttle Lock is an activity counter that can be used to monitor
//! and limit activity such as incoming connections and sign in
//! attempts.
//!
//! # Examples
//!
//! Limit calls to an API to 5 per second, or lockout for one minute
//!
//! ```
//! var counter = Throttle.init(std.time.us_per_s * 1, 5, std.time.us_per_s * 60);
//! if (counter.isThrottled()) {
//!     std.log.warn("Try again later");
//! }
//! ```
//!
//! Limit signin attempts on an email address to 5 per minute, or
//! lockout for 5 minutes.
//!
//! ```
//! var counter = StringThrottleCache.init(std.time.us_per_min * 1, 5, std.time.us_per_m * 5);
//! const email = "john@example.com";
//! if (counter.isThrottled(email)) {
//!     std.log.warn("Try again later");
//! }
//! ```
//!
//! Limit  signin attemps from an IP address to 5 attempts per
//! minute, or lockout for 2 minutes.
//! ```
//! var counter = ThrottleCache.init(i128, std.time.us_per_min * 1, 5, std.time.us_per_min * 2);
//! if (counter.isThrottled(ip_address) {
//!     std.log.warn("Try again later");
//! }
//! ```
//!

/// Throttle is an activity counter that can be used to monitor
/// and limit activity such as incoming connections and sign in
/// attempts.
pub const Throttle = struct {
    interval_duration: i64,
    max_hits_in_interval: i64,
    lockout_duration: i64,
    counter: Counter,

    pub const Counter = struct {
        interval_start: i64,
        current_hit_counter: i64,
        locked_until: i64,

        pub fn destroy(self: *Counter, allocator: Allocator) void {
            allocator.destroy(self);
        }
    };

    /// Within `interval` only allow `max_hits` or the locked status is
    /// set for `lockout_duration`
    pub fn init(interval: i64, max_hits: i64, lockout_duration: i64) Throttle {
        const now = std.time.microTimestamp();
        return .{
            .interval_duration = interval,
            .max_hits_in_interval = max_hits,
            .lockout_duration = lockout_duration,
            .counter = .{
                .interval_start = now,
                .current_hit_counter = 0,
                .locked_until = 0,
            },
        };
    }

    /// When a monitored activity occurs, `isThrottled()` counts that event and
    /// returns `true` if the activity count has exceeded the limit.
    pub fn isThrottled(self: *Throttle) bool {
        self.counter.current_hit_counter += 1;
        var now: i64 = 0;
        if (self.counter.locked_until != 0) {
            now = std.time.microTimestamp();
            if (self.counter.locked_until > now)
                return true;
            self.counter.locked_until = 0;
        }
        if (self.counter.current_hit_counter <= self.max_hits_in_interval)
            return false;

        if (now == 0)
            now = std.time.microTimestamp();

        if (self.counter.locked_until > 0) {
            if (self.counter.locked_until > now)
                return true;

            //println!("reset all");
            self.counter.interval_start = now;
            self.counter.locked_until = 0;
            self.counter.current_hit_counter = 1;
            return false;
        }
        if (now - self.counter.interval_start <= self.interval_duration) {
            self.counter.interval_start = now;
            self.counter.current_hit_counter = 1;
            self.counter.locked_until = now + self.lockout_duration;
            return true;
        }
        self.counter.interval_start = now;
        self.counter.current_hit_counter = 1;
        return false;
    }
};

pub const StringThrottleCache = struct {
    cache: ThrottleCache(u64),

    pub inline fn init(interval: i64, max_hits: i64, lockout_duration: i64) StringThrottleCache {
        return .{
            .cache = .init(interval, max_hits, lockout_duration),
        };
    }

    pub inline fn deinit(self: *StringThrottleCache, allocator: Allocator) void {
        self.cache.deinit(allocator);
    }

    pub inline fn isThrottled(self: *StringThrottleCache, allocator: Allocator, key: []const u8) error{OutOfMemory}!bool {
        const key_hash = std.hash.Wyhash.hash(0, key);
        return self.cache.isThrottled(allocator, key_hash);
    }
};

pub fn ThrottleCache(comptime T: type) type {
    return struct {
        interval_duration: i64 = 0,
        max_hits_in_interval: i64 = 0,
        lockout_duration: i64 = 0,
        counters: LRU(T, *Throttle.Counter),

        const Self = @This();

        /// Within `interval` only allow `max_hits` or the locked status is set for `lockout_duration`
        pub fn init(interval: i64, max_hits: i64, lockout_duration: i64) Self {
            //println!("Maximum {} hits in {} millisconds.\n", max_hits, interval);
            var cache: Self = .{
                .interval_duration = interval,
                .max_hits_in_interval = max_hits,
                .lockout_duration = lockout_duration,
                .counters = LRU(T, *Throttle.Counter).init(10000),
            };
            cache.counters.entry_dealloc = Throttle.Counter.destroy;
            return cache;
        }

        pub inline fn deinit(self: *Self, allocator: Allocator) void {
            self.counters.deinit(allocator);
        }

        /// When a monitored activity occurs, `isThrottled()` counts that event and
        /// returns `true` if the activity count has exceeded the limit.
        pub fn isThrottled(self: *Self, allocator: Allocator, key: T) error{OutOfMemory}!bool {
            var counter: *Throttle.Counter = undefined;

            const entry = self.counters.get(key);
            if (entry != null) {
                counter = entry.?;
            } else {
                const now = std.time.microTimestamp();
                counter = try allocator.create(Throttle.Counter);
                counter.* = .{
                    .interval_start = now,
                    .locked_until = 0,
                    .current_hit_counter = 0,
                };
                _ = try self.counters.put(allocator, key, counter);
            }

            counter.current_hit_counter += 1;
            var now: i64 = 0;
            if (counter.locked_until != 0) {
                now = std.time.microTimestamp();
                if (counter.locked_until > now)
                    return true;

                counter.locked_until = 0;
            }
            if (counter.current_hit_counter <= self.max_hits_in_interval)
                return false;

            if (now == 0)
                now = std.time.microTimestamp();

            if (counter.locked_until > 0) {
                if (counter.locked_until > now)
                    return true;

                counter.interval_start = now;
                counter.locked_until = 0;
                counter.current_hit_counter = 1;
                return false;
            }
            if (now - counter.interval_start <= self.interval_duration) {
                counter.interval_start = now;
                counter.current_hit_counter = 1;
                counter.locked_until = now + self.lockout_duration;
                return true;
            }
            counter.interval_start = now;
            counter.current_hit_counter = 1;
            return false;
        }
    };
}

test "basic" {
    var t = Throttle.init(500, 3, 1000);

    // Slow and study shouldnt locknew
    try expect(!t.isThrottled());
    sleep(us_per_ms * 600);
    try expect(!t.isThrottled());
    sleep(us_per_ms * 600);
    try expect(!t.isThrottled());
    sleep(us_per_ms * 600);
    try expect(!t.isThrottled());
    sleep(us_per_ms * 600);
    try expect(!t.isThrottled());
    sleep(us_per_ms * 600);
    try expect(!t.isThrottled());
    try expect(!t.isThrottled());
    try expect(!t.isThrottled());
    try expect(!t.isThrottled());

    try expect(t.isThrottled()); // Trigger and stay triggered for the lockout time
    sleep(us_per_ms * 300);
    try expect(t.isThrottled());
    sleep(us_per_ms * 300);
    try expect(t.isThrottled());
    sleep(us_per_ms * 500);
    try expect(!t.isThrottled());

    // Check the throttle still works after the last clear
    try expect(!t.isThrottled());
    try expect(!t.isThrottled());
    try expect(t.isThrottled());
    sleep(us_per_ms * 1100);
    try expect(!t.isThrottled());
}

test "test_throttle_key" {
    const allocator = std.testing.allocator;

    var t = StringThrottleCache.init(500, 3, 1000);
    defer t.deinit(allocator);

    const email1 = "bob1@example.com";

    // Slow and study shouldnt lock
    try expect(!try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email1));

    try expect(try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 300);
    try expect(try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 300);
    try expect(try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 500);
    try expect(!try t.isThrottled(allocator, email1));

    // Check the throttle still works after the last clear
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(try t.isThrottled(allocator, email1));
    sleep(us_per_ms * 1100);
    try expect(!try t.isThrottled(allocator, email1));
}

test "test_throttle_key_overlap" {
    const allocator = std.testing.allocator;

    var t = StringThrottleCache.init(500, 3, 1000);
    defer t.deinit(allocator);

    const email1 = "bob1@example.com";
    const email2 = "bob2@example.com";

    // Slow and study shouldnt lock
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 600);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));

    try expect(try t.isThrottled(allocator, email1));
    try expect(try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 300);
    try expect(try t.isThrottled(allocator, email1));
    try expect(try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 300);
    try expect(try t.isThrottled(allocator, email1));
    try expect(try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 500);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));

    // Check the throttle still works after the last clear
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
    try expect(try t.isThrottled(allocator, email1));
    try expect(try t.isThrottled(allocator, email2));
    sleep(us_per_ms * 1100);
    try expect(!try t.isThrottled(allocator, email1));
    try expect(!try t.isThrottled(allocator, email2));
}

const std = @import("std");
const expect = std.testing.expect;
const us_per_ms = std.time.us_per_ms;
const sleep = std.time.sleep;
const Allocator = std.mem.Allocator;

const LRU = @import("lru.zig").LRU;
