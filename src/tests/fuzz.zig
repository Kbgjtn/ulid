//! Fuzz tests. `zig build test` runs each once; `zig build test --fuzz`
//! (optionally `--fuzz=1M`) searches for failures.

const std = @import("std");
const testing = std.testing;
const Smith = testing.Smith;
const maxInt = std.math.maxInt;
const Ulid = @import("../Ulid.zig");
const Generator = Ulid.Generator;

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Bytes biased towards the alphabet, its lowercase form and the aliases,
/// with the rest of the byte range still reachable.
const text_weights: []const Smith.Weight = &.{
    .rangeAtMost(u8, 0x00, 0xff, 1),
    .rangeAtMost(u8, '0', '9', 8),
    .rangeAtMost(u8, 'A', 'Z', 8),
    .rangeAtMost(u8, 'a', 'z', 4),
};

/// The digit value of `c`, or null when `options` rejects it. Written
/// separately from the library's lookup tables so the two can disagree.
fn refDigit(c: u8, options: Ulid.DecodeOptions) ?u5 {
    var u = c;
    if (options.lowercase) u = std.ascii.toUpper(c) else if (std.ascii.isLower(c)) return null;
    if (options.aliases) switch (u) {
        'I', 'L' => return 1,
        'O' => return 0,
        else => {},
    };
    const i = std.mem.indexOfScalar(u8, alphabet, u) orelse return null;
    return @intCast(i);
}

/// A slow, obvious decoder: one 128-bit accumulator, one character at a time.
fn refDecode(text: []const u8, options: Ulid.DecodeOptions) Ulid.DecodeError!Ulid {
    if (text.len != Ulid.encoded_len) return error.UlidInvalidLength;
    var v: u128 = 0;
    for (text, 0..) |c, i| {
        const d = refDigit(c, options) orelse return error.UlidInvalidCharacter;
        if (i == 0 and d > 7) return error.UlidOverflow;
        v = (v << 5) | d;
    }
    var u: Ulid = undefined;
    std.mem.writeInt(u128, &u.bytes, v, .big);
    return u;
}

fn fuzzDecode(_: void, smith: *Smith) anyerror!void {
    var buf: [40]u8 = undefined;
    // Mostly the right length, so the fuzzer spends its time past the length check.
    const len: usize = if (smith.boolWeighted(1, 7))
        Ulid.encoded_len
    else
        smith.valueRangeAtMost(u8, 0, buf.len);
    const text = buf[0..len];
    smith.bytesWeighted(text, text_weights);

    inline for (.{ false, true }) |lowercase| {
        inline for (.{ false, true }) |aliases| {
            const options: Ulid.DecodeOptions = .{ .lowercase = lowercase, .aliases = aliases };
            const want = refDecode(text, options);
            const got = Ulid.decode(text, options);
            if (want) |w| {
                const g = try got;
                try testing.expectEqual(w, g);
                // Encoding gives the canonical form; decoding that is the identity.
                var out: [Ulid.encoded_len]u8 = undefined;
                g.encode(&out);
                try testing.expectEqual(g, try Ulid.decode(&out, .{ .lowercase = false }));
            } else |err| {
                try testing.expectError(err, got);
            }
        }
    }
}

fn fuzzEncode(_: void, smith: *Smith) anyerror!void {
    var u: Ulid = undefined;
    smith.bytes(&u.bytes);
    var out: [Ulid.encoded_len]u8 = undefined;
    u.encode(&out);
    for (out) |c| try testing.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
    try testing.expectEqual(u, try Ulid.decode(&out, .{ .lowercase = false }));
    try testing.expectEqual(u, try refDecode(&out, .{ .lowercase = false }));
}

fn fuzzGenerator(_: void, smith: *Smith) anyerror!void {
    var prng: std.Random.DefaultPrng = .init(smith.value(u64));
    const random = prng.random();

    var g: Generator = .{
        .on_backwards = if (smith.value(bool)) .fail else .clamp,
    };
    var ms: u48 = smith.value(u48);
    // Sometimes start just below the top of the random space to reach overflow.
    if (smith.boolWeighted(3, 1)) {
        g.last = .init(ms, maxInt(u80) - @as(u80, smith.valueRangeAtMost(u8, 0, 4)));
    }

    var steps: u32 = 0;
    while (!smith.eosWeightedSimple(1, 15) and steps < 256) : (steps += 1) {
        const delta = smith.valueRangeAtMost(i8, -2, 2);
        ms = if (delta < 0) ms -| @as(u48, @intCast(-delta)) else ms +| @as(u48, @intCast(delta));

        const before = g.last;
        if (g.next(ms, random)) |u| {
            try testing.expectEqual(u, g.last.?);
            if (before) |b| {
                try testing.expectEqual(.lt, b.order(u));
                try testing.expectEqual(@max(ms, b.timestamp()), u.timestamp());
                if (ms <= b.timestamp()) try testing.expectEqual(b.randomness() + 1, u.randomness());
            } else {
                try testing.expectEqual(ms, u.timestamp());
            }
        } else |err| {
            // A failed call leaves the state alone, and only fails for the
            // two documented reasons.
            try testing.expectEqual(before, g.last);
            const b = before.?;
            switch (err) {
                error.UlidClockBackwards => {
                    try testing.expectEqual(Generator.OnBackwards.fail, g.on_backwards);
                    try testing.expect(ms < b.timestamp());
                },
                error.UlidMonotonicOverflow => {
                    try testing.expect(ms <= b.timestamp());
                    try testing.expectEqual(maxInt(u80), b.randomness());
                },
            }
        }
    }
}

fn fuzzUuid(_: void, smith: *Smith) anyerror!void {
    var raw: [16]u8 = undefined;
    smith.bytes(&raw);

    // Any ULID converts, keeps every bit outside version and variant, and
    // converts back to the same UUID.
    const u: Ulid = .{ .bytes = raw };
    const v = u.toUuidV7();
    try testing.expectEqual(@as(u8, 0x7), v[6] >> 4);
    try testing.expectEqual(@as(u8, 0b10), v[8] >> 6);
    const keep: u128 = ~((@as(u128, 0xF) << 76) | (@as(u128, 0b11) << 62));
    try testing.expectEqual(
        std.mem.readInt(u128, &raw, .big) & keep,
        std.mem.readInt(u128, &v, .big) & keep,
    );
    const back = try Ulid.fromUuidV7(v);
    try testing.expectEqual(v, back.bytes);
    try testing.expectEqual(u.timestamp(), back.timestamp());

    // Raw bytes are accepted exactly when they carry v7's version and variant.
    const is_v7 = raw[6] >> 4 == 0x7 and raw[8] >> 6 == 0b10;
    if (Ulid.fromUuidV7(raw)) |w| {
        try testing.expect(is_v7);
        try testing.expectEqual(raw, w.bytes);
    } else |_| try testing.expect(!is_v7);
}

/// Bytes biased towards hex digits and the hyphen.
const uuid_text_weights: []const Smith.Weight = &.{
    .rangeAtMost(u8, 0x00, 0xff, 1),
    .rangeAtMost(u8, '0', '9', 8),
    .rangeAtMost(u8, 'a', 'f', 8),
    .rangeAtMost(u8, 'A', 'F', 4),
    .value(u8, '-', 4),
};

/// A slow, obvious UUID text parser: check the shape of every position,
/// then collect the hex digits. Written separately from `parseUuidV7`.
fn refParseUuidV7(text: []const u8) error{ UuidInvalidLength, UuidInvalidCharacter, UuidNotV7 }![16]u8 {
    if (text.len != 36) return error.UuidInvalidLength;
    var v: u128 = 0;
    for (text, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return error.UuidInvalidCharacter;
            continue;
        }
        const d = std.fmt.charToDigit(c, 16) catch return error.UuidInvalidCharacter;
        v = (v << 4) | d;
    }
    if ((v >> 76) & 0xF != 0x7 or (v >> 62) & 0b11 != 0b10) return error.UuidNotV7;
    var out: [16]u8 = undefined;
    std.mem.writeInt(u128, &out, v, .big);
    return out;
}

fn fuzzUuidText(_: void, smith: *Smith) anyerror!void {
    var buf: [40]u8 = undefined;
    var len: usize = 36;
    if (smith.boolWeighted(1, 3)) {
        // Well-formed text of random bytes in a random case, then up to two
        // damaged positions, so the fuzzer gets past the shape checks.
        var raw: [16]u8 = undefined;
        smith.bytes(&raw);
        const digits = if (smith.value(bool)) "0123456789abcdef" else "0123456789ABCDEF";
        var i: usize = 0;
        for (raw, 0..) |b, n| {
            if (n == 4 or n == 6 or n == 8 or n == 10) {
                buf[i] = '-';
                i += 1;
            }
            buf[i] = digits[b >> 4];
            buf[i + 1] = digits[b & 0xF];
            i += 2;
        }
        var damage = smith.valueRangeAtMost(u8, 0, 2);
        while (damage > 0) : (damage -= 1) {
            buf[smith.valueRangeAtMost(u8, 0, 35)] = smith.valueWeighted(u8, uuid_text_weights);
        }
    } else {
        if (smith.boolWeighted(7, 1)) len = smith.valueRangeAtMost(u8, 0, buf.len);
        smith.bytesWeighted(buf[0..len], uuid_text_weights);
    }
    const text = buf[0..len];

    const got = Ulid.parseUuidV7(text);
    if (refParseUuidV7(text)) |want| {
        const u = try got;
        try testing.expectEqual(want, u.bytes);
        // Printing gives the lowercase form; parsing that is the identity.
        var out: [36]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try w.print("{f}", .{u.fmtUuid()});
        try testing.expect(std.ascii.eqlIgnoreCase(text, &out));
        try testing.expectEqual(u, try Ulid.parseUuidV7(&out));
    } else |err| {
        try testing.expectError(err, got);
    }
}

/// Printable ASCII other than '"' and '\\', biased towards the alphabet.
const json_text_weights: []const Smith.Weight = &.{
    .rangeAtMost(u8, 0x20, 0x21, 1),
    .rangeAtMost(u8, 0x23, 0x5b, 1),
    .rangeAtMost(u8, 0x5d, 0x7e, 1),
    .rangeAtMost(u8, '0', '9', 8),
    .rangeAtMost(u8, 'A', 'Z', 8),
    .rangeAtMost(u8, 'a', 'z', 4),
};

fn fuzzJson(_: void, smith: *Smith) anyerror!void {
    var text_buf: [40]u8 = undefined;
    const len: usize = if (smith.boolWeighted(1, 7))
        Ulid.encoded_len
    else
        smith.valueRangeAtMost(u8, 0, text_buf.len);
    const text = text_buf[0..len];
    smith.bytesWeighted(text, json_text_weights);

    // The JSON string, with some characters written as \u00XX escapes.
    var src_buf: [2 + 40 * 6]u8 = undefined;
    var n: usize = 0;
    src_buf[n] = '"';
    n += 1;
    for (text) |c| {
        if (smith.boolWeighted(3, 1)) {
            src_buf[n] = c;
            n += 1;
        } else {
            _ = std.fmt.bufPrint(src_buf[n..][0..6], "\\u{x:0>4}", .{c}) catch unreachable;
            n += 6;
        }
    }
    src_buf[n] = '"';
    n += 1;

    // Any allocation fails the parse with OutOfMemory, which the
    // comparison below reports.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const got = std.json.parseFromSliceLeaky(Ulid, failing.allocator(), src_buf[0..n], .{});
    if (Ulid.decode(text, .{})) |want| {
        try testing.expectEqual(want, try got);
    } else |err| {
        try testing.expectError(switch (err) {
            error.UlidInvalidLength => error.LengthMismatch,
            error.UlidInvalidCharacter => error.InvalidCharacter,
            error.UlidOverflow => error.Overflow,
        }, got);
    }
}

test "fuzz decode against a reference decoder" {
    try testing.fuzz({}, fuzzDecode, .{ .corpus = &.{
        "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "7ZZZZZZZZZZZZZZZZZZZZZZZZZ",
        "8ZZZZZZZZZZZZZZZZZZZZZZZZZ",
        "01arz3ndektsv4rrffq69g5fav",
        "OLIARZ3NDEKTSV4RRFFQ69G5FU",
    } });
}

test "fuzz encode round trip" {
    try testing.fuzz({}, fuzzEncode, .{});
}

test "fuzz generator stays monotonic" {
    try testing.fuzz({}, fuzzGenerator, .{});
}

test "fuzz UUIDv7 conversion" {
    try testing.fuzz({}, fuzzUuid, .{});
}

test "fuzz UUIDv7 text parsing against a reference parser" {
    try testing.fuzz({}, fuzzUuidText, .{ .corpus = &.{
        "017f22e2-79b0-7cc3-98c4-dc0c0c07398f",
        "017F22E2-79B0-7CC3-98C4-DC0C0C07398F",
        "017f22e2-79b0-4cc3-98c4-dc0c0c07398f",
        "017f22e2-79b0-7cc3-c8c4-dc0c0c07398f",
        "017f22e279b0-7cc3-98c4-dc0c0c07398f0",
    } });
}

test "fuzz JSON parsing against decode" {
    try testing.fuzz({}, fuzzJson, .{ .corpus = &.{
        "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "01arz3ndektsv4rrffq69g5fav",
        "8ZZZZZZZZZZZZZZZZZZZZZZZZZ",
    } });
}
