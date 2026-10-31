//! The empty rival list used when `zig build bench` runs without
//! `-Dcompare`, so the default bench needs nothing from bench/vendor.

/// No rival libraries. See bench/rivals.zig for the adapter shape.
pub const all = .{};
