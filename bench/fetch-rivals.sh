#!/bin/sh
# Clones the rival Zig ULID libraries that `zig build bench -Dcompare`
# runs against into bench/vendor, each pinned to the commit benched.
# bench/vendor is gitignored and never part of the package.
set -eu
cd "$(dirname "$0")"
mkdir -p vendor

fetch() {
    dir="vendor/$1"
    if [ ! -d "$dir/.git" ]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$2"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$3"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    echo "$1 $(git -C "$dir" rev-parse --short HEAD)"
}

fetch hendriknielaender-ulid.zig https://github.com/hendriknielaender/ulid.zig debff99b8693a9bcf59a2387f0fc683ef0a69c6b
fetch jkoop-ulid-zig https://github.com/jkoop/ulid-zig f6ca9f83687aabda291cd6211733d4f4971e03c3
fetch leroycep-zig-ulid https://github.com/leroycep/zig-ulid 63d1146d6d7b36f35622d8c946a938495484b82c
