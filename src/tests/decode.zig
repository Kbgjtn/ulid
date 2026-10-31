const std = @import("std");
const testing = std.testing;
const Ulid = @import("../Ulid.zig");

const example = "01ARZ3NDEKTSV4RRFFQ69G5FAV";

/// Returns `example` with the character at `index` replaced by `c`.
fn withChar(index: usize, c: u8) [Ulid.encoded_len]u8 {
    var text = example.*;
    text[index] = c;
    return text;
}

test "decode rejects wrong length" {
    try testing.expectError(error.UlidInvalidLength, Ulid.decode(example[0..25], .{}));
    try testing.expectError(error.UlidInvalidLength, Ulid.decode(example ++ "0", .{}));
    try testing.expectError(error.UlidInvalidLength, Ulid.decode("", .{}));
}

test "decode spec example" {
    const u = try Ulid.decode(example, .{});
    try testing.expectEqual(@as(u48, 1469922850259), u.timestamp());
    try testing.expectEqual(@as(u80, 0xd6764c61efb99302bd5b), u.randomness());
}

test "decode aliases off rejects I L O U" {
    for ("ILOUilou") |c| {
        const text = withChar(5, c);
        try testing.expectError(error.UlidInvalidCharacter, Ulid.decode(&text, .{}));
    }
}

test "decode aliases on maps I L to 1 and O to 0" {
    const one = try Ulid.decode(&withChar(5, '1'), .{});
    const zero = try Ulid.decode(&withChar(5, '0'), .{});
    for ("IL") |c| {
        try testing.expectEqual(one, try Ulid.decode(&withChar(5, c), .{ .aliases = true }));
    }
    try testing.expectEqual(zero, try Ulid.decode(&withChar(5, 'O'), .{ .aliases = true }));
    for ("ilo", [_]Ulid{ one, one, zero }) |c, want| {
        try testing.expectEqual(want, try Ulid.decode(&withChar(5, c), .{ .aliases = true }));
    }
}

test "decode aliases on still rejects U" {
    for ("Uu") |c| {
        const text = withChar(5, c);
        try testing.expectError(error.UlidInvalidCharacter, Ulid.decode(&text, .{ .aliases = true }));
    }
}

test "decode lowercase on equals uppercase" {
    var lower: [Ulid.encoded_len]u8 = undefined;
    _ = std.ascii.lowerString(&lower, example);
    try testing.expectEqual(try Ulid.decode(example, .{}), try Ulid.decode(&lower, .{}));
}

test "decode lowercase off rejects lowercase" {
    var lower: [Ulid.encoded_len]u8 = undefined;
    _ = std.ascii.lowerString(&lower, example);
    try testing.expectError(error.UlidInvalidCharacter, Ulid.decode(&lower, .{ .lowercase = false }));
    _ = try Ulid.decode(example, .{ .lowercase = false });
}

test "decode rejects first character above 7" {
    for ("89AZz") |c| {
        var text: [Ulid.encoded_len]u8 = @splat('Z');
        text[0] = c;
        try testing.expectError(error.UlidOverflow, Ulid.decode(&text, .{}));
    }
}

test "decode reports errors in order" {
    // Length is checked before any character.
    try testing.expectError(error.UlidInvalidLength, Ulid.decode("8-", .{}));
    // An invalid first character is not an overflow.
    try testing.expectError(error.UlidInvalidCharacter, Ulid.decode(&withChar(0, 'U'), .{}));
    // Overflow on the first character wins over a later invalid one.
    var text = withChar(0, '8');
    text[25] = '-';
    try testing.expectError(error.UlidOverflow, Ulid.decode(&text, .{}));
    // A valid first character lets a later invalid one through.
    try testing.expectError(error.UlidInvalidCharacter, Ulid.decode(&withChar(25, '-'), .{}));
}

test "decode accepts max" {
    const u = try Ulid.decode("7" ++ "Z" ** 25, .{});
    try testing.expectEqual(Ulid{ .bytes = @splat(0xFF) }, u);
}

test "decode rejects other bytes" {
    for ([_]u8{ '-', ' ', 0, 0x80, 0xFF }) |c| {
        for ([_]usize{ 0, 13, 25 }) |i| {
            const text = withChar(i, c);
            try testing.expectError(error.UlidInvalidCharacter, Ulid.decode(&text, .{ .aliases = true }));
        }
    }
}

test "decode round-trips encode" {
    var prng: std.Random.DefaultPrng = .init(0x0123);
    const random = prng.random();
    for (0..1000) |_| {
        var bytes: [16]u8 = undefined;
        random.bytes(&bytes);
        const u: Ulid = .{ .bytes = bytes };
        var text: [Ulid.encoded_len]u8 = undefined;
        u.encode(&text);
        try testing.expectEqual(u, try Ulid.decode(&text, .{ .lowercase = false }));
    }
}

test "decode and encode at comptime" {
    const text = comptime blk: {
        @setEvalBranchQuota(10_000);
        const u = Ulid.decode(example, .{}) catch unreachable;
        var out: [Ulid.encoded_len]u8 = undefined;
        u.encode(&out);
        break :blk out;
    };
    try testing.expectEqualStrings(example, &text);
}
