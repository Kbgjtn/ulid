//! Root of `zig build test`. Kept apart from src/Ulid.zig, which is the only
//! source file in the package, so that consumers never load the tests.
test {
    _ = @import("Ulid.zig");
    _ = @import("tests/encode.zig");
    _ = @import("tests/decode.zig");
    _ = @import("tests/generator.zig");
    _ = @import("tests/vectors.zig");
    _ = @import("tests/uuid.zig");
    _ = @import("tests/json.zig");
    _ = @import("tests/fuzz.zig");
}
