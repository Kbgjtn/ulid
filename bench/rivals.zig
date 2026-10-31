//! Adapters that give each rival Zig ULID library the shape bench/main.zig
//! expects, so every library runs the same cases on the same inputs.
//! Used by `zig build bench -Dcompare`; bench/fetch-rivals.sh clones the
//! libraries into bench/vendor at the commits benched.
//!
//! Each adapter declares `name`, `Native` (the library's ULID type),
//! `fromUlid`, `toUlid` and `encode`. It may also declare `decode`,
//! `decodeAliases` and a `Generator` with `init` and `next`, and sets
//! `rng_injectable` when its generator takes a caller's `std.Random`.
//! Adapters panic on errors so that every library pays the same for them.
const std = @import("std");
const Io = std.Io;
const Ulid = @import("ulid");

/// Every rival that builds on Zig 0.16, in table order.
pub const all = .{ Hendrik, Jkoop, Leroycep };

fn int(u: Ulid) u128 {
    return std.mem.readInt(u128, &u.bytes, .big);
}

fn fromInt(v: u128) Ulid {
    var u: Ulid = undefined;
    std.mem.writeInt(u128, &u.bytes, v, .big);
    return u;
}

/// hendriknielaender/ulid.zig. Its decode rejects the Crockford aliases,
/// and its generator always draws from `io.random`.
const Hendrik = struct {
    const lib = @import("hendrik");

    pub const name = "hendriknielaender/ulid.zig";
    pub const Native = lib.Ulid;
    pub const rng_injectable = false;

    pub fn fromUlid(u: Ulid) Native {
        return .{ .timestamp_ms = u.timestamp(), .randomness = u.bytes[6..].* };
    }

    pub fn toUlid(x: Native) Ulid {
        var u: Ulid = undefined;
        std.mem.writeInt(u48, u.bytes[0..6], @intCast(x.timestamp_ms), .big);
        u.bytes[6..].* = x.randomness;
        return u;
    }

    pub fn encode(x: *const Native, out: *[Ulid.encoded_len]u8) void {
        x.encode_to(out);
    }

    pub fn decode(text: *const [Ulid.encoded_len]u8) Native {
        var x: Native = undefined;
        Native.decode(text, &x) catch |err| @panic(@errorName(err));
        return x;
    }

    pub const Generator = struct {
        g: lib.UlidGenerator,
        io: Io,

        pub fn init(io: Io, random: std.Random) Generator {
            _ = random;
            return .{ .g = Native.monotonic_factory(), .io = io };
        }

        pub fn next(gen: *Generator, ms: u48) Native {
            return gen.g.next(gen.io, .{ .timestamp_ms = ms }) catch |err| @panic(@errorName(err));
        }
    };
};

/// jkoop/ulid-zig. Its decode always accepts lowercase and the aliases.
/// Its generator reads `std.time.milliTimestamp`, which Zig 0.16 removed,
/// so only the codec is benched.
const Jkoop = struct {
    const lib = @import("jkoop");

    pub const name = "jkoop/ulid-zig";
    pub const Native = lib.Ulid;

    pub fn fromUlid(u: Ulid) Native {
        return @enumFromInt(int(u));
    }

    pub fn toUlid(x: Native) Ulid {
        return fromInt(@intFromEnum(x));
    }

    pub fn encode(x: *const Native, out: *[Ulid.encoded_len]u8) void {
        _ = x.toString(out);
    }

    pub fn decode(text: *const [Ulid.encoded_len]u8) Native {
        return Native.fromString(text) catch |err| @panic(@errorName(err));
    }

    pub const decodeAliases = decode;
};

/// leroycep/zig-ulid. Its decode always accepts lowercase, the aliases
/// and '-' separators. Its generator uses `std.rand`, which Zig 0.16
/// removed, so only the codec is benched.
const Leroycep = struct {
    const lib = @import("leroycep");

    pub const name = "leroycep/zig-ulid";
    pub const Native = lib;

    pub fn fromUlid(u: Ulid) Native {
        return .{ .value = int(u) };
    }

    pub fn toUlid(x: Native) Ulid {
        return fromInt(x.value);
    }

    pub fn encode(x: *const Native, out: *[Ulid.encoded_len]u8) void {
        out.* = x.encodeBase32();
    }

    pub fn decode(text: *const [Ulid.encoded_len]u8) Native {
        return Native.decodeBase32(text) catch |err| @panic(@errorName(err));
    }

    pub const decodeAliases = decode;
};
