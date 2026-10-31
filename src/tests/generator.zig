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

test "first call uses given time" {
    var prng: std.Random.DefaultPrng = .init(7);
    var g: Generator = .{};
    const u = try g.next(0, prng.random());
    try testing.expectEqual(@as(u48, 0), u.timestamp());
    try testing.expectEqual(u, g.last.?);
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
