# ulid

A [ULID](https://github.com/ulid/spec) library for Zig 0.16.0.

A ULID is a 128-bit ID: a 48-bit Unix timestamp in milliseconds, then 80 random bits. IDs sort by creation time, whether you compare their bytes or their text. This library:

- decodes strictly and reports each kind of bad input as its own error;
- never allocates, and encodes and decodes at comptime;
- generates strictly increasing IDs from a clock and random source you can replace in tests;
- converts to and from UUIDv7, and reads and writes `std.json`.

MIT licensed. No dependencies.

## Install

```sh
zig fetch --save https://codeberg.org/Kbgjtn/ulid/archive/<version>.tar.gz
```

In `build.zig`:

```zig
const ulid_dep = b.dependency("ulid", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ulid", ulid_dep.module("ulid"));
```

## Quick start

```zig
const std = @import("std");
const Ulid = @import("ulid");

pub fn main(init: std.process.Init) !void {
    var gen: Ulid.Generator = .{};
    const id = try gen.nextNow(init.io);
    std.debug.print("{f}\n", .{id}); // 01M75H48CMBZ4S09TR80Z45T1Q

    const parsed = try Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{});
    std.debug.print("{d}\n", .{parsed.timestamp()}); // 1469922850259
}
```

## Examples

[`examples/usecases.zig`](examples/usecases.zig) is one runnable file with a function per use case:

1. Generate IDs from the wall clock.
2. Generate unguessable IDs for tokens and public URLs.
3. Generate fixed IDs in tests.
4. Parse user input, with a message per error.
5. Read when an ID was made.
6. Query a time range by ID.
7. Store IDs as 16 raw bytes.
8. Convert to and from UUIDv7.
9. Read and write JSON.
10. Share one generator between tasks.
11. Decode constant IDs at compile time.

Run it with `zig build example`. `zig build test` compiles it, so it always matches the API.

## API

| Declaration | Does | Errors |
|---|---|---|
| `Ulid` | 16 bytes, big-endian: timestamp, then randomness. | |
| `Ulid.init(ms, random)` | Builds an ID from a `u48` timestamp and a `u80` random part. | |
| `timestamp()`, `randomness()` | Return the two parts. | |
| `order(a, b)` | Compares by time, then randomness. Same as comparing bytes or text. | |
| `encode(out)` | Writes the 26-character uppercase text into a `*[26]u8`. | |
| `decode(text, options)` | Parses 26 characters of Crockford base32. | `DecodeError` |
| `"{f}"`, `fmtLower()` | Print uppercase or lowercase text. | |
| `toUuidV7()`, `fmtUuid()` | Return or print the ID as a UUIDv7. | |
| `fromUuidV7(bytes)` | Reads 16 UUIDv7 bytes. | `UuidError` |
| `parseUuidV7(text)` | Reads `8-4-4-4-12` UUID text, either hex case. | `UuidParseError` |
| `Generator.next(ms, random)` | Next ID for a time and RNG you pass in. | `Generator.Error` |
| `Generator.nextNow(io)` | Next ID from the wall clock and `io.random`. | `Generator.Error` |
| `Generator.nextNowSecure(io)` | Next ID from the wall clock and `io.randomSecure`. | `Generator.Error`, `Io.RandomSecureError` |

`std.json` support is through `jsonStringify`, `jsonParse` and `jsonParseFromValue`; you don't call them directly.

## Decoding

`decode` accepts exactly 26 characters and checks them in this order:

1. Wrong length: `error.UlidInvalidLength`.
2. A character outside the alphabet, scanning left to right: `error.UlidInvalidCharacter`.
3. A first character above `7`, which would need more than 128 bits: `error.UlidOverflow`.

`DecodeOptions` controls what counts as a valid character:

- `lowercase` (default `true`): accept `a`-`z`. The spec says decoding ignores case.
- `aliases` (default `false`): read `I` and `L` as `1` and `O` as `0`. Off by default, so one ID has one spelling. `U` is never accepted.

Compared with oklog/ulid v2.1.2 and Rust's [ulid](https://github.com/dylanhart/ulid-rs) crate:

| | this library | oklog `Parse` | oklog `ParseStrict` | Rust `ulid` |
|---|---|---|---|---|
| Lowercase | accepted | accepted | accepted | accepted |
| `I`, `L`, `O` | rejected; mapped with `aliases` | accepted without error | rejected | rejected |
| `U` | rejected | accepted without error | rejected | rejected |
| First character above `7` | `UlidOverflow` | overflow error | overflow error | accepted; the top bits are dropped |
| Clock goes backwards | clamps, or fails with `.fail` | | | clamps |

## Generator

Every ID from one `Generator` is greater than the one before.

- **Later millisecond:** draws a new 80-bit random part.
- **Same millisecond:** adds 1 to the last random part. After 2^80 IDs in one millisecond it returns `error.UlidMonotonicOverflow`.
- **Earlier millisecond:** with `on_backwards = .clamp` (the default), keeps the last timestamp and adds 1. With `.fail`, returns `error.UlidClockBackwards`.
- **Any error** leaves `last` unchanged, so the generator stays usable.

Where the randomness comes from:

| Function | Clock | Randomness |
|---|---|---|
| `next(ms, random)` | yours | yours, for example a seeded `std.Random.DefaultPrng` in tests |
| `nextNow(io)` | `Io.Clock.real` | `io.random`: a per-thread ChaCha generator, seeded from the OS, with a weaker fallback seed if the OS has no entropy |
| `nextNowSecure(io)` | `Io.Clock.real` | `io.randomSecure`: OS entropy, or `error.EntropyUnavailable`; never a fallback |

The clock is clamped to the 48-bit range, which lasts until the year 10889. A call in the same millisecond draws no randomness. A seeded non-cryptographic RNG passed to `next` is faster, but its IDs can be predicted from earlier ones.

`Generator` has no lock. To share one between threads, guard it with a `std.Io.Mutex`; to avoid the lock, give each thread its own generator.

## UUIDv7

A UUIDv7 has the same layout as a ULID, except that 6 of the 80 random bits hold its version and variant.

- `toUuidV7` sets those 6 bits. Converting back gives an ID with the same timestamp but a different random part. IDs from different milliseconds keep their order.
- `fromUuidV7` keeps all 128 bits, and returns `error.UuidNotV7` unless the version is 7 and the variant is RFC 9562's `0b10`.
- `fmtUuid` prints lowercase `8-4-4-4-12` text, such as `017f22e2-79b0-7cc3-98c4-dc0c0c07398f`.
- `parseUuidV7` reads that text in either case. It checks the length (`UuidInvalidLength`), then the hyphens and hex digits (`UuidInvalidCharacter`), then the version and variant (`UuidNotV7`).

## JSON

A `Ulid` reads and writes as its 26-character string, for example as a struct field. Parsing uses the default `DecodeOptions` and allocates nothing. Errors map to `std.json`'s own:

| `decode` error | `std.json` error |
|---|---|
| `UlidInvalidLength` | `LengthMismatch` |
| `UlidInvalidCharacter` | `InvalidCharacter` |
| `UlidOverflow` | `Overflow` |

A JSON value that is not a string returns `UnexpectedToken`.

## Performance

Median ns per operation, lower is better. Zig 0.16.0, ReleaseFast, Ryzen 3 3300X, middle of three runs.

| Case | ulid (this) | [hendriknielaender](https://github.com/hendriknielaender/ulid.zig) | [jkoop](https://github.com/jkoop/ulid-zig) | [leroycep](https://github.com/leroycep/zig-ulid) |
|---|---|---|---|---|
| encode | 6.8 | 8.5 | 6.8 | 9.3 |
| decode | 12.5 | 12.8 | 196 | 35 |
| `next`, same ms | 5.0 | 5.5 | | |
| `next`, new ms, `Io.random` | 25.4 | 23.2 | | |

Differences of about 1 ns are within noise. Encode, decode and same-millisecond `next` are level with the fastest rival; hendriknielaender is about 2 ns faster on a new millisecond. Encode and decode were measured on 2 Nov 2026 pinned to 4 cores, same-millisecond `next` on 10 Nov unpinned, and new-millisecond `next` on 11 Nov pinned to one core.

To reproduce:

```sh
bench/fetch-rivals.sh
zig build bench -Dcompare
```

## Development

| Command | Does |
|---|---|
| `zig build test` | All tests: encode, decode, generator, UUIDv7, JSON, comptime, the oklog vectors, one pass of each fuzz test; also compiles the examples |
| `zig build test -Dllvm --fuzz=1M` | Fuzzes each fuzz test for a million runs (LLVM is needed for coverage) |
| `zig build example` | Runs `examples/usecases.zig` |
| `zig build bench` | Runs the benchmark (ReleaseFast) |

CI runs fmt, build and test in Debug and ReleaseSafe on every push, a short fuzz run per push and a long one nightly.

The reference vectors in `src/tests/vectors_data.zig` come from Go's [oklog/ulid](https://github.com/oklog/ulid) v2 and are checked in both directions. Regenerate them with Go:

```sh
(cd tools && go run .) > src/tests/vectors_data.zig && zig fmt src/tests/vectors_data.zig
```

## License

MIT. See [LICENSE](LICENSE).
