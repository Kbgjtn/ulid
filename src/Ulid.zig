//! A 128-bit ULID: a 48-bit Unix time in milliseconds followed by 80
//! random bits, stored big-endian so byte order is time order.
const std = @import("std");
const Io = std.Io;

const Ulid = @This();

/// The 16 bytes of the ULID, big-endian: the timestamp, then the randomness.
bytes: [16]u8,

/// The length of the text form in Crockford base32 characters.
pub const encoded_len = 26;

/// Returns the ULID made of the timestamp `ms` and the random part `random`.
pub fn init(ms: u48, random: u80) Ulid {
    var u: Ulid = undefined;
    std.mem.writeInt(u128, &u.bytes, @as(u128, ms) << 80 | random, .big);
    return u;
}

fn int(u: Ulid) u128 {
    return std.mem.readInt(u128, &u.bytes, .big);
}

/// Returns the Unix time in milliseconds stored in the first 48 bits.
pub fn timestamp(u: Ulid) u48 {
    return @truncate(u.int() >> 80);
}

/// Returns the random part stored in the last 80 bits.
pub fn randomness(u: Ulid) u80 {
    return @truncate(u.int());
}

/// Compares two ULIDs by time, then by randomness. This is the same as
/// comparing their bytes or their text forms.
pub fn order(a: Ulid, b: Ulid) std.math.Order {
    return std.mem.order(u8, &a.bytes, &b.bytes);
}

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Writes the 26-character uppercase text form of `u` to `dest`.
/// The first character is always in '0'...'7'.
pub fn encode(u: Ulid, dest: *[encoded_len]u8) void {
    var v = u.int();
    var i: usize = encoded_len;
    while (i > 0) {
        i -= 1;
        dest[i] = alphabet[@as(u5, @truncate(v))];
        v >>= 5;
    }
}

/// Writes the canonical uppercase text form of `u`, the same 26 bytes as
/// `encode`, so `"{f}"` prints a ULID. Like other `format` methods, it
/// ignores width and fill: print into a buffer and use `"{s:>30}"` to pad.
pub fn format(u: Ulid, w: *Io.Writer) Io.Writer.Error!void {
    var buf: [encoded_len]u8 = undefined;
    u.encode(&buf);
    try w.writeAll(&buf);
}

/// Returns a value that prints `u` in lowercase with `"{f}"`.
/// `decode` accepts that form back with the default options.
pub fn fmtLower(u: Ulid) std.fmt.Alt(Ulid, formatLower) {
    return .{ .data = u };
}

/// Writes the lowercase text form of `u`. See `fmtLower`.
pub fn formatLower(u: Ulid, w: *Io.Writer) Io.Writer.Error!void {
    var buf: [encoded_len]u8 = undefined;
    u.encode(&buf);
    for (&buf) |*c| c.* = std.ascii.toLower(c.*);
    try w.writeAll(&buf);
}

pub const DecodeError = error{
    /// The text is not exactly `encoded_len` bytes long.
    UlidInvalidLength,
    /// A byte is not in the Crockford alphabet allowed by `DecodeOptions`.
    UlidInvalidCharacter,
    /// The first character is above '7', so the value needs more than 128 bits.
    UlidOverflow,
};

/// Which inputs `decode` accepts besides the uppercase Crockford alphabet.
pub const DecodeOptions = struct {
    /// Accept a-z as well as A-Z. The spec says decoding ignores case.
    lowercase: bool = true,
    /// Accept Crockford aliases: I, L = 1 and O = 0. U is never accepted.
    aliases: bool = false,
};

const invalid: u8 = 0xFF;

fn makeTable(comptime lowercase: bool, comptime aliases: bool) [256]u8 {
    @setEvalBranchQuota(8 << 10);
    var t = [_]u8{invalid} ** 256;
    for (alphabet, 0..) |c, i| {
        t[c] = i;
        if (lowercase and c >= 'A' and c <= 'Z') t[c + ('a' - 'A')] = i;
    }

    if (aliases) {
        t['I'] = 1;
        t['L'] = 1;
        t['O'] = 0;
        if (lowercase) {
            t['i'] = 1;
            t['l'] = 1;
            t['o'] = 0;
        }
    }
    // 'U' is deliberately absent from Crockford's alphabet and is never an alias.
    return t;
}

// Indexed as tables[@intFromBool(lowercase)][@intFromBool(aliases)].
const tables = blk: {
    var all: [2][2][256]u8 = undefined;
    for (0..2) |l| {
        for (0..2) |a| {
            all[l][a] = makeTable(l == 1, a == 1);
        }
    }
    break :blk all;
};

/// Parses the 26-character text form of a ULID. Allocates nothing and
/// works at comptime.
///
/// The length is checked first, and a wrong length returns
/// `error.UlidInvalidLength`. Characters are then checked left to right,
/// and the first one outside the alphabet chosen by `options` returns
/// `error.UlidInvalidCharacter`. Only the first character can return
/// `error.UlidOverflow`, when it is a valid character above '7'.
pub fn decode(text: []const u8, options: DecodeOptions) DecodeError!Ulid {
    if (text.len != encoded_len) return error.UlidInvalidLength;
    const t = &tables[@intFromBool(options.lowercase)][@intFromBool(options.aliases)];
    // 26 * 5 = 130 bits, so the first char may only carry the top 3 bits.
    const first = t[text[0]];
    if (first == invalid) return error.UlidInvalidCharacter;
    if (first > 7) return error.UlidOverflow;
    var v: u128 = first;
    for (text[1..]) |c| {
        const d = t[c];
        if (d == invalid) return error.UlidInvalidCharacter;
        v = (v << 5) | @as(u128, d);
    }
    var u: Ulid = undefined;
    std.mem.writeInt(u128, &u.bytes, v, .big);
    return u;
}

/// A monotonic ULID generator. Each ULID it returns is greater than every
/// earlier one it returned. The caller passes in the time and the random
/// source, so tests can use a fixed clock and a seeded RNG.
///
/// Not thread-safe: share one between threads only behind a lock.
pub const Generator = struct {
    /// The last ULID returned. It may be set by hand to resume a sequence,
    /// and a failed `next` leaves it unchanged.
    last: ?Ulid = null,
    /// What `next` does when `ms` is earlier than the last timestamp.
    /// Defaults to `.clamp`, like Rust's `ulid` crate, so a clock that
    /// steps back keeps producing ordered IDs instead of errors.
    on_backwards: OnBackwards = .clamp,

    pub const Error = error{
        /// The clock went backwards and `on_backwards` is `.fail`.
        UlidClockBackwards,
        /// The random part is already at its maximum within this timestamp.
        UlidMonotonicOverflow,
    };

    pub const OnBackwards = enum {
        /// Return error.UlidClockBackwards.
        fail,
        /// Keep the last timestamp and increment the random part.
        clamp,
    };

    /// Returns a ULID greater than every earlier one from this generator.
    ///
    /// A timestamp `ms` later than the last one draws a fresh random part
    /// from `random`. The same timestamp increments the last random part
    /// by one, and returns `error.UlidMonotonicOverflow` if it is already
    /// at its maximum. An earlier `ms` is handled as `on_backwards` says.
    /// On error, `last` is unchanged.
    pub fn next(g: *Generator, ms: u48, random: std.Random) Error!Ulid {
        const result = if (g.last) |last| blk: {
            const last_ts = last.timestamp();
            if (ms > last_ts) {
                break :blk Ulid.init(ms, random.int(u80));
            } else if (ms == last_ts) {
                break :blk try bump(last);
            } else switch (g.on_backwards) {
                .fail => return error.UlidClockBackwards,
                .clamp => break :blk try bump(last),
            }
        } else Ulid.init(ms, random.int(u80));

        // Only reached on success, so errors above leave g.last untouched.
        g.last = result;
        return result;
    }

    fn bump(last: Ulid) Error!Ulid {
        const r, const overflow = @addWithOverflow(last.randomness(), 1);
        if (overflow != 0) return error.UlidMonotonicOverflow;
        return Ulid.init(last.timestamp(), r);
    }
};

test {
    _ = @import("tests/encode.zig");
    _ = @import("tests/decode.zig");
    _ = @import("tests/generator.zig");
}
