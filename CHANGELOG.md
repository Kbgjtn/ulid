# Changelog

## 0.3.0 - 2026-11-11

### Added

- `parseUuidV7` parses UUIDv7 text.
- `Generator.nextNowSecure` uses `io.randomSecure` and fails with `error.EntropyUnavailable` instead of falling back.
- `UuidError` and `UuidParseError` error sets.

### Changed

- **Breaking:** a seeded `std.Random` now gives different IDs from `next`. Order is unchanged.
- `jsonParse` no longer allocates. Strings longer than 26 bytes return `error.LengthMismatch`.
- `next` is faster within the same millisecond (7.2 to 5.0 ns).

### Fixed

- README: each fuzz test gets the full `--fuzz=N` limit.

## 0.2.0 - 2026-11-02

### Added

- `Generator.nextNow` reads the wall clock and `io.random`.
- UUIDv7 conversion: `toUuidV7`, `fromUuidV7` and `fmtUuid`.
- `std.json` support: a `Ulid` reads and writes as its 26-character string.

### Changed

- Faster `decode` (13.9 to 12.6 ns) and same-millisecond `next` (8.7 to 7.5 ns).

## 0.1.0 - 2026-10-31

- First release: the `Ulid` type, strict Crockford base32 `encode` and `decode`, and a monotonic `Generator`.
