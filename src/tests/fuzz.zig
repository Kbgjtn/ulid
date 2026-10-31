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
