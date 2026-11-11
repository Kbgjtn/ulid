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

/// Parses `src` with an allocator that fails on its first allocation, so
/// any allocation on the way, by std.json or by `jsonParse`, is an error.
fn parseNoAlloc(src: []const u8) !Ulid {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    return json.parseFromSliceLeaky(Ulid, failing.allocator(), src, .{});
}

test "an escaped string parses without allocating" {
    // \u0056 is 'V'. The escape makes the scanner hand the string over in
    // pieces, which used to be joined in an allocated buffer.
    try testing.expectEqual(try Ulid.decode(text, .{}), try parseNoAlloc("\"01ARZ3NDEKTSV4RRFFQ69G5FA\\u0056\""));
    // Every character escaped.
    try testing.expectEqual(try Ulid.decode(text, .{}), try parseNoAlloc(
        "\"\\u0030\\u0031\\u0041\\u0052\\u005A\\u0033\\u004E\\u0044\\u0045\\u004B" ++
            "\\u0054\\u0053\\u0056\\u0034\\u0052\\u0052\\u0046\\u0046\\u0051\\u0036" ++
            "\\u0039\\u0047\\u0035\\u0046\\u0041\\u0056\"",
    ));
}

test "a string split across reader buffers parses without allocating" {
    // Three reads, each ending inside the string, through a 4-byte buffer.
    var io_reader: std.testing.Reader = .init(&.{}, &.{
        .{ .buffer = "\"01ARZ3ND" },
        .{ .buffer = "EKTSV4RRFFQ" },
        .{ .buffer = "69G5FAV\"" },
    });
    var buf: [4]u8 = undefined;
    io_reader.interface.buffer = &buf;
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var reader: json.Reader = .init(failing.allocator(), &io_reader.interface);
    defer reader.deinit();
    const u = try json.parseFromTokenSourceLeaky(Ulid, failing.allocator(), &reader, .{});
    try testing.expectEqual(try Ulid.decode(text, .{}), u);
}

test "a string longer than a ULID is a length mismatch" {
    try testing.expectError(error.LengthMismatch, parseNoAlloc("\"01ARZ3NDEKTSV4RRFFQ69G5FAV01ARZ3NDEKTSV4\""));
    // 27 bytes once the escape is resolved.
    try testing.expectError(error.LengthMismatch, parseNoAlloc("\"01ARZ3NDEKTSV4RRFFQ69G5FAV\\u0030\""));
    // A syntax error past byte 26 is still the scanner's.
    try testing.expectError(error.SyntaxError, parseNoAlloc("\"01ARZ3NDEKTSV4RRFFQ69G5FAV\\q\""));
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
