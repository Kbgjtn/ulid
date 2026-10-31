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

/// Decodes exactly `@bitSizeOf(T) / 5` characters into a T, left to right.
/// No branch in the loop body: invalid entries are 0xFF, and valid digits are
/// < 32, so OR-ing every digit into `bad` and checking once at the end is enough.
fn decodeChunk(
    comptime T: type,
    t: *const [256]u8,
    chars: *const [@bitSizeOf(T) / 5]u8,
) DecodeError!T {
    // Accumulate in a u64: odd widths like u45 would truncate every step.
    var v: u64 = 0;
    var bad: u8 = 0;
    for (chars) |c| {
        const d = t[c];
        bad |= d;
        v = (v << 5) | d;
    }
    if (bad >= 32) return error.UlidInvalidCharacter;
    return @truncate(v);
}

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

    // Character 0 carries only the top 3 bits of the 48-bit timestamp.
    // Check it first (invalid character, then overflow), before any shifting.
    const d0 = t[text[0]];
    if (d0 == invalid) return error.UlidInvalidCharacter;
    if (d0 > 7) return error.UlidOverflow;

    // Three independent dependency chains, each fits in one 64-bit register.
    const ts_rest = try decodeChunk(u45, t, text[1..10]); // chars 1..9  -> 45 bits
    const rnd_hi = try decodeChunk(u40, t, text[10..18]); // chars 10..17 -> 40 bits
    const rnd_lo = try decodeChunk(u40, t, text[18..26]); // chars 18..25 -> 40 bits

    const ts: u64 = (@as(u64, d0) << 45) | ts_rest;

    // Pack the 128 bits into two u64 halves and store each with one byte
    // swap, instead of three odd-width big-endian writes.
    const hi: u64 = (ts << 16) | (@as(u64, rnd_hi) >> 24);
    const lo: u64 = (@as(u64, rnd_hi) << 40) | rnd_lo;

    var u: Ulid = undefined;
    std.mem.writeInt(u64, u.bytes[0..8], hi, .big);
    std.mem.writeInt(u64, u.bytes[8..16], lo, .big);
    return u;
}

/// Returns `ulid` as an RFC 9562 UUIDv7: the same 16 bytes with the version
/// nibble (byte 6, high 4 bits) set to 7 and the variant (byte 8, top 2
/// bits) set to `0b10`. This overwrites 6 of the 80 random bits, so
/// `fromUuidV7(u.toUuidV7())` is not `u` unless those bits already matched.
/// The timestamp is unchanged.
pub fn toUuidV7(ulid: Ulid) [16]u8 {
    var b = ulid.bytes;
    b[6] = (b[6] & 0x0F) | 0x70;
    b[8] = (b[8] & 0x3F) | 0x80;
    return b;
}

/// Reads a UUIDv7 as a ULID. Both use a 48-bit big-endian millisecond
/// timestamp first, so the bytes are copied unchanged and nothing is lost.
/// Returns `error.UuidNotV7` unless the version is 7 and the variant is
/// the RFC 9562 one (`0b10`).
pub fn fromUuidV7(bytes: [16]u8) error{UuidNotV7}!Ulid {
    if (bytes[6] >> 4 != 0x07) return error.UuidNotV7;
    if (bytes[8] >> 6 != 0b10) return error.UuidNotV7;
    return .{ .bytes = bytes };
}

/// Writes `u` as a UUIDv7 in the lowercase `8-4-4-4-12` hex form, after
/// the same conversion as `toUuidV7`. See `fmtUuid`.
pub fn formatUuid(u: Ulid, w: *Io.Writer) Io.Writer.Error!void {
    const hex = "0123456789abcdef";
    const b = u.toUuidV7();

    var buf: [36]u8 = undefined;
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[o] = '-';
            o += 1;
        }
        buf[o] = hex[byte >> 4];
        buf[o + 1] = hex[byte & 0x0F];
        o += 2;
    }

    try w.writeAll(&buf);
}

/// Returns a value that prints `u` as a UUIDv7 with `"{f}"`. See `formatUuid`.
pub fn fmtUuid(u: Ulid) std.fmt.Alt(Ulid, formatUuid) {
    return .{ .data = u };
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
        // Update last in place, so the same-ms path touches only the
        // random bytes instead of copying the whole optional out and back.
        if (g.last) |*last| {
            const last_ts = std.mem.readInt(u48, last.bytes[0..6], .big);
            if (ms > last_ts) {
                last.* = Ulid.init(ms, random.int(u80));
                return last.*;
            }
            if (ms < last_ts and g.on_backwards == .fail) return error.UlidClockBackwards;
            // Same ms, or a clamped backwards clock: increment the random part.
            const r, const overflow = @addWithOverflow(std.mem.readInt(u80, last.bytes[6..16], .big), 1);
            if (overflow != 0) return error.UlidMonotonicOverflow;
            std.mem.writeInt(u80, last.bytes[6..16], r, .big);
            return last.*;
        }
        g.last = Ulid.init(ms, random.int(u80));
        return g.last.?;
    }
};
