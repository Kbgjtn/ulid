const std = @import("std");
const testing = std.testing;
const maxInt = std.math.maxInt;
const Ulid = @import("../Ulid.zig");
const Generator = Ulid.Generator;

const t0: u48 = 1_700_000_000_000;

test "default on_backwards is clamp" {
    const g: Generator = .{};
    try testing.expectEqual(Generator.OnBackwards.clamp, g.on_backwards);
}

test "same millisecond increments randomness" {
    var prng: std.Random.DefaultPrng = .init(1);
    var g: Generator = .{};
    const a = try g.next(t0, prng.random());
    const b = try g.next(t0, prng.random());
    try testing.expectEqual(t0, b.timestamp());
    try testing.expectEqual(a.randomness() + 1, b.randomness());
    try testing.expectEqual(.lt, a.order(b));
}

test "same millisecond carries past a trailing 0xFF byte" {
    var prng: std.Random.DefaultPrng = .init(1);
    const almost: Ulid = .init(t0, 0xFF);
    var g: Generator = .{ .last = almost };
    const u = try g.next(t0, prng.random());
    try testing.expectEqual(t0, u.timestamp());
    try testing.expectEqual(@as(u80, 0x100), u.randomness());
}

test "same millisecond carries through every 0xFF byte" {
    var prng: std.Random.DefaultPrng = .init(1);
    // Two trailing 0xFF bytes: the carry stops at the third byte from the end.
    var g: Generator = .{ .last = .init(t0, 0x12_FFFF) };
    try testing.expectEqual(@as(u80, 0x13_0000), (try g.next(t0, prng.random())).randomness());
    // Nine trailing 0xFF bytes: the carry reaches the first random byte.
    g.last = .init(t0, maxInt(u72));
    const top = try g.next(t0, prng.random());
    try testing.expectEqual(@as(u80, 1) << 72, top.randomness());
    try testing.expectEqual(t0, top.timestamp());
    // One below the maximum still increments; the next call overflows.
    g.last = .init(t0, maxInt(u80) - 1);
    try testing.expectEqual(maxInt(u80), (try g.next(t0, prng.random())).randomness());
    try testing.expectError(error.UlidMonotonicOverflow, g.next(t0, prng.random()));
}

test "monotonic overflow fails and keeps last" {
    var prng: std.Random.DefaultPrng = .init(2);
    const full: Ulid = .init(t0, maxInt(u80));
    var g: Generator = .{ .last = full };
    try testing.expectError(error.UlidMonotonicOverflow, g.next(t0, prng.random()));
    try testing.expectEqual(full, g.last.?);
    // A later millisecond recovers.
    const u = try g.next(t0 + 1, prng.random());
    try testing.expectEqual(t0 + 1, u.timestamp());
}

test "backwards clock fails in fail mode and keeps last" {
    var prng: std.Random.DefaultPrng = .init(3);
    var g: Generator = .{ .on_backwards = .fail };
    const a = try g.next(t0, prng.random());
    try testing.expectError(error.UlidClockBackwards, g.next(t0 - 1, prng.random()));
    try testing.expectEqual(a, g.last.?);
}

test "backwards clock clamps in clamp mode" {
    var prng: std.Random.DefaultPrng = .init(4);
    var g: Generator = .{ .on_backwards = .clamp };
    const a = try g.next(t0, prng.random());
    const b = try g.next(t0 - 5, prng.random());
    try testing.expectEqual(t0, b.timestamp());
    try testing.expectEqual(a.randomness() + 1, b.randomness());
}

test "backwards clock at max randomness reports overflow in clamp mode" {
    var prng: std.Random.DefaultPrng = .init(5);
    const full: Ulid = .init(t0, maxInt(u80));
    var g: Generator = .{ .last = full, .on_backwards = .clamp };
    try testing.expectError(error.UlidMonotonicOverflow, g.next(t0 - 1, prng.random()));
    try testing.expectEqual(full, g.last.?);
}

test "later millisecond draws fresh randomness" {
    var prng: std.Random.DefaultPrng = .init(6);
    var g: Generator = .{};
    const a = try g.next(t0, prng.random());
    const b = try g.next(t0 + 1, prng.random());
    try testing.expectEqual(t0 + 1, b.timestamp());
    // With this seed the fresh draw is not simply a + 1.
    try testing.expect(b.randomness() != a.randomness() +% 1);
}

fn fillCounting(counter: *u8, dest: []u8) void {
    for (dest) |*d| {
        counter.* += 1;
        d.* = counter.*;
    }
}

test "a fresh draw takes 10 bytes and stores them in the order drawn" {
    var counter: u8 = 0;
    const random: std.Random = .{ .ptr = &counter, .fillFn = @ptrCast(&fillCounting) };
    var g: Generator = .{};
    const a = try g.next(t0, random);
    try testing.expectEqual(t0, a.timestamp());
    try testing.expectEqual(@as(u80, 0x0102_0304_0506_0708_090a), a.randomness());
    try testing.expectEqual(10, counter);
    // The same millisecond draws nothing.
    _ = try g.next(t0, random);
    try testing.expectEqual(10, counter);
    const b = try g.next(t0 + 1, random);
    try testing.expectEqual(@as(u80, 0x0b0c_0d0e_0f10_1112_1314), b.randomness());
    try testing.expectEqual(20, counter);
}

test "first call uses given time" {
    var prng: std.Random.DefaultPrng = .init(7);
    var g: Generator = .{};
    const u = try g.next(0, prng.random());
    try testing.expectEqual(@as(u48, 0), u.timestamp());
    try testing.expectEqual(u, g.last.?);
}

// `nextNow` and `nextNowSecure` clamp the wall clock into 0 .. maxInt(u48)
// before they call `next`, so these pin what a generator does at both ends.

test "millisecond 0 is a valid timestamp and increments" {
    var prng: std.Random.DefaultPrng = .init(10);
    var g: Generator = .{};
    const a = try g.next(0, prng.random());
    try testing.expectEqual(@as(u48, 0), a.timestamp());
    const b = try g.next(0, prng.random());
    try testing.expectEqual(@as(u48, 0), b.timestamp());
    try testing.expectEqual(a.randomness() + 1, b.randomness());
}

test "the last millisecond increments and keeps its timestamp" {
    var prng: std.Random.DefaultPrng = .init(11);
    var g: Generator = .{ .last = .init(maxInt(u48), 0) };
    const u = try g.next(maxInt(u48), prng.random());
    try testing.expectEqual(maxInt(u48), u.timestamp());
    try testing.expectEqual(@as(u80, 1), u.randomness());
}

test "the last millisecond at max randomness overflows on every call" {
    var prng: std.Random.DefaultPrng = .init(12);
    const top: Ulid = .init(maxInt(u48), maxInt(u80));
    var g: Generator = .{ .last = top };
    for (0..2) |_| {
        try testing.expectError(error.UlidMonotonicOverflow, g.next(maxInt(u48), prng.random()));
        try testing.expectEqual(top, g.last.?);
    }
}

test "seeded generator is repeatable" {
    var p1: std.Random.DefaultPrng = .init(8);
    var p2: std.Random.DefaultPrng = .init(8);
    var g1: Generator = .{};
    var g2: Generator = .{};
    for (0..100) |i| {
        const ms = t0 + @as(u48, @intCast(i / 3));
        try testing.expectEqual(try g1.next(ms, p1.random()), try g2.next(ms, p2.random()));
    }
}

test "10k ids with a jittery clock are strictly increasing" {
    var prng: std.Random.DefaultPrng = .init(9);
    const random = prng.random();
    var g: Generator = .{ .on_backwards = .clamp };
    var ms = t0;
    var prev = try g.next(ms, random);
    for (0..10_000) |_| {
        switch (random.uintLessThan(u8, 10)) {
            0...5 => {}, // same millisecond
            6...8 => ms += random.uintAtMost(u48, 3) + 1,
            else => ms -= random.uintAtMost(u48, 2) + 1, // clock steps back
        }
        const u = try g.next(ms, random);
        try testing.expectEqual(.lt, prev.order(u));
        prev = u;
    }
}

fn nowMs(io: std.Io) i64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_ms));
}

test "nextNow uses the wall clock" {
    const io = testing.io;
    var g: Generator = .{};
    const before = nowMs(io);
    const u = try g.nextNow(io);
    const after = nowMs(io);
    const ts: i64 = u.timestamp();
    try testing.expect(ts >= before and ts <= after);
}

test "nextNow burst is strictly increasing" {
    const io = testing.io;
    var g: Generator = .{};
    var prev = try g.nextNow(io);
    for (0..10_000) |_| {
        const u = try g.nextNow(io);
        try testing.expectEqual(std.math.Order.lt, prev.order(u));
        prev = u;
    }
}

test "nextNow then next on the same ms increments" {
    const io = testing.io;
    var g: Generator = .{};
    var prng: std.Random.DefaultPrng = .init(1);
    const a = try g.nextNow(io);
    const b = try g.next(a.timestamp(), prng.random());
    try testing.expectEqual(a.timestamp(), b.timestamp());
    try testing.expectEqual(std.math.Order.lt, a.order(b));
}

const SecureScript = struct {
    ms: i64,
    bytes: [10]u8 = @splat(0),
    calls: u32 = 0,
    fail: bool = false,

    fn io(self: *SecureScript) std.Io {
        const storage = struct {
            var vtable: std.Io.VTable = undefined;
            var ready = false;
        };
        if (!storage.ready) {
            storage.vtable = testing.io.vtable.*;
            storage.vtable.now = scriptNow;
            storage.vtable.randomSecure = scriptSecure;
            storage.ready = true;
        }
        return .{ .userdata = self, .vtable = &storage.vtable };
    }
};

fn scriptNow(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    const self: *SecureScript = @ptrCast(@alignCast(userdata));
    return .{ .nanoseconds = @as(i96, self.ms) * std.time.ns_per_ms };
}

fn scriptSecure(userdata: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    const self: *SecureScript = @ptrCast(@alignCast(userdata));
    self.calls += 1;
    if (self.fail) return error.EntropyUnavailable;
    @memcpy(buffer, &self.bytes);
}

const secure_bytes = [10]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a };

test "nextNowSecure fails closed when entropy is unavailable" {
    var script: SecureScript = .{ .ms = t0, .fail = true };
    var g: Generator = .{};
    try testing.expectError(error.EntropyUnavailable, g.nextNowSecure(script.io()));
    try testing.expectEqual(null, g.last);
    try testing.expectEqual(1, script.calls);
}

test "nextNowSecure does not draw again in the same millisecond" {
    var script: SecureScript = .{ .ms = t0, .bytes = secure_bytes };
    var g: Generator = .{};
    const a = try g.nextNowSecure(script.io());
    script.fail = true;
    const b = try g.nextNowSecure(script.io());
    try testing.expectEqual(a.timestamp(), b.timestamp());
    try testing.expectEqual(a.randomness() + 1, b.randomness());
    try testing.expectEqual(1, script.calls);
    try testing.expectEqual(std.mem.readInt(u80, &secure_bytes, .big), a.randomness());
}

test "nextNowSecure draws again on a later millisecond" {
    var script: SecureScript = .{ .ms = t0, .bytes = secure_bytes };
    var g: Generator = .{};
    _ = try g.nextNowSecure(script.io());

    const later: i64 = t0 + 5;
    const later_bytes = [10]u8{ 0x0a, 0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 };
    script.ms = later;
    script.bytes = later_bytes;
    const u = try g.nextNowSecure(script.io());
    try testing.expectEqual(@as(u48, @intCast(later)), u.timestamp());
    try testing.expectEqual(std.mem.readInt(u80, &later_bytes, .big), u.randomness());
    try testing.expectEqual(2, script.calls);
}

test "nextNowSecure does not draw when a backwards clock fails" {
    var script: SecureScript = .{ .ms = t0, .bytes = secure_bytes };
    var g: Generator = .{ .on_backwards = .fail };
    const a = try g.nextNowSecure(script.io());
    script.ms = t0 - 1;
    script.fail = true;
    try testing.expectError(error.UlidClockBackwards, g.nextNowSecure(script.io()));
    try testing.expectEqual(a, g.last.?);
    try testing.expectEqual(1, script.calls);
}
