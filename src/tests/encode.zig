const std = @import("std");
const testing = std.testing;
const Ulid = @import("../Ulid.zig");

fn encoded(u: Ulid) [Ulid.encoded_len]u8 {
    var out: [Ulid.encoded_len]u8 = undefined;
    u.encode(&out);
    return out;
}

test "encode zero" {
    const out = encoded(.{ .bytes = @splat(0) });
    try testing.expectEqualStrings("0" ** 26, &out);
}

test "encode max" {
    const out = encoded(.{ .bytes = @splat(0xFF) });
    try testing.expectEqualStrings("7" ++ "Z" ** 25, &out);
}

test "encode spec example" {
    const u: Ulid = .init(1469922850259, 0xd6764c61efb99302bd5b);
    const out = encoded(u);
    try testing.expectEqualStrings("01ARZ3NDEKTSV4RRFFQ69G5FAV", &out);
}

test "init round-trips timestamp and randomness" {
    const cases = [_]struct { ms: u48, random: u80 }{
        .{ .ms = 0, .random = 0 },
        .{ .ms = 1, .random = 1 },
        .{ .ms = std.math.maxInt(u48), .random = 0 },
        .{ .ms = 0, .random = std.math.maxInt(u80) },
        .{ .ms = std.math.maxInt(u48), .random = std.math.maxInt(u80) },
        .{ .ms = 1469922850259, .random = 0xd6764c61efb99302bd5b },
    };
    for (cases) |c| {
        const u: Ulid = .init(c.ms, c.random);
        try testing.expectEqual(c.ms, u.timestamp());
        try testing.expectEqual(c.random, u.randomness());
    }
}

test "init stores big-endian bytes" {
    const u: Ulid = .init(0x0102030405_06, 0x0708090a0b0c0d0e0f10);
    try testing.expectEqualSlices(u8, &.{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
    }, &u.bytes);
}

test "order follows byte order" {
    const a: Ulid = .init(1, std.math.maxInt(u80));
    const b: Ulid = .init(2, 0);
    try testing.expectEqual(.lt, a.order(b));
    try testing.expectEqual(.gt, b.order(a));
    try testing.expectEqual(.eq, a.order(a));
}

test "format matches encode" {
    const u: Ulid = .init(1469922850259, 0xd6764c61efb99302bd5b);
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{u});
    const out = encoded(u);
    try testing.expectEqualStrings(&out, text);
}

test "format with allocPrint" {
    const u: Ulid = .init(1469922850259, 0xd6764c61efb99302bd5b);
    const text = try std.fmt.allocPrint(testing.allocator, "id={f}.", .{u});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("id=01ARZ3NDEKTSV4RRFFQ69G5FAV.", text);
}

test "format ignores width" {
    const u: Ulid = .init(1469922850259, 0xd6764c61efb99302bd5b);
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f:>30}", .{u});
    try testing.expectEqualStrings("01ARZ3NDEKTSV4RRFFQ69G5FAV", text);
}

test "fmtLower prints lowercase and decodes back" {
    const u: Ulid = .init(1469922850259, 0xd6764c61efb99302bd5b);
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{u.fmtLower()});
    try testing.expectEqualStrings("01arz3ndektsv4rrffq69g5fav", text);
    try testing.expectEqual(u, try Ulid.decode(text, .{}));
}
