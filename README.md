# ulid

A [ULID](https://github.com/ulid/spec) library for Zig. A ULID is a 128-bit identifier whose bytes and text both sort by the time it was made. This library decodes strictly, never allocates, and generates monotonic IDs from a clock and random source that the caller passes in.

Requires Zig 0.16.0. MIT licensed.

## Features

- **Layout.** A `Ulid` is 16 big-endian bytes: a 48-bit Unix time in milliseconds, then 80 random bits. Comparing the bytes, the text or `order` gives the same time order.
- **Strict decoding.** Exactly 26 characters of Crockford base32. Each failure has its own error, reported in a fixed order. A first character above `7`, which would need more than 128 bits, is an error rather than silently truncated.
- **No allocation.** `encode` writes into a `*[26]u8` and `decode` returns the value. Both work at comptime.
- **Monotonic generator.** Within one millisecond the random part is incremented by one. Running out of random values is an error that leaves the generator usable. The time and the `std.Random` are arguments, so tests can fix both.
- **Formatting.** `"{f}"` prints the canonical uppercase form and `fmtLower` the lowercase one.
- **UUIDv7 conversion.** `toUuidV7`, `fromUuidV7` and `fmtUuid` convert to and from RFC 9562 UUIDv7.
- **JSON.** `std.json` reads and writes a `Ulid` as its 26-character string. Parsing uses the default decoding rules, and errors map to `std.json`'s `LengthMismatch`, `InvalidCharacter` and `Overflow`.
- **Reference vectors.** 190 values generated with Go's [oklog/ulid](https://github.com/oklog/ulid) v2 are checked in both directions.

## Installation

Fetch the package.

```sh
zig fetch --save https://codeberg.org/Kbgjtn/ulid/archive/<version>.tar.gz
```

Add the module in `build.zig`:

```zig
const ulid_dep = b.dependency("ulid", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ulid", ulid_dep.module("ulid"));
```

## Examples

```zig
const std = @import("std");
const Ulid = @import("ulid");
```

Generate a ULID from the system clock and print it in both cases:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gen: Ulid.Generator = .{};
    const id = try gen.nextNow(io);

    var buf: [64]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try stdout.interface.print("{f} {f}\n", .{ id, id.fmtLower() });
    try stdout.interface.flush();
}
```

`nextNow` reads `Clock.real` (Unix time in milliseconds, clamped to 48 bits, which lasts until the year 10889) and draws randomness from `io.random`. To pick the clock or RNG yourself, call `next(ms, random)` instead.

In tests, pass a fixed time and a seeded generator:

```zig
test "same millisecond, fixed seed" {
    var prng: std.Random.DefaultPrng = .init(42);
    var gen: Ulid.Generator = .{};
    const a = try gen.next(1_700_000_000_000, prng.random());
    const b = try gen.next(1_700_000_000_000, prng.random());
    try std.testing.expectEqual(a.randomness() + 1, b.randomness());
}
```

Decode with options, and encode into a buffer:

```zig
/// Returns the ULID in `text`, or null if it is not one. Accepts I, L and O
/// as Crockford aliases for 1, 1 and 0.
fn parse(text: []const u8) ?Ulid {
    return Ulid.decode(text, .{ .aliases = true }) catch |err| switch (err) {
        error.UlidInvalidLength, error.UlidInvalidCharacter, error.UlidOverflow => null,
    };
}

/// Writes the canonical text of `id` to `out` and returns its timestamp.
fn canonical(id: Ulid, out: *[Ulid.encoded_len]u8) u48 {
    id.encode(out);
    return id.timestamp();
}
```

Decoding works at comptime:

```zig
const example = Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{}) catch unreachable;

test "decoded at comptime" {
    try std.testing.expectEqual(@as(u48, 1469922850259), example.timestamp());
}
```

## Decoding rules

The spec leaves several cases open, and libraries disagree on them. This library picks:

- **Lowercase is accepted** (`DecodeOptions.lowercase = true`), since the spec says decoding ignores case. Set it to `false` to accept only the canonical uppercase form.
- **Aliases are off** (`DecodeOptions.aliases = false`). Crockford base32 allows reading `I` and `L` as `1` and `O` as `0`, but accepting them by default would let two different strings mean one ID. `U` is never accepted.
- **A backwards clock clamps** (`Generator.on_backwards = .clamp`). If `ms` is earlier than the last timestamp, the generator keeps the last timestamp and increments the random part, so IDs stay ordered. `.fail` returns `error.UlidClockBackwards` instead.

`decode` checks the length first (`UlidInvalidLength`), then the characters from left to right (`UlidInvalidCharacter`). Only the first character can give `UlidOverflow`. Any error from `Generator.next` leaves `last` unchanged.

Compared with oklog/ulid v2.1.2 and Rust's [ulid](https://github.com/dylanhart/ulid-rs) crate:

| | this library | oklog `Parse` | oklog `ParseStrict` | Rust `ulid` |
|---|---|---|---|---|
| Lowercase | accepted | accepted | accepted | accepted |
| `I`, `L`, `O` | rejected; mapped with `aliases` | accepted without error | rejected | rejected |
| `U` | rejected | accepted without error | rejected | rejected |
| First character above `7` | `UlidOverflow` | overflow error | overflow error | accepted; the top bits are dropped |
| Clock goes backwards | clamps, or fails with `.fail` | | | clamps |

## UUIDv7

A ULID and a UUIDv7 share their layout: a 48-bit big-endian millisecond timestamp followed by 80 bits, of which UUIDv7 spends 6 on its version and variant.

- `fromUuidV7` keeps all 128 bits. It returns `error.UuidNotV7` unless the version is 7 and the variant is RFC 9562's `0b10`.
- `toUuidV7` sets those 6 bits, overwriting 6 random bits, so converting back gives a different ULID with the same timestamp. IDs from different milliseconds keep their order.
- `"{f}"` with `fmtUuid` prints the lowercase `8-4-4-4-12` form, such as `017f22e2-79b0-7cc3-98c4-dc0c0c07398f`.

## Thread safety

`Generator` has no lock on purpose, so single-threaded code pays nothing for one. To share a generator between threads, guard it with a `std.Io.Mutex`. For independent IDs, give each thread its own generator.

## Performance

Median ns per operation, lower is better. Measured on 2 Nov 2026 with Zig 0.16.0, ReleaseFast, on a Ryzen 3 3300X pinned to 4 cores, taking the middle of three runs.

| Case | ulid (this) | [hendriknielaender](https://github.com/hendriknielaender/ulid.zig) | [jkoop](https://github.com/jkoop/ulid-zig) | [leroycep](https://github.com/leroycep/zig-ulid) |
|---|---|---|---|---|
| encode | 6.8 | 8.5 | 6.8 | 9.3 |
| decode | 12.5 | 12.8 | 196 | 35 |
| `next`, same ms | 7.2 | 5.3 | | |
| `next`, new ms, `Io.random` | 26.2 | 23.5 | | |

Encode ties jkoop, and decode is level with hendriknielaender, since differences of about 1 ns are within this bench's noise. Same-millisecond `next` is still behind hendriknielaender's.

A SWAR decode was tried and dropped because it ran slower (13.4 to 16.8 ns). The 26 table lookups dominate decode time, not the shifts that combine the digits.

To reproduce, fetch the other libraries and run the bench:

```sh
bench/fetch-rivals.sh
zig build bench -Dcompare
```

## Testing

| Command | Runs |
|---|---|
| `zig build test` | Encode, decode, generator, UUIDv7, JSON and comptime tests, the oklog vectors, and one pass of each fuzz test |
| `zig build test -Dllvm --fuzz=1M` | The fuzz tests for a million runs, shared between them (LLVM is needed for coverage) |

CI (`.github/workflows/`) runs fmt, build and test in Debug and ReleaseSafe on every push, plus a short fuzz run per push and a long one nightly.

The vectors in `src/tests/vectors_data.zig` are generated by `tools/gen-vectors.go`, which needs Go:

```sh
(cd tools && go run .) > src/tests/vectors_data.zig && zig fmt src/tests/vectors_data.zig
```

## License

MIT. See [LICENSE](LICENSE).
