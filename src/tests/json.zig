const std = @import("std");
const testing = std.testing;
const json = std.json;
const Ulid = @import("../Ulid.zig");

const text = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
const Record = struct { id: Ulid, n: u8 };

fn parse(src: []const u8) !Ulid {
    const parsed = try json.parseFromSlice(Ulid, testing.allocator, src, .{});
    defer parsed.deinit();
    return parsed.value;
}

test "struct round trip through Stringify and parseFromSlice" {
    const want: Record = .{ .id = try Ulid.decode(text, .{}), .n = 7 };

    const out = try json.Stringify.valueAlloc(testing.allocator, want, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"id\":\"" ++ text ++ "\",\"n\":7}", out);

    const parsed = try json.parseFromSlice(Record, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(want, parsed.value);
}

test "lowercase is accepted" {
    try testing.expectEqual(try Ulid.decode(text, .{}), try parse("\"01arz3ndektsv4rrffq69g5fav\""));
}

test "escaped string goes through the allocated path and is freed" {
    // \u0056 is 'V'. The escape makes the scanner build the string in a
    // buffer. parseFromSliceLeaky has no arena, so if jsonParse didn't free
    // that buffer, testing.allocator would report a leak.
    const u = try json.parseFromSliceLeaky(Ulid, testing.allocator, "\"01ARZ3NDEKTSV4RRFFQ69G5FA\\u0056\"", .{});
    try testing.expectEqual(try Ulid.decode(text, .{}), u);
}

test "non-string values are rejected" {
    try testing.expectError(error.UnexpectedToken, parse("42"));
    try testing.expectError(error.UnexpectedToken, parse("null"));
    try testing.expectError(error.UnexpectedToken, parse("[1,2]"));
}

test "decode errors map to std.json errors" {
    try testing.expectError(error.LengthMismatch, parse("\"01ARZ3\""));
    try testing.expectError(error.InvalidCharacter, parse("\"01ARZ3NDEKTSV4RRFFQ69G5FAU\""));
    try testing.expectError(error.InvalidCharacter, parse("\"O1ARZ3NDEKTSV4RRFFQ69G5FAV\""));
    try testing.expectError(error.Overflow, parse("\"8ZZZZZZZZZZZZZZZZZZZZZZZZZ\""));
}

test "parseFromValue" {
    const want = try Ulid.decode(text, .{});
    const ok = try json.parseFromValue(Ulid, testing.allocator, .{ .string = text }, .{});
    defer ok.deinit();
    try testing.expectEqual(want, ok.value);

    try testing.expectError(error.UnexpectedToken, json.parseFromValue(Ulid, testing.allocator, .{ .integer = 1 }, .{}));
    try testing.expectError(error.LengthMismatch, json.parseFromValue(Ulid, testing.allocator, .{ .string = "01" }, .{}));
}
