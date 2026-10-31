//! Checks the oklog/ulid/v2 vectors in vectors_data.zig in both directions.
const std = @import("std");
const testing = std.testing;
const Ulid = @import("../Ulid.zig");
const vectors = @import("vectors_data.zig").vectors;

test "vectors decode and encode" {
    try testing.expect(vectors.len > 100);
    for (vectors) |v| {
        const want: Ulid = .{ .bytes = v.bytes };
        try testing.expectEqual(want, try Ulid.decode(v.text, .{ .lowercase = false }));
        var out: [Ulid.encoded_len]u8 = undefined;
        want.encode(&out);
        try testing.expectEqualStrings(v.text, &out);
    }
}
