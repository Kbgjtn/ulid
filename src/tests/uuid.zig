const std = @import("std");
const testing = std.testing;
const maxInt = std.math.maxInt;
const Ulid = @import("../Ulid.zig");

/// RFC 9562 appendix A.6: the UUIDv7 example for
/// 2022-02-22 19:22:22 UTC (1645557742000 ms).
const rfc_bytes: [16]u8 = .{
    0x01, 0x7F, 0x22, 0xE2, 0x79, 0xB0, 0x7C, 0xC3,
    0x98, 0xC4, 0xDC, 0x0C, 0x0C, 0x07, 0x39, 0x8F,
};
const rfc_text = "017f22e2-79b0-7cc3-98c4-dc0c0c07398f";
/// The same 128 bits in ULID text form.
const rfc_ulid = "01FWHE4YDGFK1SHH6W1G60EECF";

/// Every bit except the version nibble and the variant bits.
const keep_mask: u128 = ~((@as(u128, 0xF) << 76) | (@as(u128, 0b11) << 62));

fn bits(b: [16]u8) u128 {
    return std.mem.readInt(u128, &b, .big);
}

fn expectV7(b: [16]u8) !void {
    try testing.expectEqual(@as(u8, 0x7), b[6] >> 4);
    try testing.expectEqual(@as(u8, 0b10), b[8] >> 6);
}

test "RFC 9562 example converts both ways" {
    const u = try Ulid.fromUuidV7(rfc_bytes);
    try testing.expectEqual(@as(u48, 1645557742000), u.timestamp());
    try testing.expectEqual(rfc_bytes, u.toUuidV7());
    try testing.expectEqual(u, try Ulid.decode(rfc_ulid, .{}));

    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{u.fmtUuid()});
    try testing.expectEqualStrings(rfc_text, s);
}

test "toUuidV7 sets version and variant and keeps every other bit" {
    var prng: std.Random.DefaultPrng = .init(7);
    const cases = [_]Ulid{
        .init(0, 0),
        .init(maxInt(u48), maxInt(u80)),
        .init(1645557742000, prng.random().int(u80)),
        .init(prng.random().int(u48), prng.random().int(u80)),
    };
    for (cases) |u| {
        const b = u.toUuidV7();
        try expectV7(b);
        try testing.expectEqual(bits(u.bytes) & keep_mask, bits(b) & keep_mask);
        try testing.expectEqual(u.timestamp(), (try Ulid.fromUuidV7(b)).timestamp());
    }
}

test "fromUuidV7 then toUuidV7 is the identity" {
    var prng: std.Random.DefaultPrng = .init(8);
    for (0..64) |_| {
        const v = Ulid.init(prng.random().int(u48), prng.random().int(u80)).toUuidV7();
        const u = try Ulid.fromUuidV7(v);
        try testing.expectEqual(v, u.bytes);
        try testing.expectEqual(v, u.toUuidV7());
    }
}

test "toUuidV7 keeps order across different milliseconds" {
    const a: Ulid = .init(1000, maxInt(u80));
    const b: Ulid = .init(1001, 0);
    const ua = try Ulid.fromUuidV7(a.toUuidV7());
    const ub = try Ulid.fromUuidV7(b.toUuidV7());
    try testing.expectEqual(.lt, ua.order(ub));
}

test "fromUuidV7 rejects other versions and variants" {
    const nil: [16]u8 = @splat(0x00);
    const max: [16]u8 = @splat(0xFF);
    var v4 = rfc_bytes;
    v4[6] = (v4[6] & 0x0F) | 0x40;
    var ncs = rfc_bytes; // variant 0b0x
    ncs[8] &= 0x3F;
    var microsoft = rfc_bytes; // variant 0b110
    microsoft[8] = (microsoft[8] & 0x1F) | 0xC0;
    for ([_][16]u8{ nil, max, v4, ncs, microsoft }) |b| {
        try testing.expectError(error.UuidNotV7, Ulid.fromUuidV7(b));
    }
}

test "UUIDv7 conversion works at comptime" {
    const b = comptime (Ulid.decode(rfc_ulid, .{}) catch unreachable).toUuidV7();
    try testing.expectEqual(rfc_bytes, b);
    const u = comptime Ulid.fromUuidV7(rfc_bytes) catch unreachable;
    try testing.expectEqual(@as(u48, 1645557742000), u.timestamp());
}

const rfc_text_upper = "017F22E2-79B0-7CC3-98C4-DC0C0C07398F";

test "parseUuidV7 round-trips the RFC 9562 example" {
    const u = try Ulid.parseUuidV7(rfc_text);
    try testing.expectEqual(try Ulid.fromUuidV7(rfc_bytes), u);
    try testing.expectEqual(u, try Ulid.parseUuidV7(rfc_text_upper));
    const parsed = comptime Ulid.parseUuidV7(rfc_text) catch unreachable;
    try testing.expectEqual(rfc_bytes, parsed.bytes);
}

test "parseUuidV7 rejects a bad length, hyphen, digit, version, or variant" {
    try testing.expectError(error.UuidInvalidLength, Ulid.parseUuidV7("017f22e2"));

    var missing_hyphen: [36]u8 = rfc_text.*;
    missing_hyphen[8] = 'a';
    try testing.expectError(error.UuidInvalidCharacter, Ulid.parseUuidV7(&missing_hyphen));

    var bad_digit: [36]u8 = rfc_text.*;
    bad_digit[0] = 'g';
    try testing.expectError(error.UuidInvalidCharacter, Ulid.parseUuidV7(&bad_digit));

    var bad_version: [36]u8 = rfc_text.*;
    bad_version[14] = '4';
    try testing.expectError(error.UuidNotV7, Ulid.parseUuidV7(&bad_version));

    var bad_variant: [36]u8 = rfc_text.*;
    bad_variant[19] = 'c';
    try testing.expectError(error.UuidNotV7, Ulid.parseUuidV7(&bad_variant));
}

test "parseUuidV7 reports length, then character, then version" {
    // Too long, with a bad character and version 4: the length wins.
    try testing.expectError(error.UuidInvalidLength, Ulid.parseUuidV7("g17f22e2-79b0-4cc3-98c4-dc0c0c07398f0"));
    // Version 4 and a bad last digit: the character wins, wherever it is.
    try testing.expectError(error.UuidInvalidCharacter, Ulid.parseUuidV7("017f22e2-79b0-4cc3-98c4-dc0c0c07398g"));
    // Variant 0b11 and a hyphen moved one place to the right.
    try testing.expectError(error.UuidInvalidCharacter, Ulid.parseUuidV7("017f22e2-79b0-7cc3-c8c4d-c0c0c07398f"));
    try testing.expectError(error.UuidInvalidLength, Ulid.parseUuidV7(""));
    try testing.expectError(error.UuidInvalidLength, Ulid.parseUuidV7("urn:uuid:017f22e2-79b0-7cc3-98c4-dc0c0c07398f"));
    try testing.expectError(error.UuidInvalidLength, Ulid.parseUuidV7("{017f22e2-79b0-7cc3-98c4-dc0c0c07398f}"));
}

test "the UUIDv7 functions return the named error sets" {
    const from = @typeInfo(@typeInfo(@TypeOf(Ulid.fromUuidV7)).@"fn".return_type.?).error_union.error_set;
    const parse = @typeInfo(@typeInfo(@TypeOf(Ulid.parseUuidV7)).@"fn".return_type.?).error_union.error_set;
    try testing.expect(from == Ulid.UuidError);
    try testing.expect(parse == Ulid.UuidParseError);
    try testing.expect(Ulid.UuidParseError == error{ UuidInvalidLength, UuidInvalidCharacter, UuidNotV7 });
}
